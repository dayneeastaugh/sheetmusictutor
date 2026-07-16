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
        var hand: Hand
        var name: String
        var matched: Bool
        var signedErrorMs: Double?
    }

    /// Assemble the report. `previous` (if over the same bar range) drives the delta
    /// and the fixed-bars wins.
    static func build(notes: [Note], wrongBars: [Int],
                      sectionStart: Int, sectionEnd: Int, tempoPct: Double,
                      previous: PassReport?) -> PassReport {
        var wrongPerBar: [Int: Int] = [:]
        for b in wrongBars { wrongPerBar[b, default: 0] += 1 }

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
                          deltaVsPrevious: delta, fixedBars: fixed)
    }
}
