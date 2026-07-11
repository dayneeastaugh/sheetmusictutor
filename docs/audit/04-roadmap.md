# Remediation roadmap

Sequenced waves; each is independently shippable and leaves the app working. Finding IDs reference
`02-findings.md`. Efforts are working-session estimates for this codebase's author+assistant pace.

**Sequencing logic in one line:** first stop the app lying or dying (Wave 0), then build the safety
net + fix the hot loop that every later change must run through (Wave 1), then improve the feedback
the practice loop exists to deliver (Wave 2), then widen the surface (iPad/UI — Wave 3), then
deepen (Wave 4). Structural-before-cosmetic because Waves 2–4 all edit the same files Waves 0–1
harden; doing UI polish first would mean re-testing it after every foundation change.

---

## Wave 0 — Stop the bleeding (≈ 2–3 sessions)

**Goal:** no crash on bad input, no silent data loss, no silently-wrong model, no unearned rewards.
**Resolves:** MUSIC-02, QUAL-02, UX-01, MUSIC-01 (mitigation), PROD-03, ARCH-05.

1. Bounds-checked, throwing `ByteReader` in MIDIParser (MUSIC-02) + a truncated-file fixture.
2. Atomic writes for `metadata.json`/`flags.json`; surface undecodable song folders instead of
   silently skipping (QUAL-02).
3. **Reconciliation banner** on the practice screen when any hand's `isClean == false`, linking to
   the existing diagnostics sheet (UX-01). Also shown once at import completion.
4. **Repeat/structure guard** (MUSIC-01 mitigation): if XML total beats and last MIDI beat diverge
   by > 1 bar, banner: "This piece's structure (repeats?) can't be aligned yet — cursor and grading
   will be wrong after the first repeat." Document in INGESTION.md.
5. Speed-trainer clamp: enabling with `tempoPct >= target` adjusts start tempo or explains (PROD-03).
6. Update `audio.startSeconds` on mid-loop section change (ARCH-05).

**Done when:** garbage `.mid` import shows an error alert (no crash); killing the app mid-save never
hides a song; an unclean import is visibly flagged; drill can't instantly master.

## Wave 1 — Foundations: tests + the hot loop (≈ 1 week)

**Goal:** a committed safety net under the music core, and a practice loop that never lags.
**Resolves:** QUAL-01, PROD-01, ARCH-01, ARCH-02, ARCH-04, ARCH-07; enables everything later.
**Prerequisite:** Wave 0 (its fixes need the tests; the banner needs to exist before real-score
triage so failures are visible).

1. **Real-score triage** (PROD-01): import 5–10 of your own MuseScore exports; record each
   reconciliation. Clean ones become golden fixtures; failures become the Wave 2/4 parser worklist.
2. **Test target** (QUAL-01), in this order of value: golden reconciliation counts per fixture;
   parser corrupt/truncated cases; `drillAdvance`; `currentTroubleBars`; `SongMeta` back-compat
   decode; tie-merge + ornament absorption unit cases.
3. **Tick-loop rewrite** (ARCH-01): monotonic indices over sorted schedules (reset on seek/loop);
   interval index for sounding-note sets; `bridge.seek` only on beat movement ≥ ε.
4. **Canvas keyboard** (ARCH-02): single-pass draw, precomputed geometry, remove the inner
   `.frame(height: 90)`. This + (3) should close the trill-lag complaint; verify with a dense
   fixture at 120%.
5. `MIDIClientDispose` in `deinit` now; promote `MIDIInput`/`AudioEnginePlayer` to app-level
   lifetime (ARCH-04). Idempotent `onAppear` (ARCH-07).

**Done when:** `xcodebuild test` runs green with real-score goldens; trills display keystroke-instant
on the densest fixture; song-switching doesn't accumulate MIDI clients.

## Wave 2 — Core-loop feedback quality (≈ 1 week)

