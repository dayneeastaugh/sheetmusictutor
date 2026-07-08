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

## Open Questions
- Revisit ADR-009 (sandbox) and ADR-010 (sound source) before any iPad build or distribution.
- Resolve ADR-015 (GRDB vs SwiftData) before starting the persistence layer.
