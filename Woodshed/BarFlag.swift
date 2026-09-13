//
//  BarFlag.swift
//  Woodshed
//
//  Manual "revisit" flags: a short note you attach to a bar to remind yourself what
//  to work on (e.g. "LH jump"). One flag per bar. Persisted per song as flags.json
//  (a small mutable array, rewritten on change — unlike the append-only history).
//

import Foundation

/// A user note pinned to a bar. Keyed by `bar` (one per bar; re-flagging edits it).
struct BarFlag: Codable, Identifiable, Hashable {
    var bar: Int            // 1-based bar number
    var note: String        // the reminder ("LH jump", "watch the trill", …)
    var date: Date = Date()

    var id: Int { bar }
}

/// Reads/writes the per-song `flags.json`. Pure file IO — no UI, no engines.
enum BarFlagStore {
    static func fileURL(in folder: URL) -> URL {
        folder.appendingPathComponent("flags.json")
    }

    /// Load flags sorted by bar. Missing → none; corrupt → set aside + reported.
    static func load(from folder: URL) -> [BarFlag] {
        (StoreIO.load([BarFlag].self, from: fileURL(in: folder), decoder: decoder) ?? [])
            .sorted { $0.bar < $1.bar }
    }

    /// Persist the whole set (empty writes an empty array). Atomic, so a kill
    /// mid-write can't leave a truncated flags.json. Failures are reported.
    static func save(_ flags: [BarFlag], to folder: URL) {
        StoreIO.write(flags.sorted { $0.bar < $1.bar }, to: fileURL(in: folder),
                      encoder: encoder, what: "your bar flags")
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; e.dateEncodingStrategy = .iso8601; return e
    }()
    static let decoder: JSONDecoder = {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }()
}
