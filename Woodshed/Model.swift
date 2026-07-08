//
//  Model.swift
//  Woodshed
//
//  Phase 0 spike — the small, shared data model.
//
//  This file only holds *types* (structs/enums), no logic. Keeping the data
//  definitions in one place means the MIDI parser, the (later) MusicXML parser,
//  and the views all speak the same language.
//

import Foundation

/// Which hand plays a note. Comes from the MIDI track / MusicXML staff.
enum Hand: String {
    case right = "RH"
    case left  = "LH"
    case unknown = "?"
}

/// One sounding note, as understood *from the MIDI file* in Increment 1.
/// Timing (onset/duration in seconds) is the source of truth here, per the PRD.
/// In Increment 2 we'll enrich this by fusing MusicXML identity (spelled name,
/// voice, notated duration) onto these same timings.
struct MidiNote: Identifiable {
    let id = UUID()
    var pitch: Int              // MIDI note number (60 = middle C / C4)
    var onsetSeconds: Double    // when it starts sounding (source of truth for playback)
    var durationSeconds: Double // how long it sounds
    var onsetBeats: Double      // musical position (tick / ticksPerQuarter) — tempo-independent,
                                // used to align with MusicXML; NOT affected by tempo changes
    var track: Int              // which SMF track it came from
    var hand: Hand
}

/// The result of parsing one MIDI file.
struct MidiScore {
    var ticksPerQuarter: Int
    var tempoBPM: Double                 // the first tempo in the file
    var timeSignature: (num: Int, den: Int)?
    var notes: [MidiNote]                // sorted by onset time
    var secondsAtBeat: (Double) -> Double // convert any quarter-beat position to seconds (tempo map)
    var rightHandCount: Int { notes.filter { $0.hand == .right }.count }
    var leftHandCount: Int  { notes.filter { $0.hand == .left  }.count }
}

// MARK: - MusicXML side (Increment 2)

/// One `<note>` as read from MusicXML. This carries *identity and notation*
/// (spelling, hand/staff, voice, notated rhythm, ties) — but NOT authoritative
/// timing. Timing comes from the MIDI. `onsetBeats`/`durationBeats` are in
/// quarter-note beats from the start of the piece, used only to *align* XML
/// notes with MIDI notes during fusion.
struct XMLNote {
    var pitch: Int?          // MIDI number; nil for a rest
    var spelledName: String? // e.g. "G4", "F#3", "Bb2"; nil for a rest
    var isRest: Bool
    var isChord: Bool        // sounds together with the previous note
    var staff: Int           // 1 = top (usually RH), 2 = bottom (usually LH)
    var voice: Int
    var notatedType: String? // "eighth", "quarter", "half", …
    var dots: Int
    var tieStart: Bool
    var tieStop: Bool
    var hasOrnament: Bool     // trill / turn / mordent etc — expands to many MIDI notes
    var onsetBeats: Double
    var durationBeats: Double
    var measure: Int
    var hand: Hand { staff == 1 ? .right : (staff == 2 ? .left : .unknown) }
}

/// The result of parsing one MusicXML file.
struct MusicXMLScore {
    var divisions: Int
    var tempoBPM: Double?
    var timeSignature: (num: Int, den: Int)?
    var keyFifths: Int
    var notes: [XMLNote]     // all notes incl. rests, in document/onset order
    // Per-measure metric structure, for the metronome (barlines + meter per bar).
    var measures: [(startBeat: Double, lengthBeats: Double, num: Int, den: Int)]
}

// MARK: - Fused model (the authoritative output of the spike)

/// The authoritative note event: MIDI *timing* fused with MusicXML *identity*.
/// This is the thing Phase 0 exists to produce and eyeball.
struct NoteEvent: Identifiable {
    let id = UUID()
    var pitch: Int
    var spelledName: String   // from MusicXML when matched, else a sharp fallback
    var hand: Hand
    var voice: Int
    var notatedType: String   // "eighth" etc, from MusicXML ("?" if unmatched)
    var onsetSeconds: Double   // from MIDI — source of truth for WHEN it sounds
    var durationSeconds: Double // from MIDI — source of truth
    var notatedBeat: Double    // from MusicXML — the NOTATED position (quarter beats from start),
                               // used to drive the OSMD cursor (matches OSMD's own timestamps)
    var matchedXML: Bool       // did we find a MusicXML note for this MIDI note?
    var ornamentNotes: Int     // # of extra MIDI notes absorbed as a trill/turn/mordent realization
    var isOrnamented: Bool { ornamentNotes > 0 }
}

/// Per-hand reconciliation between the two files — how the spike proves itself.
struct Reconciliation {
    var hand: Hand
    var xmlSoundingCount: Int   // XML written notes after merging ties, this hand
    var midiCount: Int          // MIDI note-ons, this hand
    var matched: Int            // written notes matched 1:1 to a MIDI note
    var ornamentRealizations: Int // extra MIDI notes absorbed into ornamented notes
    var unmatchedMIDI: [String] // MIDI notes with no XML partner (human-readable)
    var unmatchedXML: [String]  // XML notes with no MIDI partner
    /// Clean = every MIDI note explained (as a written note or an ornament note)
    /// and every written note matched.
    var isClean: Bool { unmatchedMIDI.isEmpty && unmatchedXML.isEmpty
                        && matched + ornamentRealizations == midiCount }
}

struct FusedScore {
    var tempoBPM: Double
    var timeSignature: (num: Int, den: Int)?
    var keyFifths: Int
    var events: [NoteEvent]     // sorted by onset
    // Metronome click grid: playback time (seconds) of each click + whether it's a
    // bar downbeat (accent). Built from barlines + per-measure meter.
    var clickGrid: [(time: Double, accent: Bool)]
    var reconciliations: [Reconciliation]
}

// MARK: - Pitch spelling helper

/// A default name for a MIDI pitch using sharps (e.g. 61 -> "C#4").
/// NOTE: this is only a fallback. The *correct* spelling (C# vs Db) can only
/// come from the MusicXML, which we add in Increment 2. Middle C = C4 = 60.
func defaultPitchName(_ midi: Int) -> String {
    let names = ["C","C#","D","D#","E","F","F#","G","G#","A","A#","B"]
    let octave = midi / 12 - 1
    return "\(names[((midi % 12) + 12) % 12])\(octave)"
}
