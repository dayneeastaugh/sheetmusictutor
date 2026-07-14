//
//  PracticeView.swift
//  Woodshed
//
//  The practice screen — presentation only (logic lives in `PracticeSession`).
//
//  Layout (the audit's Wave-3 restructure): the notation CANVAS is the hero — a slim
//  transport header (mode · status · Play), the ingest-quality banner when needed,
//  the score, and a collapsible keyboard. Everything set-and-forget lives in a
//  trailing INSPECTOR with three tabs: Controls (Playback / Focus / Start / Grading /
//  View groups), Progress, and Flags — first-class, not buried in a menu. The ⋯ menu
//  keeps only true utilities (cursor actions, diagnostics). `.inspector` adapts
//  natively on iPad (collapsible column / sheet). See docs/DESIGN.md.
//

import SwiftUI
import Combine
import UniformTypeIdentifiers

struct PracticeView: View {
    let song: Song
    @ObservedObject var library: SongLibrary
    @StateObject private var session: PracticeSession
    @ObservedObject private var debugLog = DebugLog.shared
    @State private var showDiagnostics = false
    @State private var showHelp = false
    @State private var showLogExporter = false
    @State private var logDoc: TextFileDocument?
    @State private var showInspector = true
    @State private var inspectorTab: InspectorTab = .controls
    // Persisted globally (matches AppSettings.keyboardVisibleKey) so "Show keyboard"
    // carries across song switches and app launches like the other view preferences.
    @AppStorage("pref.keyboardVisible") private var keyboardVisible = true
    @State private var flagEditorBar: Int?      // non-nil ⇒ inline flag editor open (from a score tap)
    @State private var flagEditorNote = ""
    @State private var showSectionNamePrompt = false
    @State private var sectionNameText = ""

