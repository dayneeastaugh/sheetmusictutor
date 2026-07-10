# Design — Woodshed

A **first structural redesign** has landed: a `NavigationSplitView` shell, a notation-hero practice
screen, and a wrapping control bar that adapts between Mac and iPad. It still uses stock SwiftUI
controls with no bespoke type/spacing system — a full visual design pass (tokens, colour-blind-safe
scheme, intentional Dark Mode) is still owed (see Open Questions). This doc records the conventions
that exist.

## Navigation structure

A `NavigationSplitView`: **Library** (sidebar) + **Practice** (detail). On Mac the sidebar is a
persistent left column; on iPad it collapses to a slide-over reachable from a menu button. Selecting
a song in the sidebar loads it into the detail pane (selection is by song **id**, so renaming/
favouriting — which mint a new `Song` value with the same id — never drops the detail). Switching
songs gives a fresh `PracticeSession` (via `.id(song.id)`); a rename keeps the current session. An
empty detail shows a `ContentUnavailableView` prompt.

## Screen inventory

### Library (root)
A `List` of songs (title + a subtitle: **last-practised + best %** once there's history, else
date-added; ⭐ for favourites) and a **+** toolbar button to import a
MusicXML + MIDI pair (`.fileImporter`). Per-row actions (Rename / Favourite / Delete) are on a
visible **⋯ menu button** so they work by click on Mac and tap on iPad — **not** relying on
swipe-to-delete (iPad-only). The same actions are also on the right-click / long-press context menu,
with swipe-to-delete as an iPad extra.

> **Cross-platform rule:** every action must be reachable without swipe or hover. Prefer explicit
> buttons/menus over gesture-only affordances so the same UI works on Mac and iPad.

### Practice (`PracticeView`, top → bottom)
The notation is the **hero** (fills the pane); everything else is thin chrome around it. No outer
`ScrollView` — the screen fills the detail pane and the control bar wraps instead of scrolling.

1. **Header row** — a **mode segmented control** `Practice · Wait · Grade` (the three mutually-exclusive
   modes, replacing the old scattered toggles) on the left; an audio-status caption and the
   `▶︎ Play / ◼ Stop` button (`.borderedProminent`, Space shortcut, disabled in Wait mode) on the right.
   On macOS a `navigationSubtitle` shows tempo · time-sig · key · note count.
2. **Status line** — one caption that shows whatever's relevant: Wait progress (`n/N` + fumbles),
   Grade pass result + accuracy trend, "Red = notes you fumbled" + **Clear marks**, the active
   section range, or the web-bridge status.
3. **Notation** — the `WKWebView` at `maxHeight: .infinity` (white, rounded 8 pt, hairline border).
   If the song fails to load, a `ContentUnavailableView` replaces it.
