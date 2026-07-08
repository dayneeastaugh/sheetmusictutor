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
    private let sampler = AVAudioUnitSampler()
    private var sequencer: AVAudioSequencer?

    // Metronome: a generated click played through its own player node. It is driven
    // by the PLAYBACK clock (the sequencer position) against the piece's beat-time
    // grid, so clicks land on the beats as they play — following tempo changes/rubato.
    private let clickNode = AVAudioPlayerNode()
    private var clickFormat: AVAudioFormat!
    private var clickBuffer: AVAudioPCMBuffer?
    private var accentBuffer: AVAudioPCMBuffer?
    private var metroTimer: DispatchSourceTimer?
    private var clickGrid: [(time: Double, accent: Bool)] = []  // click times + downbeat flags
    private var nextClick = 0
    private let metroQueue = DispatchQueue(label: "woodshed.metronome", qos: .userInteractive)

    init() {
        engine.attach(sampler)
        engine.connect(sampler, to: engine.mainMixerNode, format: nil)
        engine.attach(clickNode)
        let sr = engine.mainMixerNode.outputFormat(forBus: 0).sampleRate
        clickFormat = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1)
        engine.connect(clickNode, to: engine.mainMixerNode, format: clickFormat)
        clickBuffer  = makeClick(frequency: 1000, amplitude: 0.5)  // normal beat
        accentBuffer = makeClick(frequency: 1500, amplitude: 0.7)  // downbeat
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

    /// Provide the precomputed click grid (click times + downbeat accents) for the piece.
    func configureMetronome(clickGrid: [(time: Double, accent: Bool)]) {
        self.clickGrid = clickGrid
    }

    /// Toggle the metronome. It only sounds while playback is running, and it clicks
    /// on the piece's barlines/pulses (in sync with the music).
    func setMetronome(_ on: Bool) {
        metronomeOn = on
        if on && isPlaying { startMetroTimer() } else { stopMetroTimer() }
    }

    private func startMetroTimer() {
        stopMetroTimer()
        nextClick = 0
        // Poll the playback position often (~4 ms) and fire any clicks we've reached.
        let timer = DispatchSource.makeTimerSource(queue: metroQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(4), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let t = self.currentTime
            while self.nextClick < self.clickGrid.count && self.clickGrid[self.nextClick].time <= t {
                self.click(accent: self.clickGrid[self.nextClick].accent)
                self.nextClick += 1
            }
        }
        metroTimer = timer
        timer.resume()
    }

    private func stopMetroTimer() {
        metroTimer?.cancel(); metroTimer = nil
    }

    private func click(accent: Bool) {
        guard let buf = accent ? accentBuffer : clickBuffer else { return }
        clickNode.scheduleBuffer(buf, at: nil, options: .interrupts, completionHandler: nil)
    }

    /// Load the system GM sound bank and select Acoustic Grand Piano (program 0).
    private func loadPianoSound() {
        let dls = URL(fileURLWithPath:
            "/System/Library/Components/CoreAudio.component/Contents/Resources/gs_instruments.dls")
        guard FileManager.default.fileExists(atPath: dls.path) else {
            status = "no system sound bank — playback will be silent"
            return
        }
        do {
            try sampler.loadSoundBankInstrument(at: dls, program: 0, bankMSB: 0x79, bankLSB: 0)
        } catch {
            status = "sound load error: \(error.localizedDescription)"
        }
    }

    /// Point the player at a MIDI file, routing all its tracks to the piano sampler.
    func load(midiURL: URL) {
        stop()
        let seq = AVAudioSequencer(audioEngine: engine)
        do {
            try seq.load(from: midiURL, options: [])
            for track in seq.tracks { track.destinationAudioUnit = sampler }
            seq.prepareToPlay()
            sequencer = seq
        } catch {
            status = "midi load error: \(error.localizedDescription)"
        }
    }

    /// Real elapsed playback time in seconds (same time base as our parsed onsets).
    var currentTime: TimeInterval { sequencer?.currentPositionInSeconds ?? 0 }

    func play() {
        guard let seq = sequencer else { return }
        do {
            if !engine.isRunning { try engine.start() }
            seq.currentPositionInSeconds = 0
            try seq.start()
            isPlaying = true
            if metronomeOn { startMetroTimer() }
        } catch {
            status = "play error: \(error.localizedDescription)"
        }
    }

    func stop() {
        stopMetroTimer()
        if let seq = sequencer {
            if seq.isPlaying { seq.stop() }
            seq.currentPositionInSeconds = 0
        }
        isPlaying = false
    }
}
