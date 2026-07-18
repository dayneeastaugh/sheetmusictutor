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

struct PassReport: Codable, Equatable {
    /// One bar's outcome this pass. `meanSignedMs` is the average signed timing error
    /// of the bar's HIT notes (< 0 rushing, > 0 dragging); nil when nothing was hit.
    struct BarResult: Identifiable, Equatable, Codable {
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
    struct HandResult: Equatable, Identifiable, Codable {
        var hand: Hand
        var id: String { hand.rawValue }
        var total: Int
        var hits: Int
        var meanSignedMs: Double?
        var accuracy: Double { total > 0 ? Double(hits) / Double(total) : 1 }
    }

    /// A fault that keeps happening: the same miss/wrong note across consecutive
    /// comparable passes. The most specific feedback the app can give.
    struct RecurringFault: Equatable, Identifiable, Codable {
        var bar: Int
        var name: String                // note name, e.g. "E♭4"
        var kind: String                // "missed" | "wrong"
        var streak: Int                 // consecutive passes including this one
        var substitution: String?       // "you play D4 instead" (nearby wrong note)
        var id: String { "\(bar)-\(name)-\(kind)" }
    }

    /// When the pass finished (set by the session; shown when a saved report is
    /// reloaded on a later launch so it's clearly "last time", not "just now").
    var date: Date? = nil
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
    /// Mean struck velocity per hand — the balance a teacher listens for ("the left
    /// hand is burying the melody"). nil unless both hands played enough notes.
    var balance: Balance? = nil
    /// Bar spans where the sustain pedal never lifted across ≥2 barlines (the muddy-
    /// pedal proxy: pianists lift at least at harmony changes).
    var pedalHolds: [ClosedRange<Int>] = []
    /// Tempo drift across the pass, % (negative = you sped up / finished faster).
    /// From the least-squares slope of hit timing errors over time. nil = not enough data.
    var tempoDriftPct: Double? = nil
    /// One teacher-style tip derived from the error PATTERN (scattered = too fast;
    /// recurring = fix notes slowly first). nil when there's nothing worth saying.
    var advice: String? = nil
    /// The most-rolled expected chord this pass (bar + onset spread in ms), when the
    /// spread is audible — "strike together" feedback the tolerance window hides.
    var worstChordSpread: ChordSpread? = nil
    /// True when this accuracy beats every prior comparable pass (≥3 on record).
    var personalBest: Bool = false

    struct Balance: Equatable, Codable {
        var rhMeanVelocity: Double
        var lhMeanVelocity: Double
        var lhLouderBy: Double { lhMeanVelocity - rhMeanVelocity }
    }
    struct ChordSpread: Equatable, Codable { var bar: Int; var ms: Double }

    /// The two things a teacher listens for in a scale: even TIMING (inter-onset
    /// consistency) and even DYNAMICS (velocity consistency).
    struct Evenness: Equatable, Codable {
        struct NoteVel: Equatable, Codable { var name: String; var velocity: Int }
        var timingScore: Double        // 0…1 (1 = metronomic)
        var dynamicScore: Double       // 0…1 (1 = perfectly level)
        var softest: NoteVel?
        var loudest: NoteVel?
    }

    /// A run of adjacent problem bars, for the compact long-score view: rather than a
    /// per-bar sliver strip (unreadable past ~24 bars), faulty bars merge into tappable
    /// ranges tinted by their worst bar. severity 1 = rough (amber), 2 = bad (red).
    struct ProblemCluster: Identifiable, Equatable {
        var range: ClosedRange<Int>
        var severity: Int
        var id: Int { range.lowerBound }
        var label: String {
            range.count == 1 ? "bar \(range.lowerBound)" : "bars \(range.lowerBound)–\(range.upperBound)"
        }
    }

