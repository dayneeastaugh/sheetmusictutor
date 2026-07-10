//
//  PracticeHistory.swift
//  Woodshed
//
//  Per-song practice history: one graded pass per record, appended to `history.jsonl`
//  in the song's own folder (append-only JSON-lines, no database — consistent with
//  the file-based library, DECISIONS ADR-018/021). This is the data behind the
//  progress trend and trouble-spot heatmap.
//

import Foundation

/// One graded practice pass. Enough context to chart trends per section/tempo and to
/// aggregate which bars you keep missing.
struct PracticePass: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var date: Date = Date()
    var mode: String = "grade"          // room for "wait" etc. later
    var sectionStart: Int               // 1-based bar range this pass covered
    var sectionEnd: Int
    var measureCount: Int               // bars in the whole piece (to tell full runs from sections)
    var tempoPct: Double
    var handMode: Int                   // 0 both, 1 RH, 2 LH
    var total: Int                      // expected notes
    var hits: Int
    var missed: Int
    var wrong: Int                      // extra/wrong notes played
    var avgMs: Double                   // mean |timing error| of hits
    var missedBars: [Int] = []          // 1-based bar per missed note (weights the heatmap)

    var accuracy: Double { total > 0 ? Double(hits) / Double(total) : 0 }
    var isFullPiece: Bool { sectionStart <= 1 && sectionEnd >= measureCount }
}

/// A bar you keep missing, with how many missed notes it accumulated across passes.
struct TroubleBar: Identifiable, Hashable {
    var bar: Int
    var misses: Int
    var id: Int { bar }
}

/// Reads/writes the per-song `history.jsonl`. Pure file IO — no UI, no engines.
enum PracticeHistory {
    static func fileURL(in folder: URL) -> URL {
        folder.appendingPathComponent("history.jsonl")
    }

    /// Append one pass as a JSON line. Falls back to creating the file if absent.
    static func append(_ pass: PracticePass, to folder: URL) {
        guard var data = try? encoder.encode(pass) else { return }
        data.append(0x0A)   // newline
        let url = fileURL(in: folder)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }

    /// Load all passes (oldest → newest, file order). A malformed line is skipped.
    static func load(from folder: URL) -> [PracticePass] {
        guard let text = try? String(contentsOf: fileURL(in: folder), encoding: .utf8) else { return [] }
        var out: [PracticePass] = []
        for line in text.split(separator: "\n") {
            if let d = line.data(using: .utf8), let p = try? decoder.decode(PracticePass.self, from: d) {
                out.append(p)
            }
        }
        return out
    }

    /// Bars ranked by how many missed notes they accumulated across ALL passes.
    static func troubleBars(_ passes: [PracticePass], top: Int = 8) -> [TroubleBar] {
        var counts: [Int: Int] = [:]
        for p in passes { for b in p.missedBars { counts[b, default: 0] += 1 } }
        return counts.map { TroubleBar(bar: $0.key, misses: $0.value) }
            .sorted { $0.misses != $1.misses ? $0.misses > $1.misses : $0.bar < $1.bar }
            .prefix(top)
            .map { $0 }
    }

    /// Bars that **still** need work — "clear as you improve". For each bar ever missed,
    /// look at the passes that covered it, newest first: it's a current trouble spot
    /// only if the most recent covering pass still missed notes in it. Play it clean
    /// and it drops off. Weight = misses across the recent window (current severity).
    static func currentTroubleBars(_ passes: [PracticePass], recentWindow: Int = 3, top: Int = 8) -> [TroubleBar] {
        var everMissed = Set<Int>()
        for p in passes { for b in p.missedBars { everMissed.insert(b) } }

        var result: [TroubleBar] = []
        let newestFirst = Array(passes.reversed())
        for bar in everMissed {
            let covering = newestFirst.filter { $0.sectionStart <= bar && bar <= $0.sectionEnd }
            guard let mostRecent = covering.first else { continue }
            guard mostRecent.missedBars.contains(bar) else { continue }   // played clean last time → cleared
            let window = covering.prefix(recentWindow)
            let weight = window.reduce(0) { $0 + $1.missedBars.filter { $0 == bar }.count }
            result.append(TroubleBar(bar: bar, misses: weight))
        }
        return result
            .sorted { $0.misses != $1.misses ? $0.misses > $1.misses : $0.bar < $1.bar }
            .prefix(top)
            .map { $0 }
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e
    }()
    static let decoder: JSONDecoder = {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }()
}
