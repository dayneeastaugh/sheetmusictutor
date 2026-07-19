//
//  WoodshedTests.swift
//  WoodshedTests
//
//  Tests for the music-domain core — the highest-consequence, pure-Swift logic.
//  Golden numbers are taken from the two bundled fixtures (real MuseScore 4.7.3
//  exports); if a parser/fusion change shifts them, that's a behaviour change to
//  justify, not a test to silence. See docs/audit/04-roadmap.md (Wave 0/1).
//

import Testing
import Foundation
import Compression
@testable import Woodshed

// MARK: - Fixture loading

private func fixtureData(_ name: String, _ ext: String) throws -> Data {
    // Fixtures ship in the app bundle's Scores/ (folder-synced); the test bundle
    // links the app, so read them via the app's bundle.
    let bundle = Bundle(for: SongLibrary.self)
    guard let url = bundle.url(forResource: name, withExtension: ext, subdirectory: "Scores")
            ?? bundle.url(forResource: name, withExtension: ext) else {
        throw NSError(domain: "fixtures", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "missing fixture \(name).\(ext)"])
    }
    return try Data(contentsOf: url)
}

// MARK: - MIDI parser robustness (MUSIC-02)

@Suite("MIDIParser robustness")
struct MIDIParserRobustness {

    @Test("intact fixture parses with expected note count")
    func intactFixture() throws {
        let score = try MIDIParser.parse(data: try fixtureData("Fly Me To the Moon", "mid"))
        #expect(score.notes.count == 333)
        #expect(score.ticksPerQuarter > 0)
    }

    @Test("truncated files throw instead of crashing")
    func truncation() throws {
        let good = try fixtureData("Fly Me To the Moon", "mid")
        // Every prefix of the header/first-track region, plus samples through the file.
        var lengths = Array(0..<min(600, good.count))
        lengths += stride(from: 600, to: good.count, by: max(1, good.count / 40))
        for n in lengths {
            #expect(throws: Error.self, "prefix \(n) bytes should throw") {
                _ = try MIDIParser.parse(data: good.prefix(n))
            }
        }
    }

    @Test("junk inputs throw")
    func junk() {
        for data in [Data(), Data("not a midi file".utf8), Data(repeating: 0xFF, count: 64)] {
            #expect(throws: Error.self) { _ = try MIDIParser.parse(data: data) }
        }
    }

    @Test("random single-byte corruption never crashes (parses or throws)")
    func corruption() throws {
        let good = try fixtureData("Fly Me To the Moon", "mid")
        var seed: UInt64 = 42
        func rnd(_ n: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int(seed % UInt64(n))
        }
        for _ in 0..<200 {
            var d = good
            d[rnd(d.count)] = UInt8(rnd(256))
            _ = try? MIDIParser.parse(data: d)   // outcome may be either; surviving is the test
        }
    }
}

// MARK: - Golden reconciliation (the fixtures must fuse cleanly)

@Suite("Ingestion goldens")
struct IngestionGoldens {

    private func fuse(_ name: String) throws -> FusedScore {
        try Ingest.fuse(midiData: try fixtureData(name, "mid"),
                        musicXMLData: try fixtureData(name, "musicxml"))
    }

    @Test("Fly Me To the Moon reconciles cleanly")
    func flyMe() throws {
        let s = try fuse("Fly Me To the Moon")
        #expect(s.structureWarning == nil)
        for r in s.reconciliations {
            #expect(r.isClean, "hand \(r.hand.rawValue): \(r.unmatchedMIDI) \(r.unmatchedXML)")
        }
        #expect(s.events.count == 333)          // one event per MIDI note-on (no ornaments here)
        #expect(s.measureStartBeats.count > 20) // sane bar structure
    }

    @Test("Chopin nocturne reconciles cleanly (with ornament absorption)")
    func chopin() throws {
        let s = try fuse("chopin-nocturne-op-9-no-2-e-flat-major")
        #expect(s.structureWarning == nil)
        for r in s.reconciliations {
            #expect(r.isClean, "hand \(r.hand.rawValue): \(r.unmatchedMIDI) \(r.unmatchedXML)")
        }
        let absorbed = s.reconciliations.reduce(0) { $0 + $1.ornamentRealizations }
        #expect(absorbed > 0)                   // the Chopin's trills/turns are absorbed, not errors
    }

    @Test("structure mismatch predicate (repeats guard)")
    func structureGuard() {
        // MIDI ends within a bar of the written score → fine.
        #expect(!Ingest.timelinesMismatch(xmlTotalBeats: 128, lastMidiBeat: 127.5, barBeats: 4))
        #expect(!Ingest.timelinesMismatch(xmlTotalBeats: 128, lastMidiBeat: 131.9, barBeats: 4))
        // MIDI runs a repeat's worth past the score → warn.
        #expect(Ingest.timelinesMismatch(xmlTotalBeats: 128, lastMidiBeat: 192, barBeats: 4))
        // Degenerate score → never warn.
        #expect(!Ingest.timelinesMismatch(xmlTotalBeats: 0, lastMidiBeat: 50, barBeats: 4))
    }
}

// MARK: - Speed trainer / mastery drill (pure transition)

@Suite("Speed trainer drill")
struct SpeedTrainerDrill {
    typealias S = PracticeSession.DrillState

    private func advance(_ s: S, acc: Double, mode: PracticeSession.SpeedTrainerMode = .byAccuracy,
                         threshold: Double = 0.9, per: Int = 2, target: Double = 100, step: Double = 10) -> S {
        PracticeSession.drillAdvance(mode: mode, accuracy: acc, threshold: threshold,
                                     passesPerStep: per, passes: s.passes, tempoPct: s.tempoPct,
                                     target: target, step: step, mastered: s.mastered)
    }

    @Test("mastery gate: dirty pass resets the streak; clean passes ramp to target")
    func byAccuracy() {
        var s = S(passes: 0, tempoPct: 80, mastered: false)
        s = advance(s, acc: 0.95); #expect(s == S(passes: 1, tempoPct: 80, mastered: false))
        s = advance(s, acc: 0.50); #expect(s == S(passes: 0, tempoPct: 80, mastered: false))   // reset
        s = advance(s, acc: 0.95); s = advance(s, acc: 0.95)
        #expect(s == S(passes: 0, tempoPct: 90, mastered: false))                              // step
        s = advance(s, acc: 0.95); s = advance(s, acc: 0.95)
        #expect(s == S(passes: 0, tempoPct: 100, mastered: false))                             // at target
        s = advance(s, acc: 0.95); s = advance(s, acc: 0.95)
        #expect(s == S(passes: 0, tempoPct: 100, mastered: true))                              // mastered
        let after = advance(s, acc: 0.95)
        #expect(after == s)                                                                    // sticky
    }

    @Test("step clamps to the target, never overshoots")
    func clamp() {
        let s = advance(S(passes: 0, tempoPct: 95, mastered: false), acc: 1.0, per: 1)
        #expect(s.tempoPct == 100)
    }

    @Test("hands progression stages advance R.H. → L.H. → both, then complete")
    func stages() {
        typealias Stage = PracticeSession.DrillStage
        #expect(Stage.rh.next == .lh)
        #expect(Stage.lh.next == .both)
        #expect(Stage.both.next == nil)
        #expect(Stage.rh.handMode == 1 && Stage.lh.handMode == 2 && Stage.both.handMode == 0)
    }

    @Test("by reps ignores accuracy; off is a no-op")
    func repsAndOff() {
        var r = S(passes: 0, tempoPct: 60, mastered: false)
        for _ in 0..<3 { r = advance(r, acc: 0.1, mode: .byReps, per: 3, step: 20) }
        #expect(r == S(passes: 0, tempoPct: 80, mastered: false))
        let o = advance(S(passes: 5, tempoPct: 70, mastered: false), acc: 1.0, mode: .off)
        #expect(o == S(passes: 5, tempoPct: 70, mastered: false))
    }
}

// MARK: - Practice history (trouble spots + persistence round-trip)

@Suite("Practice history")
struct PracticeHistoryTests {

    private func pass(_ ss: Int, _ se: Int, missed: [Int]) -> PracticePass {
        PracticePass(sectionStart: ss, sectionEnd: se, measureCount: 10, tempoPct: 100, handMode: 0,
                     total: 10, hits: 10 - missed.count, missed: missed.count, wrong: 0,
                     avgMs: 20, missedBars: missed)
    }

    @Test("current trouble bars clear as you improve")
    func decay() {
        let passes = [pass(1, 10, missed: [3, 3, 7]),
                      pass(1, 10, missed: [3, 7]),
                      pass(1, 10, missed: [7])]           // newest: bar 3 clean, bar 7 still missed
        #expect(PracticeHistory.currentTroubleBars(passes).map(\.bar) == [7])
        #expect(Set(PracticeHistory.troubleBars(passes).map(\.bar)) == Set([3, 7]))
    }

