//
//  MusicXMLParser.swift
//  Woodshed
//
//  Phase 0 spike — a MusicXML parser built on Foundation's `XMLParser`.
//
//  Why XMLParser (and not XMLDocument)? XMLParser is the event/SAX-style parser
//  available on *both* macOS and iPadOS; XMLDocument (the DOM one) is macOS-only
//  and would not compile for the iPad target. SAX means: the parser calls us back
//  as it walks the file — "started element X", "found text", "ended element X" —
//  and we maintain a little state machine to assemble notes.
//
//  What we extract per <note>: pitch (-> MIDI number + spelled name), staff (hand),
//  voice, notated duration/type, dots, and tie start/stop. We also track a musical
//  "cursor" through each measure (honoring <backup>/<forward> and chords) so every
//  note gets an onset in quarter-note beats. That beat position is used ONLY to
//  align XML notes with MIDI notes later — the MIDI remains the timing source.
//

import Foundation

final class MusicXMLParser: NSObject, XMLParserDelegate {

    static func parse(data: Data) throws -> MusicXMLScore {
        let p = MusicXMLParser()
        let parser = XMLParser(data: data)
        parser.delegate = p
        guard parser.parse() else {
            throw parser.parserError ?? MusicXMLError.parseFailed
        }
        // Multi-part scores (voice + piano, duets) aren't supported: the measure
        // cursor runs linearly and a second <part>'s beats would silently land after
        // the first part's total length — garbage positions. Refuse loudly instead.
        guard p.partCount <= 1 else { throw MusicXMLError.multiPart(p.partCount) }
        p.finishMeasure()
        return MusicXMLScore(divisions: p.divisions,
                             tempoBPM: p.tempoBPM,
                             timeSignature: p.timeSignature,
                             keyFifths: p.keyFifths,
                             notes: p.notes,
                             measures: p.measures,
                             measureRepeats: p.measureRepeats)
    }

    // MARK: - Accumulated score-level state
    private var divisions = 1
    private var tempoBPM: Double?
    private var timeSignature: (num: Int, den: Int)?
    private var keyFifths = 0
    private var notes: [XMLNote] = []

    // MARK: - Cursor / measure state
    private var measureStartBeats = 0.0      // beats before the current measure
    private var cursorDivs = 0               // position within current measure (divisions)
    private var measureMaxDivs = 0           // furthest cursor reached this measure = its actual length
    private var prevOnsetDivs = 0            // onset of the previous non-chord note
    private var measureIndex = 0
    private var seenFirstMeasure = false

    // Per-measure metric structure (for the metronome): each measure's start beat
    // (quarter beats from the piece start), its actual length in beats, and meter.
    private(set) var measures: [(startBeat: Double, lengthBeats: Double, num: Int, den: Int)] = []
    private var pendingMeasureStart = 0.0

    // Repeat structure (for the unfold): marks accumulated for the current measure,
    // plus the volta (ending) region we're currently inside — endings span measures
    // but MusicXML only marks their start/stop barlines.
    private(set) var measureRepeats: [RepeatMarks] = []
    private var currentMarks = RepeatMarks()
    private var currentEnding: [Int]? = nil
    private var endingJustStopped = false

    // MARK: - Per-element text + context flags
    private var text = ""
    private var inNote = false
    private var inPitch = false
    private var inBackup = false
    private var inForward = false
    private(set) var partCount = 0   // <part> containers seen (only 1 is supported)

    // MARK: - The note currently being assembled
    private var step: String?
    private var alter = 0
    private var octave: Int?
    private var isRest = false
    private var isChord = false
    private var noteStaff = 1
    private var noteVoice = 1
    private var noteType: String?
    private var noteDots = 0
    private var noteDurationDivs = 0
    private var tieStart = false
    private var tieStop = false
    private var hasOrnament = false
    private var isGrace = false

