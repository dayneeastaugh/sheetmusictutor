# Design — Woodshed

The current UI is a **Phase-0 diagnostic surface**, not a designed product. It's a single dense
screen optimised for proving functionality, using stock SwiftUI controls. This doc records the
conventions that *do* exist and flags that a real design pass is still owed.

## Navigation structure

A `NavigationStack`: **Library** (root) → **Practice** (`PracticeView`, pushed when a song is
selected). The redesign target is a `NavigationSplitView` (sidebar library + practice detail) for
Mac/iPad. The practice screen itself is still one dense vertical `ScrollView` of inline controls.

## Screen inventory

### Library (root)
A `List` of songs (title + date-added, ⭐ for favourites) and a **+** toolbar button to import a
MusicXML + MIDI pair (`.fileImporter`). Per-row actions (Rename / Favourite / Delete) are on a
visible **⋯ menu button** so they work by click on Mac and tap on iPad — **not** relying on
swipe-to-delete (iPad-only). The same actions are also on the right-click / long-press context menu,
with swipe-to-delete as an iPad extra.

> **Cross-platform rule:** every action must be reachable without swipe or hover. Prefer explicit
> buttons/menus over gesture-only affordances so the same UI works on Mac and iPad.

### Practice (`PracticeView`, top → bottom)
1. **Notation section**
   - Header: "Notation (OSMD)" + a live status caption (from the web bridge).
   - The `WKWebView` notation (fixed **360 pt** tall, white background, rounded 8 pt, hairline border).
   - **Transport row:** `▶︎ Play / ◼ Stop` (Space), Count-in picker (No / 1-bar / 2-bar), `🎵 Metronome`,
     `⟿ Smooth / ⇥ Step` cursor toggle, `🎨 Colour hands`, Bars/line picker (Auto / 1–5), `Step cursor`,
     `Reset ⟲`, audio status caption.
   - **Playback row:** Hands segmented picker (Both / R.H. / L.H.), `Tempo NNN%` + slider (25–120),
     Output picker (🔊 Speakers / 🎹 Piano / Both).
   - **Section row:** "Section" label, from-bar / to-bar steppers, `🔁 Loop`, `Whole piece` reset, and
     a "bars X–Y of N" caption when a sub-section is active.
4. **MIDI input section**
   - Header: "MIDI input" + `🎯 Wait mode` + `🎼 Grade` + mode status + `Show score notes` + MIDI
     connection status.
   - The 88-key `PianoKeyboardView` (fixed **90 pt** tall).
   - Legend caption + (in review) "Clear marks" button.
5. **Diagnostic dump** — score summary (tempo, time signature, key, event count), the per-hand
   reconciliation table (✅/⚠️), and the first 24 note events. Monospaced.

## Colour tokens (as used in code)

| Token | Value | Meaning |
|-------|-------|---------|
| Hand — right | `#1565C0` (blue) | RH noteheads (notation) & RH score notes (keyboard) |
| Hand — left | `#C62828` (red) | LH noteheads (notation) & LH score notes (keyboard) |
| Mistake / missed | `#D32F2F` (red) | Review marks on noteheads |
| You (input) | `Color.green` | Notes you're holding on the MIDI piano / mouse |
| Wrong (Wait/Grade) | `Color.red` | A held note that isn't expected now |
| Cursor | OSMD green highlight | The follow-cursor bar |
| Status – error | `.red` | Error captions |
| Status – normal | `.secondary` / `.green` | Info / positive captions |

White keys use ~0.6 opacity of the above; black keys use full. **Note:** RH-blue / LH-red is not
colour-blind-safe (red-green) — flagged for the design pass.

## Typography

Stock SwiftUI system font throughout. `.title2.bold()` for the screen title, `.headline` for section
headers, `.caption`/`.caption2` for statuses/legends. The diagnostic dump uses
`.system(.body/.footnote, design: .monospaced)`. **No custom type scale or font.**

## Spacing / layout rules

- Root `VStack(spacing: 14)` inside a padded `ScrollView`; sections use `VStack(spacing: 6)`.
- Control rows are `HStack`s of stock buttons/pickers/toggles (`.toggleStyle(.button)` for the mode
  toggles; `.pickerStyle(.segmented)` for hands/piece; menu pickers elsewhere).
- Fixed heights: notation 360 pt, keyboard 90 pt. Widths are flexible/`.fixedSize()` on pickers.
- No spacing/size token system; values are inline literals.

## Interaction & animation patterns

- **Follow-cursor:** driven from the audio clock at ~50 Hz. "Smooth" interpolates the cursor's
  horizontal position between notes; "Step" jumps note-to-note. Both snap at line breaks.
- **Follow-scroll:** when the active line changes, the notation content animates up via a CSS
  transform (0.35 s ease) to keep the active + next line in view.
- **Keyboard:** press/drag plays notes (mouse/touch) via a high-priority drag gesture; MIDI input
  lights keys live.
- **Section select on the score:** click/drag across bars to set the practice loop. A translucent
  blue highlight (rgba(21,101,192,0.13) fill, 0.45 border) marks the range without obscuring the
  notes; it spans multiple systems. "Whole piece" clears it. Stays in sync with the bar steppers.
- **Wait/Grade feedback:** blue (needed / in-window), green (correct held), red (wrong held); Wait-mode
  review marks appear on the score on exit and are removed with "Clear marks".
- **Per-pass grading (Grade + Loop):** misses **ring red progressively** as the cursor passes each note
  you didn't play (open circle, doesn't fill the notehead); the rings **wipe at each loop restart**.
  Each loop shows "Pass N: X% · Missed · Wrong · ±ms" and a "Progress 72→80→87%" accuracy trend.
- **Keyboard shortcut:** Space = Play/Stop.

## Design conventions to preserve

- The web layer is **display only** — never put logic, timing, or state decisions in `index.html`.
- Hand colours are consistent across notation and keyboard (blue = RH, red = LH).
- Feedback is **encouraging** — wrong notes are shown, never block or scold.

## Open Questions

- **No real design system.** This screen must be redesigned into proper flows (library → piece →
  practice) with a defined type scale, spacing tokens, and component set for Phase 1.
- **Colour accessibility:** replace or supplement RH-blue/LH-red with a colour-blind-safe scheme
  (e.g. shape/label cues), and support Dark Mode intentionally (the notation is forced white).
- **iPad layout / touch targets** are unconsidered (built/tested on Mac). The dense single-row
  control strips won't fit or be tappable on iPad.
- **The diagnostic dump** (reconciliation table, event list) is a developer surface — decide whether
  any of it survives into the product or moves behind a debug flag.
