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

    /// A MusicXML note after unfolding + tie-merging: one entry per *sounding* note
    /// per pass. `onsetBeats` is the UNFOLDED position (matches MIDI ticks, used for
    /// alignment); `writtenBeat` is the notated position (drives the OSMD cursor —
    /// on a repeat's second pass the cursor jumps back, like a reader's eyes).
    private struct Sounding {
        var pitch: Int
        var spelledName: String
        var voice: Int
        var notatedType: String
        var onsetBeats: Double        // unfolded (alignment timeline)
        var writtenBeat: Double       // notated (display timeline)
        var durationBeats: Double
        var hasOrnament: Bool
        var isGrace: Bool
        var matched = false
    }

    /// The playback order of measure indices implied by repeat barlines and voltas.
    /// `|:` sets the jump-back point, `:|` repeats (honouring `times`), and a volta
    /// whose numbers don't include the current pass is skipped. Identity when there
    /// are no repeats. Pure — unit-tested. (D.C./D.S./Coda jumps are NOT handled;
    /// they surface via the structure warning instead.)
    static func unfoldOrder(marks: [RepeatMarks]) -> [Int] {
        var order: [Int] = []
        var i = 0, start = 0, pass = 1
        var guardCount = 0
        while i < marks.count && guardCount < 100_000 {
            guardCount += 1
            let m = marks[i]
            if m.forward { start = i }
            if !m.endingNumbers.isEmpty && !m.endingNumbers.contains(pass) {
                // Skip this volta: advance past its stop measure.
                while i < marks.count {
                    let stop = marks[i].endingStop
                    i += 1
                    if stop { break }
                }
                continue
            }
            order.append(i)
            if m.backward && pass < max(2, m.times) {
                pass += 1
                i = start
                continue
            }
            if m.backward || (m.endingStop && !m.backward) {
                pass = 1                 // region finished — the next one counts afresh
                start = i + 1
            }
            i += 1
        }
        return order
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

        // ---- Unfold the written timeline (repeats / voltas) ----
        // The MIDI export is unfolded; the XML is written/folded. Compute the playback
        // order of measures, then give every note TWO positions: an unfolded onset
        // (aligns with MIDI ticks) and its written beat (drives the cursor/marks).
        let marks = xml.measureRepeats.count == xml.measures.count
            ? xml.measureRepeats
            : Array(repeating: RepeatMarks(), count: xml.measures.count)
        let order = unfoldOrder(marks: marks)
        let writtenStarts = xml.measures.map(\.startBeat)
        let writtenTotal = xml.measures.last.map { $0.startBeat + $0.lengthBeats } ?? 0
        var unfoldedStartAtPos: [Double] = []
        var firstOccStart = [Double?](repeating: nil, count: xml.measures.count)
        var accBeats = 0.0
        for m in order {
            unfoldedStartAtPos.append(accBeats)
            if firstOccStart[m] == nil { firstOccStart[m] = accBeats }
            accBeats += xml.measures[m].lengthBeats
        }
        let unfoldedTotal = accBeats

        // Every playable note, once per pass through its measure, with its unfolded onset.
        var notesByMeasure = [[XMLNote]](repeating: [], count: max(1, xml.measures.count))
        for n in xml.notes where !n.isRest && n.pitch != nil {
            let idx = n.measure - 1
            if idx >= 0 && idx < notesByMeasure.count { notesByMeasure[idx].append(n) }
        }
        var expanded: [(note: XMLNote, align: Double)] = []
        for (pos, m) in order.enumerated() {
            for n in notesByMeasure[m] {
                expanded.append((n, unfoldedStartAtPos[pos] + (n.onsetBeats - writtenStarts[m])))
            }
        }

        /// The written beat for an unfolded position (for unmatched-MIDI fallbacks).
        func writtenBeat(forUnfolded b: Double) -> Double {
            guard !unfoldedStartAtPos.isEmpty else { return b }
            var pos = 0
            for i in unfoldedStartAtPos.indices where unfoldedStartAtPos[i] <= b + 1e-6 { pos = i }
            let m = order[pos]
            return writtenStarts[m] + (b - unfoldedStartAtPos[pos])
        }

        var events: [NoteEvent] = []
        var reconciliations: [Reconciliation] = []
        var leftoverSlots: [Hand: [MidiSlot]] = [:]
        var leftoverSounding: [Hand: [Sounding]] = [:]
        var handTallies: [Hand: (soundingCount: Int, midiCount: Int, matched: Int,
                                 ornaments: Int, unmatchedXML: [String])] = [:]

        for hand in [Hand.right, Hand.left] {
            // XML sounding notes for this hand (unfolded, ties merged).
            let sounding = mergeTies(expanded.filter { $0.note.hand == hand })

            // MIDI notes for this hand, with a beat position for alignment.
            var slots = midi.notes
                .filter { $0.hand == hand }
                .map { MidiSlot(note: $0, onsetBeats: $0.onsetBeats) }
                .sorted { $0.onsetBeats < $1.onsetBeats }

            var soundingMut = sounding
            var matched = 0
            let unmatchedXML: [String] = []   // filled after the cross-staff pass

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
                                            notatedBeat: s.writtenBeat,   // display timeline
                                            matchedXML: true, ornamentNotes: 0))
                }
                // No in-hand partner → stays unmatched; the cross-staff pass tries next.
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

            // Leftovers are NOT emitted yet — a cross-staff pass runs first (below).
            leftoverSlots[hand] = slots.filter { !$0.matched }
            leftoverSounding[hand] = soundingMut.filter { !$0.matched }
            handTallies[hand] = (soundingCount: sounding.count, midiCount: slots.count,
                                 matched: matched, ornaments: ornamentRealizations,
                                 unmatchedXML: unmatchedXML)
        }

        // ---- Cross-staff pass ----
        // Piano notation routinely writes a hand's notes on the OTHER staff for
        // readability (e.g. the Moonlight's triplets dipping onto the bass staff).
        // Our hands come from MIDI tracks; the XML's from <staff> — so those notes
        // end up "unmatched MIDI" in one hand and "unmatched XML" in the other, in
        // perfectly matching pairs. Marry them here: the event plays as the MIDI
        // hand (that's who actually plays it) with the XML note's identity.
        var crossStaff: [Hand: Int] = [.right: 0, .left: 0]
        for (midiHand, xmlHand) in [(Hand.right, Hand.left), (Hand.left, Hand.right)] {
            guard var slots = leftoverSlots[midiHand], !slots.isEmpty,
                  var sounding = leftoverSounding[xmlHand], !sounding.isEmpty else { continue }
            for i in sounding.indices where !sounding[i].isGrace {
                let s = sounding[i]
                var bestJ = -1
                var bestDelta = Double.greatestFiniteMagnitude
                for j in slots.indices where !slots[j].matched && slots[j].note.pitch == s.pitch {
                    let delta = abs(slots[j].onsetBeats - s.onsetBeats)
                    if delta < bestDelta { bestDelta = delta; bestJ = j }
                }
                if bestJ >= 0 && bestDelta <= 1.0 {
                    slots[bestJ].matched = true
                    sounding[i].matched = true
                    crossStaff[midiHand, default: 0] += 1
                    let m = slots[bestJ].note
                    events.append(NoteEvent(pitch: m.pitch, spelledName: s.spelledName,
                                            hand: midiHand, voice: s.voice,
                                            notatedType: s.notatedType,
                                            onsetSeconds: m.onsetSeconds,
                                            durationSeconds: m.durationSeconds,
                                            notatedBeat: s.writtenBeat,
                                            matchedXML: true, ornamentNotes: 0))
                }
            }
            leftoverSlots[midiHand] = slots.filter { !$0.matched }
            leftoverSounding[xmlHand] = sounding.filter { !$0.matched }
        }

        // ---- Emit what's still unexplained + build the reconciliations ----
        for hand in [Hand.right, Hand.left] {
            let tally = handTallies[hand] ?? (0, 0, 0, 0, [])
            var unmatchedMIDI: [String] = []
            for slot in leftoverSlots[hand] ?? [] {
                let m = slot.note
                unmatchedMIDI.append("\(defaultPitchName(m.pitch)) @ \(fmt(m.onsetSeconds))s")
                events.append(NoteEvent(pitch: m.pitch, spelledName: defaultPitchName(m.pitch),
                                        hand: hand, voice: 0, notatedType: "?",
                                        onsetSeconds: m.onsetSeconds,
                                        durationSeconds: m.durationSeconds,
                                        notatedBeat: writtenBeat(forUnfolded: m.onsetBeats),   // rare fallback
                                        matchedXML: false, ornamentNotes: 0))
            }
            let unmatchedXML = tally.unmatchedXML
                + (leftoverSounding[hand] ?? []).map { "\($0.spelledName) @ beat \(fmt($0.writtenBeat)) (voice \($0.voice))" }
            reconciliations.append(Reconciliation(hand: hand,
                                                  xmlSoundingCount: tally.soundingCount,
                                                  midiCount: tally.midiCount,
                                                  matched: tally.matched,
                                                  ornamentRealizations: tally.ornaments,
                                                  crossStaff: crossStaff[hand] ?? 0,
                                                  unmatchedMIDI: unmatchedMIDI,
                                                  unmatchedXML: unmatchedXML))
        }

        events.sort { ($0.onsetSeconds, $0.pitch) < ($1.onsetSeconds, $1.pitch) }

        // First full bar's meter drives the count-in / free-run pattern.
        let firstFull = xml.measures.first { $0.lengthBeats >= Double($0.num) * 4 / Double($0.den) - 0.01 }
        let fm = firstFull ?? (startBeat: 0, lengthBeats: 4, num: 4, den: 4)
        let barPattern = (0..<max(1, fm.num)).map { clickLevel(pulseIndex: $0, num: fm.num, den: fm.den) }
        let pulseSeconds = (4.0 / Double(fm.den)) * (60.0 / tempo)

        // Structural sanity, AFTER unfolding: simple repeats/voltas are now expanded,
        // so a remaining length mismatch means jumps we don't handle (D.C./D.S./Coda)
        // or a mismatched file pair — warn loudly rather than grade a wrong model.
        let lastMidiBeat = midi.notes.map(\.onsetBeats).max() ?? 0
        let barBeats = Double(fm.num) * 4.0 / Double(fm.den)
        let structureWarning: String? = timelinesMismatch(xmlTotalBeats: unfoldedTotal,
                                                          lastMidiBeat: lastMidiBeat,
                                                          barBeats: barBeats)
            ? "The MIDI doesn't line up with the written score even after unfolding repeats (D.C./D.S.? mismatched files?) — the cursor and grading will be wrong where they diverge."
            : nil

        // The metronome clicks every PLAYED bar — i.e. over the unfolded order, so
        // repeats keep clicking on the second pass.
        var unfoldedMeasures: [(startBeat: Double, lengthBeats: Double, num: Int, den: Int)] = []
        for (pos, m) in order.enumerated() {
            let src = xml.measures[m]
            unfoldedMeasures.append((startBeat: unfoldedStartAtPos[pos], lengthBeats: src.lengthBeats,
                                     num: src.num, den: src.den))
        }

        // The app addresses time in WRITTEN beats (bars, cursor, sections); convert
        // via the first occurrence of that written position in the unfolded timeline.
        // The end-of-piece maps to the unfolded end, so a piece that finishes inside
        // a repeat region still plays out both passes.
        let secondsAtWritten: (Double) -> Double = { wb in
            if wb >= writtenTotal - 1e-6 { return midi.secondsAtBeat(unfoldedTotal + (wb - writtenTotal)) }
            var idx = 0
            for i in writtenStarts.indices where writtenStarts[i] <= wb + 1e-6 { idx = i }
            let u = (firstOccStart[idx] ?? writtenStarts[idx]) + (wb - writtenStarts[idx])
            return midi.secondsAtBeat(u)
        }

        return FusedScore(tempoBPM: tempo,
                          timeSignature: xml.timeSignature ?? midi.timeSignature,
                          keyFifths: xml.keyFifths,
                          events: events,
                          clickGrid: buildClickGrid(measures: unfoldedMeasures,
                                                    secondsAtBeat: midi.secondsAtBeat),
                          metronomeBarPattern: barPattern,
                          metronomePulseSeconds: pulseSeconds,
                          trackHands: midi.trackHands,
                          measureStartBeats: writtenStarts,
                          measureMeters: xml.measures.map { (num: $0.num, den: $0.den) },
                          totalBeats: writtenTotal,
                          secondsAtBeat: secondsAtWritten,
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

    /// Collapse tied MusicXML notes into one sounding note each, so the count lines
    /// up with MIDI note-ons. Input is the unfolded expansion: (note, unfolded onset).
    private static func mergeTies(_ handNotes: [(note: XMLNote, align: Double)]) -> [Sounding] {
        let ordered = handNotes
            .sorted { ($0.align, $0.note.pitch ?? 0) < ($1.align, $1.note.pitch ?? 0) }

        var sounding: [Sounding] = []
        var openTie: [Int: Int] = [:]   // pitch -> index of the open sounding note

        for (n, align) in ordered {
            let pitch = n.pitch!
            if n.tieStop, let idx = openTie[pitch] {
                // This note continues a tie: extend the existing sounding note's
                // notated span (used for ornament absorption); timing is from MIDI.
                sounding[idx].durationBeats = (align + n.durationBeats) - sounding[idx].onsetBeats
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
                                         onsetBeats: align,
                                         writtenBeat: n.onsetBeats,
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
