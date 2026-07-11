//
//  Ingest.swift
//  Woodshed
//
//  Phase 0 spike — fuse MusicXML identity with MIDI timing into one model.
//
//  Pipeline:
//    1. Parse the MIDI  -> per-hand notes with authoritative onset/duration (sec).
//    2. Parse the MusicXML -> notes with spelling, hand (staff), voice, ties.
//    3. Merge tied MusicXML notes so one *sounding* note == one MIDI note-on.
//    4. Within each hand, align XML sounding notes to MIDI notes (same pitch,
//       nearest beat) and attach the XML identity to the MIDI timing.
//    5. Report per-hand reconciliation so mismatches surface loudly.
//

import Foundation

enum Ingest {

    /// A MusicXML note after tie-merging: one entry per *sounding* note.
    private struct Sounding {
        var pitch: Int
        var spelledName: String
        var voice: Int
        var notatedType: String
        var onsetBeats: Double
        var durationBeats: Double
        var hasOrnament: Bool
        var isGrace: Bool
        var matched = false
    }

    /// A MIDI note plus a mutable matched flag, for the alignment pass.
    private struct MidiSlot {
        var note: MidiNote
        var onsetBeats: Double
        var matched = false
    }

    static func fuse(midiData: Data, musicXMLData: Data) throws -> FusedScore {
        let midi = try MIDIParser.parse(data: midiData)
        let xml = try MusicXMLParser.parse(data: musicXMLData)

        let tempo = midi.tempoBPM

        var events: [NoteEvent] = []
        var reconciliations: [Reconciliation] = []

        for hand in [Hand.right, Hand.left] {
            // XML sounding notes for this hand (ties merged).
            let sounding = mergeTies(xml.notes.filter { $0.hand == hand })

            // MIDI notes for this hand, with a beat position for alignment.
            var slots = midi.notes
                .filter { $0.hand == hand }
                .map { MidiSlot(note: $0, onsetBeats: $0.onsetBeats) }
                .sorted { $0.onsetBeats < $1.onsetBeats }

            var soundingMut = sounding
            var matched = 0
            var unmatchedXML: [String] = []

            // Each matched event, with the parent notated note's beat span, so we can
            // absorb ornament-realization notes into it afterwards. `index` points into
            // `events`; `startBeats`..`endBeats` is the written note's span.
            struct Parent { var index: Int; var startBeats: Double; var endBeats: Double; var ornamented: Bool }
            var parents: [Parent] = []

            // Greedy: for each XML sounding note, grab the nearest unmatched MIDI
            // note of the same pitch. A generous 1-beat window absorbs swing.
            // PRINCIPAL notes match first, grace notes second — a zero-duration grace
            // at the same beat must never steal its principal's MIDI partner.
            let matchOrder = soundingMut.indices.filter { !soundingMut[$0].isGrace }
                           + soundingMut.indices.filter { soundingMut[$0].isGrace }
            for i in matchOrder {
                let s = soundingMut[i]
                var bestJ = -1
                var bestDelta = Double.greatestFiniteMagnitude
                for j in slots.indices where !slots[j].matched && slots[j].note.pitch == s.pitch {
                    let delta = abs(slots[j].onsetBeats - s.onsetBeats)
                    if delta < bestDelta { bestDelta = delta; bestJ = j }
                }
                if bestJ >= 0 && bestDelta <= 1.0 {
                    slots[bestJ].matched = true
                    soundingMut[i].matched = true
                    matched += 1
                    let m = slots[bestJ].note
                    parents.append(Parent(index: events.count,
                                          startBeats: s.onsetBeats,
                                          endBeats: s.onsetBeats + max(s.durationBeats, 0.01),
                                          ornamented: s.hasOrnament))
                    events.append(NoteEvent(pitch: m.pitch, spelledName: s.spelledName,
                                            hand: hand, voice: s.voice,
                                            notatedType: s.notatedType,
                                            onsetSeconds: m.onsetSeconds,
                                            durationSeconds: m.durationSeconds,
                                            notatedBeat: s.onsetBeats,
                                            matchedXML: true, ornamentNotes: 0))
                } else {
                    unmatchedXML.append("\(s.spelledName) @ beat \(fmt(s.onsetBeats)) (voice \(s.voice))")
                }
            }

            // Absorb leftover MIDI notes that fall inside an *ornamented* written
            // note's beat span — these are the realized trill/turn/mordent notes.
            // They become child notes of the parent event (which grows to cover them),
            // not separate events. The `0.25`-beat pad tolerates realizations that
            // spill slightly past the notated value.
            var ornamentRealizations = 0
            for j in slots.indices where !slots[j].matched {
                let b = slots[j].onsetBeats
                if let p = parents.first(where: { $0.ornamented && b >= $0.startBeats - 0.25 && b <= $0.endBeats + 0.25 }) {
                    slots[j].matched = true
                    ornamentRealizations += 1
                    events[p.index].ornamentNotes += 1
                    let end = slots[j].note.onsetSeconds + slots[j].note.durationSeconds
                    events[p.index].durationSeconds = max(events[p.index].durationSeconds,
                                                          end - events[p.index].onsetSeconds)
                }
            }

            // Any MIDI note still with no XML partner: emit it, flagged, and report it.
            var unmatchedMIDI: [String] = []
            for slot in slots where !slot.matched {
                let m = slot.note
                unmatchedMIDI.append("\(defaultPitchName(m.pitch)) @ \(fmt(m.onsetSeconds))s")
                events.append(NoteEvent(pitch: m.pitch, spelledName: defaultPitchName(m.pitch),
                                        hand: hand, voice: 0, notatedType: "?",
                                        onsetSeconds: m.onsetSeconds,
                                        durationSeconds: m.durationSeconds,
                                        notatedBeat: m.onsetBeats,   // fallback: MIDI beat (rare)
                                        matchedXML: false, ornamentNotes: 0))
            }

            reconciliations.append(Reconciliation(hand: hand,
                                                  xmlSoundingCount: sounding.count,
                                                  midiCount: slots.count,
                                                  matched: matched,
                                                  ornamentRealizations: ornamentRealizations,
                                                  unmatchedMIDI: unmatchedMIDI,
                                                  unmatchedXML: unmatchedXML))
        }

        events.sort { ($0.onsetSeconds, $0.pitch) < ($1.onsetSeconds, $1.pitch) }

        // First full bar's meter drives the count-in / free-run pattern.
        let firstFull = xml.measures.first { $0.lengthBeats >= Double($0.num) * 4 / Double($0.den) - 0.01 }
        let fm = firstFull ?? (startBeat: 0, lengthBeats: 4, num: 4, den: 4)
        let barPattern = (0..<max(1, fm.num)).map { clickLevel(pulseIndex: $0, num: fm.num, den: fm.den) }
        let pulseSeconds = (4.0 / Double(fm.den)) * (60.0 / tempo)

        // Structural sanity: the MIDI is exported *unfolded* (repeats expanded) while
        // the MusicXML beat timeline is *written/folded*. If the MIDI runs on well past
        // the written score, the alignment above is meaningless past that point — warn
        // loudly rather than grade against a wrong model.
        let xmlTotalBeats = xml.measures.last.map { $0.startBeat + $0.lengthBeats } ?? 0
        let lastMidiBeat = midi.notes.map(\.onsetBeats).max() ?? 0
        let barBeats = Double(fm.num) * 4.0 / Double(fm.den)
        let structureWarning: String? = timelinesMismatch(xmlTotalBeats: xmlTotalBeats,
                                                          lastMidiBeat: lastMidiBeat,
                                                          barBeats: barBeats)
            ? "The MIDI is much longer than the written score (repeats?). Woodshed can't align repeated sections yet — the cursor and grading will be wrong after the first repeat."
            : nil

        return FusedScore(tempoBPM: tempo,
                          timeSignature: xml.timeSignature ?? midi.timeSignature,
                          keyFifths: xml.keyFifths,
                          events: events,
                          clickGrid: buildClickGrid(measures: xml.measures,
                                                    secondsAtBeat: midi.secondsAtBeat),
                          metronomeBarPattern: barPattern,
                          metronomePulseSeconds: pulseSeconds,
                          trackHands: midi.trackHands,
                          measureStartBeats: xml.measures.map { $0.startBeat },
                          measureMeters: xml.measures.map { (num: $0.num, den: $0.den) },
                          totalBeats: xml.measures.last.map { $0.startBeat + $0.lengthBeats }
                                      ?? (events.map { $0.notatedBeat }.max() ?? 0),
                          secondsAtBeat: midi.secondsAtBeat,
                          reconciliations: reconciliations,
                          structureWarning: structureWarning)
    }

