# Open questions for the author

Decisions or facts the audit could not settle from the code. Recommendations included where I have
one.

1. **Does your repertoire use repeats, voltas, or D.C./D.S.?** This single answer sets MUSIC-01's
   priority. If yes → the Wave 0 warning is urgent and the Wave 4 unfold work should be promoted;
   if your transcriptions are through-composed exports, it can stay a guarded edge.
   *Recommendation: answer by doing the Wave 1 real-score triage — import 5–10 of your pieces and
   read the reconciliation banner.*

2. **The stop-time crash from 2026-07-11** — still unreproduced and unsymbolicated. The disassembly
   you pasted had no app frames; the 50 Hz churn since removed is a plausible-but-unproven cause.
   *Needed: if it recurs, the `EXC_BAD_ACCESS` line + topmost Woodshed frames from Xcode's Debug
   navigator. Until then it stays an open item, not a closed fix.*

3. **Distribution intent** — personal Developer-ID forever, or possible App Store someday? Decides
   whether re-enabling the App Sandbox (ADR-009) and removing the `drawsBackground` KVC (ARCH-10)
   ever become real work.
   *Recommendation: assume personal; revisit only on a concrete trigger.*

4. **iPad SoundFont budget** — bundling a decent piano `.sf2` costs ~10–150 MB depending on
   quality. What app size is acceptable? (Affects Wave 3 item 2.)
   *Recommendation: a compact GM piano (~20–30 MB) first; upgrade only if it sounds bad on iPad
   speakers/headphones.*

5. **Grade tolerance semantics** — the current ±300 ms is *musical* time (window widens in wall-
   clock terms as you slow the tempo). Keep that behaviour and expose it, or switch to wall-clock
   with an explicit tempo curve? (MUSIC-06 implementation choice.)
   *Recommendation: keep musical-time as the base (it matches the clock everywhere else), expose
   the constant, add the early/late split.*

6. **Wait-mode chord semantics** — currently a chord may be assembled note-by-note in any order,
   extras never block, and *held* wrong notes flag red. Is "all notes down together" (stricter
   simultaneity) ever wanted as an option?
   *Recommendation: leave as is — the accumulative behaviour matches the generous principle.*

7. **Fumble definition** (MUSIC-07): when you slip on a chord, do you want the review mark on the
   chord you were attempting (current), the wrong note you actually played, or both?
   *Recommendation: both — mark the attempted chord, annotate with the played pitch.*

8. **What counts as a "pass" for the trend** — today all graded passes (any section, any tempo, any
   hands) share one trend line. As history grows, should Progress filter/split by context?
   *Recommendation: yes, eventually — group by (section, hands), annotate tempo; defer until it
   annoys you.*

9. **`bestAccuracy` semantics** — full-piece runs only (by design, undocumented in UI). Keep, or
   also track per-section bests for the mastery workflow?
   *Recommendation: keep as is until hands-gating lands, then revisit alongside it.*

10. **Keyboard rewrite consent** — closing the trill-lag complaint properly means rewriting
    `PianoKeyboardView` as a `Canvas` (ARCH-02) plus the tick-loop indexing (ARCH-01). Both are
    behaviour-preserving but non-trivial diffs to review.
    *Recommendation: do both in Wave 1; they're the fix.*

11. **Swift 6 appetite** — adopt `@MainActor`/strict concurrency incrementally during the matcher
    extraction, or stay in Swift 5 mode indefinitely?
    *Recommendation: incremental adoption starting Wave 2; never a flag-day.*
