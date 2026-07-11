# Segno — Project Guide & Source of Truth

**Segno** is a native macOS + iPadOS piano-practice tutor: import a score you transcribed in
MuseScore (MusicXML + MIDI), render the notation with a follow-cursor, play it back with per-hand
isolation and tempo control, and practise against a connected MIDI piano with feedback.

> **Naming:** the product/app is **Segno** (what users see — Dock, menu bar, icon). The Xcode
> project, scheme, target, Swift module, and repository folder remain **Woodshed** — an internal
> name only, kept to avoid churn and preserve identity/history (see DECISIONS ADR-037). So in code
> and build commands you'll still see "Woodshed" (e.g. `@testable import Woodshed`, scheme
> `Woodshed`), while the built product is `Segno.app`.

## The rule

The documents under [`/docs`](docs/) are the **single source of truth** for this app's product,
architecture, tech stack, design, and data model. They exist to prevent drift.

- **Read the relevant docs before making changes.**
- **Update them in the same commit/PR** whenever you change design, architecture, tech stack, data
  model, or functionality. Docs and code must not disagree.
- If code and docs disagree, **the code is truth** — fix the doc and note the discrepancy.
- Do not add a dependency, framework, or platform without updating [`docs/TECH_STACK.md`](docs/TECH_STACK.md).
- Record significant choices in [`docs/DECISIONS.md`](docs/DECISIONS.md) (append-only).

## Index

| Doc | What it covers |
|-----|----------------|
| [docs/PRD.md](docs/PRD.md) | Product requirements: problem, users, user stories, functional & non-functional requirements, out-of-scope, success criteria. |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | Modules/layers, data flow, component responsibilities, state management, the WKWebView JS bridge, dependency boundaries. |
| [docs/TECH_STACK.md](docs/TECH_STACK.md) | Definitive stack: Xcode/Swift/SwiftUI versions, platform targets, every dependency + why. |
| [docs/DESIGN.md](docs/DESIGN.md) | Navigation, screen/control inventory, colour/typography tokens, interaction patterns. |
| [docs/DATA_MODEL.md](docs/DATA_MODEL.md) | Entities, relationships, the ingestion→fusion model, persistence (none yet). |
| [docs/INGESTION.md](docs/INGESTION.md) | The core hard problem: MusicXML+MIDI parsing/fusion rules and the findings behind them. |
| [docs/DECISIONS.md](docs/DECISIONS.md) | ADR-style log of key decisions and rejected alternatives. |

## Status (as of this writing)

Phase 0 (vertical-slice prototype) is **complete and working on macOS**: ingestion, notation +
follow-cursor, playback (per-hand, tempo %, PC/piano/both output), a meter-aware metronome, live
MIDI input + on-screen keyboard, and first cuts of **Wait mode** and **Tempo/Grade mode** matching.
The app currently has **no persistence** and runs **sandbox-off**. See each doc's `## Open Questions`.

## Build & run

Open `Woodshed.xcodeproj` in Xcode, scheme **Woodshed**, destination **My Mac**, ⌘R — this builds
and runs **Segno.app**. Files live in a folder-synced group (`Woodshed/`) — dropping a file into
that folder adds it to the target automatically. There is no package resolution step (no SPM
dependencies).