    /// True when the MIDI timeline runs more than one bar past the written score —
    /// the signature of unfolded repeats (or a mismatched file pair). Pure, testable.
    static func timelinesMismatch(xmlTotalBeats: Double, lastMidiBeat: Double, barBeats: Double) -> Bool {
        guard xmlTotalBeats > 0 else { return false }
        return lastMidiBeat > xmlTotalBeats + max(barBeats, 1.0)
    }

    // MARK: - Tie merging

    /// Collapse tied MusicXML notes into one sounding note each, so the count
    /// lines up with MIDI note-ons. Rests are dropped.
    private static func mergeTies(_ handNotes: [XMLNote]) -> [Sounding] {
        let ordered = handNotes
            .filter { !$0.isRest && $0.pitch != nil }
            .sorted { ($0.onsetBeats, $0.pitch ?? 0) < ($1.onsetBeats, $1.pitch ?? 0) }

        var sounding: [Sounding] = []
        var openTie: [Int: Int] = [:]   // pitch -> index of the open sounding note

        for n in ordered {
            let pitch = n.pitch!
            if n.tieStop, let idx = openTie[pitch] {
                // This note continues a tie: extend the existing sounding note's
                // notated span (used for ornament absorption); timing is from MIDI.
                sounding[idx].durationBeats = (n.onsetBeats + n.durationBeats) - sounding[idx].onsetBeats
                if n.hasOrnament { sounding[idx].hasOrnament = true }
                if n.tieStart {
                    // middle of a tie chain — keep it open
                } else {
                    openTie[pitch] = nil
                }
            } else {
                sounding.append(Sounding(pitch: pitch,
                                         spelledName: n.spelledName ?? defaultPitchName(pitch),
                                         voice: n.voice,
                                         notatedType: n.notatedType ?? "?",
                                         onsetBeats: n.onsetBeats,
                                         durationBeats: n.durationBeats,
                                         hasOrnament: n.hasOrnament,
                                         isGrace: n.isGrace))
                if n.tieStart { openTie[pitch] = sounding.count - 1 }
            }
        }
        return sounding
    }

