//
//  PracticeView.swift
//  Woodshed
//
//  The practice screen — presentation only (logic lives in `PracticeSession`).
//  Layout: the notation is the hero (fills the pane); a thin header carries the
//  mode selector + transport; one wrapping control bar sits below it; the keyboard
//  is always visible (shorter on iPad). The old diagnostic dump now lives behind a
//  "Show diagnostics" item in the More menu. Reflows for Mac and iPad. See docs/DESIGN.md.
//

import SwiftUI
import Combine

struct PracticeView: View {
    let song: Song
    @ObservedObject var library: SongLibrary
    @StateObject private var session: PracticeSession
    @State private var showDiagnostics = false
    @State private var showProgress = false
    @State private var showFlags = false
    @State private var flagEditorBar: Int?      // non-nil ⇒ inline flag editor open (from a score tap)
    @State private var flagEditorNote = ""

    init(song: Song, library: SongLibrary) {
        self.song = song
        self.library = library
        _session = StateObject(wrappedValue: PracticeSession(song: song))
    }

    // Keyboard strip: a touch shorter on iPad to leave more room for the notation.
    #if os(iOS)
    private let keyboardHeight: CGFloat = 74
    #else
    private let keyboardHeight: CGFloat = 88
    #endif

    // ~50 Hz so the cursor glides smoothly (the web view interpolates position).
    private let tick = Timer.publish(every: 0.02, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 10) {
            header
            if let warning = session.ingestWarning { ingestBanner(warning) }
            statusBar
            notation
            controlBar
            keyboardArea
        }
        .padding()
        .navigationTitle(song.title)
        #if os(macOS)
        .navigationSubtitle(subtitle)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) { moreMenu }
        }
        .onAppear {
            session.onPassRecorded = { [library, song] pass in library.recordPass(pass, for: song) }
            session.onSaveBarsPerLine = { [library, song] n in library.setBarsPerLine(n, for: song) }
            session.onFlagTapped = { bar in flagEditorBar = bar; flagEditorNote = session.flagNote(forBar: bar) ?? "" }
            session.onAppear()
        }
        .onReceive(tick) { _ in session.advanceCursorWithPlayback() }
        .onChange(of: session.audio.isPlaying) { was, now in session.playingChanged(was, now) }
        .sheet(isPresented: $showDiagnostics) { diagnosticsSheet }
        .sheet(isPresented: $showProgress) {
            PracticeProgressView(song: song, passes: session.history,
                                 onDrillBar: { session.focusBar($0) },
                                 onReset: { library.resetProgress(for: song); session.reloadHistory() })
        }
        .sheet(isPresented: $showFlags) { BarFlagsView(session: session) }
        .alert("Flag bar \(flagEditorBar ?? 0)", isPresented: Binding(get: { flagEditorBar != nil },
                                                                      set: { if !$0 { flagEditorBar = nil } })) {
            TextField("Note (e.g. LH jump)", text: $flagEditorNote)
            Button("Save") { if let b = flagEditorBar { session.setFlag(bar: b, note: flagEditorNote) }; flagEditorBar = nil }
            if let b = flagEditorBar, session.flagNote(forBar: b) != nil {
                Button("Delete", role: .destructive) { if let b = flagEditorBar { session.removeFlag(bar: b) }; flagEditorBar = nil }
            }
            Button("Cancel", role: .cancel) { flagEditorBar = nil }
        } message: {
            Text("A short reminder of what to work on at this bar.")
        }
    }

    private var subtitle: String {
        guard let s = session.score else { return "" }
        let ts = s.timeSignature.map { "\($0.num)/\($0.den)" } ?? "—"
        return "\(Int(s.tempoBPM)) BPM · \(ts) · \(keyName(s.keyFifths)) · \(s.events.count) notes"
    }

    // MARK: - Header (mode + transport)

    private var header: some View {
        HStack(spacing: 12) {
            Picker("Mode", selection: Binding(get: { session.practiceMode },
                                              set: { session.practiceMode = $0 })) {
                ForEach(PracticeSession.PracticeMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .help("Practice = play & follow · Wait = advance on the right notes · Grade = play at tempo, get scored")

            Spacer()

            if !session.audio.status.isEmpty {
                Text(session.audio.status).font(.caption).foregroundStyle(.orange)
            }
            Button { session.togglePlay() } label: {
                Label(session.armed ? "Waiting…" : (session.audio.isPlaying ? "Stop" : "Play"),
                      systemImage: session.armed ? "clock" : (session.audio.isPlaying ? "stop.fill" : "play.fill"))
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.space, modifiers: [])
            .disabled(session.waitMode)   // Wait mode is driven by your keys, not transport
        }
    }

    // MARK: - Ingest-quality banner (never grade silently against a wrong model)

    private func ingestBanner(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(text).font(.caption)
            Spacer()
            Button("Details") { showDiagnostics = true }
                .font(.caption).buttonStyle(.borderless)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(.orange.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.orange.opacity(0.4)))
    }

    // MARK: - Status line (mode feedback + review marks)

    @ViewBuilder
    private var statusBar: some View {
        HStack(spacing: 10) {
            if session.armed {
                Label("Play a note to start…", systemImage: "hand.point.up.left")
                    .foregroundStyle(.blue)
            } else if session.speedMode != .off {
                if session.mastered {
                    Label("Section mastered at \(Int(session.tempoPct))% 🎉", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                } else {
                    let unit = session.speedMode == .byAccuracy ? "clean" : "passes"
                    Text("Speed trainer · \(Int(session.tempoPct))% → \(Int(session.speedTargetPct))% · "
                         + "\(session.passesAtThisTempo)/\(session.speedPassesPerStep) \(unit)"
                         + (session.gradeResult.map { " · last \(Int($0.accuracy * 100))%" } ?? ""))
                        .foregroundStyle(.blue)
                }
            } else if session.waitMode {
                Text((session.waitIndex < session.waitStepCount
                      ? "Play the blue notes (red = wrong) · \(session.waitIndex + 1)/\(session.waitStepCount)"
                      : "✓ Complete") + " · Fumbles: \(session.mistakeCount)")
                    .foregroundStyle(.green)
            } else if session.gradeMode {
                if let r = session.gradeResult {
                    Text("Pass \(session.gradeHistory.count): \(Int(r.accuracy * 100))% · Missed \(r.missed) · Wrong \(r.extra) · ±\(Int(r.avgMs))ms")
                        .foregroundStyle(r.accuracy >= 0.95 ? .green : .primary)
                    if session.gradeHistory.count > 1 {
                        Text("Progress " + session.gradeHistory.suffix(10).map { "\(Int($0.accuracy * 100))" }.joined(separator: "→") + "%")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("Play along — turn on 🔁 Loop to grade every pass").foregroundStyle(.secondary)
                }
            } else if session.mistakesShown {
                Text("Red = notes you fumbled").foregroundStyle(Color(red: 0.83, green: 0.18, blue: 0.18))
                Button("Clear marks") { session.clearMistakeMarks() }
                    .buttonStyle(.borderless)
            } else if !session.isFullPiece {
                Text("Section: bars \(session.sectionStart)–\(session.sectionEnd) of \(session.measureCount)")
                    .foregroundStyle(.secondary)
            } else {
                Text(session.bridge.status)
                    .foregroundStyle(session.bridge.status.hasPrefix("error") ? .red : .secondary)
            }
            Spacer()
        }
        .font(.caption)
        .frame(minHeight: 16)
    }

    // MARK: - Notation (hero — fills the pane)

    @ViewBuilder
    private var notation: some View {
        if let err = session.errorText {
            ContentUnavailableView("Couldn't load this song", systemImage: "exclamationmark.triangle",
                                   description: Text(err))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            NotationWebView(xmlBase64: session.xmlBase64,
                            command: session.cursorCommand,
                            bridge: session.bridge)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.secondary.opacity(0.3)))
        }
    }

    // MARK: - Control bar (wraps on narrow widths)

    private var controlBar: some View {
        FlowLayout(spacing: 8) {
            // Hands
            controlGroup {
                Text("Hands").font(.caption).foregroundStyle(.secondary)
                Picker("Hands", selection: $session.handMode) {
                    Text("Both").tag(0); Text("R.H.").tag(1); Text("L.H.").tag(2)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            // Tempo
            controlGroup {
                Text("Tempo").font(.caption).foregroundStyle(.secondary)
                Text("\(Int(session.tempoPct))%")
                    .font(.system(.caption, design: .monospaced)).frame(width: 40, alignment: .leading)
                Slider(value: $session.tempoPct, in: 25...120, step: 5).frame(width: 150)
            }
            // Section
            controlGroup {
                Text("Section").font(.caption).foregroundStyle(.secondary)
                Stepper("\(session.sectionStart)", value: $session.sectionStart, in: 1...session.measureCount)
                    .fixedSize()
                Text("–").foregroundStyle(.secondary)
                Stepper("\(session.sectionEnd)", value: $session.sectionEnd, in: session.sectionStart...session.measureCount)
                    .fixedSize()
                Toggle(isOn: $session.loopSection) { Label("Loop", systemImage: "repeat") }
                    .toggleStyle(.button)
                if !session.isFullPiece {
                    Button("All") { session.selectWholePiece() }
                }
            }
            // Loop count-in (beats before each pass — meter-aware)
            controlGroup {
                Text("Loop count-in").font(.caption).foregroundStyle(.secondary)
                Picker("Loop count-in", selection: $session.loopCountInPulses) {
                    Text("Off").tag(0)
                    ForEach(1...session.pulsesPerBar, id: \.self) { n in
                        Text(n == session.pulsesPerBar ? "Full bar (\(n))" : (n == 1 ? "1 beat" : "\(n) beats")).tag(n)
                    }
                }
                .pickerStyle(.menu).labelsHidden().fixedSize()
            }
            // Speed trainer (auto-tempo drill on the looped section, in Grade mode)
            Menu {
                Picker("Speed trainer", selection: $session.speedMode) {
                    ForEach(PracticeSession.SpeedTrainerMode.allCases) { Text($0.title).tag($0) }
                }
                if session.speedMode != .off {
                    Picker("Target tempo", selection: $session.speedTargetPct) {
                        ForEach([60, 70, 80, 90, 100, 110, 120], id: \.self) { Text("\($0)%").tag(Double($0)) }
                    }
                    Picker("Step", selection: $session.speedStepPct) {
                        ForEach([2, 5, 10], id: \.self) { Text("+\($0)%").tag(Double($0)) }
                    }
                    if session.speedMode == .byAccuracy {
                        Picker("Clean pass ≥", selection: $session.speedThreshold) {
                            ForEach([80, 85, 90, 95, 100], id: \.self) { Text("\($0)%").tag(Double($0) / 100) }
                        }
                    }
                    Picker("Passes per step", selection: $session.speedPassesPerStep) {
                        ForEach(1...5, id: \.self) { Text("\($0)").tag($0) }
                    }
                }
            } label: {
                Label(session.speedMode == .off ? "Speed trainer" : "Speed: \(session.speedMode.title)",
                      systemImage: "speedometer")
            }
            .fixedSize()
            // Metronome
            Toggle(isOn: Binding(get: { session.audio.metronomeOn }, set: { session.setMetronome($0) })) {
                Label("Metronome", systemImage: "metronome")
            }
            .toggleStyle(.button)
            // Output
            Picker("Output", selection: $session.outputMode) {
                Label("Speakers", systemImage: "speaker.wave.2").tag(0)
                Label("Piano", systemImage: "pianokeys").tag(1)
                Label("Both", systemImage: "square.stack.3d.up").tag(2)
            }
            .pickerStyle(.menu).fixedSize()
        }
    }

    /// The overflow menu — count-in, cursor, colour, bars/line, and the diagnostics.
    private var moreMenu: some View {
        Menu {
            Section("Start") {
                Picker("Count-in", selection: $session.countInBars) {
                    Text("No count-in").tag(0)
                    Text("1-bar count-in").tag(1)
                    Text("2-bar count-in").tag(2)
                }
                Toggle("Start on my first note", isOn: $session.startOnFirstNote)
            }
            Section("Metronome") {
                Toggle("Start with playback", isOn: $session.metronomeStartsWithPlayback)
                Toggle("Stop when playback stops", isOn: $session.metronomeStopsWithPlayback)
            }
            Section("Notation") {
                Toggle("Smooth cursor", isOn: $session.cursorSmooth)
                Toggle("Highlight score notes", isOn: $session.showScoreNotes)
                Toggle("Show trouble spots on score", isOn: $session.showTroubleOnScore)
                Toggle("Colour hands (RH blue / LH red)", isOn: $session.colorHands)
                Picker("Bars per line", selection: $session.barsPerLine) {
                    Text("Auto").tag(0)
                    ForEach(1...5, id: \.self) { Text("\($0) per line").tag($0) }
                }
            }
            Section("Cursor") {
                Button { session.stepCursor() } label: { Label("Step cursor forward", systemImage: "forward.frame") }
                    .disabled(session.audio.isPlaying)
                Button { session.resetCursor() } label: { Label("Reset cursor", systemImage: "arrow.uturn.left") }
            }
            Section {
                Button { showFlags = true } label: { Label("Flags…", systemImage: "flag") }
                Button { showProgress = true } label: { Label("Show progress…", systemImage: "chart.line.uptrend.xyaxis") }
                Button { showDiagnostics = true } label: { Label("Show diagnostics…", systemImage: "stethoscope") }
            }
        } label: {
            Label("More", systemImage: "ellipsis.circle")
        }
    }

    /// A labelled cluster of controls with a hairline border.
    private func controlGroup<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 6, content: content)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 8).stroke(.secondary.opacity(0.25)))
    }

    // MARK: - Keyboard

    private var keyboardArea: some View {
        KeyboardPanel(session: session, midi: session.midi, lights: session.lights, height: keyboardHeight)
    }

    // MARK: - Diagnostics (behind the More menu — score facts + reconciliation + events)

    private var diagnosticsSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let s = session.score {
                        summary(s)
                        Divider()
                        reconciliation(s)
                        Divider()
                        noteList(s)
                    } else {
                        Text("No parsed score.").foregroundStyle(.secondary)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("Diagnostics")
            .toolbar { Button("Done") { showDiagnostics = false } }
        }
        .frame(minWidth: 480, minHeight: 520)
    }

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

    private func keyName(_ fifths: Int) -> String {
        let majors = ["Cb","Gb","Db","Ab","Eb","Bb","F","C","G","D","A","E","B","F#","C#"]
        let idx = fifths + 7
        return (0..<majors.count).contains(idx) ? "\(majors[idx]) major" : "?"
    }
}

