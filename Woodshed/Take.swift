//
//  Take.swift
//  Woodshed
//
//  A "take": your own performance of a pass, captured from MIDI input with
//  musical-clock timestamps so it can be played back at any tempo. The last take
//  of a session lives in memory; the BEST graded take per section is persisted in
//  takes.json (keyed by bar range) — listen back to what you played, or to your
//  best-ever run of the passage.
//

import Foundation

/// One note you played: pitch, velocity, and on/off in musical seconds relative
/// to the take's start.
struct TakeNote: Codable, Equatable {
    var p: Int          // MIDI pitch
    var v: Int          // velocity 1…127
    var on: Double      // musical seconds from take start
    var off: Double
}

struct Take: Codable, Equatable {
    var date = Date()
    var sectionStart: Int
    var sectionEnd: Int
    var tempoPct: Double
    var accuracy: Double?      // graded takes only
    var notes: [TakeNote]
}

/// Best graded take per section, persisted per song (atomic JSON like flags/sections).
enum TakeStore {
    static func fileURL(in folder: URL) -> URL {
        folder.appendingPathComponent("takes.json")
    }

    static func key(start: Int, end: Int) -> String { "\(start)-\(end)" }

    static func load(from folder: URL) -> [String: Take] {
        guard let data = try? Data(contentsOf: fileURL(in: folder)) else { return [:] }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode([String: Take].self, from: data)) ?? [:]
    }

    /// Keep `take` if it beats the stored best for its section. Returns true if kept.
    @discardableResult
    static func keepIfBest(_ take: Take, in folder: URL) -> Bool {
        guard let acc = take.accuracy else { return false }
        var all = load(from: folder)
        let k = key(start: take.sectionStart, end: take.sectionEnd)
        if let existing = all[k]?.accuracy, existing >= acc { return false }
        all[k] = take
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(all) {
            try? data.write(to: fileURL(in: folder), options: .atomic)
        }
        return true
    }
}
