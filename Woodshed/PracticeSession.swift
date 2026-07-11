//
//  PracticeSession.swift
//  Woodshed
//
//  The practice screen's view-model. Owns the fused score, the three engines
//  (audio / MIDI / notation bridge), and all practice-mode logic (playback +
//  cursor sync, section looping, Wait mode, Grade mode). `PracticeView` is a thin
//  SwiftUI layer that binds to this — extracted from a ~630-line view monolith so
//  the matching/playback logic is UI-decoupled and the upcoming Mac/iPad redesign
//  only has to touch presentation. See docs/ARCHITECTURE.md.
//

import Foundation
import Combine

/// The score-note highlight for the on-screen keyboard, in its own `ObservableObject`
/// so ~50 Hz playback updates repaint only the keyboard — never the whole practice
/// screen. `set` skips no-op writes so identical frames don't publish.
final class KeyboardLights: ObservableObject {
    @Published var rh: Set<Int> = []
    @Published var lh: Set<Int> = []

    func set(rh newRH: Set<Int>, lh newLH: Set<Int>) {
        if newRH != rh { rh = newRH }
        if newLH != lh { lh = newLH }
    }
    func clear() { set(rh: [], lh: []) }
}

final class PracticeSession: ObservableObject {
    let song: Song

    // The engines this session drives. Owned here (not in the view) so all logic
    // lives in one place; the view observes them via the forwarding below.
    let audio = AudioEnginePlayer()
    let midi = MIDIInput()
    let bridge = NotationBridge()

    // MARK: Model
    @Published var score: FusedScore?
    @Published var errorText: String?
    @Published var xmlBase64 = ""
    @Published var cursorCommand = CursorCommand()

    // MARK: Cursor-sync state
    // A schedule of (playback time → notated beat). The tick reads the audio clock
    // and moves the OSMD cursor to the matching beat.
    private var schedule: [(time: Double, beat: Double)] = []
    private var scoreDuration: Double = 0
    @Published var cursorSmooth = true          // smooth glide vs. discrete note-to-note
    @Published var colorHands = false {         // colour noteheads by hand (RH blue / LH red)
        didSet { bridge.setHandColors(colorHands) }
    }
    @Published var barsPerLine = 0 {            // measures per line/system (0 = auto)
        didSet {
            bridge.setMeasuresPerSystem(barsPerLine)
            if !loadingLayout { onSaveBarsPerLine?(barsPerLine) }   // persist user changes, not the initial load
        }
    }
    /// Persist the measures-per-system choice for this song. Set by the view.
    var onSaveBarsPerLine: ((Int) -> Void)?
    /// Called when the user taps a flag marker on the score, so the view can edit it.
    var onFlagTapped: ((Int) -> Void)?
    private var loadingLayout = false           // true while applying the saved value on open

    // MARK: Section practice — play/loop a bar range instead of the whole piece.
    @Published var sectionStart = 1 {           // first bar (1-based)
        didSet {
            if sectionEnd < sectionStart { sectionEnd = sectionStart }
            onSectionChanged()
        }
    }
    @Published var sectionEnd = 1 {             // last bar (inclusive)
        didSet { onSectionChanged() }
    }
    @Published var loopSection = false          // repeat the section
    @Published var loopCountInPulses = 0        // count-in beats before each loop pass (0 = off)
    private var lastDiscreteBeat: Double = -1

    /// Beats (metronome pulses) in a bar, for the loop count-in choices (meter-aware).
    var pulsesPerBar: Int { max(1, score?.metronomeBarPattern.count ?? 4) }

    // MARK: Speed trainer / mastery — an auto-tempo drill on a looped section (Grade mode).
    // After each graded loop pass the tempo ramps toward the target; "by accuracy" only
    // counts passes that clear the threshold (the mastery gate). Reaching the target with
    // its clean passes marks the section mastered and stops the drill.
    enum SpeedTrainerMode: Int, CaseIterable, Identifiable {
        case off, byReps, byAccuracy
        var id: Int { rawValue }
        var title: String {
            switch self { case .off: return "Off"; case .byReps: return "By reps"; case .byAccuracy: return "By accuracy" }
        }
    }
    @Published var speedMode: SpeedTrainerMode = .off {
        didSet {
            if speedMode != .off {                 // it's a graded, looped drill — set that up
                if !gradeMode { setGradeMode(true) }
                loopSection = true
            }
            resetDrill()
        }
    }
    @Published var speedTargetPct: Double = 100    // ramp up to here
    @Published var speedStepPct: Double = 5        // tempo increment per advance
    @Published var speedThreshold: Double = 0.9    // accuracy for a "clean" pass (byAccuracy)
    @Published var speedPassesPerStep = 2          // passes needed to advance one step
    @Published private(set) var passesAtThisTempo = 0
    @Published private(set) var mastered = false

