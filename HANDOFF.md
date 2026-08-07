# HANDOFF — continuing work on Segno (Woodshed) from a fresh machine/session

For a Claude (or human) with **no chat history**. Read this + `CLAUDE.md` first; the
`/docs` folder is the source of truth and is **current as of the last commit**.

## What this is

**Segno** — native macOS + iPadOS piano-practice tutor (SwiftUI, no dependencies, on-device,
sandbox off). Imports MuseScore MusicXML+MIDI pairs, renders notation (OSMD in a WKWebView),
plays back, listens to a MIDI piano, and grades practice with teacher-style feedback.
Project/scheme/module are named **Woodshed** (internal); the product is **Segno.app** (ADR-037).

## State at handoff (2026-07-19)

- Everything committed and pushed on `main`; working tree clean. All tests green, both
  platforms build, app boots. Owner: Dayne (intermediate pianist, Swift/Xcode beginner —
  explain Swift things plainly; give click-by-click Xcode steps when needed).
- The recent arc (see DECISIONS.md **ADR-041…052** for full detail): diagnostic logging
  (`DebugLog`), count-in grading fix, drill upgrades (progressive add-a-bar, slow-ramp
  remediation), event-scheduled piano output incl. sustain (`PianoScheduler`), Technical
  Practice category + generated scale books (`tools/gen_scales.py`), data-safety pass
  (soft delete, backup export, visible write failures), MIDI robustness + iOS audio
  recovery, session lifecycle (`shutdown()`/`reviveIfNeeded` — ADR-044), resume-on-launch,
  streak + mastery grid, and the **pass report card** (`PassReport*` — per-bar/per-hand
  results, timing lane, recurring faults, balance, pedal, drift, chord rolls, evenness,
  wins, **themed two-tier layout** Notes / Rhythm & tempo / Touch & pedal, peek-on-score,
  collapsible, persisted per song as `report.json`).

## Build / test / verify (the discipline used so far)

```bash
# Build (macOS)
xcodebuild -scheme Woodshed -destination 'platform=macOS' build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"

# Tests — run SERIALLY: the parallel runner intermittently reports phantom 0.000s
# failures (infra flake, seen repeatedly). Serial is the truth. ~71 tests.
xcodebuild test -scheme Woodshed -destination 'platform=macOS' -only-testing:WoodshedTests -parallel-testing-enabled NO

# iOS compile check
xcodebuild -scheme Woodshed -destination 'generic/platform=iOS Simulator' build

# Boot smoke test (app must stay ALIVE ~3s)
"$HOME/Library/Developer/Xcode/DerivedData/Woodshed-"*/Build/Products/Debug/Segno.app/Contents/MacOS/Segno & sleep 3; kill %1
```

Test output format varies by run: count `✔ Test ` lines or `Test case .* passed` — check
`** TEST SUCCEEDED **` as the verdict, not just grep counts.

## Working rules (owner's explicit expectations)

1. **Docs sync every commit** — ALL of `/docs` (PRD, ARCHITECTURE, DATA_MODEL, INGESTION,
   TECH_STACK, DESIGN, DECISIONS) **and CLAUDE.md's Status paragraph**, not just
   DECISIONS/DESIGN. Say explicitly in summaries which docs changed. Significant choices
   get an ADR (append-only, next number: **ADR-053**).
2. Verify before claiming done: build both platforms, serial tests, boot. JS changes to
   `Woodshed/Web/index.html` were verified by serving the folder
   (`python3 -m http.server`) and driving the real page in a browser.
3. Commit per logical batch with detailed messages; push to `main` after each batch.
4. Feedback must stay **encouraging, never punitive** (wins first) — it's in the PRD.

## Diagnostics workflow (used constantly)

Opt-in log at `~/Library/Application Support/Segno/debug.log` (toggle: ⋯ menu → Show
diagnostics; the setting + data persist). Categories: `[midi]` in/out + lifecycle,
`[out]` piano output, `[grade]`, `[drill]`, `[wait]`, `[session]`, `[audio]`.
When Dayne says "check the logs", read that file directly. The pattern that has worked:
instrument first, reproduce once, read, then fix.

## Known quirks / open ends

- **Parallel test runner flake** (above). One crash-cascade case was a bad test index —
  if many suites fail at 0.000s, rerun serially before believing it.
- SwiftUI can retain a replaced view's `@StateObject` (memory-only husk) — that's why
  session teardown is explicit (`onDisappear → session.shutdown()`, ADR-044). Never rely
  on deinit for audible/input resources.
- The Clavinova sends continuous half-pedal CC64 (repeated down/down/up) — pedal logic
  collapses to transitions where it matters.
- Library data lives at `~/Library/Application Support/Segno/Scores/<uuid>/` (metadata,
  history.jsonl, flags, sections, time, takes, report.json). Soft-deletes go to Trash.

## Open tasks (in priority order)

1. **Calibrate feedback thresholds with the real piano** — evenness gauges (rhythm CV
   mapping, velocity-spread), timing-tint/hotspot 40 ms, theme good/watch/focus
   boundaries, balance ≥10 callout. All constants live in `PassReport.swift`
   (`PassReportBuilder.evenness`, `themes()`) and `PassReportView.swift`. Method: Dayne
   plays, reports how gauges/callouts felt vs reality, adjust.
2. **Deferred teacher items** — legato/duration grading (takes record on+off already),
   hesitation map (IOI spikes at consistent spots), rubato-aware damping of the timing
   lane. Same pattern as ADR-051: pure funcs in `PassReportBuilder` + card callouts.
3. **Deferred refactors** — extract TakeController/DrillController/PracticeClock from
   ~1700-line `PracticeSession.swift`; unify the four chord-collapse consumers; JSON
   `schemaVersion`; metronome timer lifecycle fully onto `metroQueue` (needs device
   audio verification); per-tick Set churn.
4. **iPad hardware pass** — never run on a physical iPad; audio-interruption recovery,
   Help sheet, exports, and touch flows all want one real-device session.

## Key files (recent additions; the rest is mapped in ARCHITECTURE.md)

- `Woodshed/PassReport.swift` — report model + pure builder + themes + store (report.json)
- `Woodshed/PassReportView.swift` — the card (strip/chips/lane, themed two-tier callouts)
- `Woodshed/PianoScheduler.swift` — event-scheduled MIDI-out (ornaments/pedal)
- `Woodshed/DebugLog.swift` — diagnostic logging
- `Woodshed/AppSettings.swift` — persisted preferences (`pref.*`)
- `tools/gen_scales.py` — regenerates the scale books in `Woodshed/Scores/`
- `Woodshed/Web/index.html` — OSMD page: selection (drag + click-click pairing),
  peek pulse, timing tint, overlays; Swift side in `NotationWebView.swift`

## Memory notes for a fresh Claude on the OTHER machine

That machine won't have this one's persistent memory. The three durable facts to know:
(1) `/docs` is canonical — read before changing, update in the same commit;
(2) Dayne is new to Swift/Xcode — plain explanations, GUI steps;
(3) call out doc updates explicitly in every summary (see Working rules).
