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
   *(Built: guided two-step import, drag-drop, `.mxl`, validation-by-fusing, library with search/
   sort/tags/categories and backup export.)*
2. **Read** — "I see my score rendered with a cursor that follows along and keeps the active line in
   view." *(Built.)*
3. **Listen** — "I play it back, mute one hand, slow it down, and choose whether it comes out of the
   laptop or my piano." *(Built: per-hand, tempo %, speakers/piano/both.)*
4. **Keep time** — "I turn on a metronome that clicks the right meter, with a count-in." *(Built.)*
5. **Learn the notes** — "Wait mode pauses at each note/chord until I play the right notes; wrong
   notes are shown but don't block me, and I can review what I fumbled afterwards." *(Built.)*
6. **Play along & grade** — "I play along at tempo; afterwards it tells me my accuracy and timing and
   marks what I missed." *(Built — 'Grade' mode, plus the post-pass report card below.)*
7. **Master & progress** — "It only advances tempo/section when I've played accurately;
   it shows my trouble spots and history over time." *(Built in full: history, trend, trouble spots,
   tempo mastery gating, and hands-separate → hands-together progression.)*

## 4. Functional requirements

### Implemented
- **Library & import** — a song library stored as per-song folders under Application Support. Import a
  MusicXML + MIDI pair (file picker), rename, favourite, delete, and select a song to practise. First
  launch seeds the two bundled fixtures. **Search** (titles + tags), **sort** (title / last practised /
  best), freeform **tags**, and a cross-song **practice overview** (totals + a stalest-first
  "most due" list, computed by file scan — no database).
- **Ingestion** — of a MusicXML + MIDI pair into an authoritative note model (pitch, spelled name,
  hand, voice, notated duration, tempo, meter, ties, ornaments, **repeats/voltas — unfolded**) with
  MIDI as the timing truth. A per-hand reconciliation + structure banner surface any bad parse.
  See [INGESTION.md](INGESTION.md).
- **Notation display** — render in an embedded WKWebView via OpenSheetMusicDisplay, offline. A
  Swift-driven follow-cursor (smooth glide or note-to-note step); follow-scroll keeps the active +
  next line in view. Options: colour hands (RH blue / LH orange — colour-blind-safe), fixed bars-per-line (1–5 or auto).
- **Playback** — AVAudioEngine + AVAudioUnitSampler; per-hand mute/solo (Both / R.H. / L.H.); tempo
  **25–120%** with pitch preserved; output routing to **PC speakers / MIDI piano / both**. Optional
  **sync start** — Play arms and playback begins the instant you play your first note.
- **Metronome** — meter-aware clicks (eighths for x/8, quarters for x/4), three emphasis tiers,
  count-in (0/1/2 bars), free-running mode, routable to speakers and/or piano. Options to **start it
  with playback** and **stop it when playback stops** (click only while playing).
- **MIDI input** — CoreMIDI, USB + Bluetooth, auto-reconnect; an on-screen 88-key keyboard that
  lights up what you play (green) and, during playback, the score's notes (RH blue / LH orange).
- **Training session types** — one segmented control picks the session: **Practice** (play & follow),
  **Wait** (advance on the right notes), **Grade** (play at tempo, scored), **Drill** (Grade + a
  looped auto-tempo ramp). The Controls inspector shows only the settings relevant to the chosen type.
- **Matching — Wait mode** — advance only when the required note(s) are played; live blue/green/red
  feedback; fumbles marked red on the score for review.
- **Matching — Tempo/Grade mode** — play along at tempo; a windowed greedy matcher (a pure,
  unit-tested `GradeMatcher`) scores hit / missed / wrong, mean timing, and **signed** timing —
  the summary says whether you're **rushing or dragging** and by how much. Tolerance is **tunable**
  (Strict ±150 / Normal ±300 / Relaxed ±450 ms, in musical time); missed notes are ringed red and the
  **wrong notes you play are drawn on the score** (a labelled red dot at their beat and pitch). With
  section **Loop** on, each pass is graded and a per-pass **accuracy trend** is shown, updated every
  pass; notes played during the count-in grade against bar 1. Stopping mid-pass says "pass abandoned"
  rather than silently dropping it.
- **Section focus & looping** — select a bar range (from/to bar) and play or **loop** just that
  section; a "Whole piece" reset. Playback, cursor, metronome, and Wait/Grade are all scoped to the
  section. An optional **per-loop count-in** clicks a pickup before each pass — meter- and
  tempo-aware for the **section's own bar**, not just the piece's first. **Saved sections**: name the
  current bar range and recall it in one tap (persisted per song).
- **Progress tracking** — every Grade pass is persisted per song (`history.jsonl`). A Progress view
  shows the accuracy trend, best full run, last pass, a **trouble-spot heatmap** (bars ranked by
  missed notes, tap to drill that bar), and a recent-pass log. The library row shows last-practised +
  best. (Cross-song analytics and spaced repetition are still Planned.)
- **Revisit flags** — pin a short note to a bar ("LH jump") to mark a spot to work on; flagged bars
  show a tappable ⚑ on the score, and a Flags list adds/edits/deletes and drills to a bar. Stored per
  song (`flags.json`).