    private func resetDrill() { passesAtThisTempo = 0; mastered = false }

    /// After a graded loop pass, ramp the tempo toward the target per the trainer rule.
    private func applySpeedTrainer(accuracy: Double) {
        guard speedMode != .off, loopSection else { return }
        let next = Self.drillAdvance(mode: speedMode, accuracy: accuracy, threshold: speedThreshold,
                                     passesPerStep: speedPassesPerStep, passes: passesAtThisTempo,
                                     tempoPct: tempoPct, target: speedTargetPct, step: speedStepPct, mastered: mastered)
        passesAtThisTempo = next.passes
        if next.tempoPct != tempoPct { tempoPct = next.tempoPct }   // didSet → audio.setRate; slider follows
        mastered = next.mastered
    }

    /// Pure state transition for one graded pass — no engine/UI refs, so it's unit-testable.
    /// "By reps" advances every N passes; "by accuracy" only counts passes ≥ threshold (a
    /// below-threshold pass resets the streak — the mastery gate). N passes at the target
    /// marks it mastered.
    struct DrillState: Equatable { var passes: Int; var tempoPct: Double; var mastered: Bool }
    static func drillAdvance(mode: SpeedTrainerMode, accuracy: Double, threshold: Double,
                             passesPerStep: Int, passes: Int, tempoPct: Double,
                             target: Double, step: Double, mastered: Bool) -> DrillState {
        guard mode != .off, !mastered else { return DrillState(passes: passes, tempoPct: tempoPct, mastered: mastered) }
        let clean = (mode == .byReps) ? true : accuracy >= threshold
        var p = clean ? passes + 1 : 0
        var tempo = tempoPct
        var done = mastered
        if p >= passesPerStep {
            p = 0
            if tempoPct < target { tempo = min(target, tempoPct + step) } else { done = true }
        }
        return DrillState(passes: p, tempoPct: tempo, mastered: done)
    }

    // MARK: Transport / playback
    @Published var countInBars = 0             // 0 = off, else bars of count-in before Play
    // Start behaviour
    @Published var startOnFirstNote = false    // Play arms; your first note starts playback in sync
    @Published private(set) var armed = false  // armed + waiting for your first note
    // Metronome behaviour
    @Published var metronomeStartsWithPlayback = false   // turn the metronome on when playback starts
    @Published var metronomeStopsWithPlayback = false {  // silence the metronome when playback stops
        didSet { audio.metronomeFreeRuns = !metronomeStopsWithPlayback }
    }
    @Published var handMode = 0 {              // 0 = both, 1 = RH only, 2 = LH only
        didSet { applyHands() }
    }
    @Published var tempoPct: Double = 100 {     // playback tempo percentage
        didSet { audio.setRate(Float(tempoPct) / 100) }
    }
    @Published var outputMode = 0 {            // 0 = PC speakers, 1 = piano, 2 = both
        didSet { applyOutput() }
    }

    // MARK: Keyboard highlight
    // The score-note highlight lives in its own object (not @Published on the session)
    // so updating it every note during playback repaints ONLY the keyboard, not the
    // whole practice screen — otherwise fast passages/trills lag and thrash the UI.
    let lights = KeyboardLights()
    @Published var showScoreNotes = true        // light up score notes during playback
    private var pianoSounding: Set<Int> = []    // notes currently sent to the piano (MIDI out)

    // MARK: Wait mode — step through the score, advancing only on the right notes.
    @Published var waitMode = false
    @Published private(set) var waitStepCount = 0
    @Published private(set) var waitIndex = 0
    @Published private(set) var mistakeCount = 0
    @Published var mistakesShown = false        // mistakes currently marked red on the score
    private var waitSteps: [(beat: Double, rh: Set<Int>, lh: Set<Int>)] = []
    private var waitPlayed: Set<Int> = []       // note-ons accumulated for the current step
    private var mistakes: Set<Mistake> = []     // notes at steps where a wrong note was played

    /// A fumbled/missed note position, for the review marks.
    private struct Mistake: Hashable { let beat: Double; let pitch: Int }

    // MARK: Tempo/grade mode — play along at tempo; grade the pass afterwards.
    @Published var gradeMode = false
    @Published var gradeResult: GradeResult?
    @Published var gradeHistory: [GradeResult] = []   // one entry per pass this session (progress)
    // Real-time grading state for the current pass:
    private var gradeExpected: [(pitch: Int, onset: Double, beat: Double, matched: Bool)] = []
    private var gradeMissed: Set<Mistake> = []   // notes already flagged missed (ringed) this pass
    private var gradeCheckIdx = 0                // expected notes up to here have had their window close
    private var gradeHits = 0
    private var gradeWrong = 0
    private var gradeTiming: [Double] = []       // |timing error| of hits
    private var gradePassRecorded = false        // this pass already tallied? (avoid double-recording)
    private let gradeTolerance = 0.30   // musical seconds; a note counts if within this of expected