/// The on-screen keyboard, split into its own view so it can observe `MIDIInput`
/// **directly** — it repaints on each key press without re-rendering the whole
/// practice screen, so fast passages don't lag. It also observes the session for the
/// score-note highlight + mode flags.
private struct KeyboardPanel: View {
    @ObservedObject var session: PracticeSession
    @ObservedObject var midi: MIDIInput
    @ObservedObject var lights: KeyboardLights
    var height: CGFloat

    var body: some View {
        let showScore = session.showScoreNotes || session.waitMode || session.gradeMode
        VStack(spacing: 4) {
            PianoKeyboardView(litNotes: midi.activeNotes,
                              scoreRH: showScore ? lights.rh : [],
                              scoreLH: showScore ? lights.lh : [],
                              flagWrong: session.waitMode || session.gradeMode,
                              onPress: { session.previewNoteOn($0) },
                              onRelease: { session.previewNoteOff($0) })
                .frame(height: height)
            HStack {
                Text("Green = you · RH blue / LH red")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text(midi.status).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

/// A simple flow layout: lays children left-to-right, wrapping to the next row when
/// the current one is full. Lets the practice control bar sit in one row on a wide
/// Mac window and wrap to several rows on a narrow iPad one, with no size-class code.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > maxWidth { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += s.width + spacing
            rowHeight = max(rowHeight, s.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(maxWidth, widest), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > maxWidth { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            v.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + y), anchor: .topLeading, proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowHeight = max(rowHeight, s.height)
        }
    }
}
