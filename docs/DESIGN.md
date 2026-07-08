# Design — Woodshed

The current UI is a **Phase-0 diagnostic surface**, not a designed product. It's a single dense
screen optimised for proving functionality, using stock SwiftUI controls. This doc records the
conventions that *do* exist and flags that a real design pass is still owed.

## Navigation structure

**None.** One `WindowGroup` → one `ContentView`, a single vertical `ScrollView`. No tabs, no
navigation stack, no sheets/modals. All controls are inline on the one screen.

## Screen inventory (the one screen, top → bottom)

1. **Title** — "Woodshed — Phase 0 ingestion spike".
2. **Piece picker** — segmented; switches between the two bundled fixtures.
3. **Notation section**
   - Header: "Notation (OSMD)" + a live status caption (from the web bridge).
   - The `WKWebView` notation (fixed **360 pt** tall, white background, rounded 8 pt, hairline border).
   - **Transport row:** `▶︎ Play / ◼ Stop` (Space), Count-in picker (No / 1-bar / 2-bar), `🎵 Metronome`,
     `⟿ Smooth / ⇥ Step` cursor toggle, `🎨 Colour hands`, Bars/line picker (Auto / 1–5), `Step cursor`,
     `Reset ⟲`, audio status caption.
   - **Playback row:** Hands segmented picker (Both / R.H. / L.H.), `Tempo NNN%` + slider (25–120),
     Output picker (🔊 Speakers / 🎹 Piano / Both).
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
- **Wait/Grade feedback:** blue (needed / in-window), green (correct held), red (wrong held); review
  marks appear on the score on exit and are removed with "Clear marks".
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