    struct GradeResult {
        var accuracy: Double   // hits / expected
        var hits: Int
        var total: Int
        var missed: Int
        var extra: Int         // notes you played that matched nothing
        var avgMs: Double      // mean absolute timing error of hits
    }

    /// Called when a Grade pass is tallied, so the library can persist it (history +
    /// derived stats). Set by the view; keeps this class free of the library type.
    var onPassRecorded: ((PracticePass) -> Void)?

    // MARK: Manual revisit flags (user notes pinned to bars)
    @Published private(set) var flags: [BarFlag] = []

    // MARK: Progress / trouble spots
    @Published private(set) var history: [PracticePass] = []   // this song's recorded passes
    @Published var showTroubleOnScore = true {                 // amber-tint trouble bars on the score
        didSet { refreshTroubleOverlay() }
    }
    /// Bars that still need work ("clear as you improve"), derived from `history`.
    var currentTroubleBars: [TroubleBar] { PracticeHistory.currentTroubleBars(history) }

    private var cancellables: Set<AnyCancellable> = []
    private var lastActiveNotes: Set<Int> = []

    init(song: Song) {
        self.song = song
        // Nested ObservableObjects don't propagate, so re-broadcast the engines'
        // changes as ours — the view observes only this session. NOTE: `midi` is
        // deliberately excluded — its `activeNotes` change on every key press, and
        // re-rendering the whole practice screen per note made the keyboard lag on
        // fast passages. The keyboard observes `midi` directly; input is handled by
        // the subscription below.
        for obj in [audio.objectWillChange, bridge.objectWillChange] {
            obj.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        }
        midi.$activeNotes
            .dropFirst()
            .sink { [weak self] new in
                guard let self else { return }
                let old = self.lastActiveNotes
                self.lastActiveNotes = new
                self.midiNotesChanged(old, new)
            }
            .store(in: &cancellables)
        // Apply per-song layout (saved bars-per-line) + the trouble overlay once the
        // notation reports it has rendered (the JS isn't there to receive it before then).
        bridge.$status
            .filter { $0.hasPrefix("loaded") }
            .sink { [weak self] _ in self?.applyPersistedLayoutToNotation() }
            .store(in: &cancellables)
    }

    /// After the score first renders, apply the remembered measures-per-system and the
    /// trouble overlay (both need the page's JS to exist and a score to be loaded).
    private func applyPersistedLayoutToNotation() {
        if barsPerLine != 0 { bridge.setMeasuresPerSystem(barsPerLine) }
        refreshTroubleOverlay()
        refreshFlagOverlay()
    }

    private func refreshFlagOverlay() {
        bridge.setFlaggedBars(flags.map { $0.bar })
    }

    /// Wire up engine callbacks and fuse the score. Called from the view's `onAppear`.
    func onAppear() {
        audio.pianoClick = { [weak self] level in self?.midi.sendClick(level) }
        bridge.onSelect = { [weak self] start, end in self?.sectionStart = start; self?.sectionEnd = end }
        bridge.onFlagTap = { [weak self] bar in self?.onFlagTapped?(bar) }
        applyOutput()
        ingest()
        reloadHistory()
        flags = BarFlagStore.load(from: song.folder)
        refreshFlagOverlay()
        loadingLayout = true                      // apply the remembered layout without re-saving it
        barsPerLine = song.meta.barsPerLine ?? 0
        loadingLayout = false
    }

    // MARK: - Manual revisit flags

    /// A default bar to flag from a quick "flag this bar" action — the section start.
    var currentBar: Int { sectionStart }

    func flagNote(forBar bar: Int) -> String? { flags.first { $0.bar == bar }?.note }

    /// Pin/replace a note on a bar. An empty note removes the flag.
    func setFlag(bar: Int, note: String) {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        flags.removeAll { $0.bar == bar }
        if !trimmed.isEmpty { flags.append(BarFlag(bar: bar, note: trimmed)) }
        flags.sort { $0.bar < $1.bar }
        BarFlagStore.save(flags, to: song.folder)
        refreshFlagOverlay()
    }

    func removeFlag(bar: Int) {
        flags.removeAll { $0.bar == bar }
        BarFlagStore.save(flags, to: song.folder)
        refreshFlagOverlay()
    }

    /// (Re)load this song's recorded history from disk and refresh the trouble overlay.
    func reloadHistory() {
        history = PracticeHistory.load(from: song.folder)
        refreshTroubleOverlay()
    }