4. **Control bar** — a **`FlowLayout`** (wraps on narrow widths) of labelled groups: **Hands**
   (segmented Both/R.H./L.H.), **Tempo** (% + slider 25–120), **Section** (from/to steppers, `🔁 Loop`,
   `All`), a **Loop count-in** menu (Off / 1 beat … / Full bar — choices are meter-aware, capped at the
   section's beats-per-bar), plus a **Metronome** toggle and an **Output** menu (Speakers / Piano / Both).
5. **Keyboard** — the 88-key `PianoKeyboardView` (**always visible**; 88 pt on Mac, 74 pt on iPad),
   with a legend + MIDI connection status beneath.
6. **More menu** (toolbar `⋯`) — the less-used controls: Count-in, Smooth cursor, Highlight score
   notes, **Show trouble spots on score**, Colour hands, Bars per line (**remembered per song** in
   `metadata.json`), Step cursor forward, Reset cursor, **Show progress…**, and **Show diagnostics…**.
7. **Progress** (behind the More menu, in a sheet) — headline stats (passes, best full run, last
   pass), an accuracy **trend sparkline** (with a 95% target guide), a **"still need work"** list
   (bars you're currently missing, each a tap-to-drill button that focuses the section on that bar;
   a bar clears once you play it cleanly), and a recent-pass log. A destructive **Reset** (toolbar,
   with a confirm dialog) wipes the song's history. Empty state until the first Grade pass.
8. **Diagnostics** (behind the More menu, in a sheet) — score summary, the per-hand reconciliation
   table (✅/⚠️), and the first 24 note events. Monospaced. Off the main flow but one tap away.

## Colour tokens (as used in code)

| Token | Value | Meaning |
|-------|-------|---------|
| Hand — right | `#1565C0` (blue) | RH noteheads (notation) & RH score notes (keyboard) |
| Hand — left | `#C62828` (red) | LH noteheads (notation) & LH score notes (keyboard) |
| Mistake / missed | `#D32F2F` (red) | Review marks on noteheads |
| Trouble bar | `rgba(245,158,11,…)` (amber) | Bars you still keep missing, tinted on the score (below the blue section selection) |
| You (input) | `Color.green` | Notes you're holding on the MIDI piano / mouse |
| Wrong (Wait/Grade) | `Color.red` | A held note that isn't expected now |
| Cursor | OSMD green highlight | The follow-cursor bar |
| Status – error | `.red` | Error captions |
| Status – normal | `.secondary` / `.green` | Info / positive captions |

White keys use ~0.6 opacity of the above; black keys use full. **Note:** RH-blue / LH-red is not
colour-blind-safe (red-green) — flagged for the design pass.

## Typography

Stock SwiftUI system font throughout. Screen title via `navigationTitle`; `.caption`/`.caption2` for
the status line and legends; the diagnostics sheet uses `.system(.body/.footnote, design: .monospaced)`.
**No custom type scale or font.**

## Spacing / layout rules

- Practice root is a `VStack(spacing: 10)` that **fills** the detail pane (no `ScrollView`); the
  notation takes `maxHeight: .infinity`.
- The control bar is a **`FlowLayout`** (custom `Layout`) of control groups, so it sits in one row on
  a wide Mac window and wraps to several rows on a narrow iPad one — no size-class branching.
- A control **group** is an `HStack` with a hairline `RoundedRectangle` border (`corner 8`,
  `secondary.opacity(0.25)`). Mode = `.pickerStyle(.segmented)`; Metronome/Loop = `.toggleStyle(.button)`;
  Output/More = menus. Play = `.borderedProminent`.
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
  you didn't play (open circle, doesn't fill the notehead); the rings **wipe at each loop restart**.
  Each loop shows "Pass N: X% · Missed · Wrong · ±ms" and a "Progress 72→80→87%" accuracy trend.
- **A pass is recorded once, on completion** — reaching the section end (each loop, or the single
  play-through). Stopping early **abandons** the partial pass (it isn't recorded), so the history and
  trend only reflect passes you actually finished.
- **Loop count-in:** with Loop on, an optional count-in of N beats plays before **each** pass (the
  clock freezes at the section start, the metronome clicks the last N beats of the bar as a pickup,
  then playback resumes) — time to reposition your hands. N is meter-aware (Off up to a full bar).
- **Trouble spots on the score:** the bars you still keep missing are tinted **amber** on the notation
  (toggle: More → "Show trouble spots on score"). The set is "clear as you improve" — a bar drops off
  once the most recent pass covering it is clean, and updates live after each pass. The Progress
  sheet lists the same bars (tap to drill).
- **Keyboard shortcut:** Space = Play/Stop.

## Design conventions to preserve

- The web layer is **display only** — never put logic, timing, or state decisions in `index.html`.
- Hand colours are consistent across notation and keyboard (blue = RH, red = LH).
- Feedback is **encouraging** — wrong notes are shown, never block or scold.

## Open Questions

- **No real *visual* design system yet.** The structure is redesigned (split view, notation-hero,
  adaptive control bar) but there's still no defined type scale, spacing tokens, or component set —
  and no intentional Dark Mode (the notation is forced white). That visual pass is the remaining work.
- **Colour accessibility:** RH-blue / LH-red is still not colour-blind-safe (red-green). Supplement
  with shape/label cues or swap the hue pair in the visual pass. (Deliberately deferred for now.)
- **iPad validated only by compile, not on device.** The layout now adapts (sidebar collapses, the
  control bar wraps, keyboard shorter), and both the macOS and iOS SDKs build — but it hasn't run on
  real iPad hardware, and the sound source differs there (no system `.dls`; see TECH_STACK).
- **Resolved:** the diagnostic dump moved behind the More menu → "Show diagnostics…" (a sheet), off
  the main practice flow but one tap away for checking an import.
