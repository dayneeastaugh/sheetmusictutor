//
//  ContentView.swift
//  Woodshed
//
//  Phase 0 spike — Increment 2 UI.
//
//  On appear we fuse the bundled MIDI + MusicXML into the authoritative model and
//  dump it: score facts, a per-hand reconciliation (the proof the two files agree),
//  and the first notes with spelled name / hand / voice / notated type / timing.
//  Still deliberately a diagnostic surface, not a designed screen.
//

import SwiftUI
import Combine

struct PracticeView: View {
    let song: Song
    @State private var score: FusedScore?
    @State private var errorText: String?
    @State private var xmlBase64 = ""
    @State private var cursorCommand = CursorCommand()
    @StateObject private var bridge = NotationBridge()
    @StateObject private var audio = AudioEnginePlayer()
    @StateObject private var midi = MIDIInput()

    // Cursor-sync state: a schedule of (playback time → notated beat). A display
    // timer reads the audio clock and moves the OSMD cursor to the matching beat.
    @State private var schedule: [(time: Double, beat: Double)] = []
    @State private var scoreDuration: Double = 0
    @State private var cursorSmooth = true          // smooth glide vs. discrete note-to-note
    @State private var colorHands = false           // colour noteheads by hand (RH blue / LH red)
    @State private var barsPerLine = 0              // measures per line/system (0 = auto)
    // Section practice: play/loop a bar range instead of the whole piece.
    @State private var sectionStart = 1             // first bar (1-based)
    @State private var sectionEnd = 1               // last bar (inclusive)
    @State private var loopSection = false          // repeat the section
    @State private var lastDiscreteBeat: Double = -1
    @State private var countInBars = 0              // 0 = off, else bars of count-in before Play
    @State private var handMode = 0                 // 0 = both, 1 = RH only, 2 = LH only
    @State private var tempoPct: Double = 100        // playback tempo percentage
    @State private var scoreLitRH: Set<Int> = []     // score notes sounding now — right hand
    @State private var scoreLitLH: Set<Int> = []     // score notes sounding now — left hand
    @State private var showScoreNotes = true         // light up score notes during playback
    @State private var outputMode = 0                // 0 = PC speakers, 1 = piano, 2 = both
    @State private var pianoSounding: Set<Int> = []  // notes currently sent to the piano (MIDI out)
    // Wait mode: step through the score, advancing only when you play the right notes.
    @State private var waitMode = false
    @State private var waitSteps: [(beat: Double, rh: Set<Int>, lh: Set<Int>)] = []
    @State private var waitIndex = 0
    @State private var waitPlayed: Set<Int> = []     // note-ons accumulated for the current step
    @State private var mistakes: Set<Mistake> = []   // notes at steps where a wrong note was played
    @State private var mistakesShown = false         // mistakes currently marked red on the score

    /// A fumbled note position, for the review marks.
    private struct Mistake: Hashable { let beat: Double; let pitch: Int }

    // Tempo/grade mode: play along at tempo; grade the pass afterwards.
    @State private var gradeMode = false
    @State private var gradeResult: GradeResult?
    @State private var gradeHistory: [GradeResult] = []   // one entry per pass this session (progress)
    // Real-time grading state for the current pass:
    @State private var gradeExpected: [(pitch: Int, onset: Double, beat: Double, matched: Bool)] = []
    @State private var gradeMissed: Set<Mistake> = []   // notes already flagged missed (ringed) this pass
    @State private var gradeCheckIdx = 0                // expected notes up to here have had their window close
    @State private var gradeHits = 0
    @State private var gradeWrong = 0
    @State private var gradeTiming: [Double] = []       // |timing error| of hits
    private let gradeTolerance = 0.30   // musical seconds; a note counts if within this of expected