    /// Push the current trouble bars to the score (or clear them if the toggle is off).
    private func refreshTroubleOverlay() {
        guard showTroubleOnScore else { bridge.clearTroubleBars(); return }
        bridge.setTroubleBars(currentTroubleBars.map(\.bar))
    }

    // MARK: - Practice mode (unified selector)

    /// The three mutually-exclusive practice modes, surfaced as one segmented control.
    enum PracticeMode: Int, CaseIterable, Identifiable {
        case practice, wait, grade
        var id: Int { rawValue }
        var title: String {
            switch self { case .practice: return "Practice"; case .wait: return "Wait"; case .grade: return "Grade" }
        }
    }

    /// Current mode derived from the two underlying flags; setting it routes through
    /// the existing enter/exit logic (which keeps Wait and Grade mutually exclusive).
    var practiceMode: PracticeMode {
        get { waitMode ? .wait : (gradeMode ? .grade : .practice) }
        set {
            switch newValue {
            case .practice:
                if waitMode { setWaitMode(false) }
                if gradeMode { setGradeMode(false) }
            case .wait:  setWaitMode(true)   // also clears Grade
            case .grade: setGradeMode(true)  // also clears Wait
            }
        }
    }

    // MARK: - Tempo (grade) mode

    /// Toggle grade mode. Mutually exclusive with Wait mode.
    func setGradeMode(_ on: Bool) {
        armed = false
        if on {
            if waitMode { setWaitMode(false) }
            gradeMode = true
            gradeResult = nil; gradeHistory = []
            startGradePass()
        } else {
            gradeMode = false
            gradeResult = nil; gradeHistory = []
            bridge.clearMissed()
        }
    }

    /// The section's expected notes (selected hands), sorted by onset, for grading.
    private func buildGradeExpected() -> [(pitch: Int, onset: Double, beat: Double, matched: Bool)] {
        guard let events = score?.events else { return [] }
        let rhOn = handMode != 2, lhOn = handMode != 1
        return events
            .filter { (($0.hand == .left) ? lhOn : rhOn) && inSection($0.notatedBeat) }
            .map { (pitch: $0.pitch, onset: $0.onsetSeconds, beat: $0.notatedBeat, matched: false) }
            .sorted { $0.onset < $1.onset }
    }

    /// Begin a fresh grading pass (Play start / each loop): reset tallies, wipe rings.
    private func startGradePass() {
        gradeExpected = buildGradeExpected()
        gradeMissed = []; gradeCheckIdx = 0; gradeHits = 0; gradeWrong = 0; gradeTiming = []
        gradePassRecorded = false
        bridge.markMissed([])
    }

    /// A note-on during a graded pass: match it to the nearest expected note (same
    /// pitch, within tolerance of now) → hit; otherwise it's a wrong/extra note.
    private func handleGradeNoteOn(_ added: Set<Int>) {
        let t = audio.currentTime
        for p in added {
            var best = -1, bestD = gradeTolerance + 1
            for i in gradeExpected.indices where !gradeExpected[i].matched && gradeExpected[i].pitch == p {
                let d = abs(gradeExpected[i].onset - t)
                if d <= gradeTolerance && d < bestD { bestD = d; best = i }
            }
            if best >= 0 {
                gradeExpected[best].matched = true; gradeHits += 1; gradeTiming.append(bestD)
            } else {
                gradeWrong += 1
            }
        }
    }

    /// On each tick, ring any expected note whose window has now closed unmatched —
    /// so misses appear progressively as the cursor passes them.
    private func advanceGradeMisses(_ t: Double) {
        var changed = false
        while gradeCheckIdx < gradeExpected.count && gradeExpected[gradeCheckIdx].onset + gradeTolerance < t {
            let e = gradeExpected[gradeCheckIdx]
            if !e.matched { gradeMissed.insert(Mistake(beat: e.beat, pitch: e.pitch)); changed = true }
            gradeCheckIdx += 1
        }
        if changed { bridge.markMissed(gradeMissed.map { (beat: $0.beat, pitch: $0.pitch) }) }
    }

