# Design — Woodshed

The app's structure: a `NavigationSplitView` shell (library sidebar + practice detail) and a
practice screen organised as a **notation canvas + trailing inspector** (Controls / Progress /
Flags). Hand colours are colour-blind-safe (blue/orange); the score surface is deliberately
paper-white in both colour schemes while the chrome adapts. Still stock SwiftUI controls with no
bespoke type/spacing token system (see Open Questions). This doc records the conventions that exist.

## Navigation structure

A `NavigationSplitView`: **Library** (sidebar) + **Practice** (detail). On Mac the sidebar is a
persistent left column; on iPad it collapses to a slide-over reachable from a menu button. Selecting
a song in the sidebar loads it into the detail pane (selection is by song **id**, so renaming/
favouriting — which mint a new `Song` value with the same id — never drops the detail). Switching
songs gives a fresh `PracticeSession` (via `.id(song.id)`); a rename keeps the current session. An
empty detail shows a `ContentUnavailableView` prompt.

## Screen inventory

### Help (`HelpView`, macOS)
The macOS **Help menu → "Segno Help"** (⌘?) opens an in-app help **`Window`** — a topic list
(Welcome, What you need, Adding a song, The practice screen, The four session types, Sections &
looping, Drills, Seeing how you did, Your MIDI piano, Tips & shortcuts) beside plain-language,
beginner-oriented content. We host help in-app (a `Window` scene + `CommandGroup(replacing: .help)`)
rather than as an Apple Help Book — the Help Book format is fragile (indexing + plist registration;
a misregistration is the literal "Help isn't available" error) and far less maintainable.

