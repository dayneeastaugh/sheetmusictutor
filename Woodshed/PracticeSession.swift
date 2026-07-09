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
        didSet { bridge.setMeasuresPerSystem(barsPerLine) }
    }

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
    private var lastDiscreteBeat: Double = -1

    // MARK: Transport / playback
    @Published var countInBars = 0             // 0 = off, else bars of count-in before Play
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
    @Published var scoreLitRH: Set<Int> = []    // score notes sounding now — right hand
    @Published var scoreLitLH: Set<Int> = []    // score notes sounding now — left hand
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
    private let gradeTolerance = 0.30   // musical seconds; a note counts if within this of expected

    struct GradeResult {
        var accuracy: Double   // hits / expected
        var hits: Int
        var total: Int
        var missed: Int
        var extra: Int         // notes you played that matched nothing
        var avgMs: Double      // mean absolute timing error of hits
    }

    private var cancellables: Set<AnyCancellable> = []

    init(song: Song) {
        self.song = song
        // Nested ObservableObjects don't propagate, so re-broadcast the engines'
        // changes as ours — the view observes only this session.
        for obj in [audio.objectWillChange, midi.objectWillChange, bridge.objectWillChange] {
            obj.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        }
    }

    /// Wire up engine callbacks and fuse the score. Called from the view's `onAppear`.
    func onAppear() {
        audio.pianoClick = { [weak self] level in self?.midi.sendClick(level) }
        bridge.onSelect = { [weak self] start, end in self?.sectionStart = start; self?.sectionEnd = end }
        applyOutput()
        ingest()
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

    /// Tally the finished pass into the progress history.
    private func finalizeGradePass() {
        let total = gradeExpected.count
        guard total > 0 else { return }
        let missed = gradeExpected.filter { !$0.matched }.count
        let avgMs = gradeTiming.isEmpty ? 0 : gradeTiming.reduce(0, +) / Double(gradeTiming.count) * 1000
        let r = GradeResult(accuracy: Double(gradeHits) / Double(total),
                            hits: gradeHits, total: total, missed: missed, extra: gradeWrong, avgMs: avgMs)
        gradeResult = r
        gradeHistory.append(r)
    }

    // MARK: - Wait mode

    /// Turn Wait mode on/off. On: stop playback, build the step list (per selected
    /// hands), and park on the first note. Off: clear and reset the cursor.
    func setWaitMode(_ on: Bool) {
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
            scoreLitRH = []; scoreLitLH = []
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
        scoreLitRH = s.rh.union(s.lh)
        scoreLitLH = []
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
                scoreLitRH = []; scoreLitLH = []   // reached the end
            }
        } else {
            scoreLitRH = required.subtracting(waitPlayed)   // only the still-missing notes
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
        if waitMode { handleWaitInput(added) }
        if gradeMode, audio.isRunning { handleGradeNoteOn(added) }
    }

    /// Playback started/stopped: in Grade mode a stop tallies the final (partial) pass.
    func playingChanged(_ was: Bool, _ now: Bool) {
        if was && !now && gradeMode { finalizeGradePass() }
    }

    // MARK: - Playback + cursor sync

    func setMetronome(_ on: Bool) { audio.setMetronome(on) }

    func stepCursor() { cursorCommand = .init(nonce: cursorCommand.nonce + 1, action: "next") }

    func togglePlay() {
        if audio.isPlaying {
            audio.stop()
        } else {
            if gradeMode {   // fresh practice session: reset progress + start a pass
                gradeResult = nil; gradeHistory = []
                startGradePass()
            }
            resetCursor()
            audio.startSeconds = sectionStartTime   // play from the section start
            audio.play(countInBars: countInBars)
        }
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
                if !scoreLitRH.isEmpty { scoreLitRH = [] }
                if !scoreLitLH.isEmpty { scoreLitLH = [] }
            }
            flushPianoOutput()
            return
        }
        guard audio.isRunning else { return }   // counting in — don't follow/emit notes yet
        let t = audio.currentTime
        // Reached the end of the section (or piece): loop it, or stop.
        let endTime = sectionEndTime + 0.05
        if endTime > 0 && t >= endTime {
            if loopSection {
                if gradeMode { finalizeGradePass() }   // tally the pass into the progress history
                flushPianoOutput()
                lastDiscreteBeat = -1
                audio.loopBackToStart()   // jump to section start, clear hanging notes
                if gradeMode { startGradePass() }   // reset tallies + wipe rings for the next pass
            } else {
                audio.stop()   // playingChanged() grades the final pass in Grade mode
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
            if newRH != scoreLitRH { scoreLitRH = newRH }
            if newLH != scoreLitLH { scoreLitLH = newLH }
        } else if showScoreNotes {
            let now = events.filter { $0.onsetSeconds <= t && t < $0.onsetSeconds + $0.durationSeconds }
            let rh = Set(now.filter { $0.hand != .left }.map(\.pitch))   // right + unknown
            let lh = Set(now.filter { $0.hand == .left }.map(\.pitch))
            let newRH = colorHands ? rh : rh.union(lh)
            let newLH = colorHands ? lh : []
            if newRH != scoreLitRH { scoreLitRH = newRH }
            if newLH != scoreLitLH { scoreLitLH = newLH }
        } else {
            if !scoreLitRH.isEmpty { scoreLitRH = [] }
            if !scoreLitLH.isEmpty { scoreLitLH = [] }
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
