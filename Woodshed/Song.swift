//
//  Song.swift
//  Woodshed
//
//  A song in the library: its metadata plus the on-disk files. Each song lives in
//  its own folder under Application Support/Segno/Scores/<id>/ containing
//  score.musicxml, score.mid, and metadata.json (this struct, Codable).
//

import Foundation

/// Which library group a song belongs to. Absent (nil) = repertoire — so existing
/// metadata.json files (written before this field) decode as normal pieces.
enum SongCategory: String, Codable, CaseIterable {
    case repertoire, technical
    var title: String { self == .technical ? "Technical practice" : "Repertoire" }
}

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
    var scoreZoom: Double? = nil        // remembered engraving scale (nil = 100%)
    var tags: [String]? = nil           // freeform labels ("jazz", "recital") — searchable
    var category: SongCategory? = nil   // nil = repertoire; .technical groups under Technical practice
}

/// A library song = its metadata + the folder it lives in. File URLs are derived.
struct Song: Identifiable, Hashable {
    var meta: SongMeta
    var folder: URL

    var id: UUID { meta.id }
    var title: String { meta.title }
    var category: SongCategory { meta.category ?? .repertoire }
    var musicXMLURL: URL { folder.appendingPathComponent("score.musicxml") }
    var midiURL: URL { folder.appendingPathComponent("score.mid") }
    var metadataURL: URL { folder.appendingPathComponent("metadata.json") }

    static func == (a: Song, b: Song) -> Bool { a.id == b.id && a.meta == b.meta }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
