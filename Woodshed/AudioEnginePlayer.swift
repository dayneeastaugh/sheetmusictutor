//
//  AudioEnginePlayer.swift
//  Woodshed
//
//  Phase 0 spike — Increment 4 (bonus): play the MIDI and expose a clock.
//
//  We use AVAudioEngine + AVAudioUnitSampler (per the PRD) and let AVAudioSequencer
//  play the actual .mid file through the sampler. The sequencer schedules on the
//  audio render clock and honors the file's tempo map (including the Chopin's
//  rubato), so `currentTime` is real elapsed seconds — the same time base as our
//  parsed onsets. That lets SwiftUI advance the OSMD cursor in sync.
//
//  Sound source: for the macOS spike we load the system General-MIDI sound bank
//  (gs_instruments.dls) — zero bundling. iPad will need a bundled .sf2 later.
//

import Foundation
import AVFoundation
import Combine

final class AudioEnginePlayer: ObservableObject {
    @Published var isPlaying = false     // includes the count-in
    @Published var isRunning = false     // the sequencer clock is actually advancing
    @Published var metronomeOn = false
    @Published var status = ""

    private let engine = AVAudioEngine()
    // One sampler per hand so each can be muted/soloed independently.
    private let samplerRH = AVAudioUnitSampler()
    private let samplerLH = AVAudioUnitSampler()
    private var sequencer: AVAudioSequencer?

    // Speaker (sampler) audibility state. Both hand mute and speaker-output routing
    // resolve to the samplers' volume — a sampler is audible only if its hand is on
    // AND PC-speaker output is enabled. (An intermediate mixer's outputVolume does
    // NOT mute reliably, so we gate at the samplers themselves.)
    private var rhAudible = true
    private var lhAudible = true
    private var speakersOn = true
    private var playbackRate: Float = 1.0   // tempo % / 100 (1.0 = written tempo)
    var startSeconds: Double = 0            // where playback begins (section start; 0 = whole piece)

    // Metronome: a generated click played through its own player node. It is driven
    // by the PLAYBACK clock (the sequencer position) against the piece's beat-time
    // grid, so clicks land on the beats as they play — following tempo changes/rubato.
    private let clickNode = AVAudioPlayerNode()
    private var clickFormat: AVAudioFormat!
    private var downbeatBuf: AVAudioPCMBuffer?   // strong (bar downbeat)
    private var beatBuf: AVAudioPCMBuffer?       // medium (main beat)
    private var subBuf: AVAudioPCMBuffer?        // light (subdivision)
    private var metroTimer: DispatchSourceTimer?
    private var clickGrid: [(time: Double, level: ClickLevel)] = []  // synced click times + emphasis
    private var barPattern: [ClickLevel] = []    // one bar of pulses (count-in / free-run)
    private var pulseSeconds: Double = 0.5       // seconds between pulses at the initial tempo
    private var nextClick = 0
    // Rhythm-only mode: the piano is silent and every NOTE onset ticks instead —
    // isolate the rhythm of the passage without its pitches (PRD rhythm tools).
    private var rhythmOnly = false
    private var noteGrid: [Double] = []          // note-onset times (chords deduped)
    private var nextNoteClick = 0
    private var noteBuf: AVAudioPCMBuffer?       // the note tick (distinct from the metronome)
    /// Synced metronome won't fire clicks at/after this time — set to the section end so
    /// the downbeat of the bar *past* the loop doesn't sound right before we loop back.
    var clickCeiling: Double = .infinity
    private let metroQueue = DispatchQueue(label: "woodshed.metronome", qos: .userInteractive)

    // Metronome click routing (mirrors the playback output selection).
    private var metronomeSpeakers = true
    private var metronomePiano = false
    /// When false, the metronome only clicks during playback (no free-run when stopped).
    var metronomeFreeRuns = true
    /// Set by the app to send a click to the piano over MIDI (called off the main thread).
    var pianoClick: ((ClickLevel) -> Void)?

