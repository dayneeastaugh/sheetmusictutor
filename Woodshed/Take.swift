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

/// One sustain-pedal transition in a take (musical seconds from take start).
struct PedalPoint: Codable, Equatable {
    var t: Double
    var down: Bool
}

struct Take: Codable, Equatable {
    var date = Date()
    var sectionStart: Int
    var sectionEnd: Int
    var tempoPct: Double
    var accuracy: Double?      // graded takes only
    /// 0 both, 1 RH, 2 LH. Optional for takes saved before the practice context was
    /// recorded — those are context-unknown (treated as both-hands legacy).
    var handMode: Int? = nil
    var notes: [TakeNote]
    /// Sustain-pedal transitions during the take. Optional: takes recorded before
    /// pedal capture persisted have none (audit 06: replay was hiding exactly the
    /// touch/pedal differences the report card measures).
    var pedal: [PedalPoint]? = nil
}

/// Best graded take per section, persisted per song (atomic JSON like flags/sections).
enum TakeStore {
    static func fileURL(in folder: URL) -> URL {
        folder.appendingPathComponent("takes.json")
    }

    /// Bests are kept PER practice context, not just per bar range: a slow one-hand
    /// 100% must never block a later both-hands 100% from becoming the stored best
    /// (audit 06 P2-11). Both-hands keeps the legacy "start-end" key so existing
    /// saved bests stay reachable.
    static func key(start: Int, end: Int, handMode: Int = 0) -> String {
        handMode == 0 ? "\(start)-\(end)" : "\(start)-\(end)-h\(handMode)"
    }

    static let schemaVersion = 2   // 1 = bare dictionary (pre-envelope)

    static func load(from folder: URL) -> [String: Take] {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return StoreIO.loadVersioned([String: Take].self, from: fileURL(in: folder), decoder: dec) ?? [:]
    }

    /// Keep `take` if it beats the stored best for its section + hands. Returns true
    /// only if it was kept AND durably written — a failed write used to return true
    /// while the take silently vanished (audit 06 P2-8).
    @discardableResult
    static func keepIfBest(_ take: Take, in folder: URL) -> Bool {
        guard let acc = take.accuracy else { return false }
        var all = load(from: folder)
        let k = key(start: take.sectionStart, end: take.sectionEnd, handMode: take.handMode ?? 0)
        if let existing = all[k]?.accuracy, existing >= acc { return false }
        all[k] = take
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return StoreIO.writeVersioned(all, v: schemaVersion, to: fileURL(in: folder),
                                      encoder: enc, what: "your best take")
    }
}
