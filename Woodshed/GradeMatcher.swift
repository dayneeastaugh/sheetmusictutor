//
//  GradeMatcher.swift
//  Woodshed
//
//  The Grade-mode matching engine, extracted as a pure struct (PRD §9: the matcher
//  must be UI-decoupled and testable). It consumes expected notes + live note-ons +
//  the playback clock and produces hits / misses / wrongs and **signed** timing
//  errors (negative = early/rushing, positive = late/dragging) — the actionable
//  half of timing feedback the old unsigned average couldn't give.
//
//  No engine or UI references; `PracticeSession` owns one per pass and forwards
//  events into it. Unit-tested in WoodshedTests.
//

import Foundation

struct GradeMatcher {
    struct ExpectedNote {
        let pitch: Int
        let onset: Double      // musical seconds (same clock as playback)
        let beat: Double       // notated beat, for on-score marks
        var matched = false
    }

    /// End-of-pass tally.
    struct Tally {
        var hits: Int
        var total: Int
        var missed: Int
        var wrong: Int
        var avgAbsMs: Double     // mean |timing error| of hits
        var meanSignedMs: Double // mean signed error: < 0 rushing, > 0 dragging
        var accuracy: Double { total > 0 ? Double(hits) / Double(total) : 0 }
    }

    let tolerance: Double                       // musical seconds; a note counts within ± this
    /// Tap-along / rhythm mode: ANY key matches the nearest expected onset — grading
    /// timing only, not pitch (the expected list should be onset-collapsed).
    let pitchAgnostic: Bool
    private(set) var expected: [ExpectedNote]
    private(set) var hits = 0
    private(set) var wrong = 0
    private(set) var signedErrors: [Double] = []  // seconds; one per hit
    private var checkIdx = 0                      // expected notes before this have closed windows

    init(expected: [(pitch: Int, onset: Double, beat: Double)], tolerance: Double,
         pitchAgnostic: Bool = false) {
        self.expected = expected
            .sorted { $0.onset < $1.onset }
            .map { ExpectedNote(pitch: $0.pitch, onset: $0.onset, beat: $0.beat) }
        self.tolerance = tolerance
        self.pitchAgnostic = pitchAgnostic
    }

    /// A live note-on at playback time `t`: match it to the nearest unmatched
    /// expected note of the same pitch (any pitch when `pitchAgnostic`) within
    /// tolerance → hit (recording the signed error); otherwise it's a wrong/extra.
    /// Returns `true` if it was a hit, `false` if it was a wrong note (so the caller
    /// can mark wrong notes on the score).
    @discardableResult
    mutating func noteOn(_ pitch: Int, at t: Double) -> Bool {
        var best = -1
        var bestAbs = tolerance + 1
        for i in expected.indices where !expected[i].matched
            && (pitchAgnostic || expected[i].pitch == pitch) {
            let d = abs(expected[i].onset - t)
            if d <= tolerance && d < bestAbs { bestAbs = d; best = i }
        }
        if best >= 0 {
            expected[best].matched = true
            hits += 1
            signedErrors.append(t - expected[best].onset)   // + late, − early
            return true
        }
        wrong += 1
        return false
    }

    /// Advance to playback time `t`, closing the window of every expected note whose
    /// tolerance has now elapsed. Returns the notes that just became missed, so the
    /// UI can ring them progressively as the cursor passes.
    mutating func closeWindows(upTo t: Double) -> [(beat: Double, pitch: Int)] {
        var newlyMissed: [(beat: Double, pitch: Int)] = []
        while checkIdx < expected.count && expected[checkIdx].onset + tolerance < t {
            let e = expected[checkIdx]
            if !e.matched { newlyMissed.append((beat: e.beat, pitch: e.pitch)) }
            checkIdx += 1
        }
        return newlyMissed
    }

    /// Every expected note that ended the pass unmatched (for trouble-bar attribution).
    func unmatched() -> [ExpectedNote] { expected.filter { !$0.matched } }

    /// The finished pass's numbers.
    func tally() -> Tally {
        let missed = expected.count - hits
        let avgAbs = signedErrors.isEmpty ? 0
            : signedErrors.map(abs).reduce(0, +) / Double(signedErrors.count) * 1000
        let meanSigned = signedErrors.isEmpty ? 0
            : signedErrors.reduce(0, +) / Double(signedErrors.count) * 1000
        return Tally(hits: hits, total: expected.count, missed: missed, wrong: wrong,
                     avgAbsMs: avgAbs, meanSignedMs: meanSigned)
    }
}
