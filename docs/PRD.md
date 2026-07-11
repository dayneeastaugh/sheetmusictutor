# Product Requirements — Woodshed

**Status:** Living doc, derived from the original `piano-tutor-prd.md` (draft v0.3) and reconciled
with the current codebase. Where this and the old draft differ, this doc + the code win.
**Type:** Native macOS + iPadOS app, single SwiftUI codebase, fully on-device.

## 1. Problem statement

A pianist transcribes pieces into MuseScore to (a) hear right/left hand separately and (b) untangle
tricky rhythms. MuseScore is an *editor*, not a *practice loop*: no mastery gating, weak
rhythm-isolation drills, no MIDI performance feedback, and poor practice ergonomics (fast looping,
"wait for me" mode, accuracy-tied tempo ramps). Web tools cover the *player* half but can't do native
MIDI on iPad and don't close the loop between what you play and how the session progresses.

## 2. Target users

Primary (and only) user: an intermediate adult learner, comfortable with software, who reads
notation, transcribes into MuseScore, owns a USB/Bluetooth MIDI digital piano, and practises at a Mac
or iPad. Secondary: occasionally playing for/with a young child (a low-friction "just play the chorus
slowly, both hands, loop it" path should exist). Single-user, personal instrument — **not** a product.

## 3. Core user stories & flows

1. **Import** — "I export a piece from MuseScore as MusicXML + MIDI and open it in Woodshed."
   *(Today: scores are bundled fixtures; a real import/library flow is not built.)*
2. **Read** — "I see my score rendered with a cursor that follows along and keeps the active line in
   view." *(Built.)*
3. **Listen** — "I play it back, mute one hand, slow it down, and choose whether it comes out of the
   laptop or my piano." *(Built: per-hand, tempo %, speakers/piano/both.)*
4. **Keep time** — "I turn on a metronome that clicks the right meter, with a count-in." *(Built.)*
5. **Learn the notes** — "Wait mode pauses at each note/chord until I play the right notes; wrong
   notes are shown but don't block me, and I can review what I fumbled afterwards." *(Built, first cut.)*
6. **Play along & grade** — "I play along at tempo; afterwards it tells me my accuracy and timing and
   marks what I missed." *(Built, first cut — 'Grade' mode.)*
7. **Master & progress** *(not built)* — "It only advances tempo/section when I've played accurately;
   it shows my trouble spots and history over time." *(Built: history, trend, trouble spots, and
   tempo mastery gating — the speed trainer only ramps the tempo when you play accurately. Not yet:
   hands-separate → hands-together gating.)*

## 4. Functional requirements

### Implemented
- **Library & import** — a song library stored as per-song folders under Application Support. Import a
  MusicXML + MIDI pair (file picker), rename, favourite, delete, and select a song to practise. First
  launch seeds the two bundled fixtures. (Files/iCloud/AirDrop entry points and tags/target-tempo in
  the list are not yet built — see Planned.)
- **Ingestion** — of a MusicXML + MIDI pair into an authoritative note model (pitch, spelled name,
  hand, voice, notated duration, tempo, meter, ties, ornaments) with MIDI as the timing truth. Show a
  per-hand reconciliation so a bad parse surfaces. See [INGESTION.md](INGESTION.md).
- **Notation display** — render in an embedded WKWebView via OpenSheetMusicDisplay, offline. A
  Swift-driven follow-cursor (smooth glide or note-to-note step); follow-scroll keeps the active +
  next line in view. Options: colour hands (RH blue / LH red), fixed bars-per-line (1–5 or auto).
- **Playback** — AVAudioEngine + AVAudioUnitSampler; per-hand mute/solo (Both / R.H. / L.H.); tempo
  **25–120%** with pitch preserved; output routing to **PC speakers / MIDI piano / both**. Optional
  **sync start** — Play arms and playback begins the instant you play your first note.
- **Metronome** — meter-aware clicks (eighths for x/8, quarters for x/4), three emphasis tiers,
  count-in (0/1/2 bars), free-running mode, routable to speakers and/or piano. Options to **start it
  with playback** and **stop it when playback stops** (click only while playing).
- **MIDI input** — CoreMIDI, USB + Bluetooth, auto-reconnect; an on-screen 88-key keyboard that
  lights up what you play (green) and, during playback, the score's notes (blue/red).
- **Matching — Wait mode** — advance only when the required note(s) are played; live blue/green/red
  feedback; fumbles marked red on the score for review.
- **Matching — Tempo/Grade mode** — play along at tempo; a windowed greedy matcher (a pure,
  unit-tested `GradeMatcher`) scores hit / missed / wrong, mean timing, and **signed** timing —
  the summary says whether you're **rushing or dragging** and by how much. Tolerance is **tunable**
  (Strict ±150 / Normal ±300 / Relaxed ±450 ms, in musical time); missed notes marked red. With
  section **Loop** on, each pass is graded and a per-pass **accuracy trend** is shown; the notes
  you're still missing are ringed on the score, updated every pass. Stopping mid-pass says "pass
  abandoned" rather than silently dropping it.
