# UX review — journey walkthroughs

Standard applied: the PRD's own bar — *generous, tunable tolerance; encouraging, never punitive;
the failure mode to avoid is a technically-correct but demoralising tool.* Findings cross-reference
`02-findings.md`.

## Journey 1 — First run / import a score

**As built:** First launch seeds two fixtures (SongLibrary.swift:126-133), so the library is never
empty-empty — good instinct. Empty-detail shows a clear `ContentUnavailableView` prompt
(ContentView.swift:31-35). Import is a single file-picker where you must multi-select *both* files
at once (ContentView.swift:88-93); picking just one yields an error alert telling you to try again
(:148). Success is silent — the song simply appears; nothing tells you whether the ingest is
*good*.

**Friction:** (a) Dual-select is undiscoverable — most people pick one file, hit the error, retry
(UX-02). (b) The moment of highest anxiety — "did my transcription import correctly?" — has no
answer anywhere on the happy path; the reconciliation report that answers it precisely is behind
⋯ → Show diagnostics (UX-01). (c) No `.mxl` support means MuseScore's *default* compressed export
fails with a generic message.

**Recommendation:** Two-step guided import ("1. Choose the MusicXML → 2. Choose the MIDI"), then a
one-line result: "✓ Imported · 482 notes matched cleanly" or "⚠️ 12 notes couldn't be matched —
view details". That one banner is the single highest-leverage UX change in the app (it also
operationalises the safety net for MUSIC-01/-03/-05).

## Journey 2 — Read & listen (open a song, play it back)

**As built:** Song opens fast (fixtures parse in well under a second), notation is the hero, cursor
follows with headroom, scroll-back works, per-hand/tempo/output controls are one click. Solid. The
status line multiplexes seven different messages in priority order (PracticeView.swift:120-168) —
efficient, but transient states (armed / mastered / bridge status) share one small caption slot, so
users must know to look there.

**Friction:** (a) Mid-piece meter/tempo edge: the count-in pattern is derived once from the first
full bar (MUSIC-09). (b) If the WebKit process dies, the score pane silently blanks (ARCH-08).
(c) Changing the section *while looping* produces the stale-start hybrid loop (ARCH-05) — feels
like the app "losing" your selection.

## Journey 3 — Drill a section (the core loop)

**As built:** This is the app's best flow. Drag-select bars directly on the score, loop it, get a
meter-aware count-in each pass, watch misses ring progressively, see the pass trend, and let the
speed trainer ramp tempo only when you're clean. Trouble bars tint amber and *clear when you fix
them* — that "clear as you improve" semantic is exactly the encouraging-not-punitive principle,
implemented correctly (PracticeHistory.currentTroubleBars).

**Friction, ranked:**
1. **Feedback latency under load** — the trill/turn keyboard lag (ARCH-01/-02). Instant visual
   feedback is the contract of a practice tool; this is the top experience bug.
2. **Fumble inflation** — one slip on a chord shows "Fumbles: 4" and paints the whole chord red
   (MUSIC-07/UX-04). Punitive-adjacent, and it hides *what* you actually played.
3. **No early/late signal** — "±23ms" is unsigned (MUSIC-06); "you rush the left hand" is the
   feedback a practising pianist actually wants.
4. **Speed-trainer instant-mastery** when target ≤ current tempo (PROD-03) — an unearned 🎉 reads
   as the app not paying attention.
5. Grade + Loop interplay is good, but nothing explains that a partial pass (stop early) is
   *abandoned* — users may wonder where their pass went. One caption ("pass abandoned — stopped
   early") would close it.

## Journey 4 — Review progress & plan next practice

**As built:** Progress sheet: stats, trend sparkline with a 95% guide, still-need-work list with
tap-to-drill, recent passes, destructive reset with confirmation. Flags: pin/edit/delete notes on
bars, tap-to-drill. Library rows show last-practised + best. Coherent and honest.

**Friction:** (a) Progress and Flags are *destinations* buried in an overflow menu — for the
feature that makes this a tutor, that's low billing (the pending inspector/tab restructure fixes
this; it was proposed and deferred). (b) The trend mixes different sections/tempos/hands into one
line — a 60%-tempo section pass and a 100% full run read as the same curve; per-context filtering
will matter as history grows. (c) `bestAccuracy` only counts full-piece runs — correct but
unexplained anywhere in UI.

## Cross-platform (Mac vs iPad)

The Mac experience is genuine. The iPad experience currently exists only as a compiling target:
no sound (system DLS absent; no bundled SoundFont), no `AVAudioSession` handling (ARCH-06),
drag-select is mouse-only in the web layer (UX-03), keyboard keys ~19 pt wide at 74 pt tall (target
should be ≥44 pt), and it has never run on hardware. The adaptive plumbing (FlowLayout wrap,
collapsible sidebar, per-OS keyboard height) is in place and will pay off — but "iPad support"
should be treated as *not yet shipped* rather than "needs polish". The stated cross-platform rule
("every action reachable without swipe or hover", DESIGN.md) is honoured in the SwiftUI layer;
the web layer's drag-select is its one violation (no non-gesture alternative exists — the steppers
cover it, so the rule technically survives via the Section steppers).

## Accessibility

Not started, accurately per the docs. Concretely absent: accessibility labels/traits on the piano
keys and notation pane (PianoKeyboardView.swift has none; the WKWebView SVG is opaque to
VoiceOver); hand identity is colour-only (blue/red — the worst pair for red-green deficiency) with
no shape/label channel; status emoji ("🎉", "⚑") will be read literally by VoiceOver; no Dynamic
Type consideration in the fixed-height control rows; no reduced-motion path for the scroll
animation. For a personal tool this is a conscious deferral — recording it here so it's a decision,
not an accident.

## Design-principle scorecard

| PRD principle | Verdict |
|---|---|
| Generous, tunable tolerance | Generous ✓ (±300ms musical) · tunable ✗ (constant, MUSIC-06) |
| Encouraging, never punitive | Mostly ✓ — trouble-bar decay is exemplary; fumble counting and unearned mastery are the two lapses |
| Wrong notes never block | ✓ throughout (Wait mode ignores extras; Grade counts without stopping) |
| Feedback perceptually immediate | ✗ under load (ARCH-01/-02) — the open complaint |
| Failure feedback actionable | Partial — *where* you missed is excellent (rings, amber bars); *what/why* (early/late, wrong-note identity) is missing |
