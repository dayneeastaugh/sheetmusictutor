//
//  PracticePlan.swift
//  Woodshed
//
//  A short, assembled practice session (audit 06 new-feature 1) and retention
//  checks for mastered sections (new-feature 2). Pure functions over data the
//  app already records — flags, history, saved sections — so the plan is
//  testable and every item can say WHY it was chosen. The Progress panel renders
//  it; tapping an item configures the session (focus/slow-ramp/section/whole
//  piece) using the existing drill machinery.
//

import Foundation

/// One item of today's plan, with its reasoning and its target.
struct PlanItem: Identifiable, Equatable {
    enum Kind: String {
        case warmup, drill, retention, runThrough
        var icon: String {
            switch self {
            case .warmup: return "figure.walk"
            case .drill: return "target"
            case .retention: return "brain.head.profile"
            case .runThrough: return "flag.checkered"
            }
        }
    }
    var kind: Kind
    var minutes: Int
    var title: String
    var why: String
    var bar: Int? = nil                    // drill target (swap-able)
    var rangeStart: Int? = nil             // warmup / retention / run target range
    var rangeEnd: Int? = nil
    var section: SavedSection? = nil       // retention target
    var id: String { kind.rawValue + "-" + (bar.map(String.init) ?? section?.name ?? "") }
}

enum PracticePlan {

    // MARK: Retention — "clean today" vs "still remembered later"

    /// Mastered sections that haven't been graded in a while: play them COLD and
    /// see if they held. Mastered = a pitch-graded pass of the exact range at ≥
    /// `masteryThreshold`; due = the newest such pass is ≥ `minDays` old.
    /// Stalest first. Entirely on-device, computed when the panel draws.
    static func retentionDue(sections: [SavedSection], passes: [PracticePass],
                             now: Date = Date(), minDays: Int = 3,
                             masteryThreshold: Double = 0.95) -> [SavedSection] {
        sections.compactMap { s -> (SavedSection, Date)? in
            let graded = passes.filter {
                $0.mode == "grade" && $0.sectionStart == s.start && $0.sectionEnd == s.end
            }
            guard let bestAcc = graded.map(\.accuracy).max(), bestAcc >= masteryThreshold,
                  let newest = graded.map(\.date).max(),
                  now.timeIntervalSince(newest) >= Double(minDays) * 86_400 else { return nil }
            return (s, newest)
        }
        .sorted { $0.1 < $1.1 }
        .map(\.0)
    }

    // MARK: The plan

    /// Assemble a 10/20/30-minute session from what the app knows. Deterministic
    /// and pure; `excludedBars` powers the "swap" affordance (a rejected spot is
    /// excluded and the plan rebuilt with the next candidate).
    static func build(minutes: Int, measureCount: Int,
                      trouble: [TroubleBar], flags: [BarFlag],
                      retentionDue: [SavedSection],
                      excludedBars: Set<Int> = []) -> [PlanItem] {
        var items: [PlanItem] = []
        var remaining = minutes

        // Warm-up: the opening bars, slowly — hands moving before judging begins.
        let warmupMin = max(2, Int(Double(minutes) * 0.15))
        let warmEnd = min(4, measureCount)
        items.append(PlanItem(kind: .warmup, minutes: warmupMin,
                              title: "Warm up: bars 1–\(warmEnd), slowly",
                              why: "Ease in below tempo before anything is graded.",
                              rangeStart: 1, rangeEnd: warmEnd))
        remaining -= warmupMin

        // Weak spots: the worst CURRENT trouble bars, then the oldest flags —
        // chosen from what the data says, not what feels comfortable.
        var spotCandidates: [(bar: Int, why: String)] =
            trouble.filter { !excludedBars.contains($0.bar) }
                .map { ($0.bar, "You're still missing notes there (\($0.misses)×, recent passes).") }
        for f in flags.sorted(by: { $0.date < $1.date })
        where !excludedBars.contains(f.bar) && !spotCandidates.contains(where: { $0.bar == f.bar }) {
            spotCandidates.append((f.bar, "You flagged it: “\(f.note)”."))
        }
        let spotCount = min(spotCandidates.count, minutes >= 20 ? 2 : 1)
        // The run-through and retention check reserve their time before the spots.
        let retention = retentionDue.first
        let retentionMin = retention != nil ? max(2, Int(Double(minutes) * 0.10)) : 0
        let runMin = max(3, Int(Double(minutes) * 0.30))
        var spotBudget = max(0, remaining - retentionMin - runMin)
        for (i, c) in spotCandidates.prefix(spotCount).enumerated() {
            // First spot gets the bigger share (it's the worst one).
            let share = i == 0 ? (spotCount == 1 ? spotBudget : (spotBudget * 3 + 2) / 5)
                              : spotBudget
            guard share >= 2 else { break }
            items.append(PlanItem(kind: .drill, minutes: share,
                                  title: "Drill bar \(c.bar) slowly",
                                  why: c.why, bar: c.bar))
            spotBudget -= share
            remaining -= share
        }

        // Retention: one mastered-but-stale section, played COLD — first attempt
        // is the honest signal, so it comes before the piece is warm in the hands.
        if let r = retention {
            items.append(PlanItem(kind: .retention, minutes: retentionMin,
                                  title: "Memory check: \(r.name) — play it cold",
                                  why: "Mastered a while ago; today shows whether it stuck, not whether you can re-learn it.",
                                  rangeStart: r.start, rangeEnd: r.end, section: r))
            remaining -= retentionMin
        }

        // Finish with a run — everything left lands here, and it banks the trend.
        items.append(PlanItem(kind: .runThrough, minutes: max(runMin, remaining),
                              title: "Full run-through, graded",
                              why: spotCandidates.isEmpty
                                ? "No current trouble spots — enjoy the run and bank today's trend point."
                                : "Put the drilled spots back into context and bank today's trend point.",
                              rangeStart: 1, rangeEnd: measureCount))
        return items
    }
}
