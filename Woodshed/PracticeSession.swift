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

/// Incremental lookup over the sorted playback schedules, so the 50 Hz tick does
/// **amortized O(1)** work instead of re-scanning every note each tick (the old
/// full-array filters were the main cause of trill-speed keyboard lag on the main
/// thread). Indices only ever advance with time; a backwards jump (loop restart,
/// seek) resets them automatically. Pure — no engine/UI refs — and unit-tested.
struct TickTracker {
    private(set) var scheduleIdx = -1          // last schedule entry with time <= t
    private(set) var activeIdx: [Int] = []     // event indices sounding at t (onset <= t < onset+dur)
    private(set) var winLo = 0                 // grade window: first event with onset >= t - tol
    private(set) var winHi = 0                 // grade window: first event with onset >  t + tol
    private var soundNext = 0                  // next event whose onset hasn't been reached
    private var lastT = -Double.infinity

    mutating func reset() {
        scheduleIdx = -1; activeIdx = []; winLo = 0; winHi = 0; soundNext = 0
        lastT = -.infinity
    }

    /// Advance all indices to playback time `t`. `schedule` must be sorted by time,
    /// `events` by onsetSeconds (both are, by construction, in `PracticeSession`).
    mutating func advance(to t: Double, tolerance: Double,
                          schedule: [(time: Double, beat: Double)], events: [NoteEvent]) {
        if t < lastT { reset() }               // loop restart / seek back
        lastT = t
        while scheduleIdx + 1 < schedule.count && schedule[scheduleIdx + 1].time <= t {
            scheduleIdx += 1
        }
        while soundNext < events.count && events[soundNext].onsetSeconds <= t {
            activeIdx.append(soundNext); soundNext += 1
        }
        activeIdx.removeAll { events[$0].onsetSeconds + events[$0].durationSeconds <= t }
        while winLo < events.count && events[winLo].onsetSeconds < t - tolerance { winLo += 1 }
        while winHi < events.count && events[winHi].onsetSeconds <= t + tolerance { winHi += 1 }
    }

    /// The interpolated notated beat at `t` (smooth cursor), from the current index.
    func continuousBeat(at t: Double, schedule: [(time: Double, beat: Double)]) -> Double {
        guard scheduleIdx >= 0 else { return schedule.first?.beat ?? 0 }
        let a = schedule[scheduleIdx]
        guard scheduleIdx + 1 < schedule.count else { return a.beat }
        let b = schedule[scheduleIdx + 1]
        let f = b.time > a.time ? min(max((t - a.time) / (b.time - a.time), 0), 1) : 0
        return a.beat + f * (b.beat - a.beat)
    }

    /// The exact notated beat of the latest note whose onset has passed (step cursor).
    func discreteBeat(schedule: [(time: Double, beat: Double)]) -> Double {
        scheduleIdx >= 0 ? schedule[scheduleIdx].beat : (schedule.first?.beat ?? 0)
    }
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
    /// Data-quality warning from ingestion (structure mismatch or unclean
    /// reconciliation) — shown as a persistent banner so grading is never
    /// silently wrong. nil = clean import.
    @Published private(set) var ingestWarning: String?

    // MARK: Cursor-sync state
    // A schedule of (playback time → notated beat). The tick reads the audio clock
    // and moves the OSMD cursor to the matching beat.
    private var schedule: [(time: Double, beat: Double)] = []
    private var scoreDuration: Double = 0
    private var tracker = TickTracker()         // amortized-O(1) per-tick lookups (see above)
    private var lastSentBeat = -1.0             // last beat pushed to the web cursor (skip no-ops)
    // These view/behaviour toggles are GLOBAL preferences (AppSettings): they persist
    // across launches and carry across song switches. Read from AppSettings at init
    // (inline initializers don't fire didSet, so no spurious write), written back on
    // change. Engine/bridge side-effects that don't run at init are re-applied in
    // `onAppear` / `applyPersistedLayoutToNotation`.
    @Published var cursorSmooth = AppSettings.cursorSmooth {   // smooth glide vs. discrete note-to-note
        didSet { AppSettings.cursorSmooth = cursorSmooth }
    }
    @Published var colorHands = AppSettings.colorHands {       // colour noteheads by hand (RH blue / LH orange)
        didSet { bridge.setHandColors(colorHands); AppSettings.colorHands = colorHands }
    }
    @Published var barsPerLine = 0 {            // measures per line/system (0 = auto)
        didSet {
            bridge.setMeasuresPerSystem(barsPerLine)
            if !loadingLayout { onSaveBarsPerLine?(barsPerLine) }   // persist user changes, not the initial load
        }
    }
    /// Engraving scale (1.0 = 100%). Smaller fits more bars per line — the way to make
    /// a high bars-per-line setting achievable for dense music.
    @Published var scoreZoom = 1.0 {
        didSet {
            bridge.setZoom(scoreZoom)
            if !loadingLayout { onSaveScoreZoom?(scoreZoom) }
        }
    }
    /// Persist the measures-per-system choice for this song. Set by the view.
    var onSaveBarsPerLine: ((Int) -> Void)?
    /// Persist the engraving-scale choice for this song. Set by the view.
    var onSaveScoreZoom: ((Double) -> Void)?
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

    /// The meter of the section's first bar (falls back to the piece default).
    private var sectionMeter: (num: Int, den: Int) {
        guard let s = score, sectionStart - 1 < s.measureMeters.count, sectionStart >= 1 else { return (4, 4) }
        return s.measureMeters[sectionStart - 1]
    }

    /// Beats (metronome pulses) in the section's bar, for the loop count-in choices —
    /// meter-aware per SECTION, not just the piece's first bar (a 4/4 passage in a
    /// 12/8 piece counts in 4, not 12).
    var pulsesPerBar: Int { max(1, sectionMeter.num) }