    struct GradeResult {
        var accuracy: Double   // hits / expected
        var hits: Int
        var total: Int
        var missed: Int
        var extra: Int         // notes you played that matched nothing
        var avgMs: Double      // mean absolute timing error of hits
    }
    // ~50 Hz so the cursor glides smoothly (the web view interpolates position).
    private let tick = Timer.publish(every: 0.02, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                notationSection
                keyboardSection

                if let errorText {
                    Text("⚠️ \(errorText)")
                        .foregroundStyle(.red).textSelection(.enabled)
                } else if let score {
                    summary(score)
                    Divider()
                    reconciliation(score)
                    Divider()
                    noteList(score)
                } else {
                    ProgressView("Parsing…")
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(song.title)
        .onAppear {
            audio.pianoClick = { level in midi.sendClick(level) }
            bridge.onSelect = { start, end in sectionStart = start; sectionEnd = end }
            applyOutput()
            ingest()
        }
    }

    // MARK: - Notation

    @ViewBuilder
    private var notationSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Notation (OSMD)").font(.headline)
                Spacer()
                Text(bridge.status)
                    .font(.caption)
                    .foregroundStyle(bridge.status.hasPrefix("error") ? .red : .secondary)
            }
            NotationWebView(xmlBase64: xmlBase64,
                            command: cursorCommand,
                            bridge: bridge)
                .frame(height: 360)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.secondary.opacity(0.3)))
            HStack {
                Button(audio.isPlaying ? "◼ Stop" : "▶︎ Play") { togglePlay() }
                    .keyboardShortcut(.space, modifiers: [])
                    .disabled(waitMode)
                Picker("Count-in", selection: $countInBars) {
                    Text("No count-in").tag(0)
                    Text("1-bar count-in").tag(1)
                    Text("2-bar count-in").tag(2)
                }
                .labelsHidden()
                .disabled(audio.isPlaying)
                Toggle("🎵 Metronome", isOn: Binding(
                    get: { audio.metronomeOn },
                    set: { audio.setMetronome($0) }))
                    .toggleStyle(.button)
                Toggle(cursorSmooth ? "⟿ Smooth" : "⇥ Step", isOn: $cursorSmooth)
                    .toggleStyle(.button)
                    .help("Cursor motion: smooth glide vs. jump note-to-note")
                Toggle("🎨 Colour hands", isOn: $colorHands)
                    .toggleStyle(.button)
                    .onChange(of: colorHands) { _, v in bridge.setHandColors(v) }
                    .help("Colour noteheads: right hand blue, left hand red")
                Picker("Bars/line", selection: $barsPerLine) {
                    Text("Bars/line: Auto").tag(0)
                    ForEach(1...5, id: \.self) { Text("\($0) / line").tag($0) }
                }
                .fixedSize()
                .onChange(of: barsPerLine) { _, v in bridge.setMeasuresPerSystem(v) }
                .help("How many bars to show per line (Auto = fit to width)")
                Button("Step cursor ▶") { cursorCommand = .init(nonce: cursorCommand.nonce + 1, action: "next") }
                    .disabled(audio.isPlaying)
                Button("Reset ⟲") { resetCursor() }
                if !audio.status.isEmpty {
                    Text(audio.status).font(.caption).foregroundStyle(.orange)
                }
            }
            HStack(spacing: 12) {
                Picker("Hands", selection: $handMode) {
                    Text("Both hands").tag(0)
                    Text("R.H. only").tag(1)
                    Text("L.H. only").tag(2)
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .onChange(of: handMode) { _, _ in applyHands() }

                Text("Tempo \(Int(tempoPct))%")
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 100, alignment: .leading)
                Slider(value: $tempoPct, in: 25...120, step: 5) { Text("Tempo") }
                    .frame(maxWidth: 220)
                    .onChange(of: tempoPct) { _, v in audio.setRate(Float(v) / 100) }

                Picker("Output", selection: $outputMode) {
                    Text("🔊 Speakers").tag(0)
                    Text("🎹 Piano").tag(1)
                    Text("Both").tag(2)
                }
                .fixedSize()
                .onChange(of: outputMode) { _, _ in applyOutput() }
            }
            HStack(spacing: 12) {
                Text("Section").font(.subheadline).bold()
                Stepper("bars \(sectionStart)–\(sectionEnd)", value: $sectionStart, in: 1...measureCount)
                    .fixedSize()
                    .onChange(of: sectionStart) { _, v in
                        if sectionEnd < v { sectionEnd = v }
                        onSectionChanged()
                    }
                Stepper("to \(sectionEnd)", value: $sectionEnd, in: sectionStart...measureCount)
                    .fixedSize()
                    .onChange(of: sectionEnd) { _, _ in onSectionChanged() }
                Toggle("🔁 Loop", isOn: $loopSection).toggleStyle(.button)
                Button("Whole piece") { sectionStart = 1; sectionEnd = measureCount; onSectionChanged() }
                    .disabled(isFullPiece)
                if !isFullPiece {
                    Text("bars \(sectionStart)–\(sectionEnd) of \(measureCount)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .onReceive(tick) { _ in advanceCursorWithPlayback() }
        .onChange(of: midi.activeNotes) { old, new in
            let added = new.subtracting(old)
            if added.isEmpty { return }
            if waitMode { handleWaitInput(added) }
            if gradeMode, audio.isRunning { handleGradeNoteOn(added) }
        }
        .onChange(of: audio.isPlaying) { was, now in
            // Stopped in Grade mode → tally the final (possibly partial) pass.
            if was && !now && gradeMode { finalizeGradePass() }
        }
    }

    // MARK: - Tempo (grade) mode

    /// Toggle grade mode. Mutually exclusive with Wait mode.
    private func setGradeMode(_ on: Bool) {
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
    private func setWaitMode(_ on: Bool) {
        waitMode = on
        if on {
            gradeMode = false; gradeResult = nil
            audio.stop()
            mistakes = []; mistakesShown = false
            bridge.clearMistakes()
            waitSteps = buildWaitSteps()
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

    private func clearMistakeMarks() {
        bridge.clearMistakes()
        mistakes = []
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

    private var measureCount: Int { max(1, score?.measureStartBeats.count ?? 1) }

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
    private var isFullPiece: Bool { sectionStart <= 1 && sectionEnd >= measureCount }

    /// Is a notated beat inside the current section? (Used to scope Wait/Grade.)
    private func inSection(_ beat: Double) -> Bool {
        beat >= sectionStartBeat - 0.001 && beat < sectionEndBeat - 0.001
    }

    /// React to a section change: update the on-score highlight, rebuild Wait steps,
    /// or preview the cursor there.
    private func onSectionChanged() {
        if isFullPiece { bridge.clearSelection() } else { bridge.setSelection(sectionStart, sectionEnd) }
        if waitMode {
            waitSteps = buildWaitSteps(); waitIndex = 0
            if waitSteps.isEmpty { setWaitMode(false) } else { showWaitStep(0) }
        } else if !audio.isPlaying {
            bridge.seek(sectionStartBeat)   // jump the cursor to the section start as a preview
        }
    }

    /// Apply the RH/LH selection to the audio engine (mute = 0 volume).
    private func applyHands() {
        audio.setHands(rhAudible: handMode != 2, lhAudible: handMode != 1)
        if waitMode {                       // rebuild the step list for the new hands
            waitSteps = buildWaitSteps()
            waitIndex = 0
            if waitSteps.isEmpty { setWaitMode(false) } else { showWaitStep(0) }
        }
    }

    // MARK: - MIDI keyboard

    @ViewBuilder
    private var keyboardSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("MIDI input").font(.headline)
                Toggle("🎯 Wait mode", isOn: Binding(get: { waitMode }, set: { setWaitMode($0) }))
                    .toggleStyle(.button)
                    .help("Step through the score — advances only when you play the right notes")
                Toggle("🎼 Grade", isOn: Binding(get: { gradeMode }, set: { setGradeMode($0) }))
                    .toggleStyle(.button)
                    .help("Play along at tempo, then grade your accuracy and timing")
                if waitMode {
                    Text((waitIndex < waitSteps.count
                          ? "Play the blue notes (red = wrong)  ·  \(waitIndex + 1)/\(waitSteps.count)"
                          : "✓ Complete") + "  ·  Fumbles: \(mistakes.count)")
                        .font(.caption).foregroundStyle(.green)
                }
                if gradeMode {
                    if let r = gradeResult {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Pass \(gradeHistory.count): \(Int(r.accuracy * 100))%  ·  Missed \(r.missed)  ·  Wrong \(r.extra)  ·  ±\(Int(r.avgMs))ms")
                                .foregroundStyle(r.accuracy >= 0.95 ? .green : .primary)
                            if gradeHistory.count > 1 {
                                Text("Progress " + gradeHistory.suffix(10).map { "\(Int($0.accuracy * 100))" }.joined(separator: "→") + "%")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .font(.caption)
                    } else {
                        Text("Play along — turn on 🔁 Loop to grade every pass").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if mistakesShown {
                    Text("Red = notes you fumbled").font(.caption).foregroundStyle(Color(red: 0.83, green: 0.18, blue: 0.18))
                    Button("Clear marks") { clearMistakeMarks() }
                }
                Toggle("Show score notes", isOn: $showScoreNotes)
                    .toggleStyle(.switch)
                    .font(.caption)
                Spacer()
                Text(midi.status).font(.caption).foregroundStyle(.secondary)
            }
            PianoKeyboardView(litNotes: midi.activeNotes,
                              scoreRH: (showScoreNotes || waitMode || gradeMode) ? scoreLitRH : [],
                              scoreLH: (showScoreNotes || waitMode || gradeMode) ? scoreLitLH : [],
                              flagWrong: waitMode || gradeMode,
                              onPress: { audio.playNote($0) },
                              onRelease: { audio.stopNote($0) })
            Text("Green = you · Score notes: RH blue, LH red (single blue if hand-colour is off). Click the keyboard to test.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: - Playback + cursor sync

    private func togglePlay() {
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

    private func resetCursor() {
        lastDiscreteBeat = -1
        cursorCommand = .init(nonce: cursorCommand.nonce + 1, action: "reset")
    }

    /// On each timer tick, advance the cursor to where the playback clock is.
    /// Smooth mode interpolates a continuous beat (fluid glide); step mode jumps to
    /// the latest note's exact notated beat when it changes.
    private func advanceCursorWithPlayback() {
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
                audio.stop()   // onChange(isPlaying) grades the final pass in Grade mode
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

    // MARK: - Sections

    @ViewBuilder
    private func summary(_ s: FusedScore) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(song.title).font(.headline)
            row("Tempo", String(format: "%.0f BPM", s.tempoBPM))
            row("Time signature", s.timeSignature.map { "\($0.num)/\($0.den)" } ?? "—")
            row("Key (fifths)", "\(s.keyFifths)  (\(keyName(s.keyFifths)))")
            row("Total note events", "\(s.events.count)")
        }
        .font(.system(.body, design: .monospaced))
    }

    @ViewBuilder
    private func reconciliation(_ s: FusedScore) -> some View {
        Text("MusicXML ↔ MIDI reconciliation").font(.headline)
        ForEach(s.reconciliations, id: \.hand) { r in
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(r.isClean ? "✅" : "⚠️")
                    Text("\(r.hand.rawValue): \(r.matched) written + \(r.ornamentRealizations) ornament = \(r.matched + r.ornamentRealizations) / \(r.midiCount) MIDI")
                        .bold()
                }
                ForEach(r.unmatchedMIDI, id: \.self) { Text("   extra MIDI: \($0)").foregroundStyle(.orange) }
                ForEach(r.unmatchedXML, id: \.self) { Text("   XML w/o MIDI: \($0)").foregroundStyle(.orange) }
            }
            .font(.system(.footnote, design: .monospaced))
        }
    }

    @ViewBuilder
    private func noteList(_ s: FusedScore) -> some View {
        Text("First 24 note events (by onset)").font(.headline)
        VStack(alignment: .leading, spacing: 2) {
            Text("  #  hand  name   v  notated   onset     dur")
                .foregroundStyle(.secondary)
            ForEach(Array(s.events.prefix(24).enumerated()), id: \.element.id) { i, e in
                Text(String(format: "%3d  %-4@  %-5@  %d  %-8@  %7.3f  %6.3f%@",
                            i + 1, e.hand.rawValue, e.spelledName, e.voice,
                            e.notatedType, e.onsetSeconds, e.durationSeconds,
                            e.isOrnamented ? "  ~orn+\(e.ornamentNotes)" : (e.matchedXML ? "" : "  ⚠︎")))
            }
        }
        .font(.system(.footnote, design: .monospaced))
        .textSelection(.enabled)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack { Text(label + ":"); Spacer(); Text(value).bold() }
            .frame(maxWidth: 360, alignment: .leading)
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

    private func keyName(_ fifths: Int) -> String {
        let majors = ["Cb","Gb","Db","Ab","Eb","Bb","F","C","G","D","A","E","B","F#","C#"]
        let idx = fifths + 7
        return (0..<majors.count).contains(idx) ? "\(majors[idx]) major" : "?"
    }
}