- **Drill styles** — a **Drill** session type with two styles. **Ramp the tempo**: the guided auto-tempo drill below. **Add a bar at a time** (progressive): loop a passage that grows one bar at a time — you only advance once the **newest bar** is played ≥ threshold clean (graded on that bar alone, so it isn't hidden inside the whole passage's accuracy); builds from the section start to its end (or the piece end).
- **Speed drill / mastery gating** — a guided auto-tempo drill on a looped section (Grade mode),
  set up in one **Speed drill** panel with a plain-English summary; the transport **▶ Play** starts it
  (in Drill mode Play drops to the **start tempo** and begins the ramp). The tempo ramps from start → **goal** by a **step**.
  Modes: **every few loops**, or **when I play it clean** (advance only after N passes ≥ a clean
  threshold — the mastery gate; a below-threshold pass resets the streak). Reaching the goal with
  its clean passes marks the section **mastered** and stops. Optional **one hand at a time, then
  together**: R.H. → L.H. → both, each stage through the full ramp with the mastery gate.
- **Rhythm tools v1** — "Rhythm only" mode: the piano is silent and every note onset ticks (distinct
  tone), and Grade becomes a **tap-along** — any key counts, only timing is scored (chords collapse
  to one expected tap). Respects the **Hands** setting: with R.H./L.H. selected, only that hand's
  onsets tick (and are graded), so you can isolate one hand's rhythm.
- **Takes (record & replay)** — every pass records what you play from MIDI; play back your last take
  or your **best graded take per section** at the current tempo through the chosen output.
- **Practice time** — active practice seconds are tracked per day per song; Progress shows today +
  total, the overview shows this-week + all-time. Together with the **tempo trend** sparkline this
  makes success criterion #2 measurable.
- **Wait-mode history** — completed walkthroughs are recorded as passes (fumbled steps feed the
  trouble heatmap).
- **Drill me** — one button picks today's spot (worst trouble bar → oldest flag → random) and loops
  a 2-bar window around it.

- **Feedback v2 — the pass report card** (ADR-049–052) — after every graded pass: per-bar results
  (strip / problem-range chips on long scores), a per-bar timing lane, per-hand accuracy + timing,
  **wins first** (fixed bars, deltas, personal bests), recurring-fault streaks with substitution
  detection ("you play D4 instead"), a timing hotspot + tempo-drift line, hand **balance**, **your
  pedal** (muddy-pedal spans), chord-roll detection, scale **evenness** gauges (Technical Practice),
  and teacher-style advice ("tempo too high — drop ~15%"). Every bar-referencing callout **taps to
  flash that bar on the score**; a "Drill slowly" button runs the slow-then-ramp remediation loop.
  The report persists per song (`report.json`) and survives relaunch. Optional **timing tint** colours
  noteheads blue = early / orange = late after a pass.
- **Technical Practice** (ADR-043) — a library category seeded with generated **Major/Minor scale
  books** (48 scales, correct spelling, one saved section per scale), a per-section **mastery grid**,
  and a **Suggested focus** plan (worst trouble bar, neglected-bars honesty check, run-through nudge).
- **Data safety & app polish** (ADR-044–048) — confirmed + recoverable song delete, library/song
  **backup export** (.zip), visible write failures, resume-on-launch, practice **streak + 7-day
  strip**, deterministic session teardown on song switch, MIDI unplug recovery, iOS audio-interruption
  recovery, cross-platform in-app Help + diagnostics log export (opt-in `DebugLog`).

### Planned (from the roadmap, not yet built)
- **Library refinements** — richer entry points (iCloud/AirDrop/drag-drop), target-tempo in the list.
  *(Search, sort, tags, `.mxl` import, and the guided two-step import are built.)*
- **Section refinements** — drag-across-NOTES selection. *(Saved/named sections, per-loop count-in,
  and bar drag-to-select are built. A/B markers were dropped as redundant — ADR-034.)*
- **Rhythm tools v2** — subdivision grid, count display. *(Rhythm-only playback + tap-along grading
  are built — see Implemented.)*
- **Progress & analytics — deeper** — per-piece tempo-over-time charts, spaced repetition. *(The
  cross-song overview — totals + most-due list — is built; per-piece history/trend/trouble-spots
  too.)*
- **Persistence — cross-song store** — a DB (GRDB) only if the file-scan overview ever feels slow.

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
- **Accessibility:** *first pass done* — colour-blind-safe hand colours, VoiceOver labels on the
  transport, the keyboard exposed as an accessibility element, labelled report-card elements.
  Dynamic Type and a full VoiceOver audit remain open.

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
- The user reaches target tempo on tracked sections measurably faster than before — now measurable
  via the tempo-trend sparkline + practice-time ledger.
- **Weekly use** — if it gathers dust it failed regardless of features.
- Wait/Grade feedback feels **encouraging, never punitive** (generous, tunable tolerance).

## Open Questions

- **Accessibility** — hand colours are now colour-blind-safe (RH blue / LH orange). Still open:
  VoiceOver labels (keyboard keys, notation pane), Dynamic Type in the inspector, reduced motion.
  Decide the bar for v1.
- **Grading tolerance** is now tunable (±150/300/450 ms) with early/late (rushing/dragging)
  labelling. Because it's in *musical* time it already widens in wall-clock terms at slow tempo.
  Remaining question: is an additional automatic tempo-tied curve wanted, or is the manual
  setting enough?
- **iPad** now has audio (bundled SoundFont + AVAudioSession) and touch drag-select, but has never
  run on physical hardware — a device pass is the remaining gate.
- **Mastery gating — hands** — tempo mastery gating (the accuracy-tied speed ramp) is built. The
  remaining piece is a **hands-separate → hands-together** progression (drill R.H., then L.H., then
  both, each gated on mastery). Confirm the desired flow.
