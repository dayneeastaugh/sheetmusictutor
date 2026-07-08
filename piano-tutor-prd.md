# PRD — Piano Practice Tutor ("working title: Woodshed")

**Status:** Draft v0.3 · **Author:** Dayne (with Claude) · **Type:** Native app, macOS + iPadOS, single codebase, fully on-device

> **What changed in v0.3:** Added Appendix A (competitive landscape and the rationale for building,
> as of July 2026) and clarified the MusicXML + MIDI ingestion approach.
>
> **What changed in v0.2:** Architecture moved from a browser + NAS/Docker design to a **single native
> SwiftUI app** running on macOS and iPadOS from one codebase. **No server, no NAS, no cloud, no
> account.** Scores import as **MusicXML** exported from MuseScore. **Note matching is now a core,
> day-one feature**, not a later phase. These are decided, not open.

---

## 1. Summary

A native macOS + iPadOS app that turns a score (exported from MuseScore as MusicXML) into an
interactive tutor. It renders notation with a follow-cursor, plays back with per-hand isolation and
tempo control, lets you focus and loop any section, ramps tempo as you improve, provides dedicated
**rhythm-isolation** tools, and — the core differentiator — listens to a connected MIDI piano and
compares what you play against the score **with realistic timing tolerance**, using your accuracy to
**gate tempo progression** (mastery-based practice) rather than leaving you to decide when to speed up.

The app is a personal instrument tuned to one player's pedagogy: your own library, your own devices,
no subscription, everything local, full control over behaviour. It is explicitly **not** a product
competing with Soundslice/Synthesia/flowkey.

---

## 2. Problem statement

You transcribe pieces into MuseScore to (a) hear right/left hand separately and (b) untangle the
rhythm of note groups where timing isn't obvious. MuseScore is an *editor*, not a *practice loop*: no
mastery gating, weak rhythm-isolation drills, no MIDI performance feedback, and the practice
ergonomics (fast looping, "wait for me" mode, tempo ramps tied to accuracy) aren't there. Web tools
cover the *player* half well but can't do native MIDI on iPad, aren't tailored, and none close the
loop between what you play and how the session progresses.

---

## 3. Goals & non-goals

### Goals
- Practice a specific piece from your own MuseScore-exported MusicXML, end to end, on Mac or iPad.
- Isolate right/left hand; focus and loop any bar range.
- Slow down (event timing, pitch preserved); ramp tempo back to target — ideally automatically.
- First-class **rhythm** tools for "I can't feel the timing of this group."
- **Note matching with tolerance from day one:** hear/see what you play vs the score, forgivingly.
- Close the loop: only advance tempo / section when you've actually played it accurately.
- Track practice history per piece so progress is visible.
- Run entirely on the device; data local (SQLite); no server, account, or internet dependency.

### Non-goals
- Not a notation editor (MuseScore stays the editor; this consumes its MusicXML output).
- Not audio-to-score transcription.
- **No server / NAS / cloud / multi-user / sync backend.** Single-device, on-device only.
- Not parsing MuseScore's native `.mscz` format (undocumented and version-volatile — see §6.1).
- Not time-stretching real audio recordings (synth playback only).
- Not "grade my expressive musicality." Timing tolerance is generous by design.
- Not Windows/Android/web. Apple platforms only.

---

## 4. Users & context

Single primary user (you): an intermediate adult learner, comfortable with software, who reads
notation, transcribes into MuseScore, owns a USB/Bluetooth MIDI digital piano, and practises at a Mac
or on an iPad. Occasional secondary use: playing for/with a young child, so a low-friction "just play
this slowly, both hands, loop the chorus" path should exist.

---

## 5. Scope by phase (build order)

