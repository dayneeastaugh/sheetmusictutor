//
//  PassReport.swift
//  Woodshed
//
//  The post-pass report: WHERE a graded pass went wrong (per bar), whether it's a
//  hands problem, whether you're rushing or dragging and where — and what got BETTER
//  (the PRD demands feedback that's encouraging, never punitive). Built once when a
//  pass finalizes, from the per-note results the matcher now retains. Pure + unit-
//  tested; `PracticeSession` feeds it, `PassReportCard` draws it.
//

import Foundation

struct PassReport {
    /// One bar's outcome this pass. `meanSignedMs` is the average signed timing error
    /// of the bar's HIT notes (< 0 rushing, > 0 dragging); nil when nothing was hit.
    struct BarResult: Identifiable, Equatable {
        var bar: Int                    // 1-based
        var total: Int                  // expected notes in this bar (0 = rest bar)
        var hits: Int
        var wrong: Int                  // extra notes played in this bar
        var meanSignedMs: Double?
        var missedNames: [String] = []  // note names of the misses (deduped, capped)
        var id: Int { bar }
        var missed: Int { total - hits }
        var isClean: Bool { total > 0 && missed == 0 && wrong == 0 }
        var accuracy: Double { total > 0 ? Double(hits) / Double(total) : 1 }
    }

    /// One hand's outcome (only produced when both hands were graded).
    struct HandResult: Equatable, Identifiable {
        var hand: Hand
        var id: String { hand.rawValue }
        var total: Int
        var hits: Int
        var meanSignedMs: Double?
        var accuracy: Double { total > 0 ? Double(hits) / Double(total) : 1 }
    }

    /// A fault that keeps happening: the same miss/wrong note across consecutive
    /// comparable passes. The most specific feedback the app can give.
    struct RecurringFault: Equatable, Identifiable {
        var bar: Int
        var name: String                // note name, e.g. "E♭4"
        var kind: String                // "missed" | "wrong"
        var streak: Int                 // consecutive passes including this one
        var substitution: String?       // "you play D4 instead" (nearby wrong note)
        var id: String { "\(bar)-\(name)-\(kind)" }
    }

    var sectionStart: Int
    var sectionEnd: Int
    var tempoPct: Double
    var accuracy: Double
    var bars: [BarResult]               // sectionStart…sectionEnd, in order
    var hands: [HandResult]             // empty unless both hands present
    /// vs the previous pass over the SAME bars (nil = no comparable pass).
    var deltaVsPrevious: Double?
    /// Bars clean this pass that were NOT clean the previous pass — the wins.
    var fixedBars: [Int] = []
    /// Faults recurring across consecutive comparable passes (streak ≥ 3), worst first.
    var recurring: [RecurringFault] = []
    /// Scale/technique evenness (computed from what you actually played — the take),
    /// attached for Technical Practice songs. nil = not computed / not enough notes.
    var evenness: Evenness? = nil

    /// The two things a teacher listens for in a scale: even TIMING (inter-onset
    /// consistency) and even DYNAMICS (velocity consistency).
    struct Evenness: Equatable {
        var timingScore: Double        // 0…1 (1 = metronomic)
        var dynamicScore: Double       // 0…1 (1 = perfectly level)
        var softest: (name: String, velocity: Int)?
        var loudest: (name: String, velocity: Int)?

        static func == (a: Evenness, b: Evenness) -> Bool {
            a.timingScore == b.timingScore && a.dynamicScore == b.dynamicScore
                && a.softest?.velocity == b.softest?.velocity
                && a.loudest?.velocity == b.loudest?.velocity
        }
    }

    /// Worst bar (most faults; ties → earliest), for the headline callout.
    var worstBar: BarResult? {
        bars.filter { $0.missed + $0.wrong > 0 }
            .max { a, b in
                (a.missed + a.wrong, -a.bar) < (b.missed + b.wrong, -b.bar)
            }
    }

