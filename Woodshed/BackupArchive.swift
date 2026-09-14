//
//  BackupArchive.swift
//  Woodshed
//
//  Restore a library backup (.zip made by "Export library…" / "Export…"). The
//  missing half of the backup story (audit 06 suggestion 4): a backup you can't
//  restore is a promise, not a feature.
//
//  Reuses MXLArchive's dependency-free ZIP reader. The flow is PREVIEWED: the
//  archive is inventoried (validated against its manifest when one is present),
//  the user picks songs, and duplicates are restored as COPIES with fresh ids —
//  an existing song is never overwritten.
//

import SwiftUI

/// One song found inside a backup archive.
struct BackupSong: Identifiable, Equatable {
    var id: String              // the folder name inside the archive
    var title: String
    var fileCount: Int
    var hasScorePair: Bool      // score + MIDI present (restorable)
    var alreadyInLibrary: Bool  // same folder exists → restore makes a copy
}

enum BackupArchive {
    struct Inventory {
        var songs: [BackupSong]
        /// Folder names the manifest promises but the archive doesn't contain —
        /// evidence of a truncated/incomplete backup, surfaced before restoring.
        var missingFromArchive: [String]
        var hasManifest: Bool
    }

    /// Common root prefix ("Segno Library-…/") the zipper wraps entries in, if any.
    private static func rootPrefix(_ names: [String]) -> String {
        if let m = names.first(where: { $0.hasSuffix("/manifest.json") }) {
            return String(m.dropLast("manifest.json".count))
        }
        if names.contains("manifest.json") { return "" }
        let firsts = Set(names.compactMap { $0.split(separator: "/").first })
        return firsts.count == 1 ? firsts.first! + "/" : ""
    }

    private struct ManifestEntry: Codable { var id: UUID; var title: String; var folder: String }

    /// Inventory a backup zip without writing anything.
    static func inventory(zip: Data, existingFolders: Set<String>) throws -> Inventory {
        let entries = try MXLArchive.list(zip)
        let root = rootPrefix(entries.map(\.name))
        // Group files by song folder (the first path component under the root).
        var files: [String: [MXLArchive.Entry]] = [:]
        var manifest: [ManifestEntry]? = nil
        for e in entries {
            guard e.name.hasPrefix(root) else { continue }
            let rel = String(e.name.dropFirst(root.count))
            if rel == "manifest.json" {
                manifest = try? JSONDecoder().decode([ManifestEntry].self,
                                                     from: MXLArchive.extract(e, from: zip))
                continue
            }
            let parts = rel.split(separator: "/", maxSplits: 1)
            guard parts.count == 2 else { continue }        // not inside a song folder
            files[String(parts[0]), default: []].append(e)
        }
        var songs: [BackupSong] = []
        for (folder, entries) in files {
            let names = Set(entries.map { String($0.name.split(separator: "/").last ?? "") })
            var title = folder
            if let m = manifest?.first(where: { $0.folder == folder }) {
                title = m.title
            } else if let metaEntry = entries.first(where: { $0.name.hasSuffix("/metadata.json") }),
                      let data = try? MXLArchive.extract(metaEntry, from: zip),
                      let meta = try? SongLibrary.decoder.decode(SongMeta.self, from: data) {
                title = meta.title
            }
            songs.append(BackupSong(id: folder, title: title, fileCount: entries.count,
                                    hasScorePair: names.contains("score.mid")
                                        && (names.contains("score.musicxml") || names.contains("score.xml")),
                                    alreadyInLibrary: existingFolders.contains(folder)))
        }
        let missing = (manifest ?? []).map(\.folder).filter { files[$0] == nil }
        return Inventory(songs: songs.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending },
                         missingFromArchive: missing, hasManifest: manifest != nil)
    }

    /// Restore the selected song folders into `scoresDir`. A folder that already
    /// exists is restored as a COPY: fresh folder name + fresh metadata id +
    /// "(restored)" title — the existing song is untouched. All-or-nothing per
    /// song: a failed song is cleaned up and the error thrown (audit 06: partial,
    /// silent restores are how backups lose data).
    @discardableResult
    static func restore(zip: Data, folders: Set<String>, into scoresDir: URL) throws -> Int {
        let entries = try MXLArchive.list(zip)
        let root = rootPrefix(entries.map(\.name))
        let fm = FileManager.default
        var restored = 0
        for folder in folders {
            let songEntries = entries.filter { $0.name.hasPrefix(root + folder + "/") }
            guard !songEntries.isEmpty else { continue }
            let isCopy = fm.fileExists(atPath: scoresDir.appendingPathComponent(folder).path)
            let destName = isCopy ? UUID().uuidString : folder
            let dest = scoresDir.appendingPathComponent(destName, isDirectory: true)
            do {
                try fm.createDirectory(at: dest, withIntermediateDirectories: true)
                for e in songEntries {
                    let rel = String(e.name.dropFirst(root.count + folder.count + 1))
                    guard !rel.isEmpty, !rel.contains("..") else { continue }   // no path escapes
                    let out = dest.appendingPathComponent(rel)
                    try fm.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
                    var data = try MXLArchive.extract(e, from: zip)
                    // A copy needs its own identity, or the library sees two songs
                    // with one id (selection/rename chaos).
                    if isCopy, rel == "metadata.json",
                       var meta = try? SongLibrary.decoder.decode(SongMeta.self, from: data) {
                        meta.id = UUID(uuidString: destName) ?? UUID()
                        meta.title += " (restored)"
                        data = (try? SongLibrary.encoder.encode(meta)) ?? data
                    }
                    try data.write(to: out, options: .atomic)
                }
                restored += 1
            } catch {
                try? fm.removeItem(at: dest)      // never leave a half-restored song
                throw error
            }
        }
        return restored
    }
}