    @Test("a clean section drill clears only the bars it covered")
    func sectionDrill() {
        let passes = [pass(1, 10, missed: [4, 4, 6]),
                      pass(3, 5, missed: [])]             // drilled 3–5 clean → bar 4 cleared, 6 stays
        let bars = PracticeHistory.currentTroubleBars(passes).map(\.bar)
        #expect(!bars.contains(4))
        #expect(bars.contains(6))
    }

    @Test("history.jsonl round-trip skips a malformed line")
    func roundTrip() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ws-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        PracticeHistory.append(pass(1, 10, missed: [2]), to: dir)
        PracticeHistory.append(pass(3, 5, missed: []), to: dir)
        var text = try String(contentsOf: PracticeHistory.fileURL(in: dir), encoding: .utf8)
        text += "this is not json\n"
        try text.write(to: PracticeHistory.fileURL(in: dir), atomically: true, encoding: .utf8)

        let loaded = PracticeHistory.load(from: dir)
        #expect(loaded.count == 2)
        #expect(loaded[0].missedBars == [2])
    }
}

// MARK: - Grade matcher (the pure Grade-mode engine)

@Suite("Grade matcher")
struct GradeMatcherTests {

    private func matcher(_ notes: [(Int, Double)], tol: Double = 0.3) -> GradeMatcher {
        GradeMatcher(expected: notes.map { (pitch: $0.0, onset: $0.1, beat: $0.1 * 2) }, tolerance: tol)
    }

    @Test("hits, misses, and wrongs are classified correctly")
    func classification() {
        var m = matcher([(60, 1.0), (62, 2.0), (64, 3.0)])
        m.noteOn(60, at: 1.1)          // hit, +100ms late
        m.noteOn(70, at: 1.5)          // wrong (no 70 expected)
        m.noteOn(62, at: 2.5)          // outside ±0.3 → wrong, and 62 becomes a miss
        _ = m.closeWindows(upTo: 10)
        let t = m.tally()
        #expect(t.hits == 1 && t.wrong == 2 && t.missed == 2 && t.total == 3)
    }

    @Test("noteOn returns true for a hit, false for a wrong note")
    func noteOnReturn() {
        var m = matcher([(60, 1.0)])
        #expect(m.noteOn(60, at: 1.05) == true)    // hit
        #expect(m.noteOn(61, at: 1.05) == false)   // wrong pitch → wrong note
        #expect(m.noteOn(60, at: 5.0) == false)    // right pitch, far too late → wrong
    }

    @Test("signed timing: early = rushing (negative), late = dragging (positive)")
    func signedTiming() {
        var m = matcher([(60, 1.0), (62, 2.0)])
        m.noteOn(60, at: 0.90)         // 100ms early
        m.noteOn(62, at: 2.20)         // 200ms late
        let t = m.tally()
        #expect(abs(t.meanSignedMs - 50) < 0.001)     // (−100 + 200)/2
        #expect(abs(t.avgAbsMs - 150) < 0.001)        // (100 + 200)/2
    }

    @Test("windows close progressively and report newly-missed notes once")
    func progressiveMisses() {
        var m = matcher([(60, 1.0), (62, 2.0), (64, 3.0)])
        m.noteOn(62, at: 2.0)                          // only the middle note is played
        #expect(m.closeWindows(upTo: 1.5).map(\.pitch) == [60])
        #expect(m.closeWindows(upTo: 2.5).isEmpty)     // 62 was hit
        #expect(m.closeWindows(upTo: 9.9).map(\.pitch) == [64])
        #expect(m.closeWindows(upTo: 99).isEmpty)      // nothing reported twice
    }

    @Test("repeated same-pitch notes match nearest, not first")
    func repeatedNotes() {
        var m = matcher([(60, 1.0), (60, 1.4)])
        m.noteOn(60, at: 1.38)                         // nearest is the second one
        m.noteOn(60, at: 1.02)
        let t = m.tally()
        #expect(t.hits == 2 && t.missed == 0 && t.wrong == 0)
    }

    @Test("chord notes match in any order within the window")
    func chordAnyOrder() {
        var m = matcher([(60, 1.0), (64, 1.0), (67, 1.0)])
        for p in [67, 60, 64] { m.noteOn(p, at: 1.05) }
        #expect(m.tally().hits == 3)
    }

    @Test("tap-along (pitch-agnostic): any key matches the nearest onset")
    func tapAlong() {
        var m = GradeMatcher(expected: [(60, 1.0, 2.0), (64, 2.0, 4.0)],
                             tolerance: 0.3, pitchAgnostic: true)
        m.noteOn(35, at: 1.05)          // wrong pitch, right time → hit
        m.noteOn(99, at: 2.10)          // any key → hit (+100ms)
        m.noteOn(35, at: 3.0)           // nothing near → wrong
        let t = m.tally()
        #expect(t.hits == 2 && t.wrong == 1 && t.missed == 0)
    }

    @Test("tolerance boundary: inside counts, outside doesn't")
    func boundary() {
        // 0.25 is exactly representable in binary floating point (1.3 − 1.0 is not),
        // so the boundary test isn't at the mercy of float rounding.
        var m = matcher([(60, 1.0)], tol: 0.25)
        m.noteOn(60, at: 1.25)                         // exactly on the edge → hit
        #expect(m.tally().hits == 1)
        var m2 = matcher([(60, 1.0)], tol: 0.25)
        m2.noteOn(60, at: 1.375)                       // clearly outside → wrong
        #expect(m2.tally().hits == 0 && m2.tally().wrong == 1)
    }
}

// MARK: - Rhythm-only tick grid (hand isolation)

@Suite("Rhythm grid")
struct RhythmGridTests {
    private func ev(_ pitch: Int, _ hand: Hand, _ onset: Double) -> NoteEvent {
        NoteEvent(pitch: pitch, spelledName: "x", hand: hand, voice: 1, notatedType: "quarter",
                  onsetSeconds: onset, durationSeconds: 0.4, notatedBeat: onset * 2,
                  matchedXML: true, ornamentNotes: 0)
    }

    @Test("hand filter + chord dedupe produce the right tick times")
    func handIsolation() {
        let events = [
            ev(60, .right, 0.0),
            ev(55, .left,  0.5),
            ev(62, .right, 1.0),
            ev(57, .left,  1.0),   // chord across hands at t=1.0
            ev(64, .right, 2.0),
            ev(67, .right, 2.0),   // chord within RH at t=2.0
        ]
        #expect(PracticeSession.rhythmOnsets(events, handMode: 0) == [0.0, 0.5, 1.0, 2.0])   // both
        #expect(PracticeSession.rhythmOnsets(events, handMode: 1) == [0.0, 1.0, 2.0])         // RH
        #expect(PracticeSession.rhythmOnsets(events, handMode: 2) == [0.5, 1.0])              // LH
    }

    @Test("unknown-hand notes tick as right hand; empty input is empty")
    func unknownAndEmpty() {
        let events = [ev(60, .unknown, 0.0), ev(55, .left, 1.0)]
        #expect(PracticeSession.rhythmOnsets(events, handMode: 1) == [0.0])   // RH sees the unknown
        #expect(PracticeSession.rhythmOnsets(events, handMode: 2) == [1.0])   // LH doesn't
        #expect(PracticeSession.rhythmOnsets([], handMode: 0) == [])
    }
}

// MARK: - Parser fixes (Wave 2)

@Suite("Parser fixes")
struct ParserFixTests {

    /// Build a minimal SMF from per-track lists of (delta, status, data…) events.
    private func smf(tracks: [[[UInt8]]], ticksPerQuarter: UInt8 = 96) -> Data {
        var d: [UInt8] = [0x4D, 0x54, 0x68, 0x64, 0, 0, 0, 6,           // MThd
                          0, 1, 0, UInt8(tracks.count), 0, ticksPerQuarter]
        for events in tracks {
            var track: [UInt8] = []
            for e in events { track += e }
            track += [0x00, 0xFF, 0x2F, 0x00]                           // end of track
            d += [0x4D, 0x54, 0x72, 0x6B, 0, 0, 0, UInt8(track.count)]  // MTrk
            d += track
        }
        return Data(d)
    }
    private func smf(_ events: [[UInt8]], ticksPerQuarter: UInt8 = 96) -> Data {
        smf(tracks: [events], ticksPerQuarter: ticksPerQuarter)
    }

