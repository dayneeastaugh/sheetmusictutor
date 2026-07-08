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
    @Published var isPlaying = false
    @Published var metronomeOn = false
    @Published var status = ""

    private let engine = AVAudioEngine()
    // One sampler per hand so each can be muted/soloed independently.
    private let samplerRH = AVAudioUnitSampler()
    private let samplerLH = AVAudioUnitSampler()
    private var sequencer: AVAudioSequencer?
    private var playbackRate: Float = 1.0   // tempo % / 100 (1.0 = written tempo)

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
    private let metroQueue = DispatchQueue(label: "woodshed.metronome", qos: .userInteractive)

    init() {
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
        do {
            try engine.start()
            clickNode.play()
            loadPianoSound()
        } catch {
            status = "engine error: \(error.localizedDescription)"
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
        if metronomeOn && !isPlaying { startFreeRun() }   // pick up the new tempo/meter
    }

    /// Toggle the metronome. While playing it locks to the music; while stopped it
    /// free-runs at the score tempo so you can practise without the recording.
    func setMetronome(_ on: Bool) {
        metronomeOn = on
        stopMetroTimer()
        if on { isPlaying ? startSynced() : startFreeRun() }
    }

    /// Playback-synced: fire grid clicks as the sequencer position reaches them.
    private func startSynced() {
        stopMetroTimer()
        nextClick = 0
        let timer = DispatchSource.makeTimerSource(queue: metroQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(4), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let t = self.currentTime
            while self.nextClick < self.clickGrid.count && self.clickGrid[self.nextClick].time <= t {
                self.click(self.clickGrid[self.nextClick].level)
                self.nextClick += 1
            }
        }
        metroTimer = timer
        timer.resume()
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

    /// Click N bars of the pattern, then call `completion` on the next downbeat.
    private func startCountIn(bars: Int, completion: @escaping () -> Void) {
        stopMetroTimer()
        guard bars > 0, !barPattern.isEmpty, pulseSeconds > 0 else { completion(); return }
        let total = bars * barPattern.count
        var idx = 0
        let interval = pulseSeconds / Double(playbackRate)   // count in at the chosen tempo
        let timer = DispatchSource.makeTimerSource(queue: metroQueue)
        timer.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if idx >= total {
                timer.cancel()
                DispatchQueue.main.async { completion() }
                return
            }
            self.click(self.barPattern[idx % self.barPattern.count])
            idx += 1
        }
        metroTimer = timer
        timer.resume()
    }

    private func stopMetroTimer() {
        metroTimer?.cancel(); metroTimer = nil
    }

    private func click(_ level: ClickLevel) {
        let buf: AVAudioPCMBuffer?
        switch level {
        case .downbeat: buf = downbeatBuf
        case .beat:     buf = beatBuf
        case .sub:      buf = subBuf
        }
        guard let b = buf else { return }
        clickNode.scheduleBuffer(b, at: nil, options: .interrupts, completionHandler: nil)
    }

    /// Load the system GM sound bank (Acoustic Grand Piano) into both hand samplers.
    private func loadPianoSound() {
        let dls = URL(fileURLWithPath:
            "/System/Library/Components/CoreAudio.component/Contents/Resources/gs_instruments.dls")
        guard FileManager.default.fileExists(atPath: dls.path) else {
            status = "no system sound bank — playback will be silent"
            return
        }
        do {
            try samplerRH.loadSoundBankInstrument(at: dls, program: 0, bankMSB: 0x79, bankLSB: 0)
            try samplerLH.loadSoundBankInstrument(at: dls, program: 0, bankMSB: 0x79, bankLSB: 0)
        } catch {
            status = "sound load error: \(error.localizedDescription)"
        }
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
        samplerRH.volume = rhAudible ? 1 : 0
        samplerLH.volume = lhAudible ? 1 : 0
    }

    /// Set playback speed as a fraction (0.25–1.2). Pitch is preserved (it's MIDI).
    /// The cursor + synced metronome follow automatically (they run in musical time).
    func setRate(_ rate: Float) {
        playbackRate = max(0.05, rate)
        sequencer?.rate = playbackRate
        if metronomeOn && !isPlaying { startFreeRun() }   // rescale the free-run interval
    }

    /// Real elapsed playback time in seconds (same time base as our parsed onsets).
    var currentTime: TimeInterval { sequencer?.currentPositionInSeconds ?? 0 }

    /// Start playback, optionally preceded by an N-bar count-in.
    func play(countInBars: Int = 0) {
        guard sequencer != nil else { return }
        isPlaying = true          // reflect immediately; count-in counts as "playing"
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
            seq.currentPositionInSeconds = 0
            try seq.start()
            if metronomeOn { startSynced() }
        } catch {
            status = "play error: \(error.localizedDescription)"
            isPlaying = false
        }
    }

    func stop() {
        stopMetroTimer()
        if let seq = sequencer {
            if seq.isPlaying { seq.stop() }
            seq.currentPositionInSeconds = 0
        }
        isPlaying = false
        if metronomeOn { startFreeRun() }   // resume the free-run click when stopped
    }
}
