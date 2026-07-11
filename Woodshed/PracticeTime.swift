//
//  PracticeTime.swift
//  Woodshed
//
//  Per-song practice-time ledger: seconds of ACTIVE practice per calendar day,
//  persisted as time.json ({"2026-07-11": 843.2, …}). Active = playback running,
//  or Wait mode with recent input. Feeds the Progress stats, the cross-song
//  overview totals, and the PRD's own success criterion ("reaches target tempo
//  measurably faster") — which was unmeasurable until now.
//

import Foundation

enum PracticeTime {
    static func fileURL(in folder: URL) -> URL {
        folder.appendingPathComponent("time.json")
    }

    /// Day-key (UTC-agnostic local calendar day), e.g. "2026-07-11".
    static func dayKey(for date: Date = Date()) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func load(from folder: URL) -> [String: Double] {
        guard let data = try? Data(contentsOf: fileURL(in: folder)),
              let dict = try? JSONDecoder().decode([String: Double].self, from: data) else { return [:] }
        return dict
    }

    /// Add active seconds to a day's total (atomic rewrite — the file is tiny).
    static func add(_ seconds: Double, on day: String = dayKey(), to folder: URL) {
        guard seconds > 0 else { return }
        var dict = load(from: folder)
        dict[day, default: 0] += seconds
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(dict) {
            try? data.write(to: fileURL(in: folder), options: .atomic)
        }
    }

    static func total(_ dict: [String: Double]) -> Double {
        dict.values.reduce(0, +)
    }

    /// Seconds within the last `days` calendar days (including today).
    static func recent(_ dict: [String: Double], days: Int, from date: Date = Date()) -> Double {
        let cal = Calendar.current
        let keys: Set<String> = Set((0..<days).compactMap {
            cal.date(byAdding: .day, value: -$0, to: date).map { dayKey(for: $0) }
        })
        return dict.filter { keys.contains($0.key) }.values.reduce(0, +)
    }

    /// "2h 05m" / "23m" / "45s" — for stat rows.
    static func format(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s >= 3600 { return "\(s / 3600)h \(String(format: "%02d", (s % 3600) / 60))m" }
        if s >= 60 { return "\(s / 60)m" }
        return "\(s)s"
    }
}