    /// The run of consecutive bars with the largest |mean timing error| ≥ threshold,
    /// for a "you rush bars 9–10 by ~60 ms" callout. nil when timing is basically even.
    func timingHotspot(thresholdMs: Double = 40) -> (bars: ClosedRange<Int>, meanMs: Double)? {
        var best: (bars: ClosedRange<Int>, meanMs: Double)?
        var runStart: Int? = nil
        var runSum = 0.0, runCount = 0
        func closeRun(endingBefore bar: Int) {
            guard let s = runStart, runCount > 0 else { return }
            let mean = runSum / Double(runCount)
            if abs(mean) >= thresholdMs, abs(mean) > abs(best?.meanMs ?? 0) {
                best = (s...(bar - 1), mean)
            }
            runStart = nil; runSum = 0; runCount = 0
        }
        for b in bars {
            // A bar belongs to a run if its own mean crosses the threshold in a
            // consistent direction; rest/clean-timing bars break the run.
            if let m = b.meanSignedMs, abs(m) >= thresholdMs,
               runCount == 0 || (m > 0) == (runSum > 0) {
                if runStart == nil { runStart = b.bar }
                runSum += m; runCount += 1
            } else {
                closeRun(endingBefore: b.bar)
                if let m = b.meanSignedMs, abs(m) >= thresholdMs {   // starts its own run
                    runStart = b.bar; runSum = m; runCount = 1
                }
            }
        }
        closeRun(endingBefore: (bars.last?.bar ?? 0) + 1)
        return best
    }
}

enum PassReportBuilder {
    /// One expected note's outcome, extracted from the matcher (kept engine-free so
    /// the builder is trivially testable).
    struct Note {
        var bar: Int
        var pitch: Int
        var hand: Hand
        var name: String
        var matched: Bool
        var signedErrorMs: Double?
    }

    /// A wrong/extra note played this pass, with its pitch (substitution detection).
    struct WrongNote { var bar: Int; var pitch: Int; var name: String }

    /// Assemble the report. `previous` (if over the same bar range) drives the delta
    /// and the fixed-bars wins; `previousFaults` (most-recent-first fault lists from
    /// comparable passes, incl. earlier sessions) drives recurring-fault streaks.
    static func build(notes: [Note], wrongNotes: [WrongNote],
                      sectionStart: Int, sectionEnd: Int, tempoPct: Double,
                      previous: PassReport?, previousFaults: [[PassFault]] = []) -> PassReport {
        var wrongPerBar: [Int: Int] = [:]
        for w in wrongNotes { wrongPerBar[w.bar, default: 0] += 1 }

        var bars: [PassReport.BarResult] = []
        for bar in sectionStart...max(sectionStart, sectionEnd) {
            let inBar = notes.filter { $0.bar == bar }
            let hitErrors = inBar.compactMap { $0.matched ? $0.signedErrorMs : nil }
            var missedNames: [String] = []
            for n in inBar where !n.matched && !missedNames.contains(n.name) { missedNames.append(n.name) }
            bars.append(PassReport.BarResult(
                bar: bar,
                total: inBar.count,
                hits: inBar.filter(\.matched).count,
                wrong: wrongPerBar[bar] ?? 0,
                meanSignedMs: hitErrors.isEmpty ? nil : hitErrors.reduce(0, +) / Double(hitErrors.count),
                missedNames: Array(missedNames.prefix(3))))
        }

        // Per-hand split — only meaningful when both hands were actually graded.
        var hands: [PassReport.HandResult] = []
        let byHand = Dictionary(grouping: notes.filter { $0.hand != .unknown }, by: \.hand)
        if byHand.keys.count == 2 {
            for hand in [Hand.right, Hand.left] {
                let ns = byHand[hand] ?? []
                let errs = ns.compactMap { $0.matched ? $0.signedErrorMs : nil }
                hands.append(PassReport.HandResult(
                    hand: hand, total: ns.count, hits: ns.filter(\.matched).count,
                    meanSignedMs: errs.isEmpty ? nil : errs.reduce(0, +) / Double(errs.count)))
            }
        }

        let total = notes.count
        let accuracy = total > 0 ? Double(notes.filter(\.matched).count) / Double(total) : 0

        // Wins vs the previous pass — only when it covered the same bars.
        var delta: Double? = nil
        var fixed: [Int] = []
        if let p = previous, p.sectionStart == sectionStart, p.sectionEnd == sectionEnd {
            delta = accuracy - p.accuracy
            let previouslyClean = Set(p.bars.filter(\.isClean).map(\.bar))
            fixed = bars.filter { $0.isClean && $0.total > 0 && !previouslyClean.contains($0.bar) }.map(\.bar)
        }

        return PassReport(sectionStart: sectionStart, sectionEnd: sectionEnd,
                          tempoPct: tempoPct, accuracy: accuracy,
                          bars: bars, hands: hands,
                          deltaVsPrevious: delta, fixedBars: fixed,
                          recurring: recurringFaults(notes: notes, wrongNotes: wrongNotes,
                                                     previousFaults: previousFaults))
    }

