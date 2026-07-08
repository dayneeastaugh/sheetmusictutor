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

struct ContentView: View {
    @State private var score: FusedScore?
    @State private var errorText: String?
    @State private var sampleName = "Fly Me To the Moon"
    @State private var xmlBase64 = ""
    @State private var cursorCommand = CursorCommand()
    @StateObject private var bridge = NotationBridge()
    @StateObject private var audio = AudioEnginePlayer()

    // Cursor-sync state: a schedule of (playback time → notated beat). A display
    // timer reads the audio clock and moves the OSMD cursor to the matching beat.
    @State private var schedule: [(time: Double, beat: Double)] = []
    @State private var scoreDuration: Double = 0
    @State private var lastSentBeat: Double = -1
    private let tick = Timer.publish(every: 0.03, on: .main, in: .common).autoconnect()

    private let sampleNames = ["Fly Me To the Moon",
                               "chopin-nocturne-op-9-no-2-e-flat-major"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Woodshed — Phase 0 ingestion spike")
                    .font(.title2).bold()

                Picker("Piece", selection: $sampleName) {
                    ForEach(sampleNames, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.segmented)
                .onChange(of: sampleName) { _, _ in score = nil; errorText = nil; ingest() }

                notationSection

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
        .onAppear(perform: ingest)
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
                Toggle("🎵 Metronome", isOn: Binding(
                    get: { audio.metronomeOn },
                    set: { audio.setMetronome($0) }))
                    .toggleStyle(.button)
                Button("Step cursor ▶") { cursorCommand = .init(nonce: cursorCommand.nonce + 1, action: "next") }
                    .disabled(audio.isPlaying)
                Button("Reset ⟲") { resetCursor() }
                if !audio.status.isEmpty {
                    Text(audio.status).font(.caption).foregroundStyle(.orange)
                }
            }
        }
        .onReceive(tick) { _ in advanceCursorWithPlayback() }
    }

    // MARK: - Playback + cursor sync

    private func togglePlay() {
        if audio.isPlaying {
            audio.stop()
        } else {
            resetCursor()
            audio.play()
        }
    }

    private func resetCursor() {
        lastSentBeat = -1
        cursorCommand = .init(nonce: cursorCommand.nonce + 1, action: "reset")
    }

    /// On each timer tick, move the OSMD cursor to the notated beat the playback
    /// clock has reached. Driving by beat (not by step count) is robust to swing,
    /// rubato, chords, and rest-only cursor stops.
    private func advanceCursorWithPlayback() {
        guard audio.isPlaying else { return }
        let t = audio.currentTime
        if scoreDuration > 0 && t > scoreDuration + 0.5 {   // reached the end
            audio.stop()
            return
        }
        // The notated beat of the latest note whose onset time has passed.
        var targetBeat = schedule.first?.beat ?? 0
        for entry in schedule where entry.time <= t { targetBeat = entry.beat }
        if targetBeat != lastSentBeat {
            lastSentBeat = targetBeat
            cursorCommand = .init(nonce: cursorCommand.nonce + 1, action: "toBeat", beat: targetBeat)
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private func summary(_ s: FusedScore) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(sampleName).font(.headline)
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
        guard let midiURL = url(sampleName, "mid"),
              let xmlURL = url(sampleName, "musicxml") else {
            errorText = "Couldn't find \(sampleName).mid / .musicxml in the app bundle."
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
            lastSentBeat = -1
            audio.load(midiURL: midiURL)
            audio.configureMetronome(clickGrid: fused.clickGrid)
            print("=== Woodshed fused: \(sampleName) — \(fused.events.count) events, tempo \(fused.tempoBPM) ===")
            for r in fused.reconciliations {
                print("\(r.hand.rawValue): XML=\(r.xmlSoundingCount) MIDI=\(r.midiCount) matched=\(r.matched) " +
                      "extraMIDI=\(r.unmatchedMIDI.count) missingXML=\(r.unmatchedXML.count)")
            }
        } catch {
            errorText = "\(error)"
        }
    }

    private func url(_ name: String, _ ext: String) -> URL? {
        Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "Scores")
            ?? Bundle.main.url(forResource: name, withExtension: ext)
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

#Preview {
    ContentView()
}