    // MARK: - XMLParserDelegate

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attr: [String: String] = [:]) {
        text = ""
        switch name {
        case "measure":
            // Advance by the PREVIOUS measure's *actual* filled length (from content),
            // not the nominal time signature. This is what keeps us aligned through
            // pickup/anacrusis bars (which MuseScore may leave unmarked), meter
            // changes, and cadenzas — and it mirrors how the MIDI was generated.
            if seenFirstMeasure {
                finishMeasure()                     // record the measure that just ended
                measureStartBeats += Double(measureMaxDivs) / Double(divisions)
            }
            seenFirstMeasure = true
            measureIndex += 1
            cursorDivs = 0
            measureMaxDivs = 0
            prevOnsetDivs = 0
            pendingMeasureStart = measureStartBeats  // start beat of the new measure
        case "part":
            partCount += 1
        case "note":
            inNote = true
            resetNote()
        case "pitch":
            inPitch = true
        case "chord":
            isChord = true
        case "grace":
            if inNote { isGrace = true }   // no <duration>; realized as a short MIDI note
        case "rest":
            isRest = true
        case "backup":
            inBackup = true
        case "forward":
            inForward = true
        case "tie":
            if attr["type"] == "start" { tieStart = true }
            if attr["type"] == "stop" { tieStop = true }
        case "repeat":
            if attr["direction"] == "forward" { currentMarks.forward = true }
            if attr["direction"] == "backward" {
                currentMarks.backward = true
                if let t = attr["times"].flatMap(Int.init), t >= 2 { currentMarks.times = t }
            }
        case "ending":
            // number can be "1", "2" or "1, 2"; the region spans until its stop.
            let numbers = (attr["number"] ?? "")
                .split(separator: ",")
                .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            switch attr["type"] {
            case "start":
                currentEnding = numbers.isEmpty ? [1] : numbers
            case "stop", "discontinue":
                currentMarks.endingStop = true
                endingJustStopped = true
            default: break
            }
        case "dot":
            noteDots += 1
        case "trill-mark", "turn", "inverted-turn", "delayed-turn", "mordent",
             "inverted-mordent", "wavy-line", "tremolo", "shake", "schleifer":
            if inNote { hasOrnament = true }   // realized as many notes in the MIDI
        case "sound":
            if tempoBPM == nil, let t = attr["tempo"].flatMap(Double.init) { tempoBPM = t }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "divisions": divisions = Int(value) ?? divisions
        case "fifths":    keyFifths = Int(value) ?? keyFifths
        case "beats":     if let n = Int(value) { setTimeSig(num: n, den: timeSignature?.den ?? 4) }
        case "beat-type": if let d = Int(value) { setTimeSig(num: timeSignature?.num ?? 4, den: d) }
        case "per-minute": if tempoBPM == nil, let bpm = Double(value) { tempoBPM = bpm }

        case "step":   if inPitch { step = value }
        case "alter":  if inPitch { alter = Int(value) ?? 0 }
        case "octave": if inPitch { octave = Int(value) }
        case "pitch":  inPitch = false

        case "voice":  if inNote { noteVoice = Int(value) ?? 1 }
        case "staff":  if inNote { noteStaff = Int(value) ?? 1 }
        case "type":   if inNote { noteType = value }

        case "duration":
            let d = Int(value) ?? 0
            if inBackup { cursorDivs -= d }
            else if inForward { cursorDivs += d; measureMaxDivs = max(measureMaxDivs, cursorDivs) }
            else if inNote { noteDurationDivs = d }

        case "backup":  inBackup = false
        case "forward": inForward = false
        case "note":    finalizeNote(); inNote = false
        default: break
        }
    }

    // MARK: - Helpers

    private func setTimeSig(num: Int, den: Int) {
        timeSignature = (num, den)
    }

    /// Record the measure currently being parsed (its actual filled length + meter +
    /// repeat marks). Called when the next measure starts and once at document end.
    func finishMeasure() {
        guard seenFirstMeasure else { return }
        let ts = timeSignature ?? (num: 4, den: 4)
        measures.append((startBeat: pendingMeasureStart,
                         lengthBeats: Double(measureMaxDivs) / Double(divisions),
                         num: ts.num, den: ts.den))
        currentMarks.endingNumbers = currentEnding ?? []
        measureRepeats.append(currentMarks)
        currentMarks = RepeatMarks()
        if endingJustStopped { currentEnding = nil; endingJustStopped = false }
    }

    private func resetNote() {
        step = nil; alter = 0; octave = nil
        isRest = false; isChord = false
        noteStaff = 1; noteVoice = 1; noteType = nil; noteDots = 0
        noteDurationDivs = 0
        tieStart = false; tieStop = false
        hasOrnament = false
        isGrace = false
    }

    private func finalizeNote() {
        // Determine onset (in divisions within the measure).
        let onsetDivs: Int
        if isChord {
            onsetDivs = prevOnsetDivs          // chord note sounds with the previous note
        } else {
            onsetDivs = cursorDivs
            prevOnsetDivs = cursorDivs
            cursorDivs += noteDurationDivs      // only non-chord notes advance the cursor
            measureMaxDivs = max(measureMaxDivs, cursorDivs)
        }

        let onsetBeats = measureStartBeats + Double(onsetDivs) / Double(divisions)
        let durationBeats = Double(noteDurationDivs) / Double(divisions)

        var pitch: Int? = nil
        var name: String? = nil
        if !isRest, let step, let octave {
            pitch = Self.midiNumber(step: step, alter: alter, octave: octave)
            name = Self.spelledName(step: step, alter: alter, octave: octave)
        }

        notes.append(XMLNote(pitch: pitch, spelledName: name, isRest: isRest,
                             isChord: isChord, staff: noteStaff, voice: noteVoice,
                             notatedType: noteType, dots: noteDots,
                             tieStart: tieStart, tieStop: tieStop,
                             hasOrnament: hasOrnament, isGrace: isGrace,
                             onsetBeats: onsetBeats, durationBeats: durationBeats,
                             measure: measureIndex))
    }

    private static let stepSemitone: [String: Int] =
        ["C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11]

    static func midiNumber(step: String, alter: Int, octave: Int) -> Int {
        (octave + 1) * 12 + (stepSemitone[step] ?? 0) + alter
    }

    static func spelledName(step: String, alter: Int, octave: Int) -> String {
        let acc: String
        switch alter {
        case 2: acc = "##"
        case 1: acc = "#"
        case -1: acc = "b"
        case -2: acc = "bb"
        default: acc = ""
        }
        return "\(step)\(acc)\(octave)"
    }
}

enum MusicXMLError: Error, CustomStringConvertible {
    case parseFailed
    case multiPart(Int)
    var description: String {
        switch self {
        case .parseFailed: return "Failed to parse MusicXML."
        case .multiPart(let n):
            return "This score has \(n) parts — Segno supports solo piano only. Export just the piano part from MuseScore."
        }
    }
}