| Phase | Theme | You get | Hard bits |
|------|-------|---------|-----------|
| **0** | Vertical-slice prototype | Import one MusicXML, render it, cursor + playback, mute a hand, loop 4 bars at half speed, **read live MIDI and light up played notes** | Prove the native + web-view bridge and CoreMIDI end-to-end |
| **1** | MVP player + Wait mode | Library, section focus, hand isolation, tempo slider + ramp, count-in, metronome, A/B loop, **Wait mode matching** (advance only on correct notes) | Matching state machine; timing feel |
| **2** | Tempo-mode grading | Play along at tempo; per-note hit/late/early/wrong/missed within tolerance; pass score | Real-time alignment + scoring |
| **3** | Mastery gating + rhythm tools | Auto-ramp only on N clean passes; rhythm-only playback; tap-along timing trainer; subdivision click | Practice-loop state machine |
| **4** | Progress & analytics | Practice history, per-bar trouble-spot heatmap, tempo-over-time, spaced repetition of weak bars | Useful metrics, data model |
| **Later** | Nice-to-haves | Fingering overlay, sight-reading mode, record & review, chord/theory overlay | Scope-creep control |

Matching appears in Phase 0 (read + display) and Phase 1 (Wait mode), satisfying the day-one
requirement, with full tempo grading immediately after in Phase 2.

---

## 6. Functional requirements

### 6.1 Score import & library
- Import **MusicXML** (`.musicxml` / `.mxl`) — the stable, documented interchange MuseScore exports
  via `File → Export`. This is the contract. A single export step in your existing MuseScore workflow.