    /// Adjacent faulty bars merged into ranges (rest/clean bars break a run), worst-
    /// severity first then earliest — the compact map for a long pass.
    func problemClusters() -> [ProblemCluster] {
        func sev(_ b: BarResult) -> Int {
            if b.total == 0 || b.isClean { return 0 }
            return (b.accuracy >= 0.8 && b.missed + b.wrong <= 2) ? 1 : 2
        }
        var clusters: [ProblemCluster] = []
        var run: (start: Int, end: Int, sev: Int)? = nil
        for b in bars {
            let s = sev(b)
            if s == 0 {
                if let r = run { clusters.append(.init(range: r.start...r.end, severity: r.sev)); run = nil }
            } else if var r = run {
                r.end = b.bar; r.sev = max(r.sev, s); run = r
            } else {
                run = (b.bar, b.bar, s)
            }
        }
        if let r = run { clusters.append(.init(range: r.start...r.end, severity: r.sev)) }
        return clusters.sorted { ($0.severity, -$0.range.lowerBound) > ($1.severity, -$1.range.lowerBound) }
    }

    var cleanBarCount: Int { bars.filter { $0.total == 0 || $0.isClean }.count }

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

/// Persists the most recent pass's report per song (`report.json`, atomic rewrite —
/// same pattern as flags/sections), so "how did my last practice go?" survives an app
/// restart instead of living only in the session.
enum PassReportStore {
    static func fileURL(in folder: URL) -> URL { folder.appendingPathComponent("report.json") }

    static func load(from folder: URL) -> PassReport? {
        guard let data = try? Data(contentsOf: fileURL(in: folder)) else { return nil }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(PassReport.self, from: data)
    }

    static func save(_ report: PassReport, to folder: URL) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(report) {
            try? data.write(to: fileURL(in: folder), options: .atomic)
        }
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
        var onset: Double? = nil       // musical seconds — drift + chord-spread analysis
    }

    /// A wrong/extra note played this pass, with its pitch (substitution detection).
    struct WrongNote { var bar: Int; var pitch: Int; var name: String }

    /// Assemble the report. `previous` (if over the same bar range) drives the delta
    /// and the fixed-bars wins; `previousFaults` (most-recent-first fault lists from
    /// comparable passes, incl. earlier sessions) drives recurring-fault streaks.
    static func build(notes: [Note], wrongNotes: [WrongNote],
                      sectionStart: Int, sectionEnd: Int, tempoPct: Double,
                      previous: PassReport?, previousFaults: [[PassFault]] = [],
                      priorAccuracies: [Double] = []) -> PassReport {
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

        let recurring = recurringFaults(notes: notes, wrongNotes: wrongNotes,
                                        previousFaults: previousFaults)
        var report = PassReport(sectionStart: sectionStart, sectionEnd: sectionEnd,
                                tempoPct: tempoPct, accuracy: accuracy,
                                bars: bars, hands: hands,
                                deltaVsPrevious: delta, fixedBars: fixed,
                                recurring: recurring)
        report.tempoDriftPct = tempoDrift(notes: notes)
        report.worstChordSpread = chordSpread(notes: notes)
        report.advice = advice(notes: notes, wrongNotes: wrongNotes, recurring: recurring)
        report.personalBest = priorAccuracies.count >= 3 && total > 0
            && accuracy > (priorAccuracies.max() ?? 1)
        return report
    }

    /// Tempo drift: least-squares slope of hit timing errors over musical time.
    /// error(t) ≈ (r−1)·t + c where r = your tempo / reference tempo, so the slope
    /// IS the drift ratio. Robust to a fixed offset (consistently early ≠ speeding up).
    static func tempoDrift(notes: [Note]) -> Double? {
        let pts = notes.compactMap { n -> (x: Double, y: Double)? in
            guard n.matched, let ms = n.signedErrorMs, let t = n.onset else { return nil }
            return (t, ms / 1000)
        }
        guard pts.count >= 10, let first = pts.map(\.x).min(), let last = pts.map(\.x).max(),
              last - first >= 8 else { return nil }
        let mx = pts.map(\.x).reduce(0, +) / Double(pts.count)
        let my = pts.map(\.y).reduce(0, +) / Double(pts.count)
        let varX = pts.map { ($0.x - mx) * ($0.x - mx) }.reduce(0, +)
        guard varX > 0 else { return nil }
        let cov = pts.map { ($0.x - mx) * ($0.y - my) }.reduce(0, +)
        return (cov / varX) * 100   // % — negative = getting earlier = speeding up
    }

