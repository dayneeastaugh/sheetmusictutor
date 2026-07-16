//
//  SongLibrary.swift
//  Woodshed
//
//  Manages the song library on disk. Each song is a self-contained folder under
//  Application Support/Segno/Scores/<uuid>/ with its MusicXML, MIDI, and a
//  metadata.json. The library is just a scan of those folders — no database.
//  (See docs/DECISIONS.md ADR-018.)
//

import Foundation
import Combine

final class SongLibrary: ObservableObject {
    @Published private(set) var songs: [Song] = []
    /// Set when a durable metadata write fails (disk full, permissions). Surfaced as an
    /// alert so a lost rename/favourite/best-score isn't silent. Cleared when shown.
    @Published var writeError: String?

    /// Application Support/Segno/Scores
    let scoresDir: URL

    init() {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory,
                                in: .userDomainMask, appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let newDir = base.appendingPathComponent("Segno/Scores", isDirectory: true)
        let oldDir = base.appendingPathComponent("Woodshed/Scores", isDirectory: true)

        // One-time migration from the app's former name (Woodshed → Segno): move the
        // library folder across if only the old one exists. A same-volume directory
        // rename is atomic; if it fails, fall back to reading in place so a rename can
        // never lose the user's imported songs.
        if !fm.fileExists(atPath: newDir.path), fm.fileExists(atPath: oldDir.path) {
            try? fm.createDirectory(at: newDir.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.moveItem(at: oldDir, to: newDir)
        }
        if fm.fileExists(atPath: newDir.path) {
            scoresDir = newDir
        } else if fm.fileExists(atPath: oldDir.path) {
            scoresDir = oldDir                     // migration didn't take — keep the data in place
        } else {
            scoresDir = newDir                     // fresh install
        }
        try? fm.createDirectory(at: scoresDir, withIntermediateDirectories: true)
        seedBundledFixturesIfEmpty()
        seedTechnicalPracticeIfMissing()
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
            if dir.lastPathComponent.hasPrefix(".") { continue }   // skip .Trash and other dot-folders
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
        writeMeta(meta, in: dir)
        return meta
    }

    /// Import a MusicXML + MIDI pair into a new song folder. `title` defaults to the
    /// MusicXML file's name. A compressed `.mxl` is accepted and extracted — MuseScore's
    /// default MusicXML export — so the user needn't remember to export uncompressed.
    @discardableResult
    func importSong(musicXML: URL, midi: URL, title: String? = nil) throws -> Song {
        let id = UUID()
        let folder = scoresDir.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if musicXML.pathExtension.lowercased() == "mxl" {
            let scoped = musicXML.startAccessingSecurityScopedResource()
            defer { if scoped { musicXML.stopAccessingSecurityScopedResource() } }
            let extracted = try MXLArchive.extractScore(from: try Data(contentsOf: musicXML))
            try extracted.write(to: folder.appendingPathComponent("score.musicxml"), options: .atomic)
        } else {
            try copyIn(musicXML, to: folder.appendingPathComponent("score.musicxml"))
        }
        try copyIn(midi, to: folder.appendingPathComponent("score.mid"))
        let name = (title ?? musicXML.deletingPathExtension().lastPathComponent)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let meta = SongMeta(id: id, title: name.isEmpty ? "Untitled" : name, composer: nil, dateAdded: Date())
        writeMeta(meta, in: folder)
        reload()
        return songs.first { $0.id == id } ?? Song(meta: meta, folder: folder)
    }

    /// Delete a song. **Soft-delete** so a mis-tap is recoverable: on macOS it goes to
    /// the system Trash (restore in Finder); otherwise it's moved into an in-library
    /// `.Trash/` folder (skipped by `reload`). This is the most destructive action in
    /// the app — the folder holds the score AND all recorded history/takes/flags — so
    /// it must be reversible, and the UI confirms first.
    func delete(_ song: Song) {
        let fm = FileManager.default
        #if os(macOS)
        if (try? fm.trashItem(at: song.folder, resultingItemURL: nil)) != nil { reload(); return }
        #endif
        let trash = scoresDir.appendingPathComponent(".Trash", isDirectory: true)
        try? fm.createDirectory(at: trash, withIntermediateDirectories: true)
        let dest = trash.appendingPathComponent(song.folder.lastPathComponent, isDirectory: true)
        try? fm.removeItem(at: dest)                              // clear any prior trashed copy
        if (try? fm.moveItem(at: song.folder, to: dest)) == nil {
            try? fm.removeItem(at: song.folder)                  // last resort: hard delete
        }
        reload()
    }

    /// Persist a metadata change (rename, favourite, practice data, …).
    func update(_ meta: SongMeta, in folder: URL) {
        writeMeta(meta, in: folder)
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
        // "Best" tracks Grade accuracy only — a Wait walkthrough is a different metric.
        if pass.isFullPiece && pass.mode == "grade" {
            meta.bestAccuracy = max(meta.bestAccuracy ?? 0, pass.accuracy)
        }
        songs[idx].meta = meta
        writeMeta(meta, in: songs[idx].folder)
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
        writeMeta(meta, in: songs[idx].folder)
    }

    /// Remember this song's engraving scale (1.0 = default). In-place, like barsPerLine.
    func setScoreZoom(_ z: Double, for song: Song) {
        guard let idx = songs.firstIndex(where: { $0.id == song.id }) else { return }
        let stored: Double? = abs(z - 1.0) < 0.001 ? nil : z
        guard songs[idx].meta.scoreZoom != stored else { return }
        var meta = songs[idx].meta
        meta.scoreZoom = stored
        songs[idx].meta = meta
        writeMeta(meta, in: songs[idx].folder)
    }

    /// Move a song between the Repertoire and Technical practice groups.
    func setCategory(_ category: SongCategory, for song: Song) {
        guard let idx = songs.firstIndex(where: { $0.id == song.id }) else { return }
        var meta = songs[idx].meta
        meta.category = category
        songs[idx].meta = meta
        writeMeta(meta, in: songs[idx].folder)
        reload()
    }

    /// Wipe a song's recorded practice history and the derived stats (for a fresh start).
    func resetProgress(for song: Song) {
        try? FileManager.default.removeItem(at: PracticeHistory.fileURL(in: song.folder))
        try? FileManager.default.removeItem(at: PassReportStore.fileURL(in: song.folder))
        guard let idx = songs.firstIndex(where: { $0.id == song.id }) else { return }
        var meta = songs[idx].meta
        meta.lastPracticed = nil
        meta.bestAccuracy = nil
        songs[idx].meta = meta
        writeMeta(meta, in: songs[idx].folder)
    }

    // MARK: - Backup / export

    /// A .zip of one song's folder (score + all its history/takes/flags) in a temp
    /// file, for backup or moving to another device. Restore is manual for now: unzip
    /// and drop the folder into the library's Scores/ directory (the app scans it).
    func exportURL(for song: Song) -> URL? {
        zipDirectory(song.folder, named: Self.safeFileName(song.title))
    }

    /// A .zip of the whole library (every song folder, excluding the Trash). Staged
    /// into a cleanly-named temp folder first so the archive's top level reads well.
    func exportLibraryURL() -> URL? {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("Segno Library-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        for song in songs {
            try? fm.copyItem(at: song.folder, to: staging.appendingPathComponent(song.folder.lastPathComponent))
        }
        return zipDirectory(staging, named: "Segno Library")
    }

    /// Zip a directory with `NSFileCoordinator`'s `.forUploading` option (the built-in,
    /// dependency-free way to archive a folder on Apple platforms), then copy the
    /// system temp zip to a stably-named file the exporter can hand off.
    private func zipDirectory(_ dir: URL, named name: String) -> URL? {
        var result: URL?
        var coordError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: dir, options: [.forUploading], error: &coordError) { zipTmp in
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent(name).appendingPathExtension("zip")
            try? FileManager.default.removeItem(at: dest)
            do { try FileManager.default.copyItem(at: zipTmp, to: dest); result = dest }
            catch { result = nil }
        }
        return result
    }