- **Section focus & looping** — select a bar range (from/to bar) and play or **loop** just that
  section; a "Whole piece" reset. Playback, cursor, metronome, and Wait/Grade are all scoped to the
  section. An optional **per-loop count-in** clicks a pickup before each pass — meter- and
  tempo-aware for the **section's own bar**, not just the piece's first. (Named/saved clips are not
  yet built.)
- **Progress tracking** — every Grade pass is persisted per song (`history.jsonl`). A Progress view
  shows the accuracy trend, best full run, last pass, a **trouble-spot heatmap** (bars ranked by
  missed notes, tap to drill that bar), and a recent-pass log. The library row shows last-practised +
  best. (Cross-song analytics and spaced repetition are still Planned.)
- **Revisit flags** — pin a short note to a bar ("LH jump") to mark a spot to work on; flagged bars
  show a tappable ⚑ on the score, and a Flags list adds/edits/deletes and drills to a bar. Stored per
  song (`flags.json`).
- **Speed trainer / mastery gating** — an auto-tempo drill on a looped section (Grade mode): after
  each pass the tempo ramps toward a target by a step. Modes: **by reps** (advance every N passes) and
  **by accuracy** (advance only after N *clean* passes ≥ a threshold — the mastery gate; a
  below-threshold pass resets the streak). Reaching the target with its clean passes marks the section
  **mastered** and stops. (Hands-separate → hands-together gating is still Planned.)

### Planned (from the roadmap, not yet built)
- **Library refinements** — richer entry points (iCloud/AirDrop/drag-drop), tags, search/sort,
  target-tempo shown in the list. *(Last-practised + best now shown; `.mxl` import and a guided
  two-step import flow are built.)*
- **Section refinements** — named/saved clips per piece, drag-across-notes selection, A/B markers.
  *(Per-loop count-in now built; drag-to-select on the score already exists.)*
- **Rhythm tools** — rhythm-only playback, subdivision grid, tap-along trainer, count display.
- **Mastery gating — hands** — hands-separate → hands-together gating. *(Tempo mastery gating and the
  speed trainer are built — see Implemented.)*
- **Progress & analytics — cross-song** — per-piece tempo-over-time, library-wide heatmap, spaced
  repetition. *(Per-piece history/trend/trouble-spots are built — see Implemented.)*
- **Persistence — cross-song store** — a DB (GRDB) if/when library-wide querying needs it; per-song
  history + metadata are already on disk.

## 5. Non-functional requirements

- **Platforms:** macOS 15.7 + iPadOS 26.2 from one SwiftUI codebase (visionOS builds but is not a
  target of use). No other platforms.
- **Fully on-device:** no server, NAS, account, or runtime internet dependency. All assets local.
- **Privacy:** everything local; no telemetry.
- **Offline:** the notation renderer (OSMD), fonts, sounds, and scores must all work with no network.
- **Latency/feel:** schedule audio on the render clock (the sequencer does this); keep MIDI-in →
  visual feedback perceptually immediate. Cursor updates at ~50 Hz; metronome on a high-resolution
  timer (target: move click to a sample-accurate look-ahead scheduler — see Open Questions).
- **Storage:** file-based — per-song `metadata.json` + append-only `history.jsonl` (no DB). A GRDB
  store is deferred until cross-song analytics need it (DECISIONS ADR-021).
- **Accessibility:** *not yet addressed* — see Open Questions.

## 6. Out of scope (explicit non-goals)

- Not a notation **editor** (MuseScore stays the editor; this consumes its output).
- Not audio-to-score transcription.
- **No server / NAS / cloud / multi-user / sync backend.** Single-device only.
- Not parsing MuseScore's native `.mscz` format.
- Not time-stretching real audio recordings (synth playback only).
- Not "grade my expressive musicality" — timing tolerance is generous by design.
- Not Windows/Android/web.

## 7. Success criteria

- **Ingestion is faithful** across the user's *own* MuseScore exports — correct note count, hands
  separated, sensible timing — and reconciles 100% (met for the two current fixtures).
- The user reaches target tempo on tracked sections measurably faster than before *(needs the
  progress/analytics + mastery features)*.
- **Weekly use** — if it gathers dust it failed regardless of features.
- Wait/Grade feedback feels **encouraging, never punitive** (generous, tunable tolerance).

## Open Questions

- **Accessibility** (VoiceOver, Dynamic Type, colour-blind-safe hand colours — RH blue / LH red may be
  a problem for red-green deficiency) is unaddressed. Decide the bar for v1.
- **Grading tolerance** is now tunable (±150/300/450 ms) with early/late (rushing/dragging)
  labelling. Because it's in *musical* time it already widens in wall-clock terms at slow tempo.
  Remaining question: is an additional automatic tempo-tied curve wanted, or is the manual
  setting enough?
- **iPad** is a stated first-class platform but untested; the sound source differs (no system `.dls`).
- **Mastery gating — hands** — tempo mastery gating (the accuracy-tied speed ramp) is built. The
  remaining piece is a **hands-separate → hands-together** progression (drill R.H., then L.H., then
  both, each gated on mastery). Confirm the desired flow.