    /// Push the section's count-in pattern + pulse spacing (tempo-map-aware at the
    /// section start) to the audio engine.
    private func applySectionCountIn() {
        guard let s = score else { return }
        let m = sectionMeter
        let pattern = (0..<max(1, m.num)).map { Ingest.clickLevel(pulseIndex: $0, num: m.num, den: m.den) }
        let pulseBeats = 4.0 / Double(m.den)
        let pulse = s.secondsAtBeat(sectionStartBeat + pulseBeats) - s.secondsAtBeat(sectionStartBeat)
        audio.setCountIn(pattern: pattern, pulseSeconds: max(0.05, pulse))
        if loopCountInPulses > pattern.count { loopCountInPulses = pattern.count }   // keep the picker valid
    }

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
                tempoPct = drillStartTempoClamped   // preview the start tempo (visible ramp room)
            }
            resetDrill()
        }
    }
    // The speed-trainer's CONFIGURATION persists globally (start/target/step/threshold/
    // passes/hands-progression are "my preferred drill setup"); whether a drill is
    // actually RUNNING (`speedMode`) is per-practice context and does not persist.
    @Published var speedStartPct: Double = AppSettings.speedStartPct {  // ramp up FROM here
        didSet {
            if speedMode != .off && !audio.isPlaying { tempoPct = drillStartTempoClamped }
            AppSettings.speedStartPct = speedStartPct
        }
    }
    @Published var speedTargetPct: Double = AppSettings.speedTargetPct {  // ramp up TO here
        didSet {
            if speedMode != .off { clampTempoToDrillTarget(); resetDrill() }
            AppSettings.speedTargetPct = speedTargetPct
        }
    }
    /// The start tempo, never above the goal (so there's always somewhere to ramp).
    private var drillStartTempoClamped: Double { max(25, min(speedStartPct, speedTargetPct)) }
    @Published var speedStepPct: Double = AppSettings.speedStepPct {  // tempo increment per advance
        didSet { AppSettings.speedStepPct = speedStepPct }
    }

    // Hands progression (PRD: hands-separate → hands-together gating). When on, the
    // drill runs three STAGES — R.H. alone, L.H. alone, then both hands — each through
    // the full tempo ramp with the mastery gate; mastering a stage advances the hands
    // and restarts the ramp. Only after "both hands" masters is the section done.
    enum DrillStage: Int, CaseIterable {
        case rh, lh, both
        var title: String {
            switch self { case .rh: return "R.H."; case .lh: return "L.H."; case .both: return "both hands" }
        }
        var handMode: Int { switch self { case .rh: return 1; case .lh: return 2; case .both: return 0 } }
        /// The next stage, or nil when the progression is complete. Pure — tested.
        var next: DrillStage? { DrillStage(rawValue: rawValue + 1) }
    }
    @Published var handsProgression = AppSettings.handsProgression {
        didSet {
            if speedMode != .off { resetDrill() }
            AppSettings.handsProgression = handsProgression
        }
    }
    @Published private(set) var drillStage: DrillStage = .both
    private var drillStartTempo: Double = 100      // each stage ramps from here

    /// The drill must have somewhere to ramp: if the current tempo is already at or
    /// above the target, drop to the target so mastery there is earned, not instant.
    private func clampTempoToDrillTarget() {
        if tempoPct > speedTargetPct { tempoPct = speedTargetPct }
    }
    @Published var speedThreshold: Double = AppSettings.speedThreshold {  // accuracy for a "clean" pass (byAccuracy)
        didSet { AppSettings.speedThreshold = speedThreshold }
    }
    @Published var speedPassesPerStep = AppSettings.speedPassesPerStep {  // passes needed to advance one step
        didSet { AppSettings.speedPassesPerStep = speedPassesPerStep }
    }
    @Published private(set) var passesAtThisTempo = 0
    @Published private(set) var mastered = false

    private func resetDrill() {
        passesAtThisTempo = 0
        mastered = false
        drillStartTempo = tempoPct
        drillStage = handsProgression ? .rh : .both
        if speedMode != .off, handsProgression { handMode = drillStage.handMode }
    }

    /// After a graded loop pass, ramp the tempo toward the target per the trainer rule.
    /// With hands progression on, mastering a stage advances R.H. → L.H. → both (the
    /// ramp restarts from the stage's starting tempo); only the final stage sets
    /// `mastered` (which stops the loop and celebrates).
    private func applySpeedTrainer(accuracy: Double) {
        guard speedMode != .off, loopSection else { return }
        let next = Self.drillAdvance(mode: speedMode, accuracy: accuracy, threshold: speedThreshold,
                                     passesPerStep: speedPassesPerStep, passes: passesAtThisTempo,
                                     tempoPct: tempoPct, target: speedTargetPct, step: speedStepPct, mastered: mastered)
        passesAtThisTempo = next.passes
        if next.tempoPct != tempoPct { tempoPct = next.tempoPct }   // didSet → audio.setRate; slider follows
        if next.mastered, handsProgression, let following = drillStage.next {
            drillStage = following                 // stage cleared — on to the next hands
            handMode = following.handMode          // didSet re-mutes samplers; next pass rebuilds expected
            tempoPct = drillStartTempo             // each stage earns the ramp again
            passesAtThisTempo = 0
        } else {
            mastered = next.mastered
        }
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
    @Published var countInBars = AppSettings.countInBars {   // 0 = off, else bars of count-in before Play
        didSet { AppSettings.countInBars = countInBars }
    }
    // Start behaviour
    @Published var startOnFirstNote = AppSettings.startOnFirstNote {   // your first note starts playback in sync
        didSet { AppSettings.startOnFirstNote = startOnFirstNote }
    }
    @Published private(set) var armed = false  // armed + waiting for your first note
    // Metronome behaviour
    @Published var metronomeStartsWithPlayback = AppSettings.metronomeStartsWithPlayback {   // metronome on when playback starts
        didSet { AppSettings.metronomeStartsWithPlayback = metronomeStartsWithPlayback }
    }
    @Published var metronomeStopsWithPlayback = AppSettings.metronomeStopsWithPlayback {  // silence the metronome when playback stops
        didSet { audio.metronomeFreeRuns = !metronomeStopsWithPlayback; AppSettings.metronomeStopsWithPlayback = metronomeStopsWithPlayback }
    }
    @Published var handMode = 0 {              // 0 = both, 1 = RH only, 2 = LH only
        didSet {
            applyHands()
            rebuildRhythmGrid()   // rhythm-only ticks follow the selected hand(s)
        }
    }
    @Published var tempoPct: Double = 100 {     // playback tempo percentage
        didSet { audio.setRate(Float(tempoPct) / 100) }
    }
    @Published var outputMode = AppSettings.outputMode {   // 0 = PC speakers, 1 = piano, 2 = both
        didSet { applyOutput(); AppSettings.outputMode = outputMode }
    }
    /// Rhythm-only mode: the piano is silent, every note onset ticks instead, and
    /// Grade becomes a tap-along — any key counts, only the timing is scored.
    @Published var rhythmMode = false {
        didSet {
            audio.setRhythmOnly(rhythmMode)
            if gradeMode { startGradePass() }   // rebuild expected (collapsed onsets / pitches)
        }
    }

    // MARK: Keyboard highlight
    // The score-note highlight lives in its own object (not @Published on the session)
    // so updating it every note during playback repaints ONLY the keyboard, not the
    // whole practice screen — otherwise fast passages/trills lag and thrash the UI.
    let lights = KeyboardLights()
    @Published var showScoreNotes = AppSettings.showScoreNotes {   // light up score notes during playback
        didSet { AppSettings.showScoreNotes = showScoreNotes }
    }
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
    private var fumbledSteps: Set<Int> = []     // step indices with ≥1 wrong note — the honest count
                                                // (one slip on a 4-note chord is ONE fumble, not four)

    /// A fumbled/missed note position, for the review marks.
    private struct Mistake: Hashable { let beat: Double; let pitch: Int }

    // MARK: Tempo/grade mode — play along at tempo; grade the pass afterwards.
    @Published var gradeMode = false
    @Published var gradeResult: GradeResult?
    @Published var gradeHistory: [GradeResult] = []   // one entry per pass this session (progress)
    @Published private(set) var passAbandoned = false // stopped mid-pass → not recorded (say so)
    /// Grading tolerance in **musical** seconds (window scales with the tempo slider,
    /// matching the clock everything else runs on). Tunable: strict/normal/relaxed.
    @Published var gradeTolerance = AppSettings.gradeTolerance {
        didSet { AppSettings.gradeTolerance = gradeTolerance }
    }
    // Real-time grading state for the current pass:
    private var matcher: GradeMatcher?           // the pure matching engine (GradeMatcher.swift)
    private var gradeMissed: Set<Mistake> = []   // notes already flagged missed (ringed) this pass
    private var wrongMarks: [Mistake] = []       // wrong notes you played, shown on the score this pass
    private var gradePassRecorded = false        // this pass already tallied? (avoid double-recording)

    struct GradeResult {
        var accuracy: Double   // hits / expected
        var hits: Int
        var total: Int
        var missed: Int
        var extra: Int         // notes you played that matched nothing
        var avgMs: Double      // mean absolute timing error of hits
        var signedMs: Double   // mean signed error: < 0 = rushing, > 0 = dragging
    }

    /// Called when a Grade pass is tallied, so the library can persist it (history +
    /// derived stats). Set by the view; keeps this class free of the library type.
    var onPassRecorded: ((PracticePass) -> Void)?

    // MARK: Manual revisit flags (user notes pinned to bars)
    @Published private(set) var flags: [BarFlag] = []

    // MARK: Saved (named) practice sections — persisted per song as sections.json.
    @Published private(set) var savedSections: [SavedSection] = []

    func saveCurrentSection(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        savedSections.append(SavedSection(name: trimmed, start: sectionStart, end: sectionEnd))
        savedSections.sort { $0.start < $1.start }
        SavedSectionStore.save(savedSections, to: song.folder)
    }

    func applySavedSection(_ s: SavedSection) {
        sectionStart = min(max(1, s.start), measureCount)
        sectionEnd = min(max(sectionStart, s.end), measureCount)
    }

    func deleteSavedSection(_ s: SavedSection) {
        savedSections.removeAll { $0.id == s.id }
        SavedSectionStore.save(savedSections, to: song.folder)
    }

    // MARK: Takes — record what you play, listen back (see Take.swift)
    @Published private(set) var lastTake: Take?
    @Published private(set) var isReplaying = false
    @Published private(set) var bestTakes: [String: Take] = [:]   // section key → best graded take
    private var takeOpen: [Int: (on: Double, v: Int)] = [:]       // held notes being captured
    private var takeNotes: [TakeNote] = []
    private var takeStart: Double = 0                             // musical time the take began
    private var capturing = false
    // Replay: a merged on/off event stream driven from the shared 50 Hz tick.
    private var replayEvents: [(t: Double, p: Int, v: Int, isOn: Bool)] = []
    private var replayIdx = 0
    private var replayBegan = Date()
    private var replaySounding: Set<Int> = []

    /// Begin capturing a take (each Play and each loop pass starts fresh).
    /// `audio.startSeconds` is where the pass begins — the clock may not have been
    /// repositioned yet when a count-in is pending.
    private func beginTakeCapture() {
        capturing = true
        takeOpen = [:]
        takeNotes = []
        takeStart = audio.startSeconds
    }

    /// Close the capture into `lastTake` (and persist it if it's the best graded
    /// take for this section). Empty takes are discarded.
    private func endTakeCapture(accuracy: Double?) {
        guard capturing else { return }
        capturing = false
        let now = audio.currentTime
        for (p, open) in takeOpen {                    // close anything still held
            takeNotes.append(TakeNote(p: p, v: open.v, on: open.on - takeStart, off: now - takeStart))
        }
        takeOpen = [:]
        guard !takeNotes.isEmpty else { return }
        let take = Take(sectionStart: sectionStart, sectionEnd: sectionEnd,
                        tempoPct: tempoPct, accuracy: accuracy,
                        notes: takeNotes.sorted { $0.on < $1.on })
        lastTake = take
        if accuracy != nil, TakeStore.keepIfBest(take, in: song.folder) {
            bestTakes = TakeStore.load(from: song.folder)
        }
        takeNotes = []
    }

    /// The persisted best graded take covering the current section, if any.
    var bestTakeForCurrentSection: Take? {
        bestTakes[TakeStore.key(start: sectionStart, end: sectionEnd)]
    }

    /// Play a take back through the current output routing. Replays at the CURRENT
    /// tempo slider (timestamps are musical seconds).
    func startReplay(_ take: Take) {
        guard !audio.isPlaying else { return }
        stopReplay()
        var events: [(t: Double, p: Int, v: Int, isOn: Bool)] = []
        for n in take.notes {
            events.append((n.on, n.p, n.v, true))
            events.append((max(n.off, n.on + 0.05), n.p, n.v, false))
        }
        replayEvents = events.sorted { $0.t < $1.t }
        replayIdx = 0
        replayBegan = Date()
        isReplaying = true
    }

    func stopReplay() {
        guard isReplaying else { return }
        isReplaying = false
        for p in replaySounding { previewNoteOff(p) }
        replaySounding = []
        replayEvents = []
    }

    /// Driven from the shared 50 Hz tick: fire due replay events.
    fileprivate func replayTick() {
        guard isReplaying else { return }
        guard !audio.isPlaying else { stopReplay(); return }   // playback trumps replay
        let rate = max(0.05, tempoPct / 100)                    // wall → musical seconds
        let t = Date().timeIntervalSince(replayBegan) * rate
        while replayIdx < replayEvents.count && replayEvents[replayIdx].t <= t {
            let e = replayEvents[replayIdx]
            if e.isOn { previewNoteOn(e.p); replaySounding.insert(e.p) }
            else { previewNoteOff(e.p); replaySounding.remove(e.p) }
            replayIdx += 1
        }
        if replayIdx >= replayEvents.count { stopReplay() }
    }

    /// Capture a played note-on (velocity from CoreMIDI) while a take is running.
    private func captureNoteOn(_ pitch: Int, velocity: Int) {
        guard capturing, audio.isPlaying, audio.isRunning else { return }
        takeOpen[pitch] = (on: audio.currentTime, v: velocity)
    }

    private func captureNoteOffs(_ removed: Set<Int>) {
        guard capturing else { return }
        let now = audio.currentTime
        for p in removed {
            if let open = takeOpen.removeValue(forKey: p) {
                takeNotes.append(TakeNote(p: p, v: open.v, on: open.on - takeStart, off: now - takeStart))
            }
        }
    }

    // MARK: Practice time — active seconds, accumulated on the tick and flushed to
    // the per-song time.json on stop/teardown. "Active" = playback running, or Wait
    // mode with input in the last 30 s (so an idly-open app doesn't count).
    @Published private(set) var practicedToday: Double = 0     // incl. unflushed seconds
    private var unflushedSeconds: Double = 0
    private var lastTickDate: Date?
    private var lastWaitInputDate: Date?

    private func accumulatePracticeTime() {
        let now = Date()
        defer { lastTickDate = now }
        guard let last = lastTickDate else { return }
        let dt = min(now.timeIntervalSince(last), 0.5)          // guard against app-sleep gaps
        let waitActive = waitMode && (lastWaitInputDate.map { now.timeIntervalSince($0) < 30 } ?? false)
        guard (audio.isPlaying && audio.isRunning) || waitActive else { return }
        unflushedSeconds += dt
        practicedToday += dt
        if unflushedSeconds >= 30 { flushPracticeTime() }       // durable in 30 s chunks
    }

    private func flushPracticeTime() {
        guard unflushedSeconds > 0 else { return }
        PracticeTime.add(unflushedSeconds, to: song.folder)
        unflushedSeconds = 0
    }

    deinit { if unflushedSeconds > 0 { PracticeTime.add(unflushedSeconds, to: song.folder) } }

    // MARK: Progress / trouble spots
    @Published private(set) var history: [PracticePass] = []   // this song's recorded passes
    @Published var showTroubleOnScore = AppSettings.showTroubleOnScore {   // amber-tint trouble bars on the score
        didSet { refreshTroubleOverlay(); AppSettings.showTroubleOnScore = showTroubleOnScore }
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

    /// After the score renders (first load OR a web-process-crash recovery reload),
    /// re-apply everything the page can't remember: layout, hand colours, the section
    /// highlight, and the overlays.
    private func applyPersistedLayoutToNotation() {
        if abs(scoreZoom - 1.0) > 0.001 { bridge.setZoom(scoreZoom) }
        if barsPerLine != 0 { bridge.setMeasuresPerSystem(barsPerLine) }
        if colorHands { bridge.setHandColors(true) }
        if !isFullPiece { bridge.setSelection(sectionStart, sectionEnd) }
        refreshTroubleOverlay()
        refreshFlagOverlay()
    }

    private func refreshFlagOverlay() {
        bridge.setFlaggedBars(flags.map { $0.bar })
    }

    private var hasLoaded = false   // onAppear fires on every re-appearance; load once

    /// Wire up engine callbacks and fuse the score. Called from the view's `onAppear` —
    /// which SwiftUI fires again whenever the view returns to the hierarchy (sidebar
    /// toggle, window restore), so everything past the callback wiring is **idempotent**:
    /// the score is ingested once, not re-parsed with a state reset on every appearance
    /// (audit ARCH-07).
    func onAppear() {
        audio.pianoClick = { [weak self] level in self?.midi.sendClick(level) }
        bridge.onSelect = { [weak self] start, end in self?.sectionStart = start; self?.sectionEnd = end }
        bridge.onFlagTap = { [weak self] bar in self?.onFlagTapped?(bar) }
        midi.onNoteOn = { [weak self] pitch, velocity in self?.captureNoteOn(pitch, velocity: velocity) }
        guard !hasLoaded else { return }
        hasLoaded = true
        applyOutput()                                     // restore the persisted output routing
        audio.metronomeFreeRuns = !metronomeStopsWithPlayback   // and the persisted metronome behaviour
        ingest()
        reloadHistory()
        practicedToday = PracticeTime.load(from: song.folder)[PracticeTime.dayKey()] ?? 0
        flags = BarFlagStore.load(from: song.folder)
        savedSections = SavedSectionStore.load(from: song.folder)
        bestTakes = TakeStore.load(from: song.folder)
        refreshFlagOverlay()
        loadingLayout = true                      // apply the remembered layout without re-saving it
        barsPerLine = song.meta.barsPerLine ?? 0
        scoreZoom = song.meta.scoreZoom ?? 1.0
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

    /// The four mutually-exclusive **training session types**, surfaced as one
    /// segmented control at the top of the practice screen. Drill is Grade + a looped
    /// auto-tempo ramp — a first-class session type, not a buried setting.
    enum PracticeMode: Int, CaseIterable, Identifiable {
        case practice, wait, grade, drill
        var id: Int { rawValue }
        var title: String {
            switch self {
            case .practice: return "Practice"; case .wait: return "Wait"
            case .grade: return "Grade"; case .drill: return "Drill"
            }
        }
        var blurb: String {
            switch self {
            case .practice: return "Play along and follow the score"
            case .wait: return "Advance only when you play the right notes"
            case .grade: return "Play at tempo and get scored"
            case .drill: return "Loop a section and ramp the tempo up as you improve"
            }
        }
    }

    /// Current session type derived from the underlying flags; setting it routes
    /// through the enter/exit logic (Wait / Grade / speed-drill are kept consistent).
    var practiceMode: PracticeMode {
        get {
            if waitMode { return .wait }
            if speedMode != .off { return .drill }   // drill = grade + the speed trainer
            if gradeMode { return .grade }
            return .practice
        }
        set {
            switch newValue {
            case .practice:
                speedMode = .off
                if waitMode { setWaitMode(false) }
                if gradeMode { setGradeMode(false) }
            case .wait:
                speedMode = .off
                setWaitMode(true)              // also clears Grade
            case .grade:
                speedMode = .off               // plain grade, no auto-ramp
                setGradeMode(true)             // also clears Wait
            case .drill:
                if waitMode { setWaitMode(false) }
                if !gradeMode { setGradeMode(true) }
                if speedMode == .off { speedMode = .byAccuracy }   // didSet enables loop + previews start tempo
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
            wrongMarks = []
            bridge.clearMissed()
            bridge.markWrong([])
        }
    }

    /// The section's expected notes (selected hands) for grading. In rhythm mode
    /// chords collapse to ONE expected tap per onset (timing is graded, not pitch).
    private func buildGradeExpected() -> [(pitch: Int, onset: Double, beat: Double)] {
        guard let events = score?.events else { return [] }
        let rhOn = handMode != 2, lhOn = handMode != 1
        let notes = events
            .filter { (($0.hand == .left) ? lhOn : rhOn) && inSection($0.notatedBeat) }
            .map { (pitch: $0.pitch, onset: $0.onsetSeconds, beat: $0.notatedBeat) }
        guard rhythmMode else { return notes }
        var collapsed: [(pitch: Int, onset: Double, beat: Double)] = []
        for n in notes.sorted(by: { $0.onset < $1.onset }) {
            if let last = collapsed.last, abs(last.onset - n.onset) < 0.01 { continue }   // same chord
            collapsed.append(n)
        }
        return collapsed
    }

    /// Begin a fresh grading pass (Play start / each loop): new matcher, wipe rings.
    private func startGradePass() {
        matcher = GradeMatcher(expected: buildGradeExpected(), tolerance: gradeTolerance,
                               pitchAgnostic: rhythmMode)
        gradeMissed = []
        wrongMarks = []
        gradePassRecorded = false
        passAbandoned = false
        bridge.markMissed([])
        bridge.markWrong([])
    }

    /// A note-on during a graded pass — forwarded to the matcher. Wrong notes are
    /// recorded at the current beat and drawn on the score (so you can see exactly
    /// which extra keys you hit, and where). Rhythm mode is pitch-agnostic, so a
    /// "wrong" note there has no meaningful pitch to place — skip the marks.
    private func handleGradeNoteOn(_ added: Set<Int>) {
        let t = audio.currentTime
        let beat = tracker.continuousBeat(at: t, schedule: schedule)
        var changed = false
        for p in added where !(matcher?.noteOn(p, at: t) ?? true) && !rhythmMode {
            wrongMarks.append(Mistake(beat: beat, pitch: p))
            if wrongMarks.count > 60 { wrongMarks.removeFirst() }   // cap the overlay
            changed = true
        }
        if changed { bridge.markWrong(wrongMarks.map { (beat: $0.beat, pitch: $0.pitch) }) }
    }

    /// On each tick, ring any expected note whose window has now closed unmatched —
    /// so misses appear progressively as the cursor passes them.
    private func advanceGradeMisses(_ t: Double) {
        guard let newly = matcher?.closeWindows(upTo: t), !newly.isEmpty else { return }
        for m in newly { gradeMissed.insert(Mistake(beat: m.beat, pitch: m.pitch)) }
        bridge.markMissed(gradeMissed.map { (beat: $0.beat, pitch: $0.pitch) })
    }

    /// A specific note that went wrong in the last pass, for the "what exactly went
    /// wrong" summary: its bar (1-based) and note name.
    struct NoteFault: Identifiable, Hashable { let id = UUID(); let bar: Int; let name: String }
    struct PassDetail { var accuracy: Double; var missed: [NoteFault]; var wrong: [NoteFault] }
    /// The most recent completed pass, broken down note-by-note (this session only).
    @Published private(set) var lastPassDetail: PassDetail?

    /// MIDI pitch → note name (C♯5 etc.), matching the on-score wrong-note labels.
    static func noteName(_ p: Int) -> String {
        let names = ["C","C♯","D","D♯","E","F","F♯","G","G♯","A","A♯","B"]
        return names[((p % 12) + 12) % 12] + String(p / 12 - 1)
    }

    /// Tally the finished pass into the progress history and persist it. Idempotent:
    /// a pass is recorded at most once (completion), never again when playback stops.
    private func finalizeGradePass() {
        guard let matcher, matcher.expected.count > 0, !gradePassRecorded else { return }
        gradePassRecorded = true
        let t = matcher.tally()
        let r = GradeResult(accuracy: t.accuracy, hits: t.hits, total: t.total, missed: t.missed,
                            extra: t.wrong, avgMs: t.avgAbsMs, signedMs: t.meanSignedMs)
        gradeResult = r
        gradeHistory.append(r)

        // Note-by-note breakdown of this pass (missed = expected but not played;
        // wrong = played but not expected), sorted by bar, for the summary panel.
        lastPassDetail = PassDetail(
            accuracy: t.accuracy,
            missed: matcher.unmatched().map { NoteFault(bar: barForBeat($0.beat), name: Self.noteName($0.pitch)) }
                .sorted { $0.bar < $1.bar },
            wrong: wrongMarks.map { NoteFault(bar: barForBeat($0.beat), name: Self.noteName($0.pitch)) }
                .sorted { $0.bar < $1.bar })

        let pass = PracticePass(sectionStart: sectionStart, sectionEnd: sectionEnd, measureCount: measureCount,
                                tempoPct: tempoPct, handMode: handMode,
                                total: t.total, hits: t.hits, missed: t.missed, wrong: t.wrong, avgMs: t.avgAbsMs,
                                missedBars: matcher.unmatched().map { barForBeat($0.beat) },
                                signedMs: t.meanSignedMs)
        onPassRecorded?(pass)          // persist (disk + library stats)
        history.append(pass)           // mirror in memory for progress + trouble overlay
        refreshTroubleOverlay()        // a cleaned bar drops off; a newly-missed one lights up
        endTakeCapture(accuracy: r.accuracy)      // keep the take (persisted if it's a new best)
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
            mistakes = []; fumbledSteps = []; mistakeCount = 0; mistakesShown = false
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
        mistakes = []; fumbledSteps = []; mistakeCount = 0
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
        lastWaitInputDate = Date()          // Wait counts as active practice while you're playing
        waitPlayed.formUnion(added)
        let required = waitSteps[waitIndex].rh.union(waitSteps[waitIndex].lh)
        // Any note that isn't wanted at this step is a fumble — record the step's
        // notes so they can be reviewed (marked red) afterwards.
        if !added.subtracting(required).isEmpty {
            let beat = waitSteps[waitIndex].beat
            // Review marks show WHERE you fumbled (the chord you were attempting);
            // the count is honest — one fumble per step, however many notes it has.
            for p in required { mistakes.insert(Mistake(beat: beat, pitch: p)) }
            fumbledSteps.insert(waitIndex)
            mistakeCount = fumbledSteps.count
        }
        if required.isSubset(of: waitPlayed) {
            waitIndex += 1
            if waitIndex < waitSteps.count {
                showWaitStep(waitIndex)
            } else {
                lights.rh = []; lights.lh = []   // reached the end
                recordWaitPass()                 // a completed walkthrough counts as practice history
            }
        } else {
            lights.rh = required.subtracting(waitPlayed)   // only the still-missing notes
        }
    }

    /// A completed Wait walkthrough is real practice signal: record it like a pass —
    /// hits = clean steps, wrong = fumbled steps, and the fumbled bars feed the same
    /// trouble-spot heatmap Grade misses do. (Only completions are recorded.)
    private func recordWaitPass() {
        let total = waitStepCount
        guard total > 0 else { return }
        let fumbles = fumbledSteps.count
        let fumbleBars = Set(mistakes.map { barForBeat($0.beat) })
        let pass = PracticePass(mode: "wait",
                                sectionStart: sectionStart, sectionEnd: sectionEnd,
                                measureCount: measureCount,
                                tempoPct: tempoPct, handMode: handMode,
                                total: total, hits: total - fumbles, missed: 0, wrong: fumbles,
                                avgMs: 0, missedBars: Array(fumbleBars))
        onPassRecorded?(pass)
        history.append(pass)
        refreshTroubleOverlay()
        flushPracticeTime()
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
        if audio.isPlaying {
            // Keep BOTH loop boundaries current — updating only the end left the loop
            // jumping back to the previous section's start (a confusing hybrid loop).
            audio.clickCeiling = sectionEndTime
            audio.startSeconds = sectionStartTime
        }
        applySectionCountIn()                                       // meter/tempo at the new section
        playheadBar = sectionStart                                  // the playhead follows the section
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

    /// "Drill me": pick today's spot — the worst current trouble bar, else the oldest
    /// revisit flag, else a random bar — set a 2-bar loop on it, and say why.
    @Published private(set) var drillReason: String?
    func drillMe() {
        let bar: Int
        if let t = currentTroubleBars.first {
            bar = t.bar
            drillReason = "Bar \(bar) — you're still missing notes there (\(t.misses)×)"
        } else if let f = flags.min(by: { $0.date < $1.date }) {
            bar = f.bar
            drillReason = "Bar \(bar) — flagged: \(f.note)"
        } else {
            bar = Int.random(in: 1...measureCount)
            drillReason = "Bar \(bar) — random pick, keep it honest"
        }
        sectionStart = min(max(1, bar), measureCount)
        sectionEnd = min(bar + 1, measureCount)      // a 2-bar window gives context
        loopSection = true
    }

    /// One-tap start for a speed drill: default the ramp mode if off, drop to the
    /// start tempo, and begin the looped, graded ramp on the current section.
    func startDrill() {
        guard !waitMode else { return }
        if speedMode == .off { speedMode = .byAccuracy }   // the intuitive default: ramp when clean
        if audio.isPlaying { audio.stop() }
        armed = false
        tempoPct = drillStartTempoClamped
        startPlayback(countIn: countInBars)                // resets the drill + begins the ramp
    }

    /// A plain-English description of what the drill will do, for the setup panel.
    var drillSummary: String {
        let range = isFullPiece ? "the whole piece" : "bars \(sectionStart)–\(sectionEnd)"
        let start = Int(drillStartTempoClamped), goal = Int(speedTargetPct), step = Int(speedStepPct)
        let rule = speedMode == .byAccuracy
            ? "each time you play it \u{2265}\(Int(speedThreshold * 100))% clean"
            : "every \(speedPassesPerStep) loop\(speedPassesPerStep == 1 ? "" : "s")"
        let hands = handsProgression ? ", one hand at a time then together" : ""
        return "Loops \(range) from \(start)% to \(goal)%, +\(step)% \(rule)\(hands)."
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

    /// The rhythm-only tick grid: one tick per note onset (chords deduped), filtered
    /// to the selected hand(s) so Rhythm-only + R.H./L.H. ticks just that hand — the
    /// same hand set the tap-along grader expects.
    private func rebuildRhythmGrid() {
        audio.configureRhythm(noteOnsets: Self.rhythmOnsets(score?.events ?? [], handMode: handMode))
    }

    /// One tick time per note onset for the selected hand(s), chords collapsed. Pure —
    /// unit-tested. `handMode`: 0 both / 1 RH / 2 LH; unknown-hand notes count as right.
    static func rhythmOnsets(_ events: [NoteEvent], handMode: Int) -> [Double] {
        let rhOn = handMode != 2, lhOn = handMode != 1
        var onsets: [Double] = []
        for e in events.sorted(by: { $0.onsetSeconds < $1.onsetSeconds }) {
            guard (e.hand == .left) ? lhOn : rhOn else { continue }
            if let last = onsets.last, abs(last - e.onsetSeconds) < 0.01 { continue }   // dedupe chord
            onsets.append(e.onsetSeconds)
        }
        return onsets
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
        captureNoteOffs(old.subtracting(new))
        let added = new.subtracting(old)
        if added.isEmpty { return }
        if armed {                                   // sync start: your first note starts playback now
            armed = false
            startPlayback(countIn: 0)                // immediate — your note IS the downbeat
        }
        if waitMode { handleWaitInput(added) }
        // Grade input the whole time playback is live — INCLUDING the count-in, whose
        // clock is parked at the section start. Without this, the downbeat notes you
        // play as the count-in ends (before the clock resumes) were dropped and then
        // rung as "missed". Matching them against the parked start time is correct.
        if gradeMode, audio.isPlaying { handleGradeNoteOn(added) }
    }

    /// Playback started/stopped: flush the time ledger; in Grade mode a stop tallies
    /// the final pass (if it actually reached the end). The grade finalizer runs
    /// FIRST so a completed pass's take closes with its accuracy; the nil-accuracy
    /// close is the fallback for ungraded/abandoned stops.
    func playingChanged(_ was: Bool, _ now: Bool) {
        guard was && !now else { return }
        flushPracticeTime()
        if gradeMode {
            // Only count a pass that actually reached the section end. Completion
            // already records it (idempotently); this catches the sequencer ending on
            // its own before the tick sees it. Stopping early abandons the pass.
            if audio.currentTime + 0.15 >= sectionEndTime {
                finalizeGradePass()
            } else if !gradePassRecorded {
                passAbandoned = true
            }
        }
        endTakeCapture(accuracy: nil)
    }

    // MARK: - Transport (reset · step a bar · play)

    /// Where Play begins (1-based bar). Stepping while stopped moves this; Reset and
    /// section changes send it back to the section start. Grade mode ignores it (a
    /// pass is always graded over the whole section).
    @Published private(set) var playheadBar = 1

    /// Bar stepping is meaningless mid-grade (it would corrupt the pass) and Wait
    /// mode steps by notes already.
    var canStepBars: Bool { score != nil && !waitMode && !gradeMode }

    private func barStartBeat(_ bar: Int) -> Double {
        guard let m = score?.measureStartBeats, bar - 1 < m.count, bar >= 1 else { return 0 }
        return m[bar - 1]
    }
    private var playheadTime: Double { score?.secondsAtBeat(barStartBeat(playheadBar)) ?? 0 }

    /// The 1-based bar the playback clock is currently in.
    private func currentBar(at t: Double) -> Int {
        guard let s = score else { return sectionStart }
        var bar = sectionStart
        for i in s.measureStartBeats.indices where s.secondsAtBeat(s.measureStartBeats[i]) <= t + 0.001 {
            bar = i + 1
        }
        return bar
    }

    /// ⏮ Back to the section start. While playing: jump there (in Grade mode this
    /// restarts the pass); while stopped: move the playhead + cursor there.
    func transportReset() {
        guard !waitMode else { return }
        playheadBar = sectionStart
        if audio.isPlaying {
            flushPianoOutput()
            lastDiscreteBeat = -1
            audio.startSeconds = sectionStartTime
            if gradeMode { startGradePass() }        // a reset mid-pass = start the pass over
            audio.loopBackToStart()
            bridge.seek(sectionStartBeat)
            lastSentBeat = sectionStartBeat
        } else {
            resetCursor()
            bridge.seek(sectionStartBeat)
        }
    }

    /// ◀ / ▶ one bar, clamped to the section. Stopped: moves the playhead (and the
    /// cursor as a preview). Playing: jumps the live playback position.
    func stepBar(_ delta: Int) {
        guard canStepBars, let s = score else { return }
        if audio.isPlaying {
            guard audio.isRunning else { return }    // not during a count-in
            let target = min(max(currentBar(at: audio.currentTime) + delta, sectionStart), sectionEnd)
            let t = s.secondsAtBeat(barStartBeat(target))
            flushPianoOutput()
            lastDiscreteBeat = -1
            audio.seek(toSeconds: t)
            bridge.seek(barStartBeat(target))
            lastSentBeat = barStartBeat(target)
        } else {
            playheadBar = min(max(playheadBar + delta, sectionStart), sectionEnd)
            bridge.seek(barStartBeat(playheadBar))
        }
    }

    func setMetronome(_ on: Bool) { audio.setMetronome(on) }

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
        stopReplay()                                 // playback trumps a running take replay
        resetCursor()
        // Practice mode honours the playhead (step a bar, then play from there);
        // Grade always starts at the section start — a pass covers the whole section.
        audio.startSeconds = gradeMode ? sectionStartTime : playheadTime
        audio.clickCeiling = sectionEndTime          // don't click the bar past the section (loop point)
        if metronomeStartsWithPlayback && !audio.metronomeOn { audio.metronomeOn = true }
        audio.play(countInBars: countIn)
        beginTakeCapture()                           // record what you play this pass
    }

    func resetCursor() {
        lastDiscreteBeat = -1
        lastSentBeat = -1
        tracker.reset()
        cursorCommand = .init(nonce: cursorCommand.nonce + 1, action: "reset")
    }

    /// On each timer tick, advance the cursor to where the playback clock is.
    /// Smooth mode interpolates a continuous beat (fluid glide); step mode jumps to
    /// the latest note's exact notated beat when it changes.
    func advanceCursorWithPlayback() {
        accumulatePracticeTime()
        replayTick()
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
                else { endTakeCapture(accuracy: nil) } // ungraded pass — keep the take anyway
                flushPianoOutput()
                lastDiscreteBeat = -1
                if mastered {                          // drill complete — stop and celebrate
                    audio.stop()
                    return
                }
                audio.startSeconds = sectionStartTime  // loops always return to the SECTION start
                audio.loopBackToStart(countInPulses: loopCountInPulses)   // (+ optional count-in)
                bridge.seek(sectionStartBeat)   // show the cursor at the start during the count-in
                lastSentBeat = sectionStartBeat
                if gradeMode { startGradePass() }   // reset tallies + wipe rings for the next pass
                beginTakeCapture()                  // fresh take per pass
            } else {
                if gradeMode { finalizeGradePass() }   // record the completed pass, then stop
                else { endTakeCapture(accuracy: nil) }
                audio.stop()
            }
            return
        }

        let events = score?.events ?? []
        tracker.advance(to: t, tolerance: gradeTolerance, schedule: schedule, events: events)

        if cursorSmooth {
            let beat = tracker.continuousBeat(at: t, schedule: schedule)
            if abs(beat - lastSentBeat) > 0.0005 { lastSentBeat = beat; bridge.seek(beat) }
        } else {
            let target = tracker.discreteBeat(schedule: schedule)
            if target != lastDiscreteBeat { lastDiscreteBeat = target; bridge.seek(target) }
        }

        if gradeMode { advanceGradeMisses(t) }   // ring missed notes as the cursor passes them

        // Keyboard highlight. In Grade mode, show the notes playable *now* (within the
        // grading tolerance window) as blue so anything else you play flags red — live
        // feedback matching how the pass is scored. Otherwise show the exact sounding
        // notes (RH blue / LH red when hand-colouring is on). Both read only the
        // tracker's small index windows — never the whole event list.
        if gradeMode {
            let rhOn = handMode != 2, lhOn = handMode != 1
            var rh = Set<Int>(), lh = Set<Int>()
            for i in tracker.winLo..<tracker.winHi {
                let e = events[i]
                if e.hand == .left { if lhOn { lh.insert(e.pitch) } }
                else if rhOn { rh.insert(e.pitch) }
            }
            lights.set(rh: colorHands ? rh : rh.union(lh), lh: colorHands ? lh : [])
        } else if showScoreNotes {
            var rh = Set<Int>(), lh = Set<Int>()
            for i in tracker.activeIdx {
                let e = events[i]
                if e.hand == .left { lh.insert(e.pitch) } else { rh.insert(e.pitch) }   // right + unknown
            }
            lights.set(rh: colorHands ? rh : rh.union(lh), lh: colorHands ? lh : [])
        } else {
            lights.clear()
        }

        // Send playback to the piano (MIDI out) when Piano/Both, respecting hand mutes.
        // Rhythm-only mode sends no notes anywhere — the tick is the whole point.
        if outputMode != 0 && !rhythmMode {
            let rhOn = handMode != 2, lhOn = handMode != 1
            var target = Set<Int>()
            for i in tracker.activeIdx {
                let e = events[i]
                if e.hand == .right ? rhOn : (e.hand == .left ? lhOn : true) { target.insert(e.pitch) }
            }
            for n in target.subtracting(pianoSounding) { midi.sendNoteOn(n) }
            for n in pianoSounding.subtracting(target) { midi.sendNoteOff(n) }
            pianoSounding = target
        } else if !pianoSounding.isEmpty {
            flushPianoOutput()
        }
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
            ingestWarning = Self.warningText(for: fused)

            // Prepare cursor-sync data + load the MIDI into the audio player.
            schedule = beatSchedule(fused.events)
            tracker.reset()
            scoreDuration = fused.events.map { $0.onsetSeconds + $0.durationSeconds }.max() ?? 0
            sectionStart = 1
            sectionEnd = fused.measureStartBeats.count      // whole piece by default
            bridge.clearSelection()
            bridge.clearMissed(); bridge.markWrong([]); wrongMarks = []
            gradeResult = nil; gradeHistory = []
            audio.startSeconds = 0
            audio.load(midiURL: midiURL, trackHands: fused.trackHands)
            applyHands()
            audio.configureMetronome(clickGrid: fused.clickGrid,
                                     barPattern: fused.metronomeBarPattern,
                                     pulseSeconds: fused.metronomePulseSeconds)
            rebuildRhythmGrid()   // rhythm-only tick grid (respects the current hands setting)
            applySectionCountIn()
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

    /// The banner text for a fused score, or nil when the import is clean.
    /// Structure problems (repeats) trump the per-note tally.
    static func warningText(for fused: FusedScore) -> String? {
        if let s = fused.structureWarning { return s }
        let unmatched = fused.reconciliations.reduce(0) { $0 + $1.unmatchedMIDI.count + $1.unmatchedXML.count }
        guard unmatched > 0 else { return nil }
        return "\(unmatched) note\(unmatched == 1 ? "" : "s") couldn't be matched between the score and the MIDI — grading may be off in places."
    }
}