    /// A filesystem-safe version of a song title for the export filename.
    static func safeFileName(_ s: String) -> String {
        let cleaned = s.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>")).joined(separator: "-")
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Song" : trimmed
    }

    // MARK: - Helpers

    private func copyIn(_ src: URL, to dst: URL) throws {
        let scoped = src.startAccessingSecurityScopedResource()   // harmless now (sandbox off); future-proof
        defer { if scoped { src.stopAccessingSecurityScopedResource() } }
        if FileManager.default.fileExists(atPath: dst.path) { try FileManager.default.removeItem(at: dst) }
        try FileManager.default.copyItem(at: src, to: dst)
    }

    /// Persist metadata. .atomic = temp-file-then-rename, so a kill mid-write can never
    /// leave a truncated metadata.json. A failure (disk full, permissions) is captured
    /// into `writeError` and surfaced — not swallowed, since this is durable user data
    /// (rename, favourite, category, and the best/last stats bumped after each pass).
    private func writeMeta(_ meta: SongMeta, in folder: URL) {
        do {
            try Self.encoder.encode(meta).write(to: folder.appendingPathComponent("metadata.json"),
                                                options: .atomic)
        } catch {
            writeError = "Couldn’t save “\(meta.title)”. Your change may be lost — check free disk space. (\(error.localizedDescription))"
        }
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

    /// Seed the bundled technical-practice books (Major/Minor scale sets) once —
    /// even into an existing library — carrying their category + pre-named per-scale
    /// sections. Gated by a version flag so it doesn't return after the user deletes
    /// them, and can be re-run for a future content version by bumping the key.
    private func seedTechnicalPracticeIfMissing() {
        let key = "seededTechnicalScalesV1"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        for (base, title) in [("MajorScales", "Major Scales"), ("MinorScales", "Minor Scales")] {
            guard let xml = bundleURL(base, "musicxml"), let mid = bundleURL(base, "mid") else { continue }
            let id = UUID()
            let folder = scoresDir.appendingPathComponent(id.uuidString, isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try copyIn(xml, to: folder.appendingPathComponent("score.musicxml"))
                try copyIn(mid, to: folder.appendingPathComponent("score.mid"))
                if let sections = bundleURL("\(base)-sections", "json") {
                    try? copyIn(sections, to: SavedSectionStore.fileURL(in: folder))   // one section per scale
                }
                var meta = SongMeta(id: id, title: title, composer: nil, dateAdded: Date())
                meta.category = .technical
                writeMeta(meta, in: folder)
            } catch { continue }
        }
        UserDefaults.standard.set(true, forKey: key)
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