    @Test("overlapping same-pitch notes both survive (stack, not overwrite)")
    func overlappingNotes() throws {
        // noteOn 60, then a second noteOn 60 before the first's noteOff.
        let data = smf([[0x00, 0x90, 60, 90],    // on @0
                        [0x30, 0x90, 60, 90],    // on @48 (overlap)
                        [0x30, 0x80, 60, 0],     // off @96 (closes the SECOND — LIFO)
                        [0x30, 0x80, 60, 0]])    // off @144 (closes the first)
        let score = try MIDIParser.parse(data: data)
        #expect(score.notes.count == 2)
        let sorted = score.notes.sorted { $0.onsetBeats < $1.onsetBeats }
        #expect(sorted[0].onsetBeats == 0.0 && sorted[1].onsetBeats == 0.5)
    }

    private func musicXML(parts: Int, graceBeforePrincipal: Bool = false) -> Data {
        let grace = graceBeforePrincipal ? """
            <note><grace/><pitch><step>C</step><octave>5</octave></pitch>
                  <voice>1</voice><type>eighth</type></note>
            """ : ""
        let onePart = """
            <part id="P1"><measure number="1">
              <attributes><divisions>4</divisions>
                <time><beats>4</beats><beat-type>4</beat-type></time></attributes>
              \(grace)
              <note><pitch><step>C</step><octave>5</octave></pitch>
                    <duration>4</duration><voice>1</voice><type>quarter</type></note>
            </measure></part>
            """
        let extra = parts > 1 ? onePart.replacingOccurrences(of: "P1", with: "P2") : ""
        return Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <score-partwise version="4.0">\(onePart)\(extra)</score-partwise>
            """.utf8)
    }

    @Test("multi-part scores are refused with a clear error")
    func multiPart() {
        #expect(throws: Error.self) { _ = try MusicXMLParser.parse(data: musicXML(parts: 2)) }
        #expect(throws: Never.self) { _ = try MusicXMLParser.parse(data: musicXML(parts: 1)) }
    }

    @Test("grace notes are parsed as grace and don't advance the measure cursor")
    func graceParsing() throws {
        let score = try MusicXMLParser.parse(data: musicXML(parts: 1, graceBeforePrincipal: true))
        let notes = score.notes.filter { !$0.isRest }
        #expect(notes.count == 2)
        #expect(notes[0].isGrace && !notes[1].isGrace)
        #expect(notes[0].onsetBeats == notes[1].onsetBeats)   // grace sits AT the principal's beat
        #expect(notes[0].durationBeats == 0)
    }

    @Test("cross-staff notes match across hands (Moonlight pattern)")
    func crossStaff() throws {
        // XML: C5 on staff 1 (RH) and E3 on staff 2 (LH) — but the MIDI's RH track
        // plays BOTH (the E3 is written on the bass staff for readability).
        let xml = Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <score-partwise version="4.0"><part id="P1">
              <measure number="1">
                <attributes><divisions>4</divisions>
                  <time><beats>4</beats><beat-type>4</beat-type></time></attributes>
                <note><pitch><step>C</step><octave>5</octave></pitch>
                      <duration>8</duration><voice>1</voice><staff>1</staff></note>
                <note><pitch><step>E</step><octave>3</octave></pitch>
                      <duration>8</duration><voice>1</voice><staff>2</staff></note>
                <backup><duration>16</duration></backup>
                <note><pitch><step>C</step><octave>2</octave></pitch>
                      <duration>16</duration><voice>5</voice><staff>2</staff></note>
              </measure>
            </part></score-partwise>
            """.utf8)
        // MIDI track 0 (RH): C5 then E3. Track 1 (LH): C2 whole note.
        let rh: [[UInt8]] = [[0x00, 0x90, 72, 90], [0x81, 0x40, 0x80, 72, 0],   // C5, half note (192)
                             [0x00, 0x90, 52, 90], [0x81, 0x40, 0x80, 52, 0]]   // E3, half note
        let lh: [[UInt8]] = [[0x00, 0x90, 36, 80], [0x83, 0x00, 0x80, 36, 0]]   // C2, whole (384)
        let fused = try Ingest.fuse(midiData: smf(tracks: [rh, lh]), musicXMLData: xml)
        for r in fused.reconciliations {
            #expect(r.isClean, "hand \(r.hand.rawValue): \(r.unmatchedMIDI) \(r.unmatchedXML)")
        }
        let rhRec = fused.reconciliations.first { $0.hand == .right }!
        #expect(rhRec.crossStaff == 1)                          // the E3 married across staves
        // The cross-staff event PLAYS as RH (MIDI truth) with the XML's identity.
        let e3 = fused.events.first { $0.pitch == 52 }!
        #expect(e3.hand == .right && e3.matchedXML && e3.spelledName == "E3")
    }

    @Test("grace note never steals the principal's MIDI partner")
    func gracePriority() throws {
        // Two tracks so the average-pitch heuristic assigns hands (track 0 = RH):
        // RH has the grace realization + the principal (same pitch); LH one low note.
        let rh: [[UInt8]] = [[0x00, 0x90, 72, 80],    // grace on @0
                             [0x14, 0x80, 72, 0],     // grace off @20
                             [0x04, 0x90, 72, 90],    // principal on @24 (= beat 0.25 at tpq 96)
                             [0x60, 0x80, 72, 0]]     // principal off
        let lh: [[UInt8]] = [[0x00, 0x90, 30, 80],
                             [0x60, 0x80, 30, 0]]
        let fused = try Ingest.fuse(midiData: smf(tracks: [rh, lh]),
                                    musicXMLData: musicXML(parts: 1, graceBeforePrincipal: true))
        // Both RH XML notes matched — the zero-duration grace didn't leave the
        // principal partnerless (principals match first, graces second).
        let rec = fused.reconciliations.first { $0.hand == .right }!
        #expect(rec.unmatchedXML.isEmpty && rec.unmatchedMIDI.isEmpty)
        #expect(rec.matched == 2)
    }
}

// MARK: - Repeats / voltas unfolding

@Suite("Repeat unfolding")
struct RepeatUnfoldTests {

    private func mark(f: Bool = false, b: Bool = false, times: Int = 2,
                      ending: [Int] = [], stop: Bool = false) -> RepeatMarks {
        RepeatMarks(forward: f, backward: b, times: times, endingNumbers: ending, endingStop: stop)
    }

    @Test("no repeats → identity order")
    func identity() {
        let marks = [mark(), mark(), mark()]
        #expect(Ingest.unfoldOrder(marks: marks) == [0, 1, 2])
    }

    @Test("simple repeat: bars 1–2 played twice, then 3")
    func simpleRepeat() {
        let marks = [mark(f: true), mark(b: true), mark()]
        #expect(Ingest.unfoldOrder(marks: marks) == [0, 1, 0, 1, 2])
    }

    @Test("repeat from the piece start (no forward barline)")
    func implicitStart() {
        let marks = [mark(), mark(b: true), mark()]
        #expect(Ingest.unfoldOrder(marks: marks) == [0, 1, 0, 1, 2])
    }

    @Test("first/second endings (voltas)")
    func voltas() {
        // 0 1 [volta1: 2 :||] [volta2: 3] 4
        let marks = [mark(), mark(),
                     mark(ending: [1], stop: true) /* has backward */,
                     mark(ending: [2], stop: true),
                     mark()]
        var m2 = marks; m2[2].backward = true
        #expect(Ingest.unfoldOrder(marks: m2) == [0, 1, 2, 0, 1, 3, 4])
    }

    @Test("three-times repeat honours times attribute")
    func threeTimes() {
        let marks = [mark(f: true), mark(b: true, times: 3), mark()]
        #expect(Ingest.unfoldOrder(marks: marks) == [0, 1, 0, 1, 0, 1, 2])
    }

