# Decision Log — Woodshed

Append-only, ADR-style. Newest at the bottom. Each entry: **date · decision · rationale ·
alternatives rejected**. Seeded from choices made building the Phase-0 vertical slice (2026-07-08).

Add a new ADR (don't rewrite old ones) whenever a decision changes design, architecture, stack, data
model, or a hard-to-reverse behaviour.

---

### ADR-001 — Native SwiftUI multiplatform app, fully on-device
**2026-07-08.** One SwiftUI codebase targeting macOS + iPadOS (visionOS builds along for free). No
server, NAS, cloud, account, or runtime network.
**Rationale:** personal single-user tool; native MIDI on iPad requires CoreMIDI (no Web MIDI on
iOS/Safari); privacy and zero-dependency operation.
**Rejected:** browser + NAS/Docker design (v0.1 of the PRD); web app (can't do native iPad MIDI).

### ADR-002 — Import a MusicXML + MIDI pair; MIDI = timing truth, MusicXML = identity
**2026-07-08.** Each piece is two MuseScore exports. Timing/onset in seconds comes from the MIDI; note
spelling, hand, voice, notation, ornaments come from the MusicXML.
**Rationale:** MIDI is "unfolded" (repeats/tuplets/swing/tempo-map resolved), sidestepping a whole
class of playback-timing bugs; MusicXML is the stable, documented interchange for *how it's written*.
**Rejected:** MusicXML-only (would require computing playback timing → swing/rubato bugs, proven on
the test files); MIDI-only (no spelling/hand/voice); parsing `.mscz` (undocumented, version-volatile).

### ADR-003 — Notation-centric model; absorb ornament realisations
**2026-07-08.** One `NoteEvent` per *written* note. Trill/turn/mordent realisations (many MIDI notes)
are absorbed into their parent event, not emitted as first-class notes.
**Rationale:** matches how a player reads the score; the future matcher must match the written note
leniently, never demand the realised flurry. Discovered via the Chopin (471 written vs 524 MIDI RH).
**Rejected:** one event per MIDI note-on (would make ornaments look like errors and pollute matching).

### ADR-004 — OSMD in a WKWebView for notation; Swift owns model + clock
**2026-07-08.** Render MusicXML via OpenSheetMusicDisplay inside `WKWebView`; the web layer is display
only. Swift drives cursor/colours/marks via `evaluateJavaScript`.
**Rationale:** OSMD is a mature MusicXML→SVG renderer; re-implementing engraving in Swift is out of
scope. Keeping logic/clock in Swift keeps the web layer dumb and swappable.
**Rejected:** native SVG engraving (huge scope); Verovio-native (possible later swap if the web view
feels janky, noted in PRD).

### ADR-005 — Vendor OSMD, inline it, run fully offline; no Swift package deps
**2026-07-08.** Bundle `opensheetmusicdisplay.min.js` (2.0.0) and **inline** it into `index.html`
(spliced in place of `<script src>`); zero third-party Swift packages.
**Rationale:** offline requirement (OSMD bundles VexFlow + fonts + JSZip); inlining avoids `file://`
sub-resource loading issues in WKWebView; keeps the Swift dependency surface at zero.
**Rejected:** loading OSMD from a CDN (breaks offline); `loadFileURL` with sibling resources (fragile
read-access rules — caused an early blank render).

### ADR-006 — Playback via AVAudioSequencer through per-hand samplers
**2026-07-08.** `AVAudioSequencer` plays the actual `.mid`, routing each track to a per-hand
`AVAudioUnitSampler`. Tempo via `sequencer.rate` (pitch preserved). Cursor + metronome read the
sequencer's **musical-time** position, so they follow the tempo slider automatically.
**Rationale:** the sequencer schedules on the render clock and honours the tempo map (rubato) for
free; two samplers give independent per-hand mute/solo.
**Rejected:** hand-scheduling notes on a timer (looser timing, reimplements the tempo map); a single
sampler (can't isolate hands).

### ADR-007 — Cursor/alignment by musical beat, from MIDI ticks
**2026-07-08.** Align XML↔MIDI and drive the cursor in quarter-note **beats** (`tick/ticksPerQuarter`
and MusicXML `notatedBeat`), not `seconds × BPM`.
**Rationale:** tempo-independent; survives the Chopin's 14 tempo changes and swing. OSMD's own
timestamps are notated beats, so cursor navigation matches exactly.
**Rejected:** constant-BPM second→beat conversion (drifts badly under tempo changes — observed).

### ADR-008 — Advance measures by actual filled length, not nominal meter
**2026-07-08.** The MusicXML parser advances by each measure's content length.
**Rationale:** MuseScore leaves pickup/anacrusis measures **unmarked** (`implicit` absent) and the
Chopin changes meter mid-piece; a nominal length drifts.
**Rejected:** trusting `implicit` / nominal `num×4/den` (breaks on the real files).

### ADR-009 — Disable the App Sandbox (for the spike)
**2026-07-08.** `ENABLE_APP_SANDBOX = NO`.
**Rationale:** the sandboxed WKWebView content process failed to run → blank notation. Disabling fixed
it instantly and is fine for a personal, directly-run app.
**Rejected:** keeping the sandbox with entitlements (couldn't quickly find the right set; deferred).
**Consequence:** must be revisited (with correct entitlements) for any sandboxed distribution.

### ADR-010 — macOS system GM sound bank instead of a bundled SoundFont
**2026-07-08.** Load `/System/Library/…/gs_instruments.dls` at runtime for the sampled piano.
**Rationale:** zero app-size cost for the macOS spike.
**Rejected:** bundling an `.sf2` (needed eventually for iPad, which has no system `.dls` — deferred).

### ADR-011 — Speaker mute at the samplers, not an intermediate mixer
**2026-07-08.** PC-speaker output is silenced by setting each sampler's `volume` **and** `overallGain`;
an intermediate `AVAudioMixerNode.outputVolume` does **not** mute.
**Rationale:** verified by offline render — a submix's `outputVolume = 0` still leaked; sampler
`volume = 0` renders silent (`0.00000`).
**Rejected:** the `pianoMix.outputVolume` approach (removed — didn't mute).

### ADR-012 — Follow-scroll via CSS transform, not `window.scrollTo`
**2026-07-08.** Shift the notation up with a CSS `translateY` transform on the container.
**Rationale:** `window.scrollTo` is a no-op in the SwiftUI-clipped WKWebView (not internally
scrollable), so the cursor fell out of view; a transform works regardless.
**Rejected:** `window.scrollIntoView` / `scrollTo` (didn't scroll in the embedded web view).

### ADR-013 — `XMLParser` (SAX), not `XMLDocument`, for MusicXML
**2026-07-08.** **Rationale:** `XMLDocument` is macOS-only; SAX works on iPad too.

### ADR-014 — Matching: Wait mode (step/subset) + Grade mode (windowed greedy)
**2026-07-08.** Wait mode advances when the required note-set for a beat is played (extras ignored).
Grade mode records played notes vs the playback clock and post-hoc matches each expected note to the
nearest same-pitch played note within **±300 ms of musical time**.
**Rationale:** PRD Tier A/B; generous, tunable tolerance that auto-widens in real time at slow tempo.
**Rejected (for now):** academic probabilistic score-following (out of scope); real-time online
alignment for Grade mode (post-hoc is simpler for a first cut). Tolerance is a fixed constant —
tempo-aware tolerance and early/late labelling are open.

### ADR-015 — Persistence deferred; GRDB/SQLite is the intended store
**2026-07-08.** No persistence in the spike; the PRD specifies GRDB/SQLite when built.
**Rationale:** nothing to persist yet (bundled fixtures, no library/history).
**Open:** re-evaluate **GRDB vs SwiftData** before building — SwiftData is more idiomatic for a new
multiplatform app; GRDB was chosen in the PRD for transparent SQL. Not yet decided.

### ADR-016 — Section looping: manual reposition + CC123, not AVMusicTrack loopRange
**2026-07-08.** Section practice loops by watching the playback clock in the cursor tick and calling
`AVAudioSequencer.currentPositionInSeconds = sectionStart` on the boundary, plus an All-Notes-Off
(CC 123) to both samplers to avoid hung notes, and a metronome re-sync (clicks skip past the start
position so we don't fire a burst of past clicks).
**Rationale:** full control over loop bounds, cursor, metronome, and Wait/Grade scoping; the click-skip
is a real fix needed for any mid-piece start, not just loops.
**Rejected:** `AVMusicTrack.isLoopingEnabled` / `loopRange` (less control over sub-range + the cursor
and metronome would still need manual re-sync). Grade mode intentionally does **not** loop (plays the
section once, then grades) to avoid accumulating played notes across passes.

### ADR-017 — Per-pass mistake marks via a DOM overlay, not OSMD re-render
**2026-07-08.** For per-pass grading during a section loop, missed notes are ringed with
absolutely-positioned DOM elements over the notation (`markMissed`), computed from OSMD note
`PositionAndShape.AbsolutePosition × 10 × zoom`. Wait-mode's one-shot review still re-colours
noteheads (`markMistakes`).
**Rationale:** a full OSMD `render()` per loop (every few seconds) causes a visible hitch, especially
on dense scores; an overlay updates in <1 ms and stays aligned through the follow-scroll transform.
**Rejected:** re-colouring noteheads each pass (too slow); one grade only at stop (defeats "see
progress each pass").

### ADR-018 — File-based song library (per-song folders + metadata.json), not a database yet
**2026-07-09.** The library is stored as self-contained folders under
`Application Support/Woodshed/Scores/<uuid>/` (score.musicxml + score.mid + metadata.json). No
database. Supersedes ADR-015's "GRDB is the intended store" for the current stage.
**Rationale:** songs are inherently file-centric (an XML+MIDI pair); a per-song folder is portable and
self-contained (copy/delete = done), resilient (no central index to corrupt/drift), and the library
is just a directory scan. Practice data/favourites extend `metadata.json`. Defers — doesn't preclude —
a DB: introduce GRDB only when cross-song querying (library heatmaps, spaced repetition) demands it.
**Rejected:** a master index file (central drift/corruption, less portable); GRDB/SQLite now (upfront
work + dependency not yet justified at personal-library scale). **Note:** ADR-015 remains open only
for the *future* analytics store.

### ADR-019 — Extract a `PracticeSession` view-model from the practice-view monolith
**2026-07-09.** The ~630-line practice view held all state + all playback/matching logic. Split it:
`PracticeSession` (`ObservableObject`, imports only Foundation/Combine) owns the three services, the
`FusedScore`, and every practice-mode state/logic method; `PracticeView` is a thin SwiftUI layer that
creates the session as a `@StateObject` and binds controls to it. The session **owns** its services
and re-broadcasts their `objectWillChange` so the view observes only the session. Control side-effects
that were `.onChange` modifiers became `@Published … { didSet }` on the session.
**Rationale:** done deliberately *before* the Mac/iPad redesign so the redesign only touches
presentation, and to give the matching/playback logic a UI-decoupled home (PRD §9). Lightweight MVVM,
not TCA/DI — proportionate to a single-user app.
**Rejected:** keeping services as `@StateObject` in the view and injecting them into the session
(awkward post-init wiring, implicitly-unwrapped refs); a full DI container (overkill). **Open:** lift
the *pure* matcher (no engine refs) into a standalone unit-tested `struct`; adopt `@MainActor`/Swift 6
concurrency later.

### ADR-020 — Practice-screen redesign: split view, notation-hero, adaptive control bar
**2026-07-09.** Reworked the app shell and practice screen for Mac **and** iPad from one layout:
`NavigationStack` → **`NavigationSplitView`** (library sidebar + practice detail); the practice screen
went from a scrolling stack of dense control strips to **notation at `maxHeight: .infinity`** (the
hero) + a thin header (a single `Practice · Wait · Grade` **segmented** mode control replacing the two
scattered mode toggles, plus transport) + a **`FlowLayout`** control bar that wraps instead of
overflowing + an always-visible keyboard (shorter on iPad). The Phase-0 diagnostic dump moved behind
the More menu → "Show diagnostics…" (a sheet).
**Rationale:** the fixed 360 pt notation + four dense single-row strips didn't fit or tap well on
iPad; a wrapping `FlowLayout` reflows the same controls across widths with no size-class branching
(honours the "every action reachable without swipe or hover" rule). Structural pass only — hand
colours (blue/red) unchanged and a full visual design system (tokens, colour-blind-safe scheme, Dark
Mode) is still owed.
**Rejected:** top-toolbar-plus-bottom-bar split (splits controls into two places); hiding the keyboard
by default on iPad (loses always-on live MIDI feedback); a size-class-switched layout (two code paths
vs one wrapping layout). **Verified:** builds for both the macOS and iOS SDKs; runtime tested on Mac
(boots, no crash) — not yet on iPad hardware.

### ADR-021 — Practice history as per-song append-only JSON-lines, not a database
**2026-07-10.** Persist each finished Grade pass as one JSON object appended to `history.jsonl` in the
song's own folder (`PracticePass` in `PracticeHistory.swift`). Denormalise two derived stats
(`lastPracticed`, `bestAccuracy`) into `metadata.json` so the library list needn't read every history
file. The Progress view reads `history.jsonl` on demand for trends + trouble spots. Extends ADR-018's
file-based library to practice data.
**Rationale:** practice records are per-song, append-only, and small — a JSON-lines file per song is
the natural fit: a bad line is skipped (resilient), the record travels with the song folder
(portable), and appends are O(1) with no schema/migration. Keeps the zero-dependency stance; a DB
buys nothing until **cross-song** querying exists.
**Rejected:** GRDB/SQLite now (ADR-015 — upfront work + dependency not justified at single-song
granularity); one growing `sessions.json` array per song (rewrites the whole file every pass; a
partial write corrupts all history); stuffing history into `metadata.json` (unbounded growth in the
file the library scans). **Open:** revisit a DB when library-wide analytics / spaced repetition across
pieces arrive; add Wait-mode records if useful.

### ADR-022 — Trouble spots are "clear as you improve", shown on the score
**2026-07-10.** A bar is a *current* trouble spot only while the **most recent pass that covered it**
still missed notes there (`PracticeHistory.currentTroubleBars`, weighted by misses in a small recent
window). Play it clean and it drops off. Current trouble bars are tinted **amber** directly on the
notation (a JS overlay below the blue section selection, toggle `showTroubleOnScore`) and listed in
the Progress sheet (tap to drill). A separate all-time `troubleBars` is kept for reference.
**Rationale:** "what do I still need to look at" must reflect present weakness, not a cumulative
tally that never clears; showing it on the score (not just a list) puts the guidance where you read.
Recency-by-covering-pass handles both full runs and section drills correctly (a clean section drill
clears its bars; bars it didn't cover stay).
**Rejected:** all-time cumulative misses as the headline (never clears — misleading after you've
fixed a spot); a time-decay weighting (fiddlier and less legible than "clean last time = cleared").
**Open:** manual revisit flags/notes are a separate, complementary feature (next).

### ADR-023 — Follow-scroll via a real scroll container (supersedes ADR-012's transform)
**2026-07-10.** The notation now lives in a `#scrollHost` `overflow-y:auto` viewport; follow-scroll
animates `scrollHost.scrollTop` (a hand-rolled timer tween — `scrollTo({behavior:"smooth"})` no-ops
in this WebView). Supersedes ADR-012 (translateY transform on the container).
**Rationale:** the transform pushed already-played bars off the top with **no way to scroll back** to
review them. An element-level overflow scroller scrolls both programmatically (element `scrollTop`,
unlike the document-level `window.scrollTo` that ADR-012 correctly found no-ops) **and** by hand
(wheel/trackpad/touch). Verified in a browser: container scrolls, follow keeps the cursor visible with
the right headroom, and manual scroll-back works.
**Rejected:** keeping the transform (can't review past bars); `scrollTo({behavior:"smooth"})` (no-ops
here); a rAF tween (requestAnimationFrame is throttled when the page/tab is backgrounded — a timer
tween runs regardless). ADR-012's finding about `window.scrollTo` stands; the fix was an inner
overflow element, not the document.

### ADR-024 — Per-loop count-in: freeze the clock and click a meter-aware pickup
**2026-07-10.** When looping a section, an optional count-in of N beats plays before each pass:
`AudioEnginePlayer.loopBackToStart(countInPulses:)` repositions to the section start, sets
`isRunning = false` (so the cursor/grader idle), `stop()`s the sequencer, clicks the **last N pulses
of the bar** (a pickup into the downbeat) on the metronome timer, then restarts the sequencer.
**Order matters:** stop the sequencer *before* repositioning it — jumping the position while it's
still playing fires the first bar's note-ons, which then get cut off (an audible blip in the count-in
silence). Stop → reposition → all-notes-off → count in. **And trigger the loop just *before* the
barline** (`sectionEndTime − 0.03` vs the usual `+ 0.05`) for count-in loops, so the *next* bar's
notes never start — the loop tick runs at 20 Hz, so the old "+50 ms past the end" overshoot let the
bar past the section sound briefly before the jump; the count-in silence hides the ~30 ms early cut of
the section's last note tail. (Non-count-in seamless loops keep the small `+` buffer.) N is
chosen in beats (metronome pulses), capped at the section's `metronomeBarPattern.count` so the max is
a full bar for that meter.
**Rationale:** looping to drill a passage needs a moment to reposition your hands each pass; a pickup
count (not a full-bar-from-the-downbeat) matches how players count in a partial lead. Reusing the
metronome pulse/pattern keeps it tempo- and meter-correct for free; freezing `isRunning` cleanly
suspends follow-cursor + grading during the count (grade input is already gated on `isRunning`).
**Rejected:** a fixed silent gap (no audible count to reposition to); counting always from the
downbeat (wrong for < 1 bar); scheduling the count on the sequencer itself (the sequencer plays the
score, not click-only bars). **Open:** per-section meter is approximated by the global bar pattern —
revisit if a mid-piece meter change lands inside a looped section.

### ADR-025 — Metronome resync anchors to the intended start, and stops at the loop end
**2026-07-10.** Two fixes so a looped section (esp. with a count-in) feels seamless: (1) `startSynced`
takes a `referenceTime` and every section (re)start passes `startSeconds` instead of reading
`currentTime` — `seq.start()` latency nudged `currentTime` past the section's downbeat, so the old
`time >= currentTime - 0.02` skip dropped the downbeat and the metronome resumed on beat 2 (the
"upbeat"). (2) A `clickCeiling` (= section end) suppresses the synced click for the downbeat of the
bar *past* the section, which used to sound in the ~0.05 s before the loop reset.
**Rationale:** the downbeat must land on the first beat of the loop; anchoring to the known restart
position removes the latency race, and the ceiling stops an out-of-loop click. Both are general (they
also tighten non-count-in section loops and the initial section Play), not count-in-specific.
**Rejected:** widening the skip tolerance (guesses at latency; could drop legit near clicks); firing
the downbeat from the count-in timer and skipping it in `startSynced` (tighter, but risks a double
downbeat — revisit only if residual `seq.start()` latency is audible).

### ADR-026 — Manual revisit flags: one note per bar, own file, tappable on the score
**2026-07-10.** A user can pin a short note to a bar (`BarFlag`, `BarFlagStore`), stored per song in
`flags.json` — a small array rewritten on change (not append-only like history). One flag per bar
(re-flagging edits it). Flagged bars show a tappable purple ⚑ overlay on the score (`setFlaggedBars`
→ `flag:<bar>` post → inline editor); a Flags sheet lists/adds/edits/deletes and drills to a bar.
**Rationale:** "areas I still need to look at" is partly *judgement*, not just missed-note stats, so a
manual complement to the auto trouble spots. A rewritten JSON array fits a small mutable set;
one-per-bar keeps the model and the on-score marker simple. Tappable markers put editing where you
read, and the sheet keeps every action reachable without the score gesture (Mac + iPad).
**Rejected:** flags in `metadata.json` (unbounded growth in the file the library scans); multiple
notes per bar (marker clutter + fiddlier editing — revisit if wanted); a distinct score gesture to
*create* a flag on an unflagged bar (would collide with drag-select; adding is via the sheet instead).

### ADR-027 — Keep MIDI input off the whole-screen re-render (keyboard perf)
**2026-07-11.** `PracticeSession` re-broadcasts only `audio` + `bridge` `objectWillChange`, not
`midi`. The on-screen keyboard is its own subview observing `MIDIInput` directly; live input reaches
the matcher via a `midi.$activeNotes` Combine subscription in the session (not a view `.onChange`).
**Rationale:** forwarding `midi` made the entire practice screen (notation `WKWebView` + control bar)
re-render on every note-on/off; fast passages saturated the main thread and the keyboard visibly
skipped notes. Scoping the repaint to the keyboard fixes it. Grade-mode note handling touches only
private tallies, so it doesn't re-render the screen either. **Same treatment for the score-note
highlight** (`scoreLitRH/LH`): moved off the session into a separate `KeyboardLights` object, because
it changes ~50 Hz during playback and was re-rendering the whole screen (trills/fast runs lagged, and
the churn was a likely source of a stop-time crash).
**Rejected:** throttling `activeNotes` (adds latency to feedback); moving the keyboard to a Canvas
(bigger rewrite, not needed once the re-render was scoped).

### ADR-028 — Sync start + metronome-follows-playback options
**2026-07-11.** Three opt-in playback behaviours (in the More menu's Start/Metronome sections): "Start
on my first note" (Play *arms*; the first MIDI note begins playback in sync, no count-in — your note
is the downbeat), "Metronome start with playback", and "Metronome stop when playback stops"
(`AudioEnginePlayer.metronomeFreeRuns = false` → the click sounds only while playing, no free-run).
**Rationale:** supports a play-along workflow — arm, start playing, and the backing + click come in
with you and stop when you stop. Kept as independent toggles (as requested) that compose into that
flow; grouped logically rather than scattered.
**Rejected:** a single "play-along mode" switch (less flexible; the pieces are individually useful);
counting the arming note *into* a count-in (a sync start is meant to be immediate).

### ADR-029 — Unify speed trainer + mastery gating as one auto-tempo drill
**2026-07-11.** The "speed trainer" and "mastery gating" roadmap items are the *same* mechanism, so
they're one feature: an auto-tempo drill on a Grade+Loop section. After each pass the tempo ramps
toward a target; mode **by reps** advances every N passes, **by accuracy** only after N passes ≥ a
threshold (the mastery gate). Reaching the target with clean passes marks it mastered and stops. The
decision is a pure `drillAdvance` function (unit-tested); the session just applies its result.
**Rationale:** "advance the tempo only when I've played accurately" (mastery gating) and "auto-by-
accuracy tempo ramp" (speed trainer) describe one loop — splitting them would duplicate state and UI.
A pure transition keeps the gating logic testable (PRD §9). Turning it on auto-enables Grade+Loop so
it "just works."
**Rejected:** separate speed-trainer and mastery-gating controls (redundant); advancing/mastering per
*section* automatically (kept to tempo for the first cut — section/hands progression is the next
step). **Open:** hands-separate → hands-together gating; whether mastery should also auto-advance to
the next section.

### ADR-030 — Wave 0 hardening: never crash on input, never lose a song, never warn silently
**2026-07-11.** From the audit roadmap (docs/audit/04-roadmap.md), the first remediation wave:
(1) `MIDIParser`'s byte reader is fully bounds-checked and throwing — corrupt/truncated files are a
catchable import error, never an index-out-of-range crash (fuzz-tested: 900+ adversarial inputs).
(2) `metadata.json`/`flags.json` writes are **atomic**; a song folder whose metadata is
missing/corrupt is **recovered** (rebuilt metadata, stable id from the folder name) instead of
silently vanishing from the library; unrecoverable folders are surfaced with a count.
(3) Ingest quality is never silent: `FusedScore.structureWarning` flags an unfolded-repeats
timeline mismatch (`Ingest.timelinesMismatch`, pure + tested), and any unclean reconciliation
produces a persistent **banner** on the practice screen (Details → diagnostics) and an alert at
import; an unparseable pair is rejected and removed at import.
(4) Speed trainer clamps the tempo to the target when enabled (no instant unearned "mastered");
a mid-loop section change updates the loop *start* as well as the end.
(5) The `WoodshedTests` target is real: 15 tests — parser fuzzing, golden reconciliation for both
fixtures, the repeats guard, drill transitions, trouble-bar decay, metadata back-compat.
**Rationale:** these are the "app lies or dies" edges — all cheap, all prerequisite to trusting the
tool with real repertoire. **Rejected:** implementing repeat *unfolding* now (Wave 4 — needs the
test bed first); a full import wizard (Wave 2).

### ADR-031 — Wave 1: indexed tick loop + Canvas keyboard (the trill-lag fix), lifecycle hygiene
**2026-07-11.** Second remediation wave (docs/audit/04-roadmap.md):
(1) **`TickTracker`** replaces the 50 Hz tick's four O(n) full-array scans (discrete/continuous
beat, sounding-note sets, grade window) with sorted-schedule indices that advance monotonically —
amortized O(1) per tick, auto-reset on a backwards jump (loop/seek). Cursor seeks skip when the
beat hasn't moved. Pure struct, unit-tested for **equivalence against a brute-force scan** at every
timestep plus loop-restart and interpolation cases.
(2) **`PianoKeyboardView` is a `Canvas`** — one immediate-mode draw pass with statically
precomputed key geometry, replacing ~140 per-key SwiftUI views re-diffed on every highlight change.
(1)+(2) target the "keyboard can't keep up with trills" complaint (audit ARCH-01/-02).
(3) Lifecycle: `MIDIInput` disposes its CoreMIDI client in `deinit` (a client leaked per song
switch); `AudioEnginePlayer` stops its engine/sequencer/timer in `deinit`; `PracticeSession.onAppear`
is idempotent (re-appearance no longer re-parses the score and resets practice state).
**Rejected:** promoting MIDI/audio engines to app-level singletons (a bigger lifecycle redesign —
deferred; the deinit fixes remove the leak); moving the tick off the main thread (the work is now
trivial; the complexity isn't warranted).

### ADR-032 — Wave 2: pure GradeMatcher + signed timing, parser worklist, guided .mxl import
**2026-07-11.** Third remediation wave (docs/audit/04-roadmap.md):
(1) **`GradeMatcher`** — the Grade-mode engine extracted as a pure struct (PRD §9): expected notes +
note-ons + clock in, hits/misses/wrongs out, with **signed** timing errors. The pass summary now says
"rushing ~30ms" / "dragging ~30ms" / "on time" (the actionable half of timing feedback), tolerance is
**tunable** (Strict ±150 / Normal ±300 / Relaxed ±450 ms, musical time), `signedMs` is persisted per
pass (Optional — back-compat), and stopping early shows "Pass abandoned" instead of vanishing.
(2) **Wait fumbles are honest**: one fumble per step regardless of chord size (review marks still
show the attempted chord).
(3) **Parser worklist**: overlapping same-pitch MIDI notes survive (per-key LIFO stack, not a flat
map); multi-part MusicXML is refused with a clear message (the linear measure cursor would produce
garbage beats for part 2); `<grace>` notes are parsed as such (zero duration, don't advance the
cursor) and match **after** principals so they can't steal a principal's MIDI partner; the count-in
pattern/pulse is now derived from the **section's** bar meter + tempo-map position, not the piece's
first bar.
(4) **Guided import**: two sequential pickers (score, then MIDI) replace the undiscoverable
multi-select; **`.mxl` is accepted** — extracted by a minimal, dependency-free, bounds-checked ZIP
reader (`MXLArchive`, Compression framework for raw DEFLATE; hermetically unit-tested against a
hand-built archive).
**Rejected:** a third-party ZIP dependency (zero-dependency stance; the needed subset is ~150
lines); wall-clock grading tolerance (musical time matches the clock everything else uses).

### ADR-033 — Wave 3: inspector IA, iPad enablement, colour-blind-safe hands, paper-white score
**2026-07-11.** Fourth remediation wave (docs/audit/04-roadmap.md):
(1) **Practice screen = canvas + inspector.** The wrapping control bar and overloaded ⋯ menu are
replaced by a native `.inspector` with three tabs — **Controls** (Playback/Focus/Start/Grading/View
groups in a Form), **Progress**, and **Flags** (both promoted from buried sheets to first-class
tabs). The canvas keeps only live surfaces: mode + Play, status, banner, score, collapsible keyboard.
The ⋯ menu retains only cursor utilities + diagnostics. `.inspector` adapts natively on iPad.
(2) **iPad enablement:** GeneralUser GS (~32 MB, redistribution-permitted) bundled and loaded on
iOS (macOS keeps the system DLS — same sound as always); `AVAudioSession` (.playback) configured on
iOS; **touch drag-select** added to the web layer (horizontal drag selects, vertical swipe still
scrolls — verified in-browser with synthesized touch events).
(3) **Colour-blind-safe hands:** LH red `#C62828` → orange `#E65100` across notation + keyboard —
blue/orange is the standard safe pair; the old blue/red failed exactly red-green deficiency, and
hand identity is load-bearing. Wrong/missed stays red (appears on *pressed* keys / review marks,
a different context from LH score notes).
(4) **The score stays paper-white in both colour schemes — deliberately** (as in every major
notation app); the chrome adapts via stock system colours. A true dark score theme (recolouring
OSMD output) is deferred until paper-in-dark-mode annoys in practice.
(5) Web-process crash recovery: on content-process termination the page reloads and the score,
layout, hand colours, selection, and overlays are re-applied automatically.
**Rejected:** keeping Progress/Flags as sheets (the tutor features deserve first-class placement);
a scrollable/zoomable iPad keyboard (narrow keys are acceptable for feedback display — revisit if
touch *playing* on iPad matters); shipping a dark score theme now (visual risk for unproven need).

### ADR-034 — Wave 4 depth: hands progression, repeat unfolding, sections, rhythm, overview
**2026-07-11.** The audit roadmap's final wave, in dependency order:
(1) **Hands progression** (ADR-029 follow-on): the speed trainer optionally runs three stages —
R.H. → L.H. → both hands — each through the full tempo ramp with the mastery gate; only the final
stage's mastery stops the drill. Completes PRD user story 7.
(2) **Repeats/voltas unfolded** (see the commit + INGESTION.md): per-measure `RepeatMarks`, a pure
`unfoldOrder`, dual note positions (unfolded for alignment, written for display). D.C./D.S. remain
guarded by the structure warning. Resolves audit MUSIC-01.
(3) **Saved sections**: named bar ranges per song (`sections.json`, same pattern as flags), one-tap
recall in the Focus group. **A/B markers were dropped as redundant** — drag-select + steppers +
saved sections cover the same job with less UI.
(4) **Library**: search (titles + tags), sort (title / last practised / best), freeform tags
(`SongMeta.tags`, Optional for back-compat), edited via a comma-separated alert.
(5) **Rhythm tools v1**: "Rhythm only" mode silences the piano and ticks every note onset (distinct
tone, unfolded-timeline grid, per-hand mutes respected), and Grade becomes a **tap-along** — the
matcher goes pitch-agnostic over onset-collapsed chords, so timing alone is scored. Subdivision
grid + count display deferred until wanted in practice.
(6) **Cross-song practice overview**: totals + a stalest-first "most due" list, computed by
scanning every song's `history.jsonl` on open. **Deliberately no database** — tens of songs scan
instantly; reaffirms ADR-018/021 (GRDB only if this ever feels slow).
**Also deliberately skipped:** the sample-accurate metronome scheduler (ARCH-09 — no audible-jitter
report to justify it) and a Swift 6 flag-day (still incremental-when-touched).

## Open Questions
- Revisit ADR-009 (sandbox) before distribution (ADR-010's iPad half is resolved by the bundled
  SoundFont).
- ADR-018 defers the DB; revisit when session history / cross-song analytics are built.
- Section loop has no silent reset gap and repositioning may briefly clip a sounding note; evaluate if
  it needs smoothing (ADR-016).