### Library (root)
A `List` of songs (title + a subtitle: **last-practised + best % + #tags** once set, else
date-added; ⭐ for favourites), a **search field** (titles + tags), a **sort menu** (title / last
practised / best), a **Practice overview** toolbar button (cross-song totals + stalest-first
"most due" list + practice-time totals, in a sheet), and a **+** toolbar button that runs a
**guided two-step import** (a score + MIDI pair can also be **dragged from Finder** onto the list):
pick the score (`.musicxml`/`.xml`/**`.mxl`**), then the MIDI — no multi-select needed. The pair is
validated by fusing it (unparseable → rejected with a clear error; unclean → imported with a
warning). Per-row actions (Rename / Favourite / Delete) are on a
visible **⋯ menu button** so they work by click on Mac and tap on iPad — **not** relying on
swipe-to-delete (iPad-only). The same actions are also on the right-click / long-press context menu,
with swipe-to-delete as an iPad extra.

> **Cross-platform rule:** every action must be reachable without swipe or hover. Prefer explicit
> buttons/menus over gesture-only affordances so the same UI works on Mac and iPad.

**Deselecting a bar range:** drag-select on the score sets the section; **Escape** or a **click in the
score's whitespace** (outside any bar) clears it back to the whole piece. Handled both in the web
layer (Escape keydown / whitespace mousedown → `deselect`) and by a SwiftUI `.cancelAction` fallback
for when the notation view isn't focused.

### Practice (`PracticeView`) — canvas + inspector
The practice screen is a **notation canvas** with a trailing **inspector** (`.inspector`, which
adapts natively on iPad to a collapsible column/sheet; a toolbar button toggles it). The canvas
holds only the always-live surfaces; every set-and-forget control lives in the inspector's
**Controls** tab, and **Progress** and **Flags** are first-class inspector tabs (no longer buried
in the overflow menu).

1. **Header row** — the **training-session-type** segmented control `Practice · Wait · Grade · Drill`
   on the left (the four mutually-exclusive session types; **Drill** = Grade + a looped level-up —
   either a tempo ramp or a bar-by-bar build-up, a first-class type not a buried setting); on the
   right an icon-only **metronome toggle** (`.toggleStyle(.button)`; tooltip carries the words —
   it's a live performance control, so it sits with the transport, not buried in settings) and a
   **transport cluster** in a capsule: `⏮` (back to the section start — while playing it
   jumps there, in Grade mode restarting the pass; while stopped it resets the playhead + cursor),
   `◀` / `▶` **one bar** (stopped: moves the *playhead* — where Play begins, cursor previews it;
   playing: jumps the live position; disabled in Grade — it would corrupt the pass — and in Wait),
   and the prominent icon-only `▶︎/◼` Play/Stop (Space; shows a clock while armed for sync start).
   Loops always return to the *section* start regardless of the playhead. A status-line hint shows
   "Play starts at bar N" when the playhead is off the section start. On macOS a `navigationSubtitle`
   shows tempo · time-sig · key · note count.
2. **Ingest-quality banner** (only when needed) — a persistent orange banner when the song's files
   didn't fuse cleanly (unmatched notes, or a repeats/structure mismatch), with a **Details** button
   opening the diagnostics sheet. Grading is never silently wrong. The same warning appears as an
   alert at import time; an unparseable pair is rejected at import.
3. **Status line** — one caption that shows whatever's relevant: "Play a note to start…" (when armed
   for sync start), Wait progress (`n/N` + fumbles), Grade pass result + accuracy trend, "Red = notes
   you fumbled" + **Clear marks**, the active section range, or the web-bridge status. The Play button
   shows **Waiting…** while armed.
4. **Notation** — the `WKWebView` at `maxHeight: .infinity` (rounded 8 pt, hairline border). The
   score surface is **deliberately paper-white in both light and dark mode** (like every major
   notation app); the surrounding chrome adapts via stock system colours. If the song fails to
   load, a `ContentUnavailableView` replaces it. If the web content process dies it reloads and
   re-applies score + layout + overlays automatically.
5. **Keyboard** — the 88-key `PianoKeyboardView` (88 pt on Mac, 74 pt on iPad), with a legend +
   MIDI connection status beneath. Collapsible ("Show keyboard" in View settings); when hidden a
   one-line strip keeps the MIDI status + a restore button.
6. **Inspector — Controls tab** — a grouped `Form` that shows **only the settings relevant to the
   current training-session type**, so each session presents just what it needs (ADR-039). Most of
   these controls are **global preferences** that persist across launches and carry between songs
   (View toggles, output routing, metronome/start behaviour, grading tolerance, speed-drill config —
   ADR-036); the tempo, hand, section/loop, and whether a drill is running are per-practice context.
   Sections by type: **Hands & sound** (Hands, Output — all types); **Playback** (Tempo, metronome
   start/stop-with-playback — the on/off toggle is in the transport; **Rhythm only** in Practice/Grade;
   hidden in Wait); **Focus / Section to drill** (Section from/to, **Suggest a spot**, Loop
   (Practice/Grade), Loop count-in (not Wait), Whole piece, **saved sections**); **Drill**
   (Drill only — a **Drill style** picker: *Ramp the tempo* ("Speed up" When-I-play-it-clean /
   Every-few-loops, **Start → Goal** tempo, Speed up by, clean-threshold + passes,
   one-hand-at-a-time-then-together) or *Add a bar at a time* (progressive — grows the passage one
   bar at a time, gated on playing the newest bar clean a configurable number of times **in a row**
   — *Clean passes to add a bar*, 1–8 — so you can require it's committed before extending), a
   **Keep mistakes from last loop** toggle (carries the previous loop's missed/wrong marks into the next as a heads-up; they refresh each loop, so a mistake stays while you keep making it and drops off the loop after you stop), plus a plain-English summary); the
   drill is **started from the transport ▶ Play** at the top (in Drill mode Play drops to the start
   tempo and begins the ramp); **Start** (Count-in; "Start on my first note" except Drill; playback
   types only); **Grading** (timing tolerance — Grade/Drill); **Takes** (Grade/Drill — ▶ last take /
   ▶ best graded take, replayed at the current tempo through the chosen output); **View** (all types: Bars per line — the score **auto-shrinks** until the requested count actually fits (dense
   music can't fit 4 wide bars at full size), floored at 40%; **Score size** 60–130% sets the
   *preferred/maximum* scale (the fit never grows past it) — both remembered per song; the status
   line reports the outcome, e.g. "4 bars/line · score size 53%" — Smooth cursor, Highlight score
   notes, **Problem marks** (all grade marks — trouble bars, missed & wrong notes), Colour hands, Show keyboard).
7. **Inspector — Progress tab** — headline stats (passes, best full run, last, **today's / total
   practice time**), the accuracy **trend sparkline** (95% guide), a **tempo trend** sparkline
   (100% guide — the PRD's "reaches target tempo faster" made visible), the **"still need work"**
   list (tap to drill; clears as you improve), the recent-pass log, and **Reset progress**
   (confirmed). Empty state until the first Grade pass. Completed **Wait walkthroughs** are
   recorded as passes too (fumbled steps feed the same trouble bars).
8. **Inspector — Flags tab** — add a note for a bar, the flagged-bars list (tap to drill, ⋯ to
   edit/delete). The on-score ⚑ tap still opens the inline editor.
9. **More menu** (toolbar `⋯`) — just **Show diagnostics…** (sheet: score summary, per-hand
   reconciliation table, first 24 events). The old cursor items moved into the transport.

## Colour tokens (as used in code)

| Token | Value | Meaning |
|-------|-------|---------|
| Hand — right | `#1565C0` (blue) | RH noteheads (notation) & RH score notes (keyboard) |
| Hand — left | `#E65100` (orange) | LH noteheads (notation) & LH score notes (keyboard). **Blue/orange is the colour-blind-safe pair** — the old blue/red failed red-green deficiency, and hand identity is load-bearing |
| Mistake / missed | `#D32F2F` (red) | Review marks on noteheads |
| Trouble bar | `rgba(245,158,11,…)` (amber) | Bars you still keep missing, tinted on the score (below the blue section selection) |
| Flag marker | `#8e44ad` (purple ⚑) | A manual revisit note pinned to a bar; a tappable marker at the bar's top-left |
| You (input) | `Color.green` | Notes you're holding on the MIDI piano / mouse |
| Wrong (Wait/Grade) | `Color.red` | A held note that isn't expected now |
| Cursor | OSMD green highlight | The follow-cursor bar |
| Status – error | `.red` | Error captions |
| Status – normal | `.secondary` / `.green` | Info / positive captions |

White keys use ~0.6 opacity of the above; black keys use full.

## Typography

Stock SwiftUI system font throughout. Screen title via `navigationTitle`; `.caption`/`.caption2` for
the status line and legends; the diagnostics sheet uses `.system(.body/.footnote, design: .monospaced)`.
**No custom type scale or font.**

## Spacing / layout rules

- Practice canvas is a `VStack(spacing: 8)` that **fills** the detail pane (no `ScrollView`); the
  notation takes `maxHeight: .infinity`.
- The inspector is a `.inspector` column (min 250 / ideal 300 / max 400 pt) with a segmented tab
  header; the Controls tab is a grouped `Form` — SwiftUI handles Mac/iPad presentation natively.
- Mode = `.pickerStyle(.segmented)`; Play = `.borderedProminent`; inspector controls are stock Form
  rows (`LabeledContent`, `Toggle`, `Picker`, `Stepper`).
- Keyboard height: 88 pt (macOS) / 74 pt (iOS, via `#if os(iOS)`). Notation height is flexible.
- No spacing/size token system yet; values are inline literals.

## Interaction & animation patterns

- **Follow-cursor:** driven from the audio clock at ~50 Hz. "Smooth" interpolates the cursor's
  horizontal position between notes; "Step" jumps note-to-note. Both snap at line breaks.
- **Follow-scroll:** the notation lives in a scrollable viewport (`#scrollHost`). When the active line
  changes, it animates the scroll position (0.35 s ease) to keep the active + next line in view, with
  **headroom above the active system** (≥ 40 px, scaled with zoom) so notes / ledger lines / ornaments
  above the top staff line stay fully visible. Because it's a real scroller, you can also **scroll it
  by hand** (wheel / trackpad / touch) to review bars you've already played; auto-follow resumes on the
  next cursor move.
- **Keyboard:** press/drag plays notes (mouse/touch) via a high-priority drag gesture, **routed by
  the Output setting** — the internal sampler for Speakers, the external piano (MIDI out) for Piano,
  both for Both (so tapping the keyboard is audible on the piano when Piano output is selected). MIDI
  input lights keys live.
- **Section select on the score:** click/drag across bars to set the practice loop. A translucent
  blue highlight (rgba(21,101,192,0.13) fill, 0.45 border) marks the range without obscuring the
  notes; it spans multiple systems. "Whole piece" clears it. Stays in sync with the bar steppers.
- **Wait/Grade feedback:** blue (needed / in-window), green (correct held), red (wrong held); Wait-mode
  review marks appear on the score on exit and are removed with "Clear marks".
- **Per-pass grading (Grade + Loop):** misses **ring red progressively** as the cursor passes each note
  you didn't play (open circle, doesn't fill the notehead); **wrong notes you play** are drawn on the
  score too — a small red dot at that beat, at the pitch's height (relative to a real notehead there,
  so it picks the right staff), labelled with the note name. Both **wipe at each loop restart**. Notes
  played during the **count-in** are graded against bar 1 (the clock is parked at the section start),
  so the downbeat you play as the count-in ends isn't dropped and mis-marked as missed.
  Each loop shows "Pass N: X% · Missed · Wrong · ±ms · **rushing/dragging ~Nms**" (signed timing —
  the actionable half of timing feedback) and a "Progress 72→80→87%" accuracy trend. Stopping early
  shows "Pass abandoned — stopped before the end (not recorded)". Wait-mode **fumbles count steps,
  not chord notes** — one slip on a 4-note chord is one fumble.
- **A pass is recorded once, on completion** — reaching the section end (each loop, or the single
  play-through). Stopping early **abandons** the partial pass (it isn't recorded), so the history and
  trend only reflect passes you actually finished.
- **Speed trainer (auto-tempo / mastery):** turning it on sets up Grade + Loop; the tempo slider then
  ramps automatically after each pass (by reps, or by accuracy = the mastery gate). The status line
  shows "Speed trainer · 80% → 100% · 1/2 clean · last 96%", and on mastery "Section mastered at 100%
  🎉" and the drill stops.
- **Sync start:** with "Start on my first note" on, pressing Play **arms** (status: "Play a note to
  start…", button reads "Waiting…") and playback begins the instant you play a note — your note is the
  downbeat. Optionally the metronome starts with playback and/or stops when playback stops (so the
  click runs only while you're playing).
- **Loop count-in:** with Loop on, an optional count-in of N beats plays before **each** pass (the
  clock freezes at the section start, the metronome clicks the last N beats of the bar as a pickup,
  then playback resumes) — time to reposition your hands. N is meter-aware (Off up to a full bar).
- **Revisit flags (manual):** pin a short note to a bar to remind yourself what to work on. Flagged
  bars show a tappable purple **⚑** at the top-left on the score — tap it to edit/delete the note.
  The **Flags…** sheet (More menu) lists them (bar + note), adds a flag for a chosen bar, and taps
  through to drill that bar. Stored per song in `flags.json`.
- **Problem marks on the score** (toggle: View → "Problem marks on score", default on) — one switch
  governs **all** grade-related score highlighting together: the **amber trouble bars** (bars you keep
  missing — "clear as you improve", a bar drops off once the most recent covering pass is clean),
  the **red missed-note rings**, and the **red wrong-note dots**. Turning it off clears every one of
  them (and suppresses them live during a pass); turning it on restores them. The Progress tab lists
  the trouble bars too (tap to drill). (Wait-mode fumble marks are separate — cleared via the status
  line's **Clear marks**.)
- **Keyboard shortcut:** Space = Play/Stop.

## Design conventions to preserve

- The web layer is **display only** — never put logic, timing, or state decisions in `index.html`.
- Hand colours are consistent across notation and keyboard (blue = RH, orange = LH — the colour-blind-safe pair).
- Feedback is **encouraging** — wrong notes are shown, never block or scold.

## Open Questions

- **No type/spacing token system.** Structure and IA are done (split view + inspector); the score is
  deliberately paper-white in both colour schemes and hand colours are colour-blind-safe. Remaining
  visual work: a defined type scale/spacing tokens if the stock look ever stops sufficing, and an
  optional **dark score theme** (recolouring OSMD's output) if paper-white in dark mode bothers in
  practice.
- **Accessibility beyond colour:** VoiceOver labels for the keyboard/notation, Dynamic Type in the
  inspector, reduced-motion for the follow-scroll — not yet addressed.
- **iPad still needs a hardware pass.** Audio (bundled SoundFont + AVAudioSession) and touch
  drag-select are now in place and the SDK builds, but nothing has run on a physical iPad. The
  88-key keyboard's keys are inherently narrow at iPad widths — acceptable for feedback display,
  cramped for touch playing.