    @Test("end-to-end: a repeated piece fuses cleanly with written beats preserved")
    func endToEnd() throws {
        // 2 written bars in 4/4, bars 1–2 repeated: written C4 (bar 1) + E4 (bar 2),
        // MIDI plays C E C E (each a whole note, tpq 96 → 384 ticks/bar).
        let xml = Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <score-partwise version="4.0"><part id="P1">
              <measure number="1">
                <attributes><divisions>4</divisions>
                  <time><beats>4</beats><beat-type>4</beat-type></time></attributes>
                <barline location="left"><repeat direction="forward"/></barline>
                <note><pitch><step>C</step><octave>4</octave></pitch>
                      <duration>16</duration><voice>1</voice><type>whole</type></note>
              </measure>
              <measure number="2">
                <note><pitch><step>E</step><octave>4</octave></pitch>
                      <duration>16</duration><voice>1</voice><type>whole</type></note>
                <barline location="right"><repeat direction="backward"/></barline>
              </measure>
            </part></score-partwise>
            """.utf8)
        // MIDI: two tracks (RH melody + LH pedal tone so hands assign); RH = C E C E.
        func on(_ d: UInt8, _ p: UInt8) -> [UInt8] { [d, 0x90, p, 90] }
        func off(_ d: UInt8, _ p: UInt8) -> [UInt8] { [d, 0x80, p, 0] }
        var rh: [[UInt8]] = []
        for p: UInt8 in [60, 64, 60, 64] {                     // C4 E4 C4 E4, whole notes
            rh.append(on(0, p))
            rh.append([0x83, 0x00, 0x80, p, 0])                // delta 384 (varlen 0x83 0x00)
        }
        _ = off  // (helper kept for clarity)
        let lh: [[UInt8]] = [[0x00, 0x90, 30, 80], [0x83, 0x00, 0x80, 30, 0]]
        var d: [UInt8] = [0x4D, 0x54, 0x68, 0x64, 0, 0, 0, 6, 0, 1, 0, 2, 0, 96]
        for events in [rh, lh] {
            var track: [UInt8] = []
            for e in events { track += e }
            track += [0x00, 0xFF, 0x2F, 0x00]
            d += [0x4D, 0x54, 0x72, 0x6B, 0, 0, 0, UInt8(track.count)]
            d += track
        }

        let fused = try Ingest.fuse(midiData: Data(d), musicXMLData: xml)
        #expect(fused.structureWarning == nil)                 // unfold explains the length
        let rec = fused.reconciliations.first { $0.hand == .right }!
        #expect(rec.isClean, "\(rec.unmatchedMIDI) \(rec.unmatchedXML)")
        #expect(rec.matched == 4)                              // both passes matched

        // Written beats: the second pass maps BACK to bars 1–2 (beats 0 and 4).
        let rhEvents = fused.events.filter { $0.hand == .right }.sorted { $0.onsetSeconds < $1.onsetSeconds }
        #expect(rhEvents.map(\.notatedBeat) == [0, 4, 0, 4])
        #expect(fused.totalBeats == 8)                         // written length (2 bars)
        // The metronome clicks all 4 played bars (16 quarter clicks).
        #expect(fused.clickGrid.count == 16)
        // Written beat 4 (bar 2) maps to its FIRST occurrence in time.
        #expect(abs(fused.secondsAtBeat(4) - 2.0) < 0.01)      // 4 beats @ 120 BPM = 2 s
        // The written end maps to the UNFOLDED end (both passes play out).
        #expect(abs(fused.secondsAtBeat(8) - 8.0) < 0.01)      // 16 beats @ 120 BPM
    }
}

// MARK: - MXL (compressed MusicXML) archive reader

@Suite("MXL archive")
struct MXLArchiveTests {

    /// Hand-build a ZIP with one stored entry (container.xml) and one deflate entry
    /// (the score), so the reader is tested hermetically — no external zip tool.
    private func makeMXL(scoreName: String = "score.xml", score: Data) throws -> Data {
        let container = Data("""
            <?xml version="1.0"?><container><rootfiles>
            <rootfile full-path="\(scoreName)"/></rootfiles></container>
            """.utf8)
        // Raw-deflate the score with the Compression framework (what ZIP stores).
        var deflated = Data(count: score.count + 1024)
        let written = deflated.withUnsafeMutableBytes { dst in
            score.withUnsafeBytes { src in
                compression_encode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, score.count + 1024,
                                          src.bindMemory(to: UInt8.self).baseAddress!, score.count,
                                          nil, COMPRESSION_ZLIB)
            }
        }
        deflated = deflated.prefix(written)

        func u16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
        func u32(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)] }

        var zip: [UInt8] = []
        var central: [UInt8] = []
        func addEntry(name: String, payload: Data, method: Int, uncompressed: Int) {
            let nameBytes = [UInt8](name.utf8)
            let offset = zip.count
            // Local header (time/date/crc left zero — the reader doesn't check them).
            zip += [0x50, 0x4B, 0x03, 0x04]
            zip += u16(20); zip += u16(0); zip += u16(method)
            zip += u16(0); zip += u16(0); zip += u32(0)
            zip += u32(payload.count); zip += u32(uncompressed)
            zip += u16(nameBytes.count); zip += u16(0)
            zip += nameBytes; zip += [UInt8](payload)
            // Central directory entry.
            central += [0x50, 0x4B, 0x01, 0x02]
            central += u16(20); central += u16(20); central += u16(0); central += u16(method)
            central += u16(0); central += u16(0); central += u32(0)
            central += u32(payload.count); central += u32(uncompressed)
            central += u16(nameBytes.count); central += u16(0); central += u16(0)
            central += u16(0); central += u16(0); central += u32(0)
            central += u32(offset); central += nameBytes
        }
        addEntry(name: "META-INF/container.xml", payload: container, method: 0, uncompressed: container.count)
        addEntry(name: scoreName, payload: deflated, method: 8, uncompressed: score.count)
        let cdOffset = zip.count
        zip += central
        // End of central directory.
        zip += [0x50, 0x4B, 0x05, 0x06]
        zip += u16(0); zip += u16(0); zip += u16(2); zip += u16(2)
        zip += u32(central.count); zip += u32(cdOffset); zip += u16(0)
        return Data(zip)
    }

    @Test("extracts the score named by container.xml (deflate entry)")
    func extract() throws {
        let score = Data(String(repeating: "<note>C</note>", count: 200).utf8)   // compressible
        let mxl = try makeMXL(score: score)
        let extracted = try MXLArchive.extractScore(from: mxl)
        #expect(extracted == score)
    }

    @Test("junk and truncated archives throw, never crash")
    func robustness() throws {
        #expect(throws: Error.self) { _ = try MXLArchive.extractScore(from: Data("not a zip".utf8)) }
        #expect(throws: Error.self) { _ = try MXLArchive.extractScore(from: Data()) }
        let good = try makeMXL(score: Data(String(repeating: "x", count: 500).utf8))
        for n in stride(from: 0, to: good.count, by: 37) {
            _ = try? MXLArchive.extractScore(from: good.prefix(n))   // may throw; must not crash
        }
    }
}

// MARK: - Tick tracker (the 50 Hz playback loop's incremental lookups)

@Suite("Tick tracker")
struct TickTrackerTests {

    /// A deterministic pseudo-score: n notes, varied onsets/durations/pitches, sorted
    /// by onset (the invariant `PracticeSession` guarantees).
    private func makeEvents(_ n: Int) -> [NoteEvent] {
        var seed: UInt64 = 7
        func rnd(_ m: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int(seed % UInt64(m))
        }
        var t = 0.0
        return (0..<n).map { _ in
            t += Double(rnd(40)) / 100.0                     // 0–0.4s apart
            return NoteEvent(pitch: 40 + rnd(48), spelledName: "x", hand: rnd(2) == 0 ? .right : .left,
                             voice: 1, notatedType: "quarter", onsetSeconds: t,
                             durationSeconds: 0.05 + Double(rnd(60)) / 100.0,
                             notatedBeat: t * 2, matchedXML: true, ornamentNotes: 0)
        }
    }

    @Test("incremental results match a brute-force scan at every step")
    func equivalence() {
        let events = makeEvents(300)
        let schedule = events.map { (time: $0.onsetSeconds, beat: $0.notatedBeat) }
        let tol = 0.30
        var tracker = TickTracker()
        let end = (events.last?.onsetSeconds ?? 0) + 1
        var t = 0.0
        while t < end {
            tracker.advance(to: t, tolerance: tol, schedule: schedule, events: events)

            // Brute-force ground truth (the old per-tick full scans).
            let active = Set(events.indices.filter {
                events[$0].onsetSeconds <= t && t < events[$0].onsetSeconds + events[$0].durationSeconds
            })
            #expect(Set(tracker.activeIdx) == active, "active set at t=\(t)")

            let window = Set(events.indices.filter { abs(events[$0].onsetSeconds - t) <= tol })
            #expect(Set(tracker.winLo..<tracker.winHi).filter {
                abs(events[$0].onsetSeconds - t) <= tol
            }.count == window.count, "grade window at t=\(t)")

            var discrete = schedule.first?.beat ?? 0
            for e in schedule where e.time <= t { discrete = e.beat }
            #expect(tracker.discreteBeat(schedule: schedule) == discrete, "discrete beat at t=\(t)")

            t += 0.037   // deliberately not a divisor of the onset grid
        }
    }

    @Test("a backwards jump (loop restart) resets and stays correct")
    func loopRestart() {
        let events = makeEvents(100)
        let schedule = events.map { (time: $0.onsetSeconds, beat: $0.notatedBeat) }
        var tracker = TickTracker()
        tracker.advance(to: 10.0, tolerance: 0.3, schedule: schedule, events: events)
        tracker.advance(to: 0.5, tolerance: 0.3, schedule: schedule, events: events)   // loop back
        let active = Set(events.indices.filter {
            events[$0].onsetSeconds <= 0.5 && 0.5 < events[$0].onsetSeconds + events[$0].durationSeconds
        })
        #expect(Set(tracker.activeIdx) == active)
    }

    @Test("continuous beat interpolates between anchors and clamps at the ends")
    func interpolation() {
        let schedule: [(time: Double, beat: Double)] = [(1.0, 0.0), (2.0, 4.0), (4.0, 8.0)]
        var tracker = TickTracker()
        tracker.advance(to: 0.5, tolerance: 0.3, schedule: schedule, events: [])
        #expect(tracker.continuousBeat(at: 0.5, schedule: schedule) == 0.0)   // before first anchor
        tracker.advance(to: 1.5, tolerance: 0.3, schedule: schedule, events: [])
        #expect(tracker.continuousBeat(at: 1.5, schedule: schedule) == 2.0)   // halfway 0→4
        tracker.advance(to: 3.0, tolerance: 0.3, schedule: schedule, events: [])
        #expect(tracker.continuousBeat(at: 3.0, schedule: schedule) == 6.0)   // halfway 4→8
        tracker.advance(to: 9.0, tolerance: 0.3, schedule: schedule, events: [])
        #expect(tracker.continuousBeat(at: 9.0, schedule: schedule) == 8.0)   // past the end
    }
}

// MARK: - App-level preference persistence

@Suite("App settings persistence")
struct AppSettingsTests {

    /// Round-trip each persisted preference through UserDefaults and confirm the
    /// registered first-launch defaults match the app's intended values. Uses an
    /// isolated suite so the developer's real preferences aren't touched.
    @Test("preferences round-trip and defaults are correct")
    func roundTrip() throws {
        let suiteName = "woodshed-tests-\(UUID().uuidString)"
        let d = try #require(UserDefaults(suiteName: suiteName))
        defer { d.removePersistentDomain(forName: suiteName) }

        // Defaults registration (same table AppSettings.registerDefaults uses).
        d.register(defaults: [
            "pref.cursorSmooth": true, "pref.showScoreNotes": true,
            "pref.showTroubleOnScore": true, "pref.keyboardVisible": true,
            "pref.gradeTolerance": 0.30, "pref.speedTargetPct": 100.0,
            "pref.speedStepPct": 5.0, "pref.speedThreshold": 0.9,
            "pref.speedPassesPerStep": 2,
        ])
        // Un-set keys read their registered defaults, not false/0.
        #expect(d.bool(forKey: "pref.cursorSmooth"))
        #expect(d.bool(forKey: "pref.showScoreNotes"))
        #expect(d.double(forKey: "pref.gradeTolerance") == 0.30)
        #expect(d.integer(forKey: "pref.speedPassesPerStep") == 2)
        // Keys with false/0 defaults (not registered) still read sensibly.
        #expect(d.bool(forKey: "pref.colorHands") == false)
        #expect(d.integer(forKey: "pref.outputMode") == 0)

        // A changed value round-trips.
        d.set(false, forKey: "pref.cursorSmooth")
        d.set(0.45, forKey: "pref.gradeTolerance")
        d.set(2, forKey: "pref.outputMode")
        #expect(d.bool(forKey: "pref.cursorSmooth") == false)
        #expect(d.double(forKey: "pref.gradeTolerance") == 0.45)
        #expect(d.integer(forKey: "pref.outputMode") == 2)
    }
}

// MARK: - Practice time ledger + takes

@Suite("Practice time and takes")
struct TimeAndTakesTests {

    private func tempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ws-tt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("practice streak counts consecutive days (today optional)")
    func streak() {
        let cal = Calendar.current
        func key(_ daysAgo: Int) -> String {
            PracticeTime.dayKey(for: cal.date(byAdding: .day, value: -daysAgo, to: Date())!)
        }
        // Practised today, yesterday, 2 days ago → streak 3.
        #expect(PracticeTime.streak([key(0): 100, key(1): 50, key(2): 30]) == 3)
        // Not today yet, but yesterday + the day before → streak counts from yesterday = 2.
        #expect(PracticeTime.streak([key(1): 50, key(2): 30]) == 2)
        // A gap breaks it: today + 2-days-ago (missed yesterday) → streak 1.
        #expect(PracticeTime.streak([key(0): 100, key(2): 30]) == 1)
        // Nothing recent → 0.
        #expect(PracticeTime.streak([key(5): 100]) == 0)
        #expect(PracticeTime.streak([:]) == 0)
    }

    @Test("time ledger accumulates per day and computes recents")
    func timeLedger() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        PracticeTime.add(100, on: "2026-07-10", to: dir)
        PracticeTime.add(50, on: "2026-07-10", to: dir)
        PracticeTime.add(30, on: "2026-07-01", to: dir)
        let dict = PracticeTime.load(from: dir)
        #expect(dict["2026-07-10"] == 150)
        #expect(PracticeTime.total(dict) == 180)
        // recent(7) from 2026-07-11 includes the 10th but not the 1st.
        let ref = ISO8601DateFormatter().date(from: "2026-07-11T12:00:00Z")!
        #expect(PracticeTime.recent(dict, days: 7, from: ref) == 150)
        #expect(PracticeTime.format(3725) == "1h 02m")
        #expect(PracticeTime.format(240) == "4m")
    }

    @Test("best take per section: kept only when it beats the stored accuracy")
    func bestTake() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let notes = [TakeNote(p: 60, v: 90, on: 0.0, off: 0.5)]
        let take80 = Take(sectionStart: 3, sectionEnd: 5, tempoPct: 100, accuracy: 0.8, notes: notes)
        let take90 = Take(sectionStart: 3, sectionEnd: 5, tempoPct: 100, accuracy: 0.9, notes: notes)
        let take85 = Take(sectionStart: 3, sectionEnd: 5, tempoPct: 100, accuracy: 0.85, notes: notes)
        #expect(TakeStore.keepIfBest(take80, in: dir))          // first is best
        #expect(TakeStore.keepIfBest(take90, in: dir))          // improvement kept
        #expect(!TakeStore.keepIfBest(take85, in: dir))         // regression discarded
        let stored = TakeStore.load(from: dir)[TakeStore.key(start: 3, end: 5)]
        #expect(stored?.accuracy == 0.9)
        #expect(stored?.notes == notes)
        // Ungraded takes are never persisted as "best".
        let ungraded = Take(sectionStart: 1, sectionEnd: 2, tempoPct: 100, accuracy: nil, notes: notes)
        #expect(!TakeStore.keepIfBest(ungraded, in: dir))
    }
}

// MARK: - Metadata back-compat (older metadata.json must keep decoding)

@Suite("SongMeta compatibility")
struct SongMetaCompat {

    @Test("metadata written before newer fields still decodes")
    func backCompat() throws {
        let old = #"{"id":"11111111-1111-1111-1111-111111111111","title":"Old Song","dateAdded":"2026-07-01T00:00:00Z","favourite":true}"#
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let meta = try dec.decode(SongMeta.self, from: Data(old.utf8))
        #expect(meta.title == "Old Song")
        #expect(meta.favourite)
        #expect(meta.barsPerLine == nil)
        #expect(meta.bestAccuracy == nil)
        #expect(meta.lastPracticed == nil)
    }

    @Test("bar flags round-trip with one-per-bar upsert semantics")
    func flags() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ws-flags-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        BarFlagStore.save([BarFlag(bar: 5, note: "LH jump"), BarFlag(bar: 2, note: "trill")], to: dir)
        var loaded = BarFlagStore.load(from: dir)
        #expect(loaded.map(\.bar) == [2, 5])

        loaded.removeAll { $0.bar == 5 }
        loaded.append(BarFlag(bar: 5, note: "leap cleanly"))
        BarFlagStore.save(loaded, to: dir)
        #expect(BarFlagStore.load(from: dir).first { $0.bar == 5 }?.note == "leap cleanly")
    }
}

// MARK: - Pass report (per-bar / per-hand / timing / wins)

@Suite("Pass report")
struct PassReportTests {
    private func note(_ bar: Int, pitch: Int = 60, hand: Hand = .right, name: String = "C4",
                      matched: Bool = true, ms: Double? = 0) -> PassReportBuilder.Note {
        PassReportBuilder.Note(bar: bar, pitch: pitch, hand: hand, name: name, matched: matched,
                               signedErrorMs: matched ? ms : nil)
    }
    private func wrong(_ bar: Int, pitch: Int = 62, name: String = "D4") -> PassReportBuilder.WrongNote {
        PassReportBuilder.WrongNote(bar: bar, pitch: pitch, name: name)
    }

    @Test("per-bar aggregation: totals, misses, wrongs, timing means, rest bars")
    func bars() {
        let report = PassReportBuilder.build(
            notes: [note(1, ms: 10), note(1, ms: 30),
                    note(2, name: "E4", matched: false),
                    note(4, ms: -80), note(4, ms: -40)],
            wrongNotes: [wrong(2), wrong(2)], sectionStart: 1, sectionEnd: 4, tempoPct: 80, previous: nil)
        #expect(report.bars.count == 4)
        #expect(report.bars[0].isClean && report.bars[0].meanSignedMs == 20)
        #expect(report.bars[1].missed == 1 && report.bars[1].wrong == 2
                && report.bars[1].missedNames == ["E4"])
        #expect(report.bars[2].total == 0)                       // rest bar
        #expect(report.bars[3].meanSignedMs == -60)              // rushing
        #expect(report.worstBar?.bar == 2)
        #expect(report.accuracy == 0.8)                          // 4 of 5
    }

    @Test("hands split only when both hands are graded; means are per hand")
    func hands() {
        let both = PassReportBuilder.build(
            notes: [note(1, hand: .right, ms: 10), note(1, hand: .left, ms: -50)],
            wrongNotes: [], sectionStart: 1, sectionEnd: 1, tempoPct: 100, previous: nil)
        #expect(both.hands.count == 2)
        #expect(both.hands.first { $0.hand == .left }?.meanSignedMs == -50)

        let oneHand = PassReportBuilder.build(
            notes: [note(1, hand: .right)], wrongNotes: [],
            sectionStart: 1, sectionEnd: 1, tempoPct: 100, previous: nil)
        #expect(oneHand.hands.isEmpty)
    }

    @Test("wins: delta + fixed bars vs a previous pass over the same bars only")
    func wins() {
        let first = PassReportBuilder.build(
            notes: [note(1, matched: false), note(2)],
            wrongNotes: [], sectionStart: 1, sectionEnd: 2, tempoPct: 80, previous: nil)
        #expect(first.deltaVsPrevious == nil)

        let second = PassReportBuilder.build(
            notes: [note(1), note(2)],
            wrongNotes: [], sectionStart: 1, sectionEnd: 2, tempoPct: 80, previous: first)
        #expect(second.fixedBars == [1])                          // bar 1 newly clean
        #expect(second.deltaVsPrevious == 0.5)

        // A different bar range must NOT compare.
        let other = PassReportBuilder.build(
            notes: [note(3)], wrongNotes: [], sectionStart: 3, sectionEnd: 3,
            tempoPct: 80, previous: second)
        #expect(other.deltaVsPrevious == nil && other.fixedBars.isEmpty)
    }

    @Test("recurring faults: consecutive streak, break resets, substitution detected")
    func recurring() {
        let missEb = PassFault(bar: 6, pitch: 63, kind: "missed")
        // Missed E♭4 in the 3 most recent comparable passes + this one → streak 4.
        let report = PassReportBuilder.build(
            notes: [note(6, pitch: 63, name: "E♭4", matched: false), note(7, pitch: 65, name: "F4")],
            wrongNotes: [wrong(6, pitch: 62, name: "D4")],
            sectionStart: 6, sectionEnd: 7, tempoPct: 80, previous: nil,
            previousFaults: [[missEb], [missEb], [missEb]])
        #expect(report.recurring.count == 1)
        #expect(report.recurring[0].streak == 4)
        #expect(report.recurring[0].substitution == "you play D4 instead")   // D4 is 1 semitone off

        // A pass WITHOUT the fault breaks the streak (4 of last 5 ≠ 4 in a row).
        let broken = PassReportBuilder.build(
            notes: [note(6, pitch: 63, name: "E♭4", matched: false)],
            wrongNotes: [], sectionStart: 6, sectionEnd: 6, tempoPct: 80, previous: nil,
            previousFaults: [[], [missEb], [missEb]])
        #expect(broken.recurring.isEmpty)                                    // streak 1 < 3

        // No history → nothing recurring.
        let fresh = PassReportBuilder.build(
            notes: [note(6, pitch: 63, name: "E♭4", matched: false)],
            wrongNotes: [], sectionStart: 6, sectionEnd: 6, tempoPct: 80, previous: nil)
        #expect(fresh.recurring.isEmpty)
    }

    @Test("evenness: metronomic + level playing scores high; sloppy scores low")
    func evenness() {
        func name(_ p: Int) -> String { "N\(p)" }
        // A perfectly even 16-note scale at 4 notes/sec, all velocity 80.
        let even = (0..<16).map { (pitch: 60 + $0, onset: Double($0) * 0.25, velocity: 80) }
        let e1 = PassReportBuilder.evenness(played: even, noteName: name)
        #expect(e1 != nil)
        #expect(e1!.timingScore > 0.95 && e1!.dynamicScore > 0.9)

        // Lurching timing (alternating short/long) + wild velocities.
        var t = 0.0
        let sloppy = (0..<16).map { i -> (pitch: Int, onset: Double, velocity: Int) in
            t += (i % 2 == 0) ? 0.15 : 0.4
            return (pitch: 60 + i, onset: t, velocity: i % 2 == 0 ? 40 : 110)
        }
        let e2 = PassReportBuilder.evenness(played: sloppy, noteName: name)
        #expect(e2 != nil)
        #expect(e2!.timingScore < 0.5 && e2!.dynamicScore < 0.3)
        #expect(e2!.softest?.velocity == 40 && e2!.loudest?.velocity == 110)

        // Too few notes → no judgement.
        #expect(PassReportBuilder.evenness(played: Array(even.prefix(5)), noteName: name) == nil)
    }

    @Test("report persists: save/load round-trip preserves everything shown")
    func persistence() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ws-report-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        var report = PassReportBuilder.build(
            notes: [note(1, ms: 10), note(2, pitch: 63, name: "E♭4", matched: false)],
            wrongNotes: [wrong(2)], sectionStart: 1, sectionEnd: 2, tempoPct: 85,
            previous: nil,
            previousFaults: [[PassFault(bar: 2, pitch: 63, kind: "missed")],
                             [PassFault(bar: 2, pitch: 63, kind: "missed")]])
        report.date = Date(timeIntervalSince1970: 1_752_600_000)   // whole seconds — ISO8601 round-trips exactly
        report.evenness = PassReport.Evenness(timingScore: 0.9, dynamicScore: 0.7,
                                              softest: .init(name: "G3", velocity: 50),
                                              loudest: .init(name: "C5", velocity: 96))
        PassReportStore.save(report, to: dir)
        let loaded = try #require(PassReportStore.load(from: dir))
        #expect(loaded == report)
        #expect(loaded.recurring.first?.streak == 3)
        #expect(loaded.evenness?.loudest?.name == "C5")

        // Missing / corrupt file → nil, never a crash.
        try Data("junk".utf8).write(to: PassReportStore.fileURL(in: dir))
        #expect(PassReportStore.load(from: dir) == nil)
    }

    @Test("teacher metrics: balance, pedal holds, drift, chord roll, advice, PB")
    func teacherMetrics() {
        // Balance: LH struck harder than RH.
        var expected: [(pitch: Int, onset: Double, hand: Hand)] = []
        var played: [(pitch: Int, onset: Double, velocity: Int)] = []
        for i in 0..<6 {
            expected.append((pitch: 60 + i, onset: Double(i), hand: .right))
            expected.append((pitch: 40 + i, onset: Double(i), hand: .left))
            played.append((pitch: 60 + i, onset: Double(i) + 0.05, velocity: 60))
            played.append((pitch: 40 + i, onset: Double(i) - 0.05, velocity: 85))
        }
        let b = PassReportBuilder.balance(played: played, expected: expected, tolerance: 0.3)
        #expect(b != nil && abs(b!.lhLouderBy - 25) < 0.001)

        // Pedal held from bar 1 across the bar-2 and bar-3 lines → span 1...3.
        let holds = PassReportBuilder.pedalHolds(
            pedal: [(t: 0.5, down: true), (t: 9.5, down: false)],
            barTimes: [(bar: 2, t: 4.0), (bar: 3, t: 8.0)])
        #expect(holds == [1...3])
        // A lift between the lines → no hold.
        #expect(PassReportBuilder.pedalHolds(
            pedal: [(t: 0.5, down: true), (t: 5.0, down: false), (t: 5.2, down: true), (t: 9.5, down: false)],
            barTimes: [(bar: 2, t: 4.0), (bar: 3, t: 8.0)]).isEmpty)

        // Drift: errors trending earlier at 5%/s → ≈ −5%.
        let driftNotes = (0..<12).map { i in
            PassReportBuilder.Note(bar: 1, pitch: 60, hand: .right, name: "C4", matched: true,
                                   signedErrorMs: -50.0 * Double(i), onset: Double(i))
        }
        let d = PassReportBuilder.tempoDrift(notes: driftNotes)
        #expect(d != nil && abs(d! + 5) < 0.1)

        // Chord roll: two notes written together, struck 90ms apart.
        let roll = PassReportBuilder.chordSpread(notes: [
            .init(bar: 3, pitch: 60, hand: .right, name: "C4", matched: true, signedErrorMs: -30, onset: 1.0),
            .init(bar: 3, pitch: 64, hand: .right, name: "E4", matched: true, signedErrorMs: 60, onset: 1.0),
        ])
        #expect(roll?.bar == 3 && abs(roll!.ms - 90) < 0.001)

        // Advice: scattered one-offs → "too fast" tip; personal best flag.
        let scattered = (0..<8).map { i in
            PassReportBuilder.Note(bar: 1 + i, pitch: 60 + i, hand: .right, name: "X", matched: false, signedErrorMs: nil)
        }
        let r = PassReportBuilder.build(notes: scattered + [note(9)], wrongNotes: [],
                                        sectionStart: 1, sectionEnd: 9, tempoPct: 100,
                                        previous: nil, priorAccuracies: [0.5, 0.6, 0.7])
        #expect(r.advice?.contains("tempo is too high") == true)
        #expect(!r.personalBest)                                   // 1/9 accuracy beats nothing
        let pb = PassReportBuilder.build(notes: [note(1)], wrongNotes: [],
                                         sectionStart: 1, sectionEnd: 1, tempoPct: 100,
                                         previous: nil, priorAccuracies: [0.5, 0.6, 0.7])
        #expect(pb.personalBest)                                   // 100% beats all three
    }

    @Test("problem clusters merge adjacent faulty bars, worst-severity first")
    func clusters() {
        // Bars: 1 clean, 2–3 red, 4 clean, 5 amber, 6 clean, 7 red (gaps keep them
        // as separate clusters; adjacent faulty bars would merge — tested implicitly).
        var notes: [PassReportBuilder.Note] = []
        func bar(_ n: Int, hits: Int, of total: Int) {
            for i in 0..<total {
                notes.append(.init(bar: n, pitch: 60, hand: .right, name: "C4", matched: i < hits, signedErrorMs: nil))
            }
        }
        bar(1, hits: 4, of: 4)   // clean
        bar(2, hits: 0, of: 4)   // red
        bar(3, hits: 1, of: 4)   // red   → merges with bar 2
        bar(4, hits: 4, of: 4)   // clean (breaks the run)
        bar(5, hits: 4, of: 5)   // amber (1 miss, 80%)
        bar(6, hits: 4, of: 4)   // clean (breaks the run)
        bar(7, hits: 0, of: 4)   // red
        let r = PassReportBuilder.build(notes: notes, wrongNotes: [], sectionStart: 1, sectionEnd: 7,
                                        tempoPct: 100, previous: nil)
        let cl = r.problemClusters()
        #expect(cl.count == 3)
        // Reds (2–3, 7) sort before the amber (5); reds tie-break by earliest bar.
        #expect(cl[0].range == 2...3 && cl[0].severity == 2)
        #expect(cl[1].range == 7...7 && cl[1].severity == 2)
        #expect(cl[2].range == 5...5 && cl[2].severity == 1)
        #expect(r.cleanBarCount == 3)   // bars 1, 4, 6
    }

    @Test("themes: signals map to Notes/Rhythm/Touch with severity ordering + wins line")
    func themes() {
        // A rough pass: recurring miss (Notes→focus), rushing run (Rhythm→focus),
        // pedal hold (Touch→focus). All three concerning, notes first on tie.
        let miss = PassFault(bar: 3, pitch: 63, kind: "missed")
        var rough = PassReportBuilder.build(
            notes: [note(3, pitch: 63, name: "E♭4", matched: false),
                    note(4, ms: -60), note(5, ms: -70), note(6, ms: 5)],
            wrongNotes: [], sectionStart: 3, sectionEnd: 6, tempoPct: 80,
            previous: nil, previousFaults: [[miss], [miss]])
        rough.pedalHolds = [1...3]
        let t1 = rough.themes()
        #expect(t1.map(\.kind) == [.notes, .rhythm, .touch])       // all focus → stable kind order
        #expect(t1.allSatisfy { $0.status == .focus })
        #expect(t1[0].summary.contains("E♭4") && t1[0].summary.contains("3 passes"))
        #expect(t1[1].summary.contains("rush"))
        #expect(t1[2].summary.contains("pedal held"))

        // A clean pass: everything good, wins line says clean.
        let clean = PassReportBuilder.build(
            notes: (1...12).map { note(1, pitch: 60 + $0, ms: 5) },
            wrongNotes: [], sectionStart: 1, sectionEnd: 1, tempoPct: 100, previous: nil)
        #expect(clean.themes().allSatisfy { $0.status == .good })
        #expect(clean.winsSummary == "Clean pass")

        // Wins compose: PB + fixed bars.
        var winning = clean
        winning.personalBest = true
        winning.fixedBars = [2, 5]
        #expect(winning.winsSummary == "Personal best · bars 2, 5 fixed")
    }

    @Test("timing hotspot finds the consistent run and ignores even playing")
    func hotspot() {
        let report = PassReportBuilder.build(
            notes: [note(1, ms: 5), note(2, ms: -60), note(3, ms: -70), note(4, ms: 10)],
            wrongNotes: [], sectionStart: 1, sectionEnd: 4, tempoPct: 80, previous: nil)
        let hot = report.timingHotspot()
        #expect(hot?.bars == 2...3)
        #expect(hot.map { abs($0.meanMs + 65) < 0.001 } == true)  // mean of −60, −70

        let even = PassReportBuilder.build(
            notes: [note(1, ms: 5), note(2, ms: -10)],
            wrongNotes: [], sectionStart: 1, sectionEnd: 2, tempoPct: 80, previous: nil)
        #expect(even.timingHotspot() == nil)
    }
}

// MARK: - Session lifecycle (song switch must tear the old session down)

@Suite("Session lifecycle")
struct SessionLifecycleTests {

    /// Build a real on-disk song folder from the bundled fixture pair.
    private func makeSongFolder() throws -> Song {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ws-session-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try (try fixtureData("Fly Me To the Moon", "musicxml"))
            .write(to: dir.appendingPathComponent("score.musicxml"))
        try (try fixtureData("Fly Me To the Moon", "mid"))
            .write(to: dir.appendingPathComponent("score.mid"))
        let meta = SongMeta(id: UUID(), title: "Fixture", composer: nil, dateAdded: Date())
        return Song(meta: meta, folder: dir)
    }

    @Test("a fully-wired session deallocates when released")
    @MainActor
    func idleSessionDeallocates() throws {
        let song = try makeSongFolder()
        defer { try? FileManager.default.removeItem(at: song.folder) }
        weak var leaked: PracticeSession?
        autoreleasepool {
            let session = PracticeSession(song: song)
            session.onAppear()
            leaked = session
        }
        #expect(leaked == nil, "an idle PracticeSession must deallocate on release")
    }

    @Test("a session released MID-PLAYBACK deallocates and stops its audio")
    @MainActor
    func playingSessionDeallocates() async throws {
        let song = try makeSongFolder()
        defer { try? FileManager.default.removeItem(at: song.folder) }
        weak var leakedSession: PracticeSession?
        weak var leakedAudio: AudioEnginePlayer?
        autoreleasepool {
            let session = PracticeSession(song: song)
            session.onAppear()
            session.countInBars = 0
            session.startOnFirstNote = false
            session.togglePlay()                       // really start the sequencer
            leakedSession = session
            leakedAudio = session.audio
        }
        // Give any transient async work (audio start, main-queue hops) a beat to drain.
        try await Task.sleep(for: .milliseconds(300))
        #expect(leakedSession == nil, "a playing PracticeSession must deallocate when the song is switched")
        #expect(leakedAudio == nil, "the audio engine must not outlive its session (old song keeps playing)")
    }
}

// MARK: - Ingestion trust (review cluster C)

@Suite("Ingestion trust")
struct IngestionTrustTests {

    @Test("meter emphasis: 3/8 is simple triple, 6/8 & 6/16 are compound")
    func clickLevels() {
        // 3/8 — every non-downbeat pulse is a beat (NOT a compound sub).
        #expect(Ingest.clickLevel(pulseIndex: 0, num: 3, den: 8) == .downbeat)
        #expect(Ingest.clickLevel(pulseIndex: 1, num: 3, den: 8) == .beat)
        #expect(Ingest.clickLevel(pulseIndex: 2, num: 3, den: 8) == .beat)
        // 6/8 — beats on 0 and 3, subs elsewhere.
        #expect(Ingest.clickLevel(pulseIndex: 3, num: 6, den: 8) == .beat)
        #expect(Ingest.clickLevel(pulseIndex: 1, num: 6, den: 8) == .sub)
        // 6/16 — same compound grouping now recognised.
        #expect(Ingest.clickLevel(pulseIndex: 3, num: 6, den: 16) == .beat)
        #expect(Ingest.clickLevel(pulseIndex: 2, num: 6, den: 16) == .sub)
    }

    @Test("timeline mismatch fires when the MIDI runs long OR short of the score")
    func timelineMismatch() {
        let bar = 4.0
        #expect(!Ingest.timelinesMismatch(xmlTotalBeats: 40, lastMidiBeat: 38, barBeats: bar))   // ok (last onset a bit early)
        #expect(Ingest.timelinesMismatch(xmlTotalBeats: 40, lastMidiBeat: 60, barBeats: bar))    // MIDI runs long (D.C.?)
        #expect(Ingest.timelinesMismatch(xmlTotalBeats: 40, lastMidiBeat: 20, barBeats: bar))    // MIDI ends short (folded repeat)
    }

    @Test("a single-hand MIDI (can't split hands) fails loudly, not with an empty model")
    func unassignableHandsThrows() throws {
        // One note-bearing track only → hands unknown → Ingest must throw.
        let midi = ParserFixSMF.oneTrackNote()
        let xml = ParserFixSMF.minimalXML()
        #expect(throws: MIDIError.self) { try Ingest.fuse(midiData: midi, musicXMLData: xml) }
    }

    @Test(".mxl with an implausibly large declared size is rejected, not allocated")
    func mxlSizeCap() throws {
        // A stored entry whose declared uncompressed size exceeds the cap must throw
        // .tooLarge BEFORE allocating (zip-bomb guard).
        let entry = MXLArchive.Entry(name: "score.xml", method: 8,
                                     compressedSize: 4, uncompressedSize: 999_999_999,
                                     localHeaderOffset: 0)
        // A tiny dummy archive body; extract should bail on the size check first.
        var body = [UInt8](repeating: 0, count: 64)
        body[0] = 0x50; body[1] = 0x4b; body[2] = 0x03; body[3] = 0x04
        #expect(throws: MXLError.self) { try MXLArchive.extract(entry, from: Data(body)) }
    }
}

/// Minimal MIDI/MusicXML builders for the trust tests (kept tiny + local).
enum ParserFixSMF {
    static func oneTrackNote() -> Data {
        // Header: format 1, 1 track, 96 tpq. Track: note-on 72 / note-off.
        var d: [UInt8] = [0x4D,0x54,0x68,0x64, 0,0,0,6, 0,1, 0,1, 0,96]
        var track: [UInt8] = [0x00,0x90,72,90, 0x60,0x80,72,0, 0x00,0xFF,0x2F,0x00]
        d += [0x4D,0x54,0x72,0x6B, 0,0,0, UInt8(track.count)]
        d += track
        return Data(d)
    }
    static func minimalXML() -> Data {
        Data("""
        <?xml version="1.0"?>
        <score-partwise version="3.1"><part-list><score-part id="P1"><part-name>P</part-name></score-part></part-list>
        <part id="P1"><measure number="1">
          <attributes><divisions>1</divisions><time><beats>4</beats><beat-type>4</beat-type></time>
          <clef><sign>G</sign><line>2</line></clef></attributes>
          <note><pitch><step>C</step><octave>5</octave></pitch><duration>4</duration><type>whole</type></note>
        </measure></part></score-partwise>
        """.utf8)
    }
}

// MARK: - Scale practice books (generated content must fuse cleanly)

@Suite("Scale books")
struct ScaleBookTests {
    @Test("Major scales fuse cleanly, 1:1")
    func majors() throws {
        let fused = try Ingest.fuse(midiData: try fixtureData("MajorScales", "mid"),
                                    musicXMLData: try fixtureData("MajorScales", "musicxml"))
        #expect(fused.structureWarning == nil)
        #expect(fused.events.count == 12 * 29 * 2)          // 12 scales × 29 notes × 2 hands
        #expect(fused.reconciliations.allSatisfy { $0.isClean })
        #expect(fused.measureStartBeats.count == 48)         // 12 scales × 4 bars
    }

    @Test("Minor scales (natural/harmonic/melodic) fuse cleanly, 1:1")
    func minors() throws {
        let fused = try Ingest.fuse(midiData: try fixtureData("MinorScales", "mid"),
                                    musicXMLData: try fixtureData("MinorScales", "musicxml"))
        #expect(fused.structureWarning == nil)
        #expect(fused.events.count == 36 * 29 * 2)           // 12 keys × 3 forms × 29 × 2 hands
        #expect(fused.reconciliations.allSatisfy { $0.isClean })
        #expect(fused.measureStartBeats.count == 144)
    }
}

// MARK: - PianoScheduler (edge-triggered MIDI-out, incl. ornaments/graces/pedal)

@Suite("PianoScheduler")
struct PianoSchedulerTests {

    private func note(_ pitch: Int, at onset: Double, dur: Double, hand: Hand = .right) -> NoteEvent {
        NoteEvent(pitch: pitch, spelledName: "", hand: hand, voice: 0, notatedType: "?",
                  onsetSeconds: onset, durationSeconds: dur, notatedBeat: 0,
                  matchedXML: true, ornamentNotes: 0)
    }

    @Test("fires note on then off across ticks")
    func onThenOff() {
        var s = PianoScheduler()
        s.load(notes: [note(60, at: 0.10, dur: 0.30)], pedal: [], minDuration: 0.05)
        #expect(s.advance(to: 0.05, rhOn: true, lhOn: true).isEmpty)          // before onset
        #expect(s.advance(to: 0.12, rhOn: true, lhOn: true) == [.noteOn(60)]) // onset passed
        #expect(s.advance(to: 0.30, rhOn: true, lhOn: true).isEmpty)          // still held
        #expect(s.advance(to: 0.45, rhOn: true, lhOn: true) == [.noteOff(60)])// release passed
    }

    @Test("a sub-tick grace note is still sounded (on + off), not dropped")
    func shortNoteSurvives() {
        var s = PianoScheduler()
        // 8ms note entirely between two 20ms ticks — the old set-diff missed this.
        s.load(notes: [note(72, at: 0.101, dur: 0.008)], pedal: [], minDuration: 0.05)
        _ = s.advance(to: 0.100, rhOn: true, lhOn: true)
        let cmds = s.advance(to: 0.120, rhOn: true, lhOn: true)
        #expect(cmds.contains(.noteOn(72)))
    }

    @Test("repeated same pitch re-articulates (off then on)")
    func reArticulate() {
        var s = PianoScheduler()
        s.load(notes: [note(64, at: 0.00, dur: 0.20), note(64, at: 0.10, dur: 0.20)],
               pedal: [], minDuration: 0.05)
        _ = s.advance(to: 0.01, rhOn: true, lhOn: true)                        // first on
        let cmds = s.advance(to: 0.11, rhOn: true, lhOn: true)                 // second strike
        #expect(cmds == [.noteOff(64), .noteOn(64)])
    }

    @Test("muted hand is skipped, and muting mid-note releases it")
    func handMuting() {
        var s = PianoScheduler()
        s.load(notes: [note(48, at: 0.00, dur: 0.50, hand: .left)], pedal: [], minDuration: 0.05)
        #expect(s.advance(to: 0.01, rhOn: true, lhOn: false).isEmpty)          // LH muted → skipped
        // Now a RH note that starts while sounding, then gets muted.
        var s2 = PianoScheduler()
        s2.load(notes: [note(67, at: 0.00, dur: 0.50, hand: .right)], pedal: [], minDuration: 0.05)
        #expect(s2.advance(to: 0.01, rhOn: true, lhOn: true) == [.noteOn(67)])
        #expect(s2.advance(to: 0.02, rhOn: false, lhOn: true) == [.noteOff(67)])
    }

    @Test("pedal transitions drive sustain and collapse redundant states")
    func pedal() {
        var s = PianoScheduler()
        s.load(notes: [], pedal: [(0.10, true), (0.30, false)], minDuration: 0.05)
        #expect(s.advance(to: 0.05, rhOn: true, lhOn: true).isEmpty)
        #expect(s.advance(to: 0.15, rhOn: true, lhOn: true) == [.pedal(true)])
        #expect(s.advance(to: 0.20, rhOn: true, lhOn: true).isEmpty)           // no change
        #expect(s.advance(to: 0.35, rhOn: true, lhOn: true) == [.pedal(false)])
    }

    @Test("a backward jump repositions without replaying passed notes")
    func loopReposition() {
        var s = PianoScheduler()
        s.load(notes: [note(60, at: 0.10, dur: 0.10), note(62, at: 1.00, dur: 0.10)],
               pedal: [], minDuration: 0.05)
        _ = s.advance(to: 0.50, rhOn: true, lhOn: true)   // played the first note
        // Loop back to 0.05 — must NOT re-fire the 0.10 note until it's reached again.
        #expect(s.advance(to: 0.05, rhOn: true, lhOn: true).isEmpty)
        #expect(s.advance(to: 0.12, rhOn: true, lhOn: true) == [.noteOn(60)])
    }
}