- **Explicitly not** parsing `.mscz` (MuseScore's native zip/XML): undocumented, version-volatile
  (your file is 4.7.3), and it would create a permanent format-drift maintenance tax for no benefit.
- Import via Files / iCloud Drive / AirDrop / drag-drop; app copies into its own local store.
- Parse MusicXML once in Swift into an authoritative note-event model (pitch, hand/staff, onset,
  duration, voice, tempo, time signature) that drives playback, matching, and the cursor. The web
  view gets the same MusicXML only to draw the picture.
- Library view: pieces with tags (composer, key, difficulty, status), last-practised, target tempo.

### 6.2 Notation display
- Render the score in an embedded WKWebView via OpenSheetMusicDisplay, with a **follow-cursor** that
  Swift drives ("highlight event N"). The web view is display-only; it owns no logic or clock.
- Show/hide RH staff, LH staff, or both.
- Optional overlays (toggles): note names, beat/count numbers, fingering (if present in the XML).
- Tap/click any note or bar to move the cursor there.
- Handle long pieces (paged or continuous scroll keeping the cursor in view).

### 6.3 Playback engine
- Native playback via AVAudioEngine + AVAudioUnitSampler with a bundled sampled piano (SoundFont/EXS).
- **Per-hand mute/solo** (RH / LH / both), independent volume (separate sampler nodes per staff).
- **Tempo:** target BPM (from the score, editable) and a % control (~25%–120%), pitch preserved.
- **Count-in** (1–2 bars) with configurable subdivisions.
- **Metronome / click:** on/off, downbeat accent, subdivision option, own volume.
  - *Future phase — customisable metronome settings.* The Phase 0 spike ships a working metronome
    that derives its clicks from the actual barlines and per-measure meter (so accents land on the
    downbeat through pickups and mid-piece meter changes), clicking the denominator's beat unit
    (eighths for x/8, quarters for x/4). A later phase should expose **user-customisable settings**:
    click subdivision (beat / eighths / sixteenths / triplet), multi-tier accents (strong downbeat →
    medium main-beats → light subdivisions, esp. for compound meters like 12/8), click volume and
    sound, count-in bars, and a free-running mode (click without playback for practising away from
    the recording). Also revisit tightness: move the click onto a sample-accurate look-ahead scheduler
    on the render clock (the spike drives it from a high-resolution timer against the playback clock).
- Loop toggle with seamless wrap. Schedule everything on the audio render clock, not timers.

### 6.4 Section focus & looping
- Select a bar range (drag across notes or type "bars 17–24"); snap to bar/rest boundaries.
- Loop indefinitely; optional silent reset gap of N beats between reps.
- Save named clips per piece ("bridge", "LH jump bar 33") for instant recall.

### 6.5 Speed trainer (tempo ramp)
- **Manual:** slider only.
- **Auto by reps:** +X% every N loops up to target.
- **Auto by accuracy (MIDI):** advance only when the last pass scores ≥ threshold (§6.7/§6.8).
- Show current % and distance to target; mark reaching target tempo on a tracked section.

### 6.6 Rhythm tools (under-served — lean in)
- **Rhythm-only playback:** mute pitch; play one percussive click on every note onset of the selected
  hand(s) at the selected tempo, so you can *hear the timing of a note group* in isolation.
- **Subdivision grid:** visual beat/subdivision grid under the staff; cursor snaps to it.
- **Tap-along trainer:** tap any MIDI note/pedal (or key) on each onset; score the tapped rhythm vs the
  notated rhythm and show where you rushed/dragged. Pure timing, no pitch.
- **Count display:** show "1 e & a 2 …" aligned to the notes for a passage.

### 6.7 MIDI input & matching (core, day one)
- Connect USB/Bluetooth MIDI via **CoreMIDI**; show device + a live keyboard that lights up as you
  play. Native on both macOS and iPadOS — no Web MIDI, no HTTPS, no Safari/iOS exclusion.
- Use CoreMIDI event timestamps as the timing source of truth for the matcher.
- **Two feedback modes:**
  - **Wait mode (MVP):** playback pauses at each note/chord and only advances when you play the correct
    note(s). Wrong notes flash but don't block; a chord requires all notes within a short grace window.
    No tempo pressure. Best for learning notes and fingering.
  - **Tempo mode (Phase 2):** playback runs at tempo; the matcher aligns your live, error-laden stream
    to the expected stream and labels each note hit / late / early / wrong / missed within a tolerance
    window (start ~±150 ms, widening at slow tempi, tightening as tempo rises).
- **Per-note visual feedback:** colour notes green/amber/red after each pass; keyboard shows expected
  vs played.
- **Pass score:** % correct, timing spread, wrong/extra count. Feeds mastery gating.
- Tolerances are explicit and tunable. The tool must feel encouraging, never punitive.

### 6.8 Practice loop / mastery gating (the "tutor")
- Per-piece practice plan: ordered sections, each with a target tempo and a mastery rule (e.g. "≥95%
  correct, ≤X ms average timing error, 3 consecutive clean passes").
- The app drives the session: loop current section → grade → if mastered, ramp tempo or advance; if
  not, keep looping (optionally auto-slow after repeated misses).
- "Hands separately → hands together" gating: require each hand to pass separately first.

### 6.9 Progress & analytics
- Per-piece: tempo vs target over time, session log, minutes practised.
- **Trouble-spot heatmap:** colour each bar by historical error rate.
- Optional spaced-repetition queue: failed bars resurface more often in future sessions.

### 6.10 Settings
- Global: audio output/latency, MIDI input selection, default tolerances, theme.
- Per-piece: target tempo, ramp rule, mastery thresholds, saved clips, fingering source.

---

## 7. Suggested additional features (beyond the original list)

Ranked by value-to-effort for *your* practice:
1. **Rhythm-only + tap-along trainer** (§6.6) — solves your stated pain; under-served everywhere.
2. **Mastery-gated tempo ramp** (§6.5/§6.8) — the feature that makes this a tutor, not a player.
3. **Trouble-spot heatmap + spaced repetition** (§6.9) — turns history into "practise *this* today".
4. **Hands-separate → hands-together gating** — encodes the standard method into the tool.
5. **Fingering overlay** — read from the MusicXML if you add fingering in MuseScore.
6. **Record & review** — capture your MIDI performance; scrub it back against the score.
7. **Sight-reading mode** — reveal bar-by-bar, or hide a beat ahead of the cursor.
8. **Chord/harmony overlay** — chord symbols / roman numerals for theory-aware practice.
9. **Session goals & streaks** — lightweight targets ("bridge to 90 BPM today").
10. **Backing/drone** — play the other hand or a click as accompaniment while you play one hand.

Deferred (scope traps): real-audio time-stretch, sync/cloud, video, notation editing.

---

## 8. Non-functional requirements & constraints

- **Platforms:** macOS + iPadOS from one SwiftUI codebase. No other platforms.
- **Fully on-device:** no server, NAS, account, or runtime internet requirement.
- **Storage:** SQLite via GRDB (direct SQL, transparent) — pieces, sections, sessions, cached note
  events, attempts. Score files in the app's local container.
- **MIDI:** CoreMIDI, USB + Bluetooth. Works identically on both platforms.
- **Latency/feel:** schedule audio on the render clock (look-ahead), not timers; keep MIDI-in →
  visual feedback perceptually immediate (< ~50 ms).
- **Signing/distribution:** macOS runs freely (self-signed). iPad needs either the free path
  (rebuild/re-sign weekly from Xcode; wireless debugging eases it; 3-device limit) or the Apple
  Developer Program ($99/yr, 1-year signing, up to 100 devices). Recommend the $99 path for daily iPad
  use. UAE has no alternative app stores, so those are the two realistic options.
- **Privacy:** everything local; no telemetry.

---

## 9. Technical architecture (decided)

**One SwiftUI multiplatform app.** Layers:

- **Score model (Swift):** a MusicXML parser producing the authoritative note-event model. Single
  source of truth for playback, matching, and cursor position.
- **Notation view (WKWebView + OSMD):** display + follow-cursor only, driven by Swift ("highlight
  event N", "show bars 17–24", "hide LH"). No logic, no clock in the web layer. (Verovio-native SVG is
  a possible later swap if the web view feels janky; not needed for MVP.)
- **Audio (AVAudioEngine + AVAudioUnitSampler):** sampled piano, per-staff sampler nodes for hand
  isolation, tempo via event scheduling, metronome/click, look-ahead scheduler for tight timing.
- **MIDI (CoreMIDI):** device discovery, note-on/off with hardware timestamps → the matcher.
- **Matching engine (Swift, core module, UI-decoupled, testable):** consumes expected events + live
  MIDI; Wait mode first, tempo-mode alignment + scoring next (see §10).
- **Practice engine (Swift):** the session state machine — looping, mastery rules, tempo ramp,
  hands-separate→together gating.
- **Persistence (GRDB/SQLite):** library, per-piece config, session history, attempts.

No backend, no network calls. The MuseScore CLI conversion service from v0.1 is removed entirely.

---

## 10. The hard problem: note matching / score following

The only genuinely hard piece; scope it in two tiers. CoreMIDI timestamps make both more tractable
than a browser would.

**Tier A — Wait mode (MVP).** State machine over the expected event stream. At each cursor position
there's a required note-set (note or chord). Buffer incoming `noteon`; when the required set is met
within a grace window, advance. Wrong/extra notes are shown but ignored for advancement. No global
tempo, so no alignment problem — robust, forgiving, pedagogically strong. A few days of careful state
handling.

**Tier B — Tempo mode (immediately after A).** Playback runs at tempo; align a live, error-laden
performance in real time:
- Maintain a pointer into expected events; match each incoming note to the nearest expected note
  within tolerance and label hit / early / late / wrong / missed.
- Tolerance ~±150 ms baseline (a reference practice tool uses roughly ±300 ms), widening at slow
  tempi and tightening as tempo rises. Never demand perfection.
- Handle the real mess: rolled chords, dropped/doubled notes, pedal-blurred releases, learner tempo
  drift. A windowed greedy matcher suffices for a *known* score; do **not** build academic-grade
  probabilistic following.
- Pass score = f(% correct, timing spread, wrong/extra) → feeds mastery gating.

Design principle throughout: **generous, tunable tolerance**. The failure mode to avoid is a tool
that's technically correct but demoralising.

---

## 11. Risks & mitigations

| Risk | Likelihood | Mitigation |
|------|-----------|-----------|
| Tempo-mode matching (Tier B) eats unbounded time | High | Ship Wait mode (Tier A) first; it delivers most of the tutor value. Time-box Tier B. |
| Swift/Xcode learning curve slows early progress | Medium | Phase 0 vertical slice proves the whole stack before feature work; keep engine modules plain and testable. |
| WKWebView ↔ Swift bridge (cursor sync) feels laggy | Medium | Keep the web layer dumb (display only); drive cursor from the Swift audio clock; consider Verovio-native later if needed. |
| Playback timing feels loose | Medium | Look-ahead scheduler on the render clock from day one; test click-vs-playback tightness in Phase 0. |
| iPad re-signing friction on the free path | Low | Use the $99/yr Developer Program for daily iPad use. |
| MusicXML export quirks between MuseScore versions | Low | MusicXML is stable/documented; test against your real exports; it's the contract, not `.mscz`. |
| Scope creep (audio-stretch, sync, video) | Medium | They're in Non-goals; keep them there until v1 is genuinely used. |

---

## 12. Open decisions

Most prior decisions are now closed (native stack, no NAS, MusicXML import, matching-as-core). Remaining:
1. iPad signing: free weekly re-sign vs $99/yr Developer Program (recommend $99 for daily use).
2. Sampled-piano source: which SoundFont/sample set to bundle (quality vs app size).
3. Whether Phase 3 rhythm tools or Phase 4 analytics come first after tempo-mode lands — driven by
   which helps *your* practice more.

---

## 13. Success metrics (personal)

- You reach target tempo on tracked sections measurably faster than before (tempo-over-time curve).
- You actually use it weekly (if it gathers dust, it failed regardless of features).
- The trouble-spot heatmap changes what you practise (the data is actionable).
- Time-to-learn a new piece trends down across several pieces.

---

## Appendix A — Competitive landscape & rationale for building (as of July 2026)

A market scan was done before committing to a build, specifically to check we're not just
re-implementing an existing product. Summary of findings and why we're building anyway.

**The three closest existing tools:**

- **Synthesia** (~$39 one-time; native Windows/macOS/iPadOS/Android). Imports MusicXML and MIDI;
  can show falling notes, sheet music, or both; has a "melody practice" wait mode (waits for the
  correct note), a rhythm mode (judges timing vs a metronome), hands-separate practice, slow-down,
  loops, a built-in metronome, and score/progress tracking. **But:** it is falling-notes-first, with
  notation and scoring as secondary/basic; and it is slowly maintained (mobile build last updated
  ~Sept 2024). It is the closest single product on paper, but not a notation-first, adaptive tutor.

- **Piano Marvel** (~$16/mo subscription; macOS/iPadOS/Windows/Android; cloud). Notation-first with
  MIDI note-and-timing assessment; lets you upload your own music as XML+MIDI and slice it into
  segments; "whole / chopped / minced" practice maps onto hands-together and hands-separate section
  drilling; slows passages, isolates hands, adjusts tempo; tracks progress; SASR sight-reading test.
  **But:** the upload path — the exact thing we care about — is unreliable for MuseScore XML.
  Multiple user reports (MuseScore and Piano World forums) describe MuseScore→Piano Marvel uploads
  frequently breaking (content cut off, fingering collisions, layout issues), inconsistently across
  files, with fiddly export-setting workarounds. It's also subscription and cloud-based.

- **Soundslice** (subscription; browser, works on iPad via web). Best-in-class *player*:
  pitch-preserving slow-down, drag-to-loop with snapping, hide/mute either hand, rhythm-count
  display, gradual speed-up, MusicXML import. **But:** it does not grade your playing at all; its
  MIDI support is for note *entry* only, and explicitly not on Safari/iOS.

Others around the edges: MasterPiano, sightreading.training, Melodics, Tomplay, Yousician, PianoVision.

**The gap, and why we build:** No incumbent reliably serves this specific combination —
*practice my own MuseScore transcriptions* + *notation-first* + *mastery-gated adaptive tempo* +
*rhythm-isolation drills* + *native Mac/iPad* + *on-device, no subscription, tailored to me*. The
incumbents' common weak point (Piano Marvel especially) is precisely our core requirement: reliably
ingesting the user's own MuseScore scores.

**Honest counter-risk and its mitigation:** Piano Marvel's buggy MusicXML import is partly evidence
that robust MusicXML parsing is genuinely hard — a risk we would inherit. It is much smaller for us
because we only ever parse *one user's* files, from *one* MuseScore version, with *consistent* export
settings — a tiny, controllable subset versus the arbitrary XML Piano Marvel must accept. We further
de-risk it by exporting **both** MusicXML and MIDI from the same score: MusicXML drives the notation
(what's written / how to draw it), MIDI drives the authoritative note-and-timing model (when it
sounds). MIDI is already "unfolded" (repeats, tuplets, tempo map resolved), so this sidesteps the
class of playback-timing bugs that come from computing timing out of MusicXML.

**Consequence for build order:** Phase 0 must first prove faithful ingestion of the user's *real*
MuseScore exports (starting with *Fly Me to the Moon* plus one or two others) before any further
work. If even the user's own files parse inconsistently, that must surface immediately.
