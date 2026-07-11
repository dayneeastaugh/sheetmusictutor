# Findings register

Format: **ID · Severity · Effort · Confidence**. Evidence is `File:lines` in the current tree.
Severity honesty note: nothing here is `Critical` in the "data destroyed / crashes constantly"
sense — the two worst items are a crash-on-bad-input and a silently-wrong music model, rated High
because they gate the PRD's make-or-break assumption rather than daily use of the current fixtures.

---

## Music-domain correctness

### MUSIC-01 · High · L · High — Repeats/voltas/D.C. break the model silently
**Evidence:** MusicXMLParser.swift:88-102 (linear measure cursor, no repeat handling — no
`<repeat>`/`<ending>`/barline parsing anywhere); Ingest.swift:70-97 (alignment by beat proximity);
Ingest.swift:126 (unmatched MIDI emitted with `notatedBeat: m.onsetBeats` — an *unfolded* beat that
can exceed the notated score length); docs/INGESTION.md (documents MIDI as "unfolded" but never
names repeats as unsupported).
**Rationale:** The XML beat timeline is written/folded; MIDI beats are performance/unfolded. For any
piece with a repeat, every MIDI note after the first repeat sits ≥ one full section away from its
XML partner → fails the 1.0-beat window → floods `unmatchedMIDI`. Those notes still become events
with out-of-range `notatedBeat`s, so the cursor, grading, wait steps, and trouble bars are all
wrong *past the first repeat* — while playback sounds perfect. This is the "teaches wrong practice"
failure class, on the exact input the PRD calls make-or-break (your own transcriptions). The
reconciliation report would scream — but it's hidden (UX-01).
**Recommendation:** Short-term (Wave 0): detect the condition — XML total beats vs MIDI last-note
beat differing by more than a bar — and show a prominent "this piece has repeats/structure Woodshed
can't align yet" warning at import/open. Document it in INGESTION.md. Long-term (Wave 4): parse
`<repeat>`/`<ending>` barlines and unfold the XML timeline to match the MIDI.