    /// Tally the finished pass into the progress history and persist it. Idempotent:
    /// a pass is recorded at most once (completion), never again when playback stops.
    private func finalizeGradePass() {
        let total = gradeExpected.count
        guard total > 0, !gradePassRecorded else { return }
        gradePassRecorded = true
        let missed = gradeExpected.filter { !$0.matched }.count
        let avgMs = gradeTiming.isEmpty ? 0 : gradeTiming.reduce(0, +) / Double(gradeTiming.count) * 1000
        let r = GradeResult(accuracy: Double(gradeHits) / Double(total),
                            hits: gradeHits, total: total, missed: missed, extra: gradeWrong, avgMs: avgMs)
        gradeResult = r
        gradeHistory.append(r)

        let pass = PracticePass(sectionStart: sectionStart, sectionEnd: sectionEnd, measureCount: measureCount,
                                tempoPct: tempoPct, handMode: handMode,
                                total: total, hits: gradeHits, missed: missed, wrong: gradeWrong, avgMs: avgMs,
                                missedBars: gradeExpected.filter { !$0.matched }.map { barForBeat($0.beat) })
        onPassRecorded?(pass)          // persist (disk + library stats)
        history.append(pass)           // mirror in memory for progress + trouble overlay
        refreshTroubleOverlay()        // a cleaned bar drops off; a newly-missed one lights up
        applySpeedTrainer(accuracy: r.accuracy)   // ramp tempo / gate mastery for the next pass
    }

    /// The 1-based bar containing a notated beat (via the measure start-beat table).
    private func barForBeat(_ beat: Double) -> Int {
        guard let m = score?.measureStartBeats else { return sectionStart }
        var bar = 1
        for i in m.indices where m[i] <= beat + 0.0001 { bar = i + 1 }
        return bar
    }

    // MARK: - Wait mode

    /// Turn Wait mode on/off. On: stop playback, build the step list (per selected
    /// hands), and park on the first note. Off: clear and reset the cursor.
    func setWaitMode(_ on: Bool) {
        armed = false
        waitMode = on
        if on {
            gradeMode = false; gradeResult = nil
            audio.stop()
            mistakes = []; mistakeCount = 0; mistakesShown = false
            bridge.clearMistakes()
            waitSteps = buildWaitSteps(); waitStepCount = waitSteps.count
            waitIndex = 0
            if waitSteps.isEmpty { waitMode = false; return }
            showWaitStep(0)
        } else {
            lights.rh = []; lights.lh = []
            // On exit, mark the fumbled notes red on the score for review.
            if !mistakes.isEmpty {
                bridge.markMistakes(mistakes.map { (beat: $0.beat, pitch: $0.pitch) })
                mistakesShown = true
            } else {
                resetCursor()
            }
        }
    }

    func clearMistakeMarks() {
        bridge.clearMistakes()
        mistakes = []; mistakeCount = 0
        mistakesShown = false
        resetCursor()
    }

    /// Group the score into steps (one per notated beat that has notes for the
    /// selected hands), each carrying the required RH/LH pitches.
    private func buildWaitSteps() -> [(beat: Double, rh: Set<Int>, lh: Set<Int>)] {
        guard let events = score?.events else { return [] }
        let rhOn = handMode != 2, lhOn = handMode != 1
        var map: [Int: (beat: Double, rh: Set<Int>, lh: Set<Int>)] = [:]
        for e in events {
            let isLeft = e.hand == .left
            if isLeft ? !lhOn : !rhOn { continue }
            if !inSection(e.notatedBeat) { continue }   // scope Wait mode to the section
            let key = Int((e.notatedBeat * 100).rounded())
            var entry = map[key] ?? (beat: e.notatedBeat, rh: [], lh: [])
            if isLeft { entry.lh.insert(e.pitch) } else { entry.rh.insert(e.pitch) }
            map[key] = entry
        }
        return map.values.sorted { $0.beat < $1.beat }
    }

    /// Park the cursor on step `i` and show ALL its required notes on the keyboard
    /// (blue = still needed). The set shrinks as you play the right notes.
    private func showWaitStep(_ i: Int) {
        guard i < waitSteps.count else { return }
        waitPlayed = []
        let s = waitSteps[i]
        bridge.seek(s.beat)
        lights.rh = s.rh.union(s.lh)
        lights.lh = []
    }

    /// A note-on arrived: record it, update what's still missing, and advance once
    /// every required note has been played. Wrong/extra notes don't block (they show
    /// red on the keyboard while held).
    private func handleWaitInput(_ added: Set<Int>) {
        guard waitIndex < waitSteps.count else { return }
        waitPlayed.formUnion(added)
        let required = waitSteps[waitIndex].rh.union(waitSteps[waitIndex].lh)
        // Any note that isn't wanted at this step is a fumble — record the step's
        // notes so they can be reviewed (marked red) afterwards.
        if !added.subtracting(required).isEmpty {
            let beat = waitSteps[waitIndex].beat
            for p in required { mistakes.insert(Mistake(beat: beat, pitch: p)) }
            mistakeCount = mistakes.count
        }
        if required.isSubset(of: waitPlayed) {
            waitIndex += 1
            if waitIndex < waitSteps.count {
                showWaitStep(waitIndex)
            } else {
                lights.rh = []; lights.lh = []   // reached the end
            }
        } else {
            lights.rh = required.subtracting(waitPlayed)   // only the still-missing notes
        }
    }