    /// The most-rolled written chord: expected notes sharing an onset whose matched
    /// strike times spread audibly (the ± tolerance window otherwise hides a roll).
    static func chordSpread(notes: [Note], chordEpsilon: Double = 0.02) -> PassReport.ChordSpread? {
        let hits = notes.filter { $0.matched && $0.onset != nil && $0.signedErrorMs != nil }
            .sorted { $0.onset! < $1.onset! }
        var worst: PassReport.ChordSpread? = nil
        var group: [Note] = []
        func flush() {
            if group.count >= 2 {
                let times = group.map { $0.signedErrorMs! }
                let spread = times.max()! - times.min()!
                if spread >= 60, spread > (worst?.ms ?? 0) {
                    worst = .init(bar: group[0].bar, ms: spread)
                }
            }
            group = []
        }
        for n in hits {
            if let lastOnset = group.last?.onset, n.onset! - lastOnset >= chordEpsilon { flush() }
            group.append(n)
        }
        flush()
        return worst
    }

    /// The teacher's tip, from the error PATTERN: repeated same-spot faults mean fix
    /// the notes slowly; scattered one-offs mean the tempo is simply too high.
    private static func advice(notes: [Note], wrongNotes: [WrongNote],
                               recurring: [PassReport.RecurringFault]) -> String? {
        let faults = notes.filter { !$0.matched }.count + wrongNotes.count
        if recurring.count >= 2 {
            return "The same spots miss every pass — fix the notes slowly (check the fingering) before adding speed."
        }
        if faults >= 6 && recurring.isEmpty {
            return "These errors are scattered one-offs — usually the tempo is too high. Drop ~15% and re-run."
        }
        return nil
    }

    /// Mean struck velocity per hand. Played notes are attributed to a hand via the
    /// nearest same-pitch expected note within tolerance (wrong notes don't count).
    static func balance(played: [(pitch: Int, onset: Double, velocity: Int)],
                        expected: [(pitch: Int, onset: Double, hand: Hand)],
                        tolerance: Double) -> PassReport.Balance? {
        var rh: [Double] = [], lh: [Double] = []
        for p in played {
            let e = expected
                .filter { $0.pitch == p.pitch && abs($0.onset - p.onset) <= tolerance }
                .min { abs($0.onset - p.onset) < abs($1.onset - p.onset) }
            switch e?.hand {
            case .right: rh.append(Double(p.velocity))
            case .left: lh.append(Double(p.velocity))
            default: break
            }
        }
        guard rh.count >= 5, lh.count >= 5 else { return nil }
        return .init(rhMeanVelocity: rh.reduce(0, +) / Double(rh.count),
                     lhMeanVelocity: lh.reduce(0, +) / Double(lh.count))
    }

    /// Bar spans where the pedal stayed down across ≥2 consecutive barlines.
    /// `barTimes` = each interior barline as (bar it starts, its time).
    static func pedalHolds(pedal: [(t: Double, down: Bool)],
                           barTimes: [(bar: Int, t: Double)]) -> [ClosedRange<Int>] {
        var holds: [ClosedRange<Int>] = []
        var isDown = false, downSince = 0.0
        var events = pedal.sorted { $0.t < $1.t }
        events.append((t: .greatestFiniteMagnitude, down: false))   // close a hold still open
        for e in events {
            if e.down && !isDown { isDown = true; downSince = e.t }
            else if !e.down && isDown {
                isDown = false
                let crossed = barTimes.filter { $0.t > downSince && $0.t < e.t }.map(\.bar)
                if crossed.count >= 2, let f = crossed.first, let l = crossed.last {
                    holds.append((f - 1)...l)   // the hold began in the bar before the first line
                }
            }
        }
        return holds
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
            softest: soft.map { .init(name: noteName($0.pitch), velocity: $0.velocity) },
            loudest: loud.map { .init(name: noteName($0.pitch), velocity: $0.velocity) })
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
