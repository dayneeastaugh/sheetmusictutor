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
    func reload() {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: scoresDir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        var loaded: [Song] = []
        for dir in dirs {
            let isDir = (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDir else { continue }
            let metaURL = dir.appendingPathComponent("metadata.json")
            guard let data = try? Data(contentsOf: metaURL),
                  let meta = try? Self.decoder.decode(SongMeta.self, from: data) else { continue }
            loaded.append(Song(meta: meta, folder: dir))
        }
        songs = loaded.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
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

    // MARK: - Helpers

    private func copyIn(_ src: URL, to dst: URL) throws {
        let scoped = src.startAccessingSecurityScopedResource()   // harmless now (sandbox off); future-proof
        defer { if scoped { src.stopAccessingSecurityScopedResource() } }
        if FileManager.default.fileExists(atPath: dst.path) { try FileManager.default.removeItem(at: dst) }
        try FileManager.default.copyItem(at: src, to: dst)
    }

    private func writeMeta(_ meta: SongMeta, in folder: URL) throws {
        try Self.encoder.encode(meta).write(to: folder.appendingPathComponent("metadata.json"))
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
