//
//  SongLibrary.swift
//  Woodshed
//
//  Manages the song library on disk. Each song is a self-contained folder under
//  Application Support/Woodshed/Scores/<uuid>/ with its MusicXML, MIDI, and a
//  metadata.json. The library is just a scan of those folders — no database.
//  (See docs/DECISIONS.md ADR-018.)
//

import Foundation
import Combine

final class SongLibrary: ObservableObject {
    @Published private(set) var songs: [Song] = []

    /// Application Support/Woodshed/Scores
    let scoresDir: URL

    init() {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                 in: .userDomainMask, appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        scoresDir = base.appendingPathComponent("Woodshed/Scores", isDirectory: true)
        try? FileManager.default.createDirectory(at: scoresDir, withIntermediateDirectories: true)
        seedBundledFixturesIfEmpty()
        reload()
    }

    /// Rescan the scores directory and rebuild `songs` (sorted by title).
    /// A folder whose `metadata.json` is missing or unreadable is NOT silently
    /// skipped (that made a song vanish from the list while its files sat on disk —
    /// e.g. after a kill mid-write): if the score files are present we **recover** it
    /// with rebuilt metadata; otherwise it's surfaced via `unreadableFolderCount`.
    func reload() {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: scoresDir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        var loaded: [Song] = []
        var unreadable = 0
        for dir in dirs {
            let isDir = (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDir else { continue }
            let metaURL = dir.appendingPathComponent("metadata.json")
            if let data = try? Data(contentsOf: metaURL),
               let meta = try? Self.decoder.decode(SongMeta.self, from: data) {
                loaded.append(Song(meta: meta, folder: dir))
            } else if let meta = recoverMeta(in: dir) {
                loaded.append(Song(meta: meta, folder: dir))
            } else {
                unreadable += 1     // no score files either — surface, don't hide
            }
        }
        unreadableFolderCount = unreadable
        songs = loaded.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// Folders in Scores/ that couldn't be read *or* recovered (shown in the library).
    @Published private(set) var unreadableFolderCount = 0

    /// Rebuild metadata for a folder whose metadata.json is missing/corrupt but whose
    /// score files survive. Reuses the folder's UUID name if it has one (keeps the
    /// song's identity stable) and writes the recovered file back.
    private func recoverMeta(in dir: URL) -> SongMeta? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.appendingPathComponent("score.musicxml").path),
              fm.fileExists(atPath: dir.appendingPathComponent("score.mid").path) else { return nil }
        let id = UUID(uuidString: dir.lastPathComponent) ?? UUID()
        let added = ((try? fm.attributesOfItem(atPath: dir.path))?[.creationDate] as? Date) ?? Date()
        let meta = SongMeta(id: id, title: "Recovered song", composer: nil, dateAdded: added)
        try? writeMeta(meta, in: dir)
        return meta
    }

    /// Import a MusicXML + MIDI pair into a new song folder. `title` defaults to the
    /// MusicXML file's name.
    @discardableResult
    func importSong(musicXML: URL, midi: URL, title: String? = nil) throws -> Song {
        let id = UUID()
        let folder = scoresDir.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try copyIn(musicXML, to: folder.appendingPathComponent("score.musicxml"))
        try copyIn(midi, to: folder.appendingPathComponent("score.mid"))
        let name = (title ?? musicXML.deletingPathExtension().lastPathComponent)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let meta = SongMeta(id: id, title: name.isEmpty ? "Untitled" : name, composer: nil, dateAdded: Date())
        try writeMeta(meta, in: folder)
        reload()
        return songs.first { $0.id == id } ?? Song(meta: meta, folder: folder)
    }

    /// Delete a song and all its files.
    func delete(_ song: Song) {
        try? FileManager.default.removeItem(at: song.folder)
        reload()
    }

    /// Persist a metadata change (rename, favourite, practice data, …).
    func update(_ meta: SongMeta, in folder: URL) {
        try? writeMeta(meta, in: folder)
        reload()
    }

    /// Record a finished Grade pass: append it to the song's history and bump the
    /// derived stats shown in the library (last-practiced, best full-piece accuracy).
    /// Updates just this one song in place — no full rescan (this fires every loop).
    func recordPass(_ pass: PracticePass, for song: Song) {
        PracticeHistory.append(pass, to: song.folder)
        guard let idx = songs.firstIndex(where: { $0.id == song.id }) else { return }
        var meta = songs[idx].meta
        meta.lastPracticed = pass.date
        if pass.isFullPiece { meta.bestAccuracy = max(meta.bestAccuracy ?? 0, pass.accuracy) }
        songs[idx].meta = meta
        try? writeMeta(meta, in: songs[idx].folder)
    }

    /// Remember this song's measures-per-system layout choice (0 = auto). Updates the
    /// one song in place; skips the write if unchanged.
    func setBarsPerLine(_ n: Int, for song: Song) {
        guard let idx = songs.firstIndex(where: { $0.id == song.id }) else { return }
        let stored = n == 0 ? nil : n
        guard songs[idx].meta.barsPerLine != stored else { return }
        var meta = songs[idx].meta
        meta.barsPerLine = stored
        songs[idx].meta = meta
        try? writeMeta(meta, in: songs[idx].folder)
    }

    /// Wipe a song's recorded practice history and the derived stats (for a fresh start).
    func resetProgress(for song: Song) {
        try? FileManager.default.removeItem(at: PracticeHistory.fileURL(in: song.folder))
        guard let idx = songs.firstIndex(where: { $0.id == song.id }) else { return }
        var meta = songs[idx].meta
        meta.lastPracticed = nil
        meta.bestAccuracy = nil
        songs[idx].meta = meta
        try? writeMeta(meta, in: songs[idx].folder)
    }

    // MARK: - Helpers

    private func copyIn(_ src: URL, to dst: URL) throws {
        let scoped = src.startAccessingSecurityScopedResource()   // harmless now (sandbox off); future-proof
        defer { if scoped { src.stopAccessingSecurityScopedResource() } }
        if FileManager.default.fileExists(atPath: dst.path) { try FileManager.default.removeItem(at: dst) }
        try FileManager.default.copyItem(at: src, to: dst)
    }

    private func writeMeta(_ meta: SongMeta, in folder: URL) throws {
        // .atomic = write to a temp file, then rename — a kill mid-write can never
        // leave a truncated metadata.json behind.
        try Self.encoder.encode(meta).write(to: folder.appendingPathComponent("metadata.json"),
                                            options: .atomic)
    }

    /// On first launch (empty library), seed the two bundled fixtures so the app
    /// isn't empty. Once the user manages their own songs these never re-appear.
    private func seedBundledFixturesIfEmpty() {
        let existing = (try? FileManager.default.contentsOfDirectory(atPath: scoresDir.path)) ?? []
        guard existing.isEmpty else { return }
        for name in ["Fly Me To the Moon", "chopin-nocturne-op-9-no-2-e-flat-major"] {
            guard let xml = bundleURL(name, "musicxml"), let mid = bundleURL(name, "mid") else { continue }
            _ = try? importSong(musicXML: xml, midi: mid, title: name)
        }
    }

    private func bundleURL(_ name: String, _ ext: String) -> URL? {
        Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "Scores")
            ?? Bundle.main.url(forResource: name, withExtension: ext)
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; e.dateEncodingStrategy = .iso8601; return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }()
}
