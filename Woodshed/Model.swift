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
    var trackHands: [Hand]               // hand assigned to each SMF track (for audio routing)
    var pedalEvents: [(seconds: Double, down: Bool)] = []  // sustain-pedal (CC64) transitions
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
    var isGrace: Bool = false // grace note: no <duration>, realized as a short MIDI note
    var onsetBeats: Double
    var durationBeats: Double
    var measure: Int
    var hand: Hand { staff == 1 ? .right : (staff == 2 ? .left : .unknown) }
}

/// Repeat structure marks on one measure (from `<barline>` elements). Drives the
/// unfold: `|:` = forward, `:|` = backward (with a pass count), voltas = the ending
/// numbers this measure belongs to. See `Ingest.unfoldOrder`.
struct RepeatMarks: Equatable {
    var forward = false           // |: repeat starts at this measure
    var backward = false          // :| repeat back at the end of this measure
    var times = 2                 // total passes through a backward repeat
    var endingNumbers: [Int] = [] // volta number(s) this measure is inside ([] = none)
    var endingStop = false        // the volta region ends after this measure
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
    // Per-measure repeat marks (parallel to `measures`).
    var measureRepeats: [RepeatMarks] = []
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
    var crossStaff: Int = 0     // this hand's MIDI notes written on the OTHER staff
    var unmatchedMIDI: [String] // MIDI notes with no XML partner (human-readable)
    var unmatchedXML: [String]  // XML notes with no MIDI partner
    /// Clean = every MIDI note explained (as a written note, an ornament note, or a
    /// cross-staff note) and every written note matched.
    var isClean: Bool { unmatchedMIDI.isEmpty && unmatchedXML.isEmpty
                        && matched + ornamentRealizations + crossStaff == midiCount }
}

/// Metronome click emphasis. Compound meters (e.g. 12/8) use all three tiers:
/// strong downbeat, medium on each main beat, light on the other subdivisions.
enum ClickLevel { case downbeat, beat, sub }

struct FusedScore {
    var tempoBPM: Double
    var timeSignature: (num: Int, den: Int)?
    var keyFifths: Int
    var events: [NoteEvent]     // sorted by onset
    // Realized ornament/trill/turn/mordent notes, absorbed out of `events` for a
    // notation-centric grade but kept here so playback to the piano can *sound* them
    // (hand-tagged; never graded or notated). Sorted by onset. See docs/INGESTION.md.
    var playbackExtras: [NoteEvent] = []
    // Sustain-pedal (CC64) transitions in playback seconds, for MIDI-out to the piano.
    var pedalTimeline: [(time: Double, down: Bool)] = []
    // Metronome click grid: playback time (seconds) of each click + its emphasis.
    // Built from barlines + per-measure meter (drives the playback-synced metronome).
    var clickGrid: [(time: Double, level: ClickLevel)]
    // One full bar of pulse levels + the seconds between pulses at the initial tempo,
    // used for the count-in and the free-running (no-playback) metronome.
    var metronomeBarPattern: [ClickLevel]
    var metronomePulseSeconds: Double
    var trackHands: [Hand]      // MIDI track → hand, for per-hand audio routing
    // Section-practice support: bar structure + a beat→seconds converter.
    var measureStartBeats: [Double]        // notated start beat of each measure (bar N-1 = index)
    var measureMeters: [(num: Int, den: Int)] // each measure's meter (for section-aware count-ins)
    var totalBeats: Double                 // notated length of the whole piece, in quarter beats
    var secondsAtBeat: (Double) -> Double  // convert any notated beat to playback seconds (tempo map)
    var reconciliations: [Reconciliation]
    // Non-nil when the two files' timelines don't line up structurally (e.g. the
    // MIDI is longer than the written score because repeats were unfolded on export
    // — Woodshed can't align those yet). Surfaced prominently in the UI so grading
    // is never silently wrong. See docs/INGESTION.md.
    var structureWarning: String? = nil
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