### MUSIC-02 · High · M · High — Corrupt/truncated MIDI crashes the app
**Evidence:** MIDIParser.swift:224-247 (`ByteReader.peekUInt8`/`readUInt8`/`readUInt16`/`readUInt32`
/`readBytes` all index `bytes[offset…]` with no bounds checks); 250-258 (`readVarLen` loops on
unchecked reads); 60-118 (parse loop trusts `trackLen`, `len` payload sizes from the file).
**Rationale:** Any truncated download, wrong-file-renamed-.mid, or non-MuseScore export with an
unexpected structure indexes past the array → `Fatal error: Index out of range` → hard crash *at
import or song-open*. Swift arrays trap on out-of-bounds (this is a deliberate safety feature — it
becomes a reliable crash, not a heisenbug, but it's still a crash the user hits). File robustness
is an explicit PRD §2.8 requirement ("degrade gracefully, not crash").
**Recommendation:** Give `ByteReader` throwing reads (`guard offset + n <= bytes.count else throw
MIDIError.malformed`) and propagate. One fixture test with a truncated file locks it in. Same
review for `readString`/`skip` arithmetic.

### MUSIC-03 · Medium · S · High — Overlapping same-pitch notes drop the first note
**Evidence:** MIDIParser.swift:100-107 — `openNotes[key] = absoluteTick` overwrites an already-open
note-on for the same channel+pitch; the eventual note-off closes only the second.
**Rationale:** Legitimate piano MIDI contains overlapping same-pitch notes (pedalled repeated
notes, voice overlaps, MuseScore tie exports). Each occurrence silently deletes one note from the
model → one phantom "unmatched XML" in reconciliation and one un-gradeable note.
**Recommendation:** Make `openNotes` store a stack (`[Int: [Int]]`), close LIFO. Small, contained.

### MUSIC-04 · Medium · M · High — Multi-part MusicXML produces garbage silently
**Evidence:** MusicXMLParser.swift:84-129 — no handling of `<part>`/`<score-part>`; the measure
cursor (`measureStartBeats += …`, :93-98) keeps accumulating across a second `<part>`'s measures,
so part 2's notes land at beats after the *sum* of part 1's length.
**Rationale:** Fine for MuseScore solo-piano exports (one part, two staves). But import anything
with a second part (voice + piano, a duet) and every beat in part 2 is wrong — no error raised.
**Recommendation:** Count `<part>` elements; if > 1, either parse only the first with a visible
notice, or refuse with a clear message. Full multi-part support is out of scope per PRD.

### MUSIC-05 · Medium · S · High — Grace notes can steal the principal note's match
**Evidence:** MusicXMLParser: no `<grace>` handling (grace notes have no `<duration>` →
`noteDurationDivs` stays 0, note lands at the cursor with zero length, :192-221); Ingest.swift:70-97
(greedy nearest-same-pitch within 1.0 beat — a zero-duration grace at the same beat as its
principal competes for the same MIDI note; whichever XML note is processed first wins).
**Rationale:** Chopin-style writing is full of grace notes; a stolen match makes a correctly-played
principal note un-creditable in Grade mode (its event carries the grace's identity, or the
principal ends up "unmatched"). Currently masked because the ornament-absorption pass mops up some
leftovers. INGESTION.md already lists grace timing as an open question — this sharpens it.
**Recommendation:** Parse `<grace>`, mark the XMLNote, exclude grace notes from primary alignment
(absorb them like ornament realizations instead).

### MUSIC-06 · Medium · S · High — Grade tolerance is fixed and not tempo-aware; no early/late signal
**Evidence:** PracticeSession.swift:196 (`gradeTolerance = 0.30` *musical* seconds, constant);
378-392 (`abs()` match — direction discarded); 413 (`avgMs` is mean |error| — unsigned).
**Rationale:** Because the clock is musical time, ±0.30 s at 50% tempo is ±0.6 s wall-clock
(extremely generous) and ±0.25 s at 120% — the *opposite* gradient to the PRD's "tighter at speed,
wider when slow" goal is at least directionally present, but it's incidental, untunable, and the
player can never learn whether they rush or drag (the single most actionable timing feedback).
**Recommendation:** Expose tolerance as a setting; record signed error; surface "you rush/drag by
~Nms" in the pass summary. Small change, big feedback value.

### MUSIC-07 · Low · M · Medium — Wait-mode "fumbles" record the wrong thing and overcount
**Evidence:** PracticeSession.swift:508-514 — a wrong note inserts the step's *required* pitches
into `mistakes` (not the wrong pitch you played); `mistakeCount = mistakes.count` counts required
notes, so one slip on a 4-note chord = "Fumbles: 4"; review marks colour the whole chord red.
**Rationale:** Defensible as "mark where you fumbled", but the count inflates errors — mildly
punitive vs the PRD's generous-feedback principle, and the red chord doesn't tell you *what* you
did. (Rated Low for correctness because it's a presentation semantics choice; see UX-04.)
**Recommendation:** Count fumble *events* (one per step), and record the played-wrong pitch too.

### MUSIC-08 · Low · S · High — Unison doubling / cross-voice ties mismatch by design
**Evidence:** Ingest.swift:167-198 — `mergeTies` keys open ties by pitch only (cross-voice
collision); two-voice unison (same pitch, same beat) = two XML sounding notes racing for one MIDI
note (MuseScore typically emits one note-on for a unison).
**Rationale:** Produces one spurious "XML w/o MIDI" per occurrence — noise in reconciliation, not
practice-affecting. Divisi is already a named open question in INGESTION.md.
**Recommendation:** Note in docs; dedupe identical (pitch, onset) sounding notes before alignment.

### MUSIC-09 · Low · S · High — Count-in meter comes from the first full bar only
**Evidence:** Ingest.swift:141-145 (`firstFull` bar pattern + pulse seconds fixed for the piece);
AudioEnginePlayer.swift:154-218 (all count-ins use that single pattern).
**Rationale:** Looping a 4/4 section of a piece that *starts* in 12/8 counts you in with the wrong
pattern; pulse spacing also ignores tempo-map position (uses first tempo). Edge case for the
current repertoire; real for the Chopin fixture's meter changes.
**Recommendation:** Derive the count-in pattern from the section's bar (`measures[sectionStart-1]`),
and its pulse length from `secondsAtBeat` at that spot.

---

## Architecture / performance

### ARCH-01 · High · M · High — The 50 Hz tick does repeated O(n) scans on the main thread
**Evidence:** PracticeSession.swift:767-771 (`discreteBeat`: full-schedule linear scan per tick);
775-786 (`continuousBeat`: linear scan from index 0 per tick); 729-749 (keyboard highlight: full
`events` filter — twice the work in Grade mode); 752-763 (MIDI-out echo: another full filter);
716 (`bridge.seek` = one `evaluateJavaScript` IPC per tick). Driven from a view timer
(PracticeView.swift:39, 63).
**Rationale:** For an n-note piece this is ~4·n element visits × 50/sec on the main thread, plus a
WebKit IPC — *concurrent with* SwiftUI diffing and MIDI input handling. This is the most probable
cause of the outstanding "keyboard doesn't refresh fast enough on trills/turns" complaint (the
publish-path fixes already landed were necessary but not sufficient), and it scales with score
size.
**Recommendation:** Keep sorted arrays + a monotonic index that only advances with `t` (reset on
seek/loop); precompute per-event sounding intervals into an index; only call `bridge.seek` when the
interpolated beat moves ≥ some epsilon. This is a contained rewrite of one function + two helpers.

### ARCH-02 · High · M · High — The on-screen keyboard is ~140 diffed views with O(n²) lookups
**Evidence:** PianoKeyboardView.swift:55-104 — 52 white `Rectangle`+`overlay` views + 36 black keys
via `ForEach`, each body evaluation recomputing `whiteNotes`/`blackNotes` (88-element filters,
:34-35) and `whiteNotes.firstIndex(of:)` per black key (:72, :110 — 36 × O(52)); `.frame(height: 90)`
hardcoded (:101) fighting the caller's 74/88 pt frames (PracticeView.swift:32-36, 429).
**Rationale:** Every highlight change re-diffs the whole key forest; at trill rates stacked on
ARCH-01's tick load, frames drop — the user-visible symptom. A `Canvas` draws the same keyboard in
one pass with no per-key identity, and is the standard SwiftUI idiom once you exceed a few dozen
dynamic shapes.
**Recommendation:** Rewrite `PianoKeyboardView` as a `Canvas` (draw whites, then blacks, colour by
set membership; hit-test in the gesture as now). Precompute key geometry once per size. Remove the
inner hardcoded height.

### ARCH-03 · Medium · L · High — `PracticeSession` is the new monolith
**Evidence:** PracticeSession.swift (830 lines; mode FSM :315-339, grade matcher :341-435, wait
matcher :437-525, section math :541-598, tick driver :679-786, MIDI echo :751-763, drill :83-141,
flags :280-301, history :303-313, ingest :788-829). Every feature of the past week modified this
file.
**Rationale:** Not urgent — it works and is honestly commented — but it is the highest-traffic
file, the interaction-bug surface (loop × count-in × drill × grade regressions all lived here), and
the reason the matcher still can't be tested without engines. PRD §9 explicitly wants the matcher
standalone.
**Recommendation:** Extract in dependency order: (1) `GradeMatcher` struct (expected + note-ons +
clock → tallies) — pure, test it; (2) `WaitEngine`; (3) a `SectionModel` (bars↔beats↔seconds).
Leave orchestration in the session.

### ARCH-04 · Medium · S · High — CoreMIDI client/ports leak per song switch
**Evidence:** MIDIInput.swift:27-52 (client + ports created in `setup()`, no `deinit`, no
`MIDIClientDispose`); PracticeSession.swift:36 (each session owns a new `MIDIInput`);
ContentView.swift:27-29 (`.id(song.id)` → fresh session per song).
**Rationale:** Every song switch abandons a live CoreMIDI client with connected sources. Old sinks
are defused (weak self), but the OS-side objects accumulate for the process lifetime; CoreMIDI also
recommends one client per app. Same pattern: each session builds a full `AVAudioEngine` (running
from `init`, AudioEnginePlayer.swift:69-88) — ARC tears it down, but engines/MIDI are app-lifetime
resources being churned per navigation.
**Recommendation:** Add `deinit { MIDIClientDispose(client) }` as the immediate fix; structurally,
promote `MIDIInput` (and plausibly `AudioEnginePlayer`) to app-level singletons injected into
sessions.

### ARCH-05 · Medium · S · High — Changing the section during a loop desyncs start vs end
**Evidence:** `audio.startSeconds` is set only in `startPlayback` (PracticeSession.swift:665);
`onSectionChanged` during playback updates `clickCeiling` (:567) but not `startSeconds`; the loop
reset uses the stale `startSeconds` (AudioEnginePlayer.swift:358, 363) while the tick's end check
uses the new `sectionEndTime` (:696).
**Rationale:** Drag-select a new section while looping → playback loops back to the *old* start
with the *new* end: a confusing hybrid loop until you press Stop/Play.
**Recommendation:** In `onSectionChanged`, if `audio.isPlaying` also update `audio.startSeconds =
sectionStartTime` (and re-seek or let the next boundary pick it up).

### ARCH-06 · Medium · S · High — No `AVAudioSession` configuration for iOS
**Evidence:** No `AVAudioSession` reference anywhere in the codebase (verified by search);
AudioEnginePlayer.swift:69-88 starts the engine with macOS assumptions; :244-257 loads a
macOS-only DLS path (iPad silence already tracked in TECH_STACK).
**Rationale:** On iPadOS an un-configured audio session means default category behaviour
(silent-switch muting, no interruption/route-change handling) — the iPad build will misbehave in
ways that look like mystery bugs the first time it's run on hardware.
**Recommendation:** Alongside the bundled-SoundFont work: set `.playback` category, activate on
play, handle interruption notifications. ~30 lines, iOS-gated.

### ARCH-07 · Medium · S · High — `onAppear` re-runs full ingest and resets practice state
**Evidence:** PracticeView.swift:57-62 → PracticeSession.onAppear (:266-278) → `ingest()` (:790-821)
unconditionally re-parses both files, resets `sectionStart/End` (:808-809), wipes grade history
(:811), reloads audio.
**Rationale:** `onAppear` is not a once-per-lifetime event in SwiftUI — it fires again when the view
returns to the hierarchy (sidebar show/hide, window restore, future tab/inspector changes). Today
users mostly won't notice; the first UI restructure will surface "my section/score reset itself"
bugs.
**Recommendation:** Guard with a `hasLoaded` flag (idempotent `onAppear`), or move load into
`init`/`task`.

### ARCH-08 · Low · S · High — Web-process crash leaves notation dead
**Evidence:** NotationWebView.swift:223-225 posts "web content process TERMINATED" and stops.
**Rationale:** WKWebView content processes do get killed (memory pressure, GPU resets). Recovery is
cheap: reload the inline HTML and re-send the score/state; without it the pane is blank until the
user switches songs.
**Recommendation:** In the terminate callback: `loadHTMLString` again + re-apply score, colours,
overlays (the session already has `applyPersistedLayoutToNotation`-style re-push logic to reuse).

### ARCH-09 · Low · S · High — Metronome is polled, not scheduled
**Evidence:** AudioEnginePlayer.swift:137-151 (4 ms poll of the sequencer clock, then
`scheduleBuffer(at: nil)` :238); `nextClick` shared main/metroQueue without sync (:132-136 vs :143-147).
**Rationale:** Click jitter is bounded by timer + render enqueue latency (audibly fine in practice,
but a real gap vs the PRD's sample-accurate target); the race is benign today and illegal under
Swift 6.
**Recommendation:** Defer until it audibly matters; when done, schedule clicks ahead on the render
clock (`AVAudioTime`-stamped `scheduleBuffer`) with a look-ahead window; confine `nextClick` to
`metroQueue`.

### ARCH-10 · Low · S · Medium — Private-key KVC on WKWebView
**Evidence:** NotationWebView.swift:137 — `web.setValue(false, forKey: "drawsBackground")`.
**Rationale:** Undocumented key (long-standing community workaround). Fine for a personal,
sandbox-off app; would need review for App Store distribution. Could throw `NSUnknownKeyException`
on a future macOS — wrap defensively if it ever matters.

---

## Product & feature design

### PROD-01 · High · M · High — The make-or-break assumption is untested with real repertoire
**Evidence:** Bundled fixtures only (Woodshed/Scores/: two pieces, TECH_STACK.md:50-59); PRD §7
success criterion #1 ("faithful across the user's *own* MuseScore exports"); no other scores have
ever been ingested (no fixtures, no tests, library seeds the same two).
**Rationale:** Everything above (MUSIC-01…05) is a *latent* risk exactly until a real piece from
the user's repertoire is imported. The cheapest de-risking available: import 5–10 of your actual
transcriptions and read the reconciliation report for each.
**Recommendation:** Do this by hand this week; then freeze the good ones as golden test fixtures
(QUAL-01). Pieces that fail become the prioritised parser worklist.

### PROD-02 · Info · — · High — Scope discipline is good; say so
**Evidence:** No server/cloud/telemetry code (verified: zero network APIs in app code); no `.mscz`
parsing; no audio transcription; single-user throughout.
**Rationale:** The PRD's non-goals have actually been respected — worth stating plainly since scope
creep was a named risk. The only "extra" beyond PRD phasing (revisit flags) is small, on-mission,
and earns its complexity.

### PROD-03 · Medium · S · High — Speed trainer can instantly "master" a section
**Evidence:** PracticeSession.swift:136-139 — if `tempoPct >= target` at the first advance,
`done = true`; nothing stops you enabling the drill at 100% with a 60% target (UI offers targets
60–120, PracticeView.swift:239-241), or already sitting at the target when enabling.
**Rationale:** "Section mastered at 100% 🎉" after two passes you played at the target already is
fine — but with target *below* current tempo the drill is meaningless and the celebration
unearned/confusing.
**Recommendation:** When enabling the drill (or changing target), if `tempoPct >= target` either
drop the tempo to a sensible ramp start or disable the option with an explanatory hint.

---

## Code quality & Swift practice

### QUAL-01 · High · M · High — Zero committed tests over pure, tested-by-hand logic
**Evidence:** WoodshedTests/WoodshedTests.swift (template stub, 16 lines); ingestion layer is
Foundation-only (verified); `drillAdvance` (PracticeSession.swift:128-141), `PracticeHistory`
(troubleBars/currentTroubleBars), `BarFlagStore`, both parsers, and `Ingest.fuse` are all pure or
file-IO-only. Several were validated during development with *throwaway* `swiftc` harnesses that
were never committed.
**Rationale:** The highest-consequence logic in the app is precisely the most testable and has no
safety net. Every future parser fix (MUSIC-02…05) risks silent regression without goldens.
**Recommendation:** Wire up the existing `WoodshedTests` target with Swift Testing: (1) golden
reconciliation counts for both fixtures + your real scores; (2) truncated/corrupt-file cases;
(3) `drillAdvance`, `currentTroubleBars`, `SongMeta` back-compat decode — these three already have
harness code written once; recreate as committed tests.

### QUAL-02 · Medium · S · High — Persistence writes fail silently and non-atomically
**Evidence:** SongLibrary.swift:121 (`.write(to:)` — no `.atomic`), :95, :104-112 (`try?` swallow);
BarFlag.swift:36-40 (same); PracticeHistory.swift:50-61 (`try?` append; acceptable for JSONL);
SongLibrary.swift:38-41 (scan silently skips undecodable metadata → song vanishes from the list).
**Rationale:** Disk-full or kill-mid-write → truncated `metadata.json` → the song disappears from
the library with zero feedback, though all files exist. For a tool whose value accretes in these
files, that's the main data-loss vector (history.jsonl's append-only design is already the safe
pattern).
**Recommendation:** Use `.atomic` writes for metadata/flags; on scan, surface undecodable folders
("1 song couldn't be read") instead of skipping; consider rebuilding a default metadata.json from
the folder contents.

### QUAL-03 · Low · S · High — Force-unwrap census (good) + one guarded `!`
**Evidence:** Only two in app code: AVAudioPCMBuffer creation (AudioEnginePlayer.swift:94 — fixed
format, effectively infallible) and `n.pitch!` (Ingest.swift:176 — guarded by the `filter` at :169).
**Rationale:** This is a clean bill worth recording; the `pitch!` would still read better as
`compactMap`-style unwrapping so the invariant is local.

### QUAL-04 · Low · S · High — Swift 5 mode, no strict concurrency, races noted
**Evidence:** project.pbxproj `SWIFT_VERSION = 5.0`, no `SWIFT_STRICT_CONCURRENCY`; races at
ARCH-09 (`nextClick`), and session-mutations-from-Combine-sinks rely on main-queue convention
(MIDIInput.swift:142-147 dispatches to main — correct, but unenforced).
**Rationale:** Fine today; adopt `@MainActor` on session/engines opportunistically during the
ARCH-03 extraction rather than as a big-bang migration.

### QUAL-05 · Low · S · High — Model uses tuples/closures in stored types
**Evidence:** Model.swift:40, 77, 81, 125, 130 (tuple fields); 42, 139 (`secondsAtBeat` closure in
value structs).
**Rationale:** Blocks `Codable`/`Equatable` synthesis — the reason `FusedScore` can't be cached or
snapshot-tested cheaply. Not urgent; worth doing if/when score caching lands.

---

## UX (summary — full walkthrough in 03-ux-review.md)

### UX-01 · High · S · High — Import quality feedback is hidden exactly where it's needed
**Evidence:** Reconciliation (the designed safety net) lives behind ⋯ → "Show diagnostics…"
(PracticeView.swift:307, 329-350); import success is silent (ContentView.swift:143-153); nothing at
song-open surfaces `isClean == false`.
**Recommendation:** A small badge/banner on the practice screen when any reconciliation is unclean
("⚠️ 12 notes couldn't be matched — grading may be off in places · Details"), linking to the
existing diagnostics sheet. This single change converts MUSIC-01/-03/-05/-08 from silent to visible.

### UX-02 · Medium · S · High — One-shot dual-file import is brittle
**Evidence:** ContentView.swift:88-93 (single `.fileImporter`, `allowsMultipleSelection: true`),
:143-153 (error if the pair isn't complete in one selection; no `.mxl`).
**Recommendation:** Two-step guided import (pick XML → pick MIDI) or drag-drop; `.mxl` unzip later.

### UX-03 · Medium · L · High — iPad is compile-clean but experience-broken
**Evidence:** Drag-select is mouse-event-only (index.html:429-434); 88 keys in ~74 pt height →
white keys far below 44 pt targets (PracticeView.swift:32-36); no audio (TECH_STACK), no
AVAudioSession (ARCH-06); never run on hardware.
**Recommendation:** Treat "iPad enablement" as one wave: SoundFont + audio session + touch
selection + keyboard sizing + a hardware pass.

### UX-04 · Medium · S · High — Fumble counting reads punitive (see MUSIC-07)
### UX-05 · Low · M · High — Accessibility not started: no labels on keyboard/notation, colour-only
hand coding (PianoKeyboardView.swift:29-30), emoji in status strings (PracticeView.swift:128).
### UX-06 · Low · M · High — Dark mode: notation hard-white (index.html:21; PracticeView.swift:183).
