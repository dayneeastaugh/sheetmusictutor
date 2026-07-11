//
//  Song.swift
//  Woodshed
//
//  A song in the library: its metadata plus the on-disk files. Each song lives in
//  its own folder under Application Support/Woodshed/Scores/<id>/ containing
//  score.musicxml, score.mid, and metadata.json (this struct, Codable).
//

import Foundation

/// Persisted per-song metadata (written as metadata.json in the song's folder).
/// Extend this over time with practice data — it's the single place song-specific
/// state lives, and it travels with the song folder.
struct SongMeta: Codable, Equatable {
    var id: UUID
    var title: String
    var composer: String?
    var dateAdded: Date
    var favourite: Bool = false
    var targetTempoPct: Double? = nil   // future: per-piece target tempo
    var lastPracticed: Date? = nil      // updated when a pass is recorded
    var bestAccuracy: Double? = nil     // best full-piece Grade accuracy (0…1), for the library row
    var barsPerLine: Int? = nil         // remembered measures-per-system (nil / 0 = auto layout)
    var tags: [String]? = nil           // freeform labels ("jazz", "recital") — searchable
}

/// A library song = its metadata + the folder it lives in. File URLs are derived.
struct Song: Identifiable, Hashable {
    var meta: SongMeta
    var folder: URL

    var id: UUID { meta.id }
    var title: String { meta.title }
    var musicXMLURL: URL { folder.appendingPathComponent("score.musicxml") }
    var midiURL: URL { folder.appendingPathComponent("score.mid") }
    var metadataURL: URL { folder.appendingPathComponent("metadata.json") }

    static func == (a: Song, b: Song) -> Bool { a.id == b.id && a.meta == b.meta }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