    /// Apply the audio-output selection to both playback and the metronome:
    /// PC speakers audible unless "Piano" only; piano (MIDI) used for "Piano"/"Both".
    private func applyOutput() {
        audio.setSpeakerOutput(outputMode != 1)
        audio.setMetronomeOutput(speakers: outputMode != 1, piano: outputMode != 0)
        if outputMode == 0 { flushPianoOutput() }   // leaving piano output → release notes
    }

    private func flushPianoOutput() {
        for n in pianoSounding { midi.sendNoteOff(n) }
        if !pianoSounding.isEmpty { midi.allNotesOff() }
        pianoSounding = []
    }

    // MARK: - Section practice

    var measureCount: Int { max(1, score?.measureStartBeats.count ?? 1) }

    /// Notated beat where the section begins.
    private var sectionStartBeat: Double {
        guard let m = score?.measureStartBeats, sectionStart - 1 < m.count, sectionStart >= 1 else { return 0 }
        return m[sectionStart - 1]
    }
    /// Notated beat where the section ends (start of the bar after `sectionEnd`, or end of piece).
    private var sectionEndBeat: Double {
        guard let s = score else { return 0 }
        return sectionEnd < s.measureStartBeats.count ? s.measureStartBeats[sectionEnd] : s.totalBeats
    }
    private var sectionStartTime: Double { score?.secondsAtBeat(sectionStartBeat) ?? 0 }
    private var sectionEndTime: Double { score?.secondsAtBeat(sectionEndBeat) ?? scoreDuration }
    var isFullPiece: Bool { sectionStart <= 1 && sectionEnd >= measureCount }

    /// Is a notated beat inside the current section? (Used to scope Wait/Grade.)
    private func inSection(_ beat: Double) -> Bool {
        beat >= sectionStartBeat - 0.001 && beat < sectionEndBeat - 0.001
    }

    /// React to a section change: update the on-score highlight, rebuild Wait steps,
    /// or preview the cursor there.
    private func onSectionChanged() {
        if audio.isPlaying { audio.clickCeiling = sectionEndTime }   // keep the loop click boundary current
        if speedMode != .off { resetDrill() }                       // a new section restarts the drill
        if isFullPiece { bridge.clearSelection() } else { bridge.setSelection(sectionStart, sectionEnd) }
        if waitMode {
            waitSteps = buildWaitSteps(); waitStepCount = waitSteps.count; waitIndex = 0
            if waitSteps.isEmpty { setWaitMode(false) } else { showWaitStep(0) }
        } else if !audio.isPlaying {
            bridge.seek(sectionStartBeat)   // jump the cursor to the section start as a preview
        }
    }

    /// Reset the section to the whole piece.
    func selectWholePiece() {
        sectionStart = 1; sectionEnd = measureCount
    }

    /// Focus the section on a single bar (used to drill a trouble spot from Progress).
    func focusBar(_ bar: Int) {
        let b = min(max(1, bar), measureCount)
        sectionStart = b
        sectionEnd = b
    }

    /// Apply the RH/LH selection to the audio engine (mute = 0 volume).
    private func applyHands() {
        audio.setHands(rhAudible: handMode != 2, lhAudible: handMode != 1)
        if waitMode {                       // rebuild the step list for the new hands
            waitSteps = buildWaitSteps(); waitStepCount = waitSteps.count
            waitIndex = 0
            if waitSteps.isEmpty { setWaitMode(false) } else { showWaitStep(0) }
        }
    }

    // MARK: - On-screen keyboard preview

    /// Play a note pressed on the on-screen keyboard, honouring the output routing:
    /// the internal sampler for Speakers, the external piano (MIDI out) for Piano —
    /// both for Both. Without this, tapping the keyboard is silent under Piano output
    /// (the sampler is muted and nothing was sent to the piano).
    func previewNoteOn(_ pitch: Int) {
        if outputMode != 1 { audio.playNote(pitch) }        // speakers (0) or both (2)
        if outputMode != 0 { midi.sendNoteOn(pitch) }       // piano (1) or both (2)
    }

    func previewNoteOff(_ pitch: Int) {
        if outputMode != 1 { audio.stopNote(pitch) }
        if outputMode != 0 { midi.sendNoteOff(pitch) }
    }

    // MARK: - MIDI input events (wired from the view's onChange)

    /// A change in held MIDI notes: dispatch newly-pressed notes to the active mode.
    func midiNotesChanged(_ old: Set<Int>, _ new: Set<Int>) {
        let added = new.subtracting(old)
        if added.isEmpty { return }
        if armed {                                   // sync start: your first note starts playback now
            armed = false
            startPlayback(countIn: 0)                // immediate — your note IS the downbeat
        }
        if waitMode { handleWaitInput(added) }
        if gradeMode, audio.isRunning { handleGradeNoteOn(added) }   // isRunning is true right after startPlayback
    }