    private enum InspectorTab: String, CaseIterable, Identifiable {
        case controls = "Controls", progress = "Progress", flags = "Flags"
        var id: String { rawValue }
    }

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
        VStack(spacing: 8) {
            header
            if session.practiceMode == .drill { drillProgressBar }
            if let warning = session.ingestWarning { ingestBanner(warning) }
            if let outputWarning = session.outputWarning { infoBanner(outputWarning, systemImage: "pianokeys") }
            // In a Drill the progress bar carries all the status, so we drop the
            // status line entirely to give the score the maximum room.
            if session.practiceMode != .drill { statusBar }
            notation
            keyboardArea
        }
        .padding(10)
        // Escape clears any bar selection, even when the notation web view isn't
        // focused (the web layer also handles Escape / whitespace-click). A modal, if
        // present, takes Escape first; this is a no-op when nothing is selected.
        .background(
            Button("") { if !session.isFullPiece { session.clearBarSelection() } }
                .keyboardShortcut(.cancelAction)
                .opacity(0).accessibilityHidden(true)
        )
        .navigationTitle(song.title)
        #if os(macOS)
        .navigationSubtitle(subtitle)
        #endif
        .inspector(isPresented: $showInspector) { inspectorPanel }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showInspector.toggle() } label: {
                    Label("Inspector", systemImage: "sidebar.trailing")
                }
                .help("Show or hide the controls panel")
            }
            ToolbarItem(placement: .primaryAction) { moreMenu }
        }
        .onAppear {
            session.onPassRecorded = { [library, song] pass in library.recordPass(pass, for: song) }
            session.onSaveBarsPerLine = { [library, song] n in library.setBarsPerLine(n, for: song) }
            session.onSaveScoreZoom = { [library, song] z in library.setScoreZoom(z, for: song) }
            session.onFlagTapped = { bar in flagEditorBar = bar; flagEditorNote = session.flagNote(forBar: bar) ?? "" }
            session.onAppear()
        }
        // Deterministic teardown on song switch / window close: stop playback, silence
        // the piano, and drop the MIDI connection NOW — never rely on deinit timing
        // (SwiftUI can keep the replaced view's @StateObject alive; the old song kept
        // playing and its MIDI input kept receiving).
        .onDisappear { session.shutdown() }
        .onReceive(tick) { _ in session.advanceCursorWithPlayback() }
        .onChange(of: session.audio.isPlaying) { was, now in session.playingChanged(was, now) }
        .sheet(isPresented: $showDiagnostics) { diagnosticsSheet }
        .sheet(isPresented: $showHelp) { helpSheet }
        .fileExporter(isPresented: $showLogExporter, document: logDoc,
                      contentType: .plainText, defaultFilename: "segno-debug-log") { _ in logDoc = nil }
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
        .alert("Save section (bars \(session.sectionStart)–\(session.sectionEnd))",
               isPresented: $showSectionNamePrompt) {
            TextField("Name (e.g. Bridge)", text: $sectionNameText)
            Button("Save") { session.saveCurrentSection(named: sectionNameText) }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Saved sections appear in the Focus group for one-tap recall.")
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
            Picker("Training session", selection: Binding(get: { session.practiceMode },
                                                           set: { session.practiceMode = $0 })) {
                ForEach(PracticeSession.PracticeMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .help("Training session type — " + PracticeSession.PracticeMode.allCases
                    .map { "\($0.title): \($0.blurb)" }.joined(separator: " · "))

            Spacer()

            if !session.audio.status.isEmpty {
                Text(session.audio.status).font(.caption).foregroundStyle(.orange)
            }
            // Metronome lives with the transport — it's a live performance control,
            // not a set-and-forget setting. Icon-only; the tooltip carries the words.
            Toggle(isOn: Binding(get: { session.audio.metronomeOn },
                                 set: { session.setMetronome($0) })) {
                Label("Metronome", systemImage: "metronome")
                    .labelStyle(.iconOnly)
            }
            .toggleStyle(.button)
            .help(session.audio.metronomeOn ? "Metronome on — click to turn off"
                                            : "Metronome — clicks the beat in time with the music")
            transport
        }
    }

    /// The transport cluster: ⏮ reset · ◀ bar · ▶︎ Play (prominent) · bar ▶.
    /// Bar-stepping is disabled in Grade (it would corrupt the pass) and Wait
    /// (which steps by notes); everything is disabled in Wait except its own flow.
    private var transport: some View {
        HStack(spacing: 2) {
            transportButton("backward.end.fill", help: "Back to the start of the section") {
                session.transportReset()
            }
            .disabled(session.waitMode)
            transportButton("backward.frame.fill", help: "Back one bar") { session.stepBar(-1) }
                .disabled(!session.canStepBars)
            Button { session.togglePlay() } label: {
                Image(systemName: session.armed ? "clock.fill"
                                                : (session.audio.isPlaying ? "stop.fill" : "play.fill"))
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 46, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.space, modifiers: [])
            .disabled(session.waitMode)   // Wait mode is driven by your keys, not transport
            .help(playHelp)
            .accessibilityLabel(session.armed ? "Cancel waiting for first note"
                                : (session.audio.isPlaying ? "Stop" : "Play"))
            transportButton("forward.frame.fill", help: "Forward one bar") { session.stepBar(1) }
                .disabled(!session.canStepBars)
        }
        .padding(4)
        .background(Capsule().fill(.quaternary.opacity(0.6)))
    }

    private var playHelp: String {
        session.armed ? "Waiting for your first note — press to cancel"
            : (session.audio.isPlaying ? "Stop (Space)"
                : (session.practiceMode == .drill ? "Start drill from the start tempo (Space)"
                                                  : "Play (Space)"))
    }

    private func transportButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .imageScale(.medium)
                .frame(width: 32, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
        .accessibilityLabel(help)   // .help is a Mac tooltip; VoiceOver needs this
    }

    // MARK: - Drill progress (prominent, below the header)

    @ViewBuilder
    private var drillProgressBar: some View {
        HStack(spacing: 14) {
            // Left ~2/3 — the title + the progress bar itself.
            HStack(spacing: 10) {
                Image(systemName: session.progressiveDrill ? "square.stack.3d.up" : "gauge.with.dots.needle.67percent")
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(session.progressiveDrill ? "Progressive drill" : "Speed drill")
                            .font(.caption).bold()
                        if session.mastered {
                            Label("complete", systemImage: "checkmark.seal.fill")
                                .font(.caption).foregroundStyle(.green)
                        }
                    }
                    .lineLimit(1)
                    ProgressView(value: session.mastered ? 1 : (session.drillProgress ?? 0))
                        .tint(session.mastered ? .green : .accentColor)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider().frame(height: 34)

            // Right ~1/3 — the numbers, called out prominently.
            HStack(alignment: .center, spacing: 18) { drillStats }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10).fill(.tint.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.tint.opacity(0.30)))
    }

    /// The at-a-glance numbers in the right third of the drill bar.
    @ViewBuilder
    private var drillStats: some View {
        if session.progressiveDrill {
            let w = session.progressiveWindow
            drillStat("Bars built", "\(w.built)/\(w.total)")
            if session.speedPassesPerStep > 1 {
                drillStat("Clean", "\(session.passesAtThisTempo)/\(session.speedPassesPerStep)")
            }
        } else {
            drillStat("Tempo", "\(Int(session.tempoPct))%", tint: .accentColor)
            drillStat(session.speedMode == .byAccuracy ? "Clean passes" : "Loops",
                      "\(session.passesAtThisTempo)/\(session.speedPassesPerStep)")
        }
        if let r = session.gradeResult {
            drillStat("Last pass", "\(Int(r.accuracy * 100))%",
                      tint: r.accuracy >= session.speedThreshold ? .green : .orange)
        }
    }

    private func drillStat(_ label: String, _ value: String, tint: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            Text(value).font(.title3).bold().monospacedDigit().foregroundStyle(tint)
        }
        .fixedSize()
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

    /// A lighter, informational banner (e.g. "no piano connected") — blue, no Details.
    private func infoBanner(_ text: String, systemImage: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage).foregroundStyle(.blue)
            Text(text).font(.caption)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(.blue.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.blue.opacity(0.35)))
    }

    // MARK: - Status line (mode feedback + review marks)

    @ViewBuilder
    private var statusBar: some View {
        HStack(spacing: 10) {
            if session.armed {
                Label("Play a note to start…", systemImage: "hand.point.up.left")
                    .foregroundStyle(.blue)
            } else if session.progressiveDrill {
                if session.mastered {
                    Label("Passage complete — every bar clean 🎉", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                } else {
                    Text("Progressive drill · bars \(session.sectionStart)–\(session.sectionEnd)"
                         + (session.gradeResult.map { " · last \(Int($0.accuracy * 100))%" } ?? "")
                         + " · play the newest bar clean to add the next")
                        .foregroundStyle(.blue)
                }
            } else if session.speedMode != .off {
                if session.mastered {
                    // The % is TEMPO, not a score. "Every few loops" (byReps) advances
                    // without checking accuracy, so it only reached the goal tempo — it
                    // didn't prove mastery; say so honestly.
                    let msg = session.speedMode == .byReps
                        ? "Reached goal tempo — \(Int(session.tempoPct))% 🏁"
                        : "Mastered! Clean at \(Int(session.tempoPct))% tempo 🎉"
                    Label(msg, systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                } else {
                    let unit = session.speedMode == .byAccuracy ? "clean" : "loops"
                    let stage = session.handsProgression ? "\(session.drillStage.title) · " : ""
                    Text("Speed drill · \(stage)\(Int(session.tempoPct))% → \(Int(session.speedTargetPct))% tempo · "
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
                if session.passAbandoned {
                    Text("Pass abandoned — stopped before the end (not recorded)")
                        .foregroundStyle(.secondary)
                } else if let r = session.gradeResult {
                    Text("Pass \(session.gradeHistory.count): \(Int(r.accuracy * 100))% · Missed \(r.missed) · Wrong \(r.extra) · ±\(Int(r.avgMs))ms · \(timingFeel(r.signedMs))")
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
            } else if !session.audio.isPlaying && session.playheadBar != session.sectionStart {
                Text("▶ Play starts at bar \(session.playheadBar) · ⏮ to go back to bar \(session.sectionStart)")
                    .foregroundStyle(.secondary)
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

    // MARK: - Notation (hero — fills the canvas)

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
                .background(Color.white)   // the score is deliberately "paper" in both colour schemes
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.secondary.opacity(0.3)))
        }
    }

    // MARK: - Inspector (Controls / Progress / Flags)

    private var inspectorPanel: some View {
        VStack(spacing: 0) {
            Picker("", selection: $inspectorTab) {
                ForEach(InspectorTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(10)
            Divider()
            switch inspectorTab {
            case .controls:
                controlsTab
            case .progress:
                ProgressPanel(song: song, passes: session.history,
                              practicedToday: session.practicedToday,
                              lastPassDetail: session.lastPassDetail,
                              onDrillBar: { session.focusBar($0) },
                              onReset: { library.resetProgress(for: song); session.reloadHistory() })
            case .flags:
                FlagsPanel(session: session)
            }
        }
        // Fill the column top-aligned so the Controls Form pins to the top like the
        // scrolling Progress/Flags tabs, instead of centring vertically.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .inspectorColumnWidth(min: 250, ideal: 300, max: 400)
    }

    /// The current training-session type — drives which settings are shown.
    private var mode: PracticeSession.PracticeMode { session.practiceMode }
    private var isGraded: Bool { mode == .grade || mode == .drill }

    private var controlsTab: some View {
        Form {
            Section("Hands & sound") {
                Picker("Hands", selection: $session.handMode) {
                    Text("Both").tag(0); Text("R.H.").tag(1); Text("L.H.").tag(2)
                }
                .pickerStyle(.segmented)
                Picker("Output", selection: $session.outputMode) {
                    Text("Speakers").tag(0); Text("Piano").tag(1); Text("Both").tag(2)
                }
            }
            if mode != .wait {
                Section("Playback") {
                    LabeledContent("Tempo") {
                        HStack(spacing: 6) {
                            Slider(value: $session.tempoPct, in: 25...120, step: 5)
                            Text("\(Int(session.tempoPct))%")
                                .font(.system(.caption, design: .monospaced)).frame(width: 38)
                        }
                    }
                    // The metronome on/off toggle lives in the transport; these are its behaviour.
                    Toggle("Metronome starts with playback", isOn: $session.metronomeStartsWithPlayback)
                    Toggle("Metronome stops with playback", isOn: $session.metronomeStopsWithPlayback)
                    if mode == .practice || mode == .grade {
                        Toggle("Rhythm only (ticks + tap along)", isOn: $session.rhythmMode)
                    }
                }
            }
            Section(mode == .drill ? "Section to drill" : "Focus") {
                Button { session.drillMe() } label: { Label("Suggest a spot", systemImage: "target") }
                    .help("Pick a section to work on: worst trouble bar, else oldest flag, else random — and loop it")
                if let reason = session.drillReason {
                    Text(reason).font(.caption2).foregroundStyle(.secondary)
                }
                LabeledContent("Section") {
                    HStack(spacing: 4) {
                        Stepper("\(session.sectionStart)", value: $session.sectionStart, in: 1...session.measureCount)
                            .fixedSize()
                        Text("–").foregroundStyle(.secondary)
                        Stepper("\(session.sectionEnd)", value: $session.sectionEnd, in: session.sectionStart...session.measureCount)
                            .fixedSize()
                    }
                }
                if mode == .practice || mode == .grade {
                    Toggle("Loop section", isOn: $session.loopSection)
                }
                if mode != .wait {
                    Picker("Loop count-in", selection: $session.loopCountInPulses) {
                        Text("Off").tag(0)
                        ForEach(1...session.pulsesPerBar, id: \.self) { n in
                            Text(n == session.pulsesPerBar ? "Full bar (\(n))" : (n == 1 ? "1 beat" : "\(n) beats")).tag(n)
                        }
                    }
                }
                if !session.isFullPiece {
                    Button("Whole piece") { session.selectWholePiece() }
                }
                ForEach(session.savedSections) { s in
                    HStack {
                        Button("\(s.name)  (\(s.start)–\(s.end))") { session.applySavedSection(s) }
                            .buttonStyle(.borderless)
                        Spacer()
                        Button(role: .destructive) { session.deleteSavedSection(s) } label: {
                            Image(systemName: "trash").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help("Delete this saved section")
                    }
                }
                Button {
                    sectionNameText = ""
                    showSectionNamePrompt = true
                } label: { Label("Save current section…", systemImage: "bookmark") }
                    .disabled(session.isFullPiece)
            }
            if mode == .drill { drillSection }
            if mode != .wait {
                Section("Start") {
                    Picker("Count-in", selection: $session.countInBars) {
                        Text("Off").tag(0); Text("1 bar").tag(1); Text("2 bars").tag(2)
                    }
                    if mode != .drill {
                        Toggle("Start on my first note", isOn: $session.startOnFirstNote)
                    }
                }
            }
            if isGraded {
                Section("Grading") {
                    Picker("Timing tolerance", selection: $session.gradeTolerance) {
                        Text("Strict (±150 ms)").tag(0.15)
                        Text("Normal (±300 ms)").tag(0.30)
                        Text("Relaxed (±450 ms)").tag(0.45)
                    }
                }
                takesSection
            }
            Section("View") {
                Picker("Bars per line", selection: $session.barsPerLine) {
                    Text("Auto").tag(0)
                    ForEach(1...5, id: \.self) { Text("\($0)").tag($0) }
                }
                // Bars per line is a MAXIMUM — dense music may not fit that many at
                // full size. Shrinking the score is how you make it achievable.
                Picker("Score size", selection: $session.scoreZoom) {
                    Text("60%").tag(0.6); Text("70%").tag(0.7); Text("80%").tag(0.8)
                    Text("90%").tag(0.9); Text("100%").tag(1.0); Text("115%").tag(1.15)
                    Text("130%").tag(1.3)
                }
                Toggle("Smooth cursor", isOn: $session.cursorSmooth)
                Toggle("Highlight score notes", isOn: $session.showScoreNotes)
                Toggle("Problem marks on score", isOn: $session.showTroubleOnScore)
                    .help("Show trouble bars (amber), missed notes, and wrong notes on the score")
                Toggle("Colour hands", isOn: $session.colorHands)
                Toggle("Show keyboard", isOn: $keyboardVisible)
            }
        }
        .formStyle(.grouped)
    }

    /// The drill setup (shown only in the Drill session type). No "off" here — you
    /// leave a drill by switching training-session type.
    @ViewBuilder
    private var drillSection: some View {
        Section("Drill") {
            Picker("Drill", selection: Binding(get: { session.drillStyle },
                                               set: { session.drillStyle = $0 })) {
                ForEach(PracticeSession.DrillStyle.allCases) { Text($0.title).tag($0) }
            }
            if session.progressiveDrill {
                Picker("“Clean” means", selection: $session.speedThreshold) {
                    ForEach([80, 85, 90, 95, 100], id: \.self) { Text("≥ \($0)%").tag(Double($0) / 100) }
                }
                Picker("Clean passes to add a bar", selection: $session.speedPassesPerStep) {
                    ForEach(1...8, id: \.self) { Text("\($0)").tag($0) }
                }
                .help("Play the newest bar clean this many times in a row before the next bar is added")
            } else {
                Picker("Speed up", selection: $session.speedMode) {
                    Text("When I play it clean").tag(PracticeSession.SpeedTrainerMode.byAccuracy)
                    Text("Every few loops").tag(PracticeSession.SpeedTrainerMode.byReps)
                }
                Picker("Start tempo", selection: $session.speedStartPct) {
                    ForEach([40, 50, 60, 70, 80, 90], id: \.self) { Text("\($0)%").tag(Double($0)) }
                }
                Picker("Goal tempo", selection: $session.speedTargetPct) {
                    ForEach([60, 70, 80, 90, 100, 110, 120], id: \.self) { Text("\($0)%").tag(Double($0)) }
                }
                Picker("Speed up by", selection: $session.speedStepPct) {
                    ForEach([2, 5, 10], id: \.self) { Text("+\($0)%").tag(Double($0)) }
                }
                if session.speedMode == .byAccuracy {
                    Picker("“Clean” means", selection: $session.speedThreshold) {
                        ForEach([80, 85, 90, 95, 100], id: \.self) { Text("≥ \($0)%").tag(Double($0) / 100) }
                    }
                    Picker("Clean passes to speed up", selection: $session.speedPassesPerStep) {
                        ForEach(1...8, id: \.self) { Text("\($0)").tag($0) }
                    }
                } else {
                    Picker("Loops before speeding up", selection: $session.speedPassesPerStep) {
                        ForEach(1...8, id: \.self) { Text("\($0)").tag($0) }
                    }
                }
                Toggle("One hand at a time, then together", isOn: $session.handsProgression)
            }
            Toggle("Keep mistakes from last loop", isOn: $session.keepDrillMistakes)
                .help("Carry the previous loop's missed/wrong marks into the next as a heads-up; they clear once you stop making them")
            Text(session.drillSummary).font(.caption2).foregroundStyle(.secondary)
            Label(session.audio.isPlaying ? "Press ◼ Stop above to end the drill"
                                          : "Press ▶ Play above to start the drill",
                  systemImage: "arrow.up").font(.caption2).foregroundStyle(.secondary)
        }
    }

    /// Take replay (shown for graded session types).
    @ViewBuilder
    private var takesSection: some View {
        Section("Takes") {
            if session.isReplaying {
                Button { session.stopReplay() } label: { Label("Stop replay", systemImage: "stop.circle") }
            } else {
                Button {
                    if let t = session.lastTake { session.startReplay(t) }
                } label: {
                    Label(session.lastTake.map { "Play last take (\($0.notes.count) notes)" }
                          ?? "Play last take", systemImage: "play.circle")
                }
                .disabled(session.lastTake == nil || session.audio.isPlaying)
                Button {
                    if let t = session.bestTakeForCurrentSection { session.startReplay(t) }
                } label: {
                    Label(session.bestTakeForCurrentSection.map {
                            "Play best take (\(Int(($0.accuracy ?? 0) * 100))%)"
                          } ?? "Play best take", systemImage: "star.circle")
                }
                .disabled(session.bestTakeForCurrentSection == nil || session.audio.isPlaying)
            }
            Text("Every pass records what you play. The best graded take per section is kept.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    /// The overflow menu — true utilities only (transport + controls live elsewhere).
    private var moreMenu: some View {
        Menu {
            // Help is reachable here on BOTH platforms (iPad has no menu bar, so the
            // macOS Help menu / ⌘? isn't available there).
            Button { showHelp = true } label: { Label("Segno Help", systemImage: "questionmark.circle") }
            Button { showDiagnostics = true } label: { Label("Show diagnostics…", systemImage: "stethoscope") }
        } label: {
            Label("More", systemImage: "ellipsis.circle")
        }
    }

    /// Help presented as a sheet with its own Done button (used on iPad, and available
    /// from the ⋯ menu on Mac too). On Mac the menu-bar Help ⌘? opens a window instead.
    private var helpSheet: some View {
        NavigationStack {
            HelpView()
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showHelp = false } } }
        }
    }

    // MARK: - Keyboard

    @ViewBuilder
    private var keyboardArea: some View {
        if keyboardVisible {
            KeyboardPanel(session: session, midi: session.midi, lights: session.lights, height: keyboardHeight)
        } else {
            HStack {
                Text(session.midi.status).font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button { keyboardVisible = true } label: {
                    Label("Show keyboard", systemImage: "pianokeys").font(.caption2)
                }
                .buttonStyle(.borderless)
            }
        }
    }

    // MARK: - Diagnostics (behind the More menu — score facts + reconciliation + events)

    private var diagnosticsSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    debugLogSection
                    Divider()
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
        .frame(minWidth: 480, minHeight: 560)
    }

    @ViewBuilder
    private var debugLogSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Diagnostic logging").font(.headline)
            Toggle("Record a detailed log (MIDI input, grading, drills)", isOn: $debugLog.enabled)
            Text("Off by default. Turn on, reproduce the issue, then Export the log — it's a single file you can send. The setting and the log survive restarts.")
                .font(.caption2).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button("Export log…") { exportDebugLog() }
                    .disabled(debugLog.byteCount == 0)
                Button("Clear log", role: .destructive) { debugLog.clear() }
                    .disabled(debugLog.byteCount == 0)
                Spacer()
                Text(debugLog.byteCount > 0 ? "\(debugLog.byteCount) bytes" : "empty")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if debugLog.enabled && !debugLog.tail.isEmpty {
                Text("Recent (live tail)").font(.caption).foregroundStyle(.secondary).padding(.top, 2)
                ScrollView {
                    Text(debugLog.tail.suffix(40).joined(separator: "\n"))
                        .font(.system(.caption2, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(height: 120)
                .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.4)))
            }
        }
    }

    /// Cross-platform log export (macOS save panel + iPad share/save sheet) via
    /// `.fileExporter` — the old `NSSavePanel` path was a dead button on iPad.
    private func exportDebugLog() {
        guard let url = debugLog.exportURL(),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        logDoc = TextFileDocument(text: text)
        showLogExporter = true
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
                    Text("\(r.hand.rawValue): \(r.matched) written + \(r.ornamentRealizations) ornament"
                         + (r.crossStaff > 0 ? " + \(r.crossStaff) cross-staff" : "")
                         + " = \(r.matched + r.ornamentRealizations + r.crossStaff) / \(r.midiCount) MIDI")
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

    /// The actionable half of timing feedback: are you ahead of or behind the beat?
    private func timingFeel(_ signedMs: Double) -> String {
        if abs(signedMs) < 8 { return "on time" }
        return signedMs < 0 ? "rushing ~\(Int(-signedMs))ms" : "dragging ~\(Int(signedMs))ms"
    }
}

/// The on-screen keyboard, split into its own view so it can observe `MIDIInput`
/// and `KeyboardLights` **directly** — it repaints on each key press / highlight
/// change without re-rendering the whole practice screen.
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
                Text("Green = you · RH blue / LH orange")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text(midi.status).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}
