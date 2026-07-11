# Woodshed audit — executive summary

**Audit date:** 2026-07-11 · **Tree state:** commit `219a390` + uncommitted work (revisit flags,
speed trainer, sync start, keyboard-perf changes). Read-only; no code was modified.

## The honest headline

Woodshed is **much further along than its own docs admit** — a working practice tool, not a spike.
The core loop (pick a song → follow the score → loop a section → get graded → see progress) exists
end-to-end, the architecture has a real separation between a pure ingestion layer, engine services,
a view-model, and thin views, and the on-disk design (per-song folders, append-only history) is
sound and appropriately boring. The strongest asset is the **design discipline recorded in
`/docs`** — decisions have rationale, docs match code unusually well, and the "MIDI = timing truth,
MusicXML = identity" fusion model is genuinely good thinking.

What it is **not** yet: validated against real-world scores, tested, or safe at its edges. Every
line of the highest-consequence code (two hand-rolled parsers + the fusion + the matcher) has
**zero committed tests**, has only ever been exercised against the two bundled fixtures, and has at
least one crash-on-corrupt-input path and one silent-wrong-model path (repeats). The performance of
the 50 Hz practice loop is the direct cause of the still-open "keyboard can't keep up with trills"
complaint. None of this is structural rot — it is deferred hardening, and it's all fixable in
place.

## Top 5 things that matter most (in order)

1. **A piece with repeats/voltas will be silently mis-modelled** (MUSIC-01). The MusicXML beat
   timeline is folded, the MIDI is unfolded; after the first repeat, alignment collapses. The
   reconciliation report *would* show it — but it's now hidden in a debug sheet (UX-01). This is
   the "teaches wrong practice" class of bug, on the app's make-or-break assumption (your own
   MuseScore exports).
2. **A corrupt or truncated `.mid` import crashes the app** (MUSIC-02). The hand-rolled byte reader
   has no bounds checking. One bad file → crash on import, every time.
3. **The 50 Hz tick does O(n) work four times over, on the main thread** (ARCH-01), and the
   keyboard is ~140 diffed SwiftUI views (ARCH-02). This — not the publish path already fixed — is
   the remaining cause of the trill/turn display lag you're still seeing.
4. **Zero tests on the music-domain core** (QUAL-01). The parsers, fusion, matcher, and drill logic
   are pure and trivially testable — several were verified with throwaway harnesses during
   development that were never committed. The PRD's stated make-or-break (parsing *your* real
   exports) has never been exercised beyond two fixtures.
5. **The library can silently lose a song's visibility** (QUAL-03): metadata writes are non-atomic
   and the library scan silently skips any folder whose `metadata.json` doesn't decode.

## The single biggest risk

**Unvalidated ingestion presented with silent confidence.** The app *looks* authoritative — cursor
moves, grading scores, trouble bars glow — even when the underlying model is wrong (repeats,
multi-part files, grace-note mismatches). The reconciliation check that was designed as the safety
net (a genuinely good idea) has been moved out of sight. If you import a real piece from your own
repertoire that hits one of these gaps, the app will confidently grade you against a wrong model —
the exact demoralising-tool failure the PRD names as the thing to avoid.

## What is genuinely good and should be preserved

- **The fusion model** (MIDI timing + XML identity, ornament absorption, beat-based alignment) —
  the domain thinking here is right, and INGESTION.md explaining *why* each rule exists is rare.
- **The docs-as-source-of-truth discipline** (ADR log, per-doc open questions, docs updated with
  code). Keep this exactly as is.
- **Layering direction**: pure ingestion (Foundation-only) / engine services (one framework each) /
  view-model / thin views. The seams are real even where the view-model has grown fat.
- **The web layer stayed dumb** — display only, Swift owns clock and state, exactly per design.
- **File-based persistence** (per-song folders, append-only JSONL history) — resilient, portable,
  right-sized for a single-user tool. Don't reach for a database yet.
- **Zero dependencies, fully offline** — verified: no network calls anywhere in app code.

## Bottom line

State: a **capable v0.5** with excellent bones and unhardened edges. The fastest path to "this tool
made my practice better" is not more features — it's Wave 0 + Wave 1 of the roadmap
(`04-roadmap.md`): stop the crash/data-loss/wrong-model edges, put a real test harness under the
music core with your *own* scores as fixtures, and fix the practice-loop performance so feedback is
instant. After that, the feature backlog (hands gating, iPad, UI restructure) sits on solid ground.