    /// Playback started/stopped: in Grade mode a stop tallies the final (partial) pass.
    func playingChanged(_ was: Bool, _ now: Bool) {
        guard was && !now && gradeMode else { return }
        // Only count a pass that actually reached the section end. Completion already
        // records it (idempotently); this catches the case where the sequencer ends on
        // its own before the tick sees it. Stopping early abandons the partial pass.
        if audio.currentTime + 0.15 >= sectionEndTime { finalizeGradePass() }
    }

    // MARK: - Playback + cursor sync

    func setMetronome(_ on: Bool) { audio.setMetronome(on) }

    func stepCursor() { cursorCommand = .init(nonce: cursorCommand.nonce + 1, action: "next") }

    func togglePlay() {
        if audio.isPlaying {
            audio.stop()
        } else if armed {
            armed = false                            // pressing Play again cancels the "waiting" state
        } else if startOnFirstNote {
            armed = true                             // wait for the first note; the tick idles meanwhile
        } else {
            startPlayback(countIn: countInBars)
        }
    }

    /// Actually begin playback from the section start (used by Play and by sync-start).
    private func startPlayback(countIn: Int) {
        if gradeMode {   // fresh practice session: reset progress + start a pass
            gradeResult = nil; gradeHistory = []
            startGradePass()
        }
        if speedMode != .off { resetDrill() }        // a fresh Play restarts the drill from the current tempo
        resetCursor()
        audio.startSeconds = sectionStartTime        // play from the section start
        audio.clickCeiling = sectionEndTime          // don't click the bar past the section (loop point)
        if metronomeStartsWithPlayback && !audio.metronomeOn { audio.metronomeOn = true }
        audio.play(countInBars: countIn)
    }

    func resetCursor() {
        lastDiscreteBeat = -1
        cursorCommand = .init(nonce: cursorCommand.nonce + 1, action: "reset")
    }

    /// On each timer tick, advance the cursor to where the playback clock is.
    /// Smooth mode interpolates a continuous beat (fluid glide); step mode jumps to
    /// the latest note's exact notated beat when it changes.
    func advanceCursorWithPlayback() {
        guard audio.isPlaying else {
            // In Wait mode the keyboard shows the required notes — don't clear them.
            if !waitMode {
                if !lights.rh.isEmpty { lights.rh = [] }
                if !lights.lh.isEmpty { lights.lh = [] }
            }
            flushPianoOutput()
            return
        }
        guard audio.isRunning else { return }   // counting in — don't follow/emit notes yet
        let t = audio.currentTime
        // Reached the end of the section (or piece): loop it, or stop.
        // For a count-in loop, trigger just BEFORE the barline so the next bar's notes
        // never start (the count-in silence hides the tiny early cut). Otherwise allow a
        // small buffer past the end so the section's last note isn't clipped.
        let loopingWithCountIn = loopSection && loopCountInPulses > 0
        let endTime = sectionEndTime + (loopingWithCountIn ? -0.03 : 0.05)
        if endTime > 0 && t >= endTime {
            if loopSection {
                if gradeMode { finalizeGradePass() }   // tally the pass (+ ramp/gate the speed trainer)
                flushPianoOutput()
                lastDiscreteBeat = -1
                if mastered {                          // drill complete — stop and celebrate
                    audio.stop()
                    return
                }
                audio.loopBackToStart(countInPulses: loopCountInPulses)   // section start (+ optional count-in)
                bridge.seek(sectionStartBeat)   // show the cursor at the start during the count-in
                if gradeMode { startGradePass() }   // reset tallies + wipe rings for the next pass
            } else {
                if gradeMode { finalizeGradePass() }   // record the completed pass, then stop
                audio.stop()
            }
            return
        }
        if cursorSmooth {
            bridge.seek(continuousBeat(at: t))
        } else {
            let target = discreteBeat(at: t)
            if target != lastDiscreteBeat { lastDiscreteBeat = target; bridge.seek(target) }
        }

        if gradeMode { advanceGradeMisses(t) }   // ring missed notes as the cursor passes them

        let events = score?.events ?? []
        // Keyboard highlight. In Grade mode, show the notes playable *now* (within the
        // grading tolerance window) as blue so anything else you play flags red — live
        // feedback matching how the pass is scored. Otherwise show the exact sounding
        // notes (RH blue / LH red when hand-colouring is on).
        if gradeMode {
            let rhOn = handMode != 2, lhOn = handMode != 1
            let now = events.filter { abs($0.onsetSeconds - t) <= gradeTolerance && (($0.hand == .left) ? lhOn : rhOn) }
            let rh = Set(now.filter { $0.hand != .left }.map(\.pitch))
            let lh = Set(now.filter { $0.hand == .left }.map(\.pitch))
            let newRH = colorHands ? rh : rh.union(lh)
            let newLH = colorHands ? lh : []
            if newRH != lights.rh { lights.rh = newRH }
            if newLH != lights.lh { lights.lh = newLH }
        } else if showScoreNotes {
            let now = events.filter { $0.onsetSeconds <= t && t < $0.onsetSeconds + $0.durationSeconds }
            let rh = Set(now.filter { $0.hand != .left }.map(\.pitch))   // right + unknown
            let lh = Set(now.filter { $0.hand == .left }.map(\.pitch))
            let newRH = colorHands ? rh : rh.union(lh)
            let newLH = colorHands ? lh : []
            if newRH != lights.rh { lights.rh = newRH }
            if newLH != lights.lh { lights.lh = newLH }
        } else {
            if !lights.rh.isEmpty { lights.rh = [] }
            if !lights.lh.isEmpty { lights.lh = [] }
        }

        // Send playback to the piano (MIDI out) when Piano/Both, respecting hand mutes.
        if outputMode != 0 {
            let rhOn = handMode != 2, lhOn = handMode != 1
            let target = Set(events.filter { e in
                e.onsetSeconds <= t && t < e.onsetSeconds + e.durationSeconds
                    && (e.hand == .right ? rhOn : (e.hand == .left ? lhOn : true))
            }.map(\.pitch))
            for n in target.subtracting(pianoSounding) { midi.sendNoteOn(n) }
            for n in pianoSounding.subtracting(target) { midi.sendNoteOff(n) }
            pianoSounding = target
        } else if !pianoSounding.isEmpty {
            flushPianoOutput()
        }
    }