/// The previewed-restore sheet: what's in the backup, what's missing, what will
/// become a copy — restore only what's ticked.
struct BackupRestoreView: View {
    let inventory: BackupArchive.Inventory
    let onRestore: (Set<String>) -> Void
    let onCancel: () -> Void
    @State private var selected: Set<String>

    init(inventory: BackupArchive.Inventory,
         onRestore: @escaping (Set<String>) -> Void, onCancel: @escaping () -> Void) {
        self.inventory = inventory
        self.onRestore = onRestore
        self.onCancel = onCancel
        // Everything restorable starts ticked — restoring is why the user is here.
        _selected = State(initialValue: Set(inventory.songs.filter(\.hasScorePair).map(\.id)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Restore from backup").font(.headline)
            if !inventory.hasManifest {
                Label("Older backup (no manifest) — contents read directly from the archive.",
                      systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
            }
            if !inventory.missingFromArchive.isEmpty {
                Label("This backup's manifest lists \(inventory.missingFromArchive.count) song(s) the archive doesn't contain — it may be incomplete.",
                      systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
            List(inventory.songs) { song in
                Toggle(isOn: Binding(get: { selected.contains(song.id) },
                                     set: { if $0 { selected.insert(song.id) } else { selected.remove(song.id) } })) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(song.title)
                        Text(subtitle(song)).font(.caption)
                            .foregroundStyle(song.hasScorePair ? (song.alreadyInLibrary ? Color.orange : .secondary) : .red)
                    }
                }
                .disabled(!song.hasScorePair)
            }
            .frame(minHeight: 220)
            HStack {
                Button("Cancel", role: .cancel) { onCancel() }
                Spacer()
                Button("Restore \(selected.count) song\(selected.count == 1 ? "" : "s")") { onRestore(selected) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selected.isEmpty)
            }
        }
        .padding(16)
        .frame(minWidth: 440, minHeight: 340)
    }

    private func subtitle(_ song: BackupSong) -> String {
        guard song.hasScorePair else { return "score files missing — can’t restore" }
        var bits = ["\(song.fileCount) files"]
        if song.alreadyInLibrary { bits.append("already in your library — restores as a copy") }
        return bits.joined(separator: " · ")
    }
}
