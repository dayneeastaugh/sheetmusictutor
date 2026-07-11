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