    /// The exact notated beat of the latest note whose onset time has passed.
    private func discreteBeat(at t: Double) -> Double {
        var target = schedule.first?.beat ?? 0
        for e in schedule where e.time <= t { target = e.beat }
        return target
    }

    /// Interpolate the notated beat at playback time `t` from the (time → beat)
    /// schedule, giving a smoothly-advancing position between note onsets.
    private func continuousBeat(at t: Double) -> Double {
        guard let first = schedule.first else { return 0 }
        if t <= first.time { return first.beat }
        var i = 0
        while i + 1 < schedule.count && schedule[i + 1].time <= t { i += 1 }
        if i + 1 < schedule.count {
            let a = schedule[i], b = schedule[i + 1]
            let f = b.time > a.time ? (t - a.time) / (b.time - a.time) : 0
            return a.beat + f * (b.beat - a.beat)
        }
        return schedule[i].beat
    }

    // MARK: - Ingestion

    private func ingest() {
        let midiURL = song.midiURL, xmlURL = song.musicXMLURL
        guard FileManager.default.fileExists(atPath: midiURL.path),
              FileManager.default.fileExists(atPath: xmlURL.path) else {
            errorText = "This song's files are missing (score.musicxml / score.mid)."
            return
        }
        do {
            audio.stop()
            let midiData = try Data(contentsOf: midiURL)
            let xmlData = try Data(contentsOf: xmlURL)
            xmlBase64 = xmlData.base64EncodedString()   // handed to OSMD for rendering
            let fused = try Ingest.fuse(midiData: midiData, musicXMLData: xmlData)
            score = fused

            // Prepare cursor-sync data + load the MIDI into the audio player.
            schedule = beatSchedule(fused.events)
            scoreDuration = fused.events.map { $0.onsetSeconds + $0.durationSeconds }.max() ?? 0
            sectionStart = 1
            sectionEnd = fused.measureStartBeats.count      // whole piece by default
            bridge.clearSelection()
            bridge.clearMissed(); gradeResult = nil; gradeHistory = []
            audio.startSeconds = 0
            audio.load(midiURL: midiURL, trackHands: fused.trackHands)
            applyHands()
            audio.configureMetronome(clickGrid: fused.clickGrid,
                                     barPattern: fused.metronomeBarPattern,
                                     pulseSeconds: fused.metronomePulseSeconds)
        } catch {
            errorText = "\(error)"
        }
    }

    /// A time→beat schedule: each entry maps a MIDI onset time (seconds) to the
    /// note's NOTATED beat. Sorted by time; the cursor driver looks up the latest
    /// entry whose time has passed and moves OSMD to that notated beat.
    private func beatSchedule(_ events: [NoteEvent]) -> [(time: Double, beat: Double)] {
        events.map { (time: $0.onsetSeconds, beat: $0.notatedBeat) }
              .sorted { $0.time < $1.time }
    }
}
