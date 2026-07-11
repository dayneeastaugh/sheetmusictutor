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