    private static func fmt(_ x: Double) -> String { String(format: "%.2f", x) }

    // MARK: - Metronome click grid

    /// Emphasis for a pulse within a bar: index 0 is the downbeat; in compound
    /// meters (x/8, x divisible by 3) every third subdivision is a main beat and the
    /// rest are light subdivisions; simple meters treat every beat as a main beat.
    static func clickLevel(pulseIndex: Int, num: Int, den: Int) -> ClickLevel {
        if pulseIndex == 0 { return .downbeat }
        let compound = (den == 8 && num % 3 == 0)
        if compound { return pulseIndex % 3 == 0 ? .beat : .sub }
        return .beat
    }

    /// Build metronome clicks from the actual barlines and each measure's meter.
    /// The first pulse of every *full* bar is a downbeat; a short pickup measure gets
    /// light clicks so the first strong beat lands on bar 1.
    private static func buildClickGrid(
        measures: [(startBeat: Double, lengthBeats: Double, num: Int, den: Int)],
        secondsAtBeat: (Double) -> Double
    ) -> [(time: Double, level: ClickLevel)] {
        var grid: [(time: Double, level: ClickLevel)] = []
        for m in measures {
            // Click the beat unit named by the denominator: eighths for x/8
            // (so 12/8 clicks all 12 eighths), quarters for x/4, etc.
            let pulse = 4.0 / Double(m.den)
            let fullBarBeats = Double(m.num) * 4.0 / Double(m.den)
            let isFullBar = m.lengthBeats >= fullBarBeats - 0.01
            var b = m.startBeat
            var index = 0
            let end = m.startBeat + m.lengthBeats
            while b < end - 1e-6 {
                let level: ClickLevel = isFullBar ? clickLevel(pulseIndex: index, num: m.num, den: m.den) : .sub
                grid.append((time: secondsAtBeat(b), level: level))
                index += 1
                b += pulse
            }
        }
        return grid
    }
}
