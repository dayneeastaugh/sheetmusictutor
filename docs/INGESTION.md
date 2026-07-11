# Ingestion — MusicXML + MIDI Fusion

The core hard problem: faithfully turning a MuseScore export pair into a correct note-and-timing
model. This documents the rules the parsers/fusion follow and **why** — every rule here exists
because a real test file broke a naive approach. Code: `MIDIParser.swift`, `MusicXMLParser.swift`,
`Ingest.swift`. Validated against `Fly Me To the Moon` (swing 4/4) and `Chopin Nocturne Op.9 No.2`
(rubato 12/8 with meter changes, pickup, ornaments, tuplets). Both reconcile 100%.

## The contract: export both files

Each piece is exported from MuseScore twice: an **uncompressed `.musicxml`** and a **`.mid`**. We use
each for what it's good at:

- **MIDI = timing source of truth.** It is already "unfolded": repeats, tuplets, swing, and the
  tempo map are resolved into actual note onsets. Onset/duration in seconds come from here.
- **MusicXML = identity / notation.** Spelling (C♯ vs D♭), hand/staff, voice, notated rhythm, ties,
  ornaments, per-measure meter — how it's *written*. Never compute playback timing from it.

> Export `.musicxml` **uncompressed** (not `.mxl`). `.mxl` is a zip; unzipping in-app (esp. on iPad)
> is avoidable plumbing. `.mxl` support is a later concern.

## Rule 1 — Align in musical beats from MIDI ticks, not seconds×BPM
Convert each MIDI note's tick position to beats (`tick / ticksPerQuarter`). This is
tempo-independent, so it survives tempo changes. *Why:* the Chopin has **14 tempo changes** (20–80
BPM); reconstructing beats from `seconds × constantBPM` drifts and mis-aligns everything.

## Rule 2 — Advance measures by actual filled length, not the nominal meter
`MusicXMLParser` tracks the furthest cursor position reached in each measure and advances
`measureStartBeats` by that, not by `num × 4/den`. *Why:* the Chopin opens with a **pickup/anacrusis**
that MuseScore does **not** mark `implicit`, and the piece has **mid-piece meter changes** (12/8 → 6/4
→ 2/4). A fixed nominal length drifts after the pickup and after each meter change.

## Rule 3 — Notation-centric model; absorb ornament realisations
One `NoteEvent` per **written** note. A trill/turn/mordent is one written note in MusicXML but many
note-ons in MIDI. `Ingest` detects ornaments (`<ornaments>`, `trill-mark`, `mordent`, `turn`,
`wavy-line`, …) and **absorbs** the extra MIDI notes into the parent event (`ornamentNotes` count),
rather than emitting them as first-class notes. *Why:* the Chopin RH has 471 written notes but 524
MIDI note-ons; the 53-note gap is 11 ornaments. The **matcher must match the written note leniently**
and treat the realised flurry as satisfied — never demand the exact alternations.

## Rule 4 — Merge tied notes
A tie in MusicXML is two `<note>` elements; in MIDI it is one sustained note-on. `Ingest.mergeTies`
collapses tied XML notes into one sounding note so the per-hand XML count matches the MIDI note-on
count. (This is how 267 RH pitched notes − 66 ties = 201/202 lines up with MIDI.)

## Rule 5 — Fuse by hand, then by beat + pitch
MuseScore exports each staff as its own MIDI **track** (track 0 = RH, track 1 = LH; confirmed by
pitch range and count). Within each hand, XML sounding notes are matched to MIDI notes by nearest
musical beat + equal pitch (a generous 1-beat window absorbs swing). The result attaches XML identity
(spelling/hand/voice/notatedType) onto MIDI timing → `NoteEvent`.

## Rule 6 — Spelling comes from MusicXML, always
The same MIDI pitch is spelled by context: e.g. MIDI 56 renders as **G♯3** in one bar and **A♭3** in
another. MIDI alone can only say "56"; the XML gives the correct enharmonic. This is the whole point
of importing both.

## Reconciliation (the self-check)
`Ingest` produces a per-hand `Reconciliation` (`isClean` when every MIDI note is accounted for as a
written note or an absorbed ornament, and every written note matched). If anything is unclean, a
**warning banner** appears on the practice screen (and at import) with a Details link to the ✅/⚠️
table — an unclean import is never silent, because grading against a wrong model is the worst
failure mode this app has.

## Known limitation: repeats / voltas / D.C. are NOT aligned
The MIDI export is **unfolded** (repeats expanded into real time) while the MusicXML beat timeline
is **written/folded** — and the aligner matches on beats. A piece with repeats therefore cannot be
aligned past the first repeat: every second-pass MIDI note misses its 1-beat window and the model is
wrong from there on. `Ingest` detects the signature (the MIDI running more than a bar past the
written score — `timelinesMismatch`) and sets `FusedScore.structureWarning`, which the UI surfaces
prominently. Until unfolding is implemented (parse `<repeat>`/`<ending>` barlines and expand the XML
timeline), the workaround is to export from MuseScore with repeats written out.

## Parser specifics worth knowing
- **`MusicXMLParser` uses `XMLParser` (SAX), not `XMLDocument`** — because `XMLDocument` is macOS-only
  and would break the iPad target.
- **`MIDIParser` is hand-rolled** (no dependency): header + `MTrk` chunks, running status, varlen
  deltas, tempo map integration, note-on/off pairing. Supports musical (ticks-per-quarter) division
  only, not SMPTE. Every byte read is **bounds-checked and throwing** — a truncated/corrupt file is
  a catchable `MIDIError.malformed`, never a crash (fuzz-tested in `WoodshedTests`).
- Grace notes: currently parsed as zero-duration notes; they generally match fine but are an edge
  case to watch.

## Metronome grid (built here, used by audio)
From the per-measure meter, `Ingest.buildClickGrid` emits click times with three emphasis tiers:
downbeat (bar start), beat (main beats — every 3rd subdivision in compound meters), sub (other
subdivisions). It clicks the denominator's unit (eighths for `x/8`, quarters for `x/4`) and keeps the
downbeat on the barline through pickups and meter changes.

## Open Questions
- **Repeats/voltas** are detected and warned about but not aligned (see Known limitation above) —
  implementing XML timeline unfolding is the biggest ingestion feature left.
- Grace-note timing/handling isn't specially modelled — confirm whether the matcher needs it.
- Multiple voices per staff beyond the tested files (e.g. divisi) are parsed (`voice`) but untested.
- `.mxl` (compressed) import is not implemented; the contract is uncompressed `.musicxml`.
- Track→hand relies on MuseScore's one-track-per-staff export + an average-pitch fallback; a file
  that merges hands into one track would need a different strategy.