    /// Evenness from the notes you actually played: (pitch, onset seconds, velocity).
    /// Chords collapse to one onset; interval outliers (the bar-line breath, the held
    /// final note) are excluded by a median filter. nil when there's too little to
    /// judge (< 8 onsets).
    static func evenness(played: [(pitch: Int, onset: Double, velocity: Int)],
                         chordEpsilon: Double = 0.01,
                         noteName: (Int) -> String) -> PassReport.Evenness? {
        let sorted = played.sorted { $0.onset < $1.onset }
        var onsets: [Double] = []
        for n in sorted where onsets.last.map({ n.onset - $0 >= chordEpsilon }) ?? true {
            onsets.append(n.onset)
        }
        guard onsets.count >= 8 else { return nil }

        // Timing: coefficient of variation of the inter-onset intervals, after
        // dropping intervals wildly off the median (pauses, the final long note).
        let iois = zip(onsets.dropFirst(), onsets).map(-)
        let med = iois.sorted()[iois.count / 2]
        let steady = iois.filter { $0 > med * 0.25 && $0 < med * 2.5 }
        guard steady.count >= 6, med > 0 else { return nil }
        let mean = steady.reduce(0, +) / Double(steady.count)
        let variance = steady.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(steady.count)
        let cv = mean > 0 ? (variance.squareRoot() / mean) : 1
        let timingScore = max(0, min(1, 1 - cv * 2))       // CV 0 → 1.0, CV 0.25 → 0.5, ≥0.5 → 0

        // Dynamics: velocity spread. std ~6 is very level; ~30 is all over the place.
        let vels = sorted.map { Double($0.velocity) }
        let vMean = vels.reduce(0, +) / Double(vels.count)
        let vVar = vels.map { ($0 - vMean) * ($0 - vMean) }.reduce(0, +) / Double(vels.count)
        let dynamicScore = max(0, min(1, 1 - vVar.squareRoot() / 30))
        let soft = sorted.min { $0.velocity < $1.velocity }
        let loud = sorted.max { $0.velocity < $1.velocity }

        return PassReport.Evenness(
            timingScore: timingScore, dynamicScore: dynamicScore,
            softest: soft.map { (noteName($0.pitch), $0.velocity) },
            loudest: loud.map { (noteName($0.pitch), $0.velocity) })
    }

    /// This pass's per-note faults, for persisting on the PracticePass record.
    static func faults(notes: [Note], wrongNotes: [WrongNote], cap: Int = 60) -> [PassFault] {
        let missed = notes.filter { !$0.matched }
            .map { PassFault(bar: $0.bar, pitch: $0.pitch, kind: "missed") }
        let wrong = wrongNotes.map { PassFault(bar: $0.bar, pitch: $0.pitch, kind: "wrong") }
        return Array((missed + wrong).prefix(cap))
    }

    /// Faults present THIS pass that also appeared in consecutive previous passes.
    /// Streak counts back from the most recent previous pass and breaks at the first
    /// pass without the fault — "4 passes in a row", not "4 of the last 10".
    private static func recurringFaults(notes: [Note], wrongNotes: [WrongNote],
                                        previousFaults: [[PassFault]]) -> [PassReport.RecurringFault] {
        guard !previousFaults.isEmpty else { return [] }
        let prevSets = previousFaults.map(Set.init)
        var out: [PassReport.RecurringFault] = []
        var seen = Set<PassFault>()

        func streak(_ f: PassFault) -> Int {
            var n = 1
            for set in prevSets { if set.contains(f) { n += 1 } else { break } }
            return n
        }
        for n in notes where !n.matched {
            let f = PassFault(bar: n.bar, pitch: n.pitch, kind: "missed")
            guard !seen.contains(f), case let s = streak(f), s >= 3 else { continue }
            seen.insert(f)
            // A nearby wrong note in the same bar is likely what got played instead.
            let sub = wrongNotes.first { $0.bar == n.bar && abs($0.pitch - n.pitch) <= 2 }
            out.append(PassReport.RecurringFault(bar: n.bar, name: n.name, kind: "missed",
                                                 streak: s,
                                                 substitution: sub.map { "you play \($0.name) instead" }))
        }
        for w in wrongNotes {
            let f = PassFault(bar: w.bar, pitch: w.pitch, kind: "wrong")
            guard !seen.contains(f), case let s = streak(f), s >= 3 else { continue }
            seen.insert(f)
            out.append(PassReport.RecurringFault(bar: w.bar, name: w.name, kind: "wrong",
                                                 streak: s, substitution: nil))
        }
        return out.sorted { $0.streak > $1.streak }.prefix(3).map { $0 }
    }
}