**Goal:** the feedback a practising pianist acts on — trustworthy, tunable, specific.
**Resolves:** MUSIC-06, MUSIC-07/UX-04, MUSIC-03, MUSIC-05, MUSIC-09, UX-02.
**Prerequisite:** Wave 1 (matcher/parser changes need the tests; extraction makes them safe).

1. Extract `GradeMatcher` as a pure struct (start of ARCH-03), then: signed timing (early/late),
   tunable tolerance (UI in the More/inspector), tempo-aware window (MUSIC-06).
2. Wait-mode fumbles: count events not chord notes; record the actually-played wrong pitch;
   review marks show it (MUSIC-07/UX-04).
3. Parser worklist from Wave 1 triage: overlapping-note stack (MUSIC-03), `<grace>` handling
   (MUSIC-05), per-section count-in pattern (MUSIC-09), multi-part guard (MUSIC-04).
4. Guided two-step import + `.mxl` (unzip) support (UX-02).
5. "Pass abandoned" caption when stopping mid-pass.

**Done when:** grade summary says "you rush by ~30ms"; a chord slip counts as one fumble; your
real-score triage list is clean or explicitly flagged.

## Wave 3 — Experience: the UI restructure + iPad + visual system (≈ 1–2 weeks)

**Goal:** the professional shell — and iPad actually shipped, not just compiling.
**Resolves:** UX-03, ARCH-06, UX-05 (baseline), UX-06; the deferred inspector decision.
**Prerequisite:** Wave 1 (ARCH-07's idempotent lifecycle; perf fixes — restructuring the UI around
a laggy core bakes the lag in); Wave 2 recommended (control inventory stabilises first).

1. Decide + implement the practice-screen restructure (the three-pane/inspector proposal from
   2026-07-11, or its centre-stacked alternative). Progress/Flags become first-class.
2. iPad enablement as one unit: bundled `.sf2` + `AVAudioSession` (ARCH-06) + touch drag-select in
   the web layer + keyboard touch-target sizing + a hardware validation pass (UX-03).
3. Visual system: type/spacing tokens, intentional dark mode incl. notation background, colour-
   blind-safe hand coding (shape/label channel, not hue swap alone) (UX-05/06 baseline).
4. Web-process crash recovery while touching the web layer anyway (ARCH-08).

**Done when:** same practice session is comfortable on Mac and a physical iPad; dark mode is
deliberate everywhere; hands distinguishable without colour vision.

## Wave 4 — Depth (backlog, order by appetite)

- **Repeats/voltas unfold** (MUSIC-01 proper fix) — parse repeat barlines/endings, unfold the XML
  timeline; the biggest single expansion of "pieces Woodshed can handle". Do after tests exist.
- **Hands-separate → hands-together mastery gating** (PRD; drill already has the scaffolding).
- Metronome look-ahead scheduling (ARCH-09) if click jitter ever becomes audible.
- Rhythm tools; named/saved sections + A/B markers; library search/tags.
- Cross-song analytics — the first feature that justifies a DB decision (GRDB vs SwiftData).
- Swift 6 / `@MainActor` adoption, ideally ratcheted during ARCH-03 extraction (QUAL-04).

## Do not do this yet

- **Database migration** — file-based persistence is correct at this scale; a DB before cross-song
  analytics is pure cost (re-affirming ADR-018/-021).
- **Big-bang Swift 6 strict concurrency** — adopt actor isolation opportunistically during the
  Wave 2 extraction instead; a flag-day migration now would stall feature work for zero user value.
- **OSMD upgrade** — 2.0.0 is pinned, working, and characterised; an upgrade invalidates the
  anchor/coordinate assumptions (×10 unit scaling, cursor internals) for no current need.
- **Visual polish before the restructure** — token/dark-mode work applied to the current layout
  gets thrown away when the inspector lands; sequence it inside Wave 3.
- **visionOS anything** — it builds; leave it there.
- **More practice features** (rhythm tools, saved clips…) before Waves 0–2 — every one of them
  lands in `PracticeSession`/the tick loop, i.e. on top of the exact code Waves 0–2 stabilise.