    init() {
        #if os(iOS)
        // iOS requires an explicit audio session: .playback so the piano sounds even
        // with the silent switch on, activated before the engine starts. Without this
        // the engine's behaviour on iPad is undefined (audit ARCH-06).
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        engine.attach(samplerRH)
        engine.attach(samplerLH)
        engine.connect(samplerRH, to: engine.mainMixerNode, format: nil)
        engine.connect(samplerLH, to: engine.mainMixerNode, format: nil)
        engine.attach(clickNode)
        let sr = engine.mainMixerNode.outputFormat(forBus: 0).sampleRate
        clickFormat = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1)
        engine.connect(clickNode, to: engine.mainMixerNode, format: clickFormat)
        downbeatBuf = makeClick(frequency: 1600, amplitude: 0.72)  // strong
        beatBuf     = makeClick(frequency: 1200, amplitude: 0.55)  // medium
        subBuf      = makeClick(frequency: 900,  amplitude: 0.38)  // light
        noteBuf     = makeClick(frequency: 1450, amplitude: 0.60)  // rhythm-only note tick
        do {
            try engine.start()
            clickNode.play()
            loadPianoSound()
        } catch {
            status = "engine error: \(error.localizedDescription)"
        }
        registerAudioNotifications()
    }

    deinit {
        // Sessions own their engine, so tear it down deterministically on song switch
        // rather than leaving a running engine to the whims of deallocation order.
        notifTokens.forEach { NotificationCenter.default.removeObserver($0) }
        metroTimer?.cancel()
        sequencer?.stop()
        engine.stop()
    }

    // MARK: - Audio-session / engine resilience
    //
    // Real devices interrupt and reconfigure audio out from under us: a phone/FaceTime
    // call, plugging/unplugging headphones, switching to a Bluetooth speaker. Any of
    // these stops or rebuilds `AVAudioEngine`; without recovery, playback goes silent
    // with no way back except relaunch. We observe the three signals and revive.

    private var notifTokens: [NSObjectProtocol] = []

    private func registerAudioNotifications() {
        let nc = NotificationCenter.default
        // Engine graph torn down by a route/format change (both platforms) → rebuild
        // and resume where we were (unplugging headphones shouldn't end your loop).
        notifTokens.append(nc.addObserver(forName: .AVAudioEngineConfigurationChange,
                                          object: engine, queue: .main) { [weak self] _ in
            self?.reviveEngine(resumeSequencer: true, reason: "route/format change")
        })
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        notifTokens.append(nc.addObserver(forName: AVAudioSession.interruptionNotification,
                                          object: session, queue: .main) { [weak self] note in
            self?.handleInterruption(note)
        })
        #endif
    }

    #if os(iOS)
    private func handleInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            // iOS has paused us and stopped the engine — reflect a stopped transport.
            stopMetroTimer(); isRunning = false; isPlaying = false
        case .ended:
            // Reactivate the session and revive the engine so the NEXT Play works. We
            // don't auto-resume playback after a call (surprising to have the piano
            // start on its own); the user presses Play.
            try? AVAudioSession.sharedInstance().setActive(true)
            reviveEngine(resumeSequencer: false, reason: "interruption ended")
            if metronomeOn && metronomeFreeRuns { startFreeRun() }
        @unknown default: break
        }
    }
    #endif

    /// Restart the engine (and click node) after it was stopped/reconfigured, resuming
    /// the sequencer at its current position if we were mid-playback.
    private func reviveEngine(resumeSequencer: Bool, reason: String) {
        let resumePos = sequencer?.currentPositionInSeconds ?? startSeconds
        let wasRunning = isRunning
        do {
            if !engine.isRunning { try engine.start() }
            if !clickNode.isPlaying { clickNode.play() }
            if resumeSequencer, wasRunning, let seq = sequencer {
                if !seq.isPlaying { seq.currentPositionInSeconds = resumePos; try seq.start() }
                if metronomeOn || rhythmOnly { startSynced(referenceTime: resumePos) }
            }
            DebugLog.shared.log("audio", "engine revived (\(reason))")
        } catch {
            status = "audio recovery error: \(error.localizedDescription)"
        }
    }

    /// A short decaying sine "tick" rendered into a buffer once, reused per click.
    private func makeClick(frequency: Double, amplitude: Float) -> AVAudioPCMBuffer {
        let sr = clickFormat.sampleRate
        let frames = AVAudioFrameCount(sr * 0.05)          // 50 ms
        let buf = AVAudioPCMBuffer(pcmFormat: clickFormat, frameCapacity: frames)!
        buf.frameLength = frames
        let samples = buf.floatChannelData![0]
        for i in 0..<Int(frames) {
            let t = Double(i) / sr
            let env = Float(exp(-t * 45))                  // fast decay → a "tick"
            samples[i] = amplitude * env * Float(sin(2 * .pi * frequency * t))
        }
        return buf
    }

    // MARK: - Metronome

    /// Provide the piece's synced click grid plus the one-bar pattern + pulse spacing
    /// used for the count-in and the free-running (no-playback) metronome.
    func configureMetronome(clickGrid: [(time: Double, level: ClickLevel)],
                            barPattern: [ClickLevel], pulseSeconds: Double) {
        self.clickGrid = clickGrid
        self.barPattern = barPattern
        self.pulseSeconds = pulseSeconds
        if metronomeOn && !isPlaying && metronomeFreeRuns { startFreeRun() }   // pick up the new tempo/meter
    }

    /// The count-in's own bar pattern + pulse spacing. The piece-global `barPattern`
    /// comes from the FIRST full bar, which is wrong for a section in a different
    /// meter (or after tempo-map changes) — the session sets these per section.
    private var countInPattern: [ClickLevel] = []
    private var countInPulseSeconds: Double = 0
    func setCountIn(pattern: [ClickLevel], pulseSeconds: Double) {
        countInPattern = pattern
        countInPulseSeconds = pulseSeconds
    }
    private var effectiveCountInPattern: [ClickLevel] { countInPattern.isEmpty ? barPattern : countInPattern }
    private var effectiveCountInPulse: Double { countInPulseSeconds > 0 ? countInPulseSeconds : pulseSeconds }

    /// Toggle the metronome. While playing it locks to the music; while stopped it
    /// free-runs at the score tempo so you can practise without the recording.
    func setMetronome(_ on: Bool) {
        metronomeOn = on
        stopMetroTimer()
        if on {
            if isPlaying { startSynced() }
            else if metronomeFreeRuns { startFreeRun() }
        }
    }

    /// Playback-synced: fire grid clicks as the sequencer position reaches them.
    /// `referenceTime` is where playback is (re)starting from — pass the exact intended
    /// position (e.g. the section start) rather than letting `currentTime` (already
    /// nudged past it by `seq.start()` latency) drop the first downbeat.
    private func startSynced(referenceTime: Double? = nil) {
        stopMetroTimer()
        // Skip clicks before the start position (playback may start mid-piece for a
        // section, or loop back) so we don't fire a burst of past clicks.
        let now = referenceTime ?? currentTime
        nextClick = clickGrid.firstIndex { $0.time >= now - 0.02 } ?? clickGrid.count
        nextNoteClick = noteGrid.firstIndex { $0 >= now - 0.02 } ?? noteGrid.count
        let timer = DispatchSource.makeTimerSource(queue: metroQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(4), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let t = self.currentTime
            if self.metronomeOn {
                while self.nextClick < self.clickGrid.count && self.clickGrid[self.nextClick].time <= t {
                    if self.clickGrid[self.nextClick].time < self.clickCeiling - 0.001 {
                        self.click(self.clickGrid[self.nextClick].level)
                    }
                    self.nextClick += 1
                }
            }
            if self.rhythmOnly {
                while self.nextNoteClick < self.noteGrid.count && self.noteGrid[self.nextNoteClick] <= t {
                    if self.noteGrid[self.nextNoteClick] < self.clickCeiling - 0.001 {
                        self.noteTick()
                    }
                    self.nextNoteClick += 1
                }
            }
        }
        metroTimer = timer
        timer.resume()
    }

    /// The rhythm-only tick for a note onset (and to the piano when routed there).
    private func noteTick() {
        if metronomeSpeakers, let b = noteBuf {
            clickNode.scheduleBuffer(b, at: nil, options: .interrupts, completionHandler: nil)
        }
        if metronomePiano { pianoClick?(.beat) }
    }

    /// Rhythm-only playback: silence the piano and tick every note onset instead.
    func setRhythmOnly(_ on: Bool) {
        rhythmOnly = on
        applySamplerVolumes()
        if isPlaying && isRunning {
            if metronomeOn || rhythmOnly { startSynced(referenceTime: currentTime) }
            else { stopMetroTimer() }
        }
    }

    /// The note-onset grid for rhythm-only mode (sorted; chords deduped by the caller).
    /// The grid is read by the click timer on `metroQueue`, so mutate it there — and
    /// re-align the tick pointer if the grid changes mid-playback (e.g. the hands
    /// setting switches while rhythm-only is running).
    func configureRhythm(noteOnsets: [Double]) {
        metroQueue.async { [weak self] in
            guard let self else { return }
            self.noteGrid = noteOnsets
            if self.isPlaying && self.isRunning {
                let t = self.currentTime
                self.nextNoteClick = self.noteGrid.firstIndex { $0 >= t - 0.02 } ?? self.noteGrid.count
            }
        }
    }

    /// Free-running: click the bar pattern on a steady timer, no playback needed.
    private func startFreeRun() {
        stopMetroTimer()
        guard !barPattern.isEmpty, pulseSeconds > 0 else { return }
        var idx = 0
        let interval = pulseSeconds / Double(playbackRate)   // slower at reduced tempo
        let timer = DispatchSource.makeTimerSource(queue: metroQueue)
        timer.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.click(self.barPattern[idx % self.barPattern.count])
            idx += 1
        }
        metroTimer = timer
        timer.resume()
    }

    /// Click N bars of the (section-aware) pattern, then call `completion` on the
    /// next downbeat.
    private func startCountIn(bars: Int, completion: @escaping () -> Void) {
        stopMetroTimer()
        let pattern = effectiveCountInPattern, pulse = effectiveCountInPulse
        guard bars > 0, !pattern.isEmpty, pulse > 0 else { completion(); return }
        let total = bars * pattern.count
        var idx = 0
        let interval = pulse / Double(playbackRate)   // count in at the chosen tempo
        let timer = DispatchSource.makeTimerSource(queue: metroQueue)
        timer.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if idx >= total {
                timer.cancel()
                DispatchQueue.main.async { completion() }
                return
            }
            self.click(pattern[idx % pattern.count])
            idx += 1
        }
        metroTimer = timer
        timer.resume()
    }

    /// Click the last `pulses` beats of the (section-aware) bar — a pickup — at the
    /// current tempo, then call `completion`. Used for the per-loop count-in.
    private func startCountInPulses(pulses: Int, completion: @escaping () -> Void) {
        stopMetroTimer()
        let pattern = effectiveCountInPattern, pulse = effectiveCountInPulse
        let barLen = pattern.count
        guard pulses > 0, barLen > 0, pulse > 0 else { completion(); return }
        let n = min(pulses, barLen)
        let startIdx = barLen - n                              // last n pulses → lead into the downbeat
        var idx = 0
        let interval = pulse / Double(playbackRate)            // count in at the chosen tempo
        let timer = DispatchSource.makeTimerSource(queue: metroQueue)
        timer.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if idx >= n {
                timer.cancel()
                DispatchQueue.main.async { completion() }
                return
            }
            self.click(pattern[(startIdx + idx) % barLen])
            idx += 1
        }
        metroTimer = timer
        timer.resume()
    }

    private func stopMetroTimer() {
        metroTimer?.cancel(); metroTimer = nil
    }

    /// Route the metronome click to PC speakers, the piano (MIDI), or both.
    func setMetronomeOutput(speakers: Bool, piano: Bool) {
        metronomeSpeakers = speakers
        metronomePiano = piano
    }

    private func click(_ level: ClickLevel) {
        if metronomeSpeakers {
            let buf: AVAudioPCMBuffer?
            switch level {
            case .downbeat: buf = downbeatBuf
            case .beat:     buf = beatBuf
            case .sub:      buf = subBuf
            }
            if let b = buf { clickNode.scheduleBuffer(b, at: nil, options: .interrupts, completionHandler: nil) }
        }
        if metronomePiano { pianoClick?(level) }
    }

    /// Load a piano into both hand samplers. macOS keeps the system GM bank (zero
    /// app-size cost, the sound the app has always had); iPadOS has no system `.dls`,
    /// so it loads the bundled GeneralUser GS SoundFont — without this the iPad build
    /// was silent. Falls back to the bundled font on macOS if the system bank moves.
    private func loadPianoSound() {
        var candidates: [URL] = []
        #if os(macOS)
        candidates.append(URL(fileURLWithPath:
            "/System/Library/Components/CoreAudio.component/Contents/Resources/gs_instruments.dls"))
        #endif
        if let sf2 = Bundle.main.url(forResource: "GeneralUserGS", withExtension: "sf2", subdirectory: "Sounds")
            ?? Bundle.main.url(forResource: "GeneralUserGS", withExtension: "sf2") {
            candidates.append(sf2)
        }
        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            do {
                try samplerRH.loadSoundBankInstrument(at: url, program: 0, bankMSB: 0x79, bankLSB: 0)
                try samplerLH.loadSoundBankInstrument(at: url, program: 0, bankMSB: 0x79, bankLSB: 0)
                return
            } catch {
                status = "sound load error: \(error.localizedDescription)"
            }
        }
        if status.isEmpty { status = "no sound bank found — playback will be silent" }
    }

    /// Point the player at a MIDI file, routing each track to its hand's sampler.
    func load(midiURL: URL, trackHands: [Hand]) {
        stop()
        let seq = AVAudioSequencer(audioEngine: engine)
        do {
            try seq.load(from: midiURL, options: [])
            for (i, track) in seq.tracks.enumerated() {
                let hand = i < trackHands.count ? trackHands[i] : .right
                track.destinationAudioUnit = (hand == .left) ? samplerLH : samplerRH
            }
            seq.rate = playbackRate
            seq.prepareToPlay()
            sequencer = seq
        } catch {
            status = "midi load error: \(error.localizedDescription)"
        }
    }

    // MARK: - Per-hand mute / solo and tempo

    /// Set which hands are audible (mute = volume 0). RH/LH route to separate samplers.
    func setHands(rhAudible: Bool, lhAudible: Bool) {
        self.rhAudible = rhAudible
        self.lhAudible = lhAudible
        applySamplerVolumes()
    }

    /// Mute/unmute the PC-speaker output of the sampled piano (the metronome is
    /// unaffected — it's a separate node). When off, playback can still go to the
    /// piano over MIDI.
    func setSpeakerOutput(_ on: Bool) {
        speakersOn = on
        applySamplerVolumes()
    }

    private func applySamplerVolumes() {
        let rh = rhAudible && speakersOn && !rhythmOnly   // rhythm-only: the piano is silent
        let lh = lhAudible && speakersOn && !rhythmOnly
        samplerRH.volume = rh ? 1 : 0
        samplerLH.volume = lh ? 1 : 0
        // Belt-and-suspenders: also drive the sampler's own gain to silence.
        samplerRH.overallGain = rh ? 0 : -120
        samplerLH.overallGain = lh ? 0 : -120
    }

    /// Set playback speed as a fraction (0.25–1.2). Pitch is preserved (it's MIDI).
    /// The cursor + synced metronome follow automatically (they run in musical time).
    func setRate(_ rate: Float) {
        playbackRate = max(0.05, rate)
        sequencer?.rate = playbackRate
        if metronomeOn && !isPlaying && metronomeFreeRuns { startFreeRun() }   // rescale the free-run interval
    }

    /// Real elapsed playback time in seconds (same time base as our parsed onsets).
    var currentTime: TimeInterval { sequencer?.currentPositionInSeconds ?? 0 }

    // MARK: - Live note playing (on-screen keyboard testing)

    func playNote(_ note: Int) { samplerRH.startNote(UInt8(clamping: note), withVelocity: 90, onChannel: 0) }
    func stopNote(_ note: Int) { samplerRH.stopNote(UInt8(clamping: note), onChannel: 0) }

    /// Start playback, optionally preceded by an N-bar count-in.
    func play(countInBars: Int = 0) {
        guard let seq = sequencer else { return }
        isPlaying = true          // reflect immediately; count-in counts as "playing"
        isRunning = false         // ...but the clock isn't advancing during the count-in
        seq.currentPositionInSeconds = startSeconds   // park the clock at the start so notes played
                                                      // during the count-in grade against bar 1
        stopMetroTimer()          // stop any free-run click
        if countInBars > 0 {
            startCountIn(bars: countInBars) { [weak self] in self?.reallyStart() }
        } else {
            reallyStart()
        }
    }

    private func reallyStart() {
        guard isPlaying, let seq = sequencer else { return }   // may have been stopped mid count-in
        do {
            if !engine.isRunning { try engine.start() }
            seq.currentPositionInSeconds = startSeconds
            try seq.start()
            isRunning = true
            if metronomeOn || rhythmOnly { startSynced(referenceTime: startSeconds) }
        } catch {
            status = "play error: \(error.localizedDescription)"
            isPlaying = false
        }
    }

    /// Jump back to the section start for a loop: reposition and clear hanging sampler
    /// notes. With `countInPulses > 0`, freeze the clock at the start and click that
    /// many pulses (a pickup into the downbeat) before resuming — time to reposition
    /// your hands each pass. Otherwise resume immediately.
    func loopBackToStart(countInPulses: Int = 0) {
        if countInPulses > 0 {
            // Stop BEFORE repositioning — jumping the position while the sequencer is
            // still playing fires the first bar's note-ons, which then get cut off (an
            // audible blip in the count-in silence). Freeze, move, clear, then count in.
            isRunning = false
            if let seq = sequencer, seq.isPlaying { seq.stop() }
            sequencer?.currentPositionInSeconds = startSeconds
            allSamplerNotesOff()
            startCountInPulses(pulses: countInPulses) { [weak self] in self?.resumeAfterLoopCountIn() }
        } else {
            // No count-in: keep playing across the jump for a seamless loop.
            sequencer?.currentPositionInSeconds = startSeconds
            allSamplerNotesOff()
            if metronomeOn || rhythmOnly { startSynced(referenceTime: startSeconds) }
        }
    }

    /// Jump the live playback position (transport bar-stepping). Clears hanging
    /// sampler notes and re-syncs the metronome to the new position.
    func seek(toSeconds t: Double) {
        guard isPlaying, isRunning, let seq = sequencer else { return }
        seq.currentPositionInSeconds = max(0, t)
        allSamplerNotesOff()
        if metronomeOn || rhythmOnly { startSynced(referenceTime: t) }
    }

    /// Resume the sequencer at the section start after a per-loop count-in.
    private func resumeAfterLoopCountIn() {
        guard isPlaying, let seq = sequencer else { return }   // may have been stopped mid count-in
        do {
            seq.currentPositionInSeconds = startSeconds
            try seq.start()
            isRunning = true
            if metronomeOn || rhythmOnly { startSynced(referenceTime: startSeconds) }
        } catch {
            status = "loop resume error: \(error.localizedDescription)"
        }
    }

    /// All-notes-off on both piano samplers (used when looping to avoid stuck notes).
    private func allSamplerNotesOff() {
        for ch: UInt8 in 0..<16 {
            samplerRH.sendController(123, withValue: 0, onChannel: ch)
            samplerLH.sendController(123, withValue: 0, onChannel: ch)
        }
    }

    func stop() {
        stopMetroTimer()
        if let seq = sequencer {
            if seq.isPlaying { seq.stop() }
            seq.currentPositionInSeconds = startSeconds
        }
        allSamplerNotesOff()
        isPlaying = false
        isRunning = false
        if metronomeOn && metronomeFreeRuns { startFreeRun() }   // resume free-run only if enabled
    }
}
