//
//  PracticeProgressView.swift
//  Woodshed
//
//  The per-song progress panel: how your Grade passes are trending, the bars you
//  keep missing (tap to drill), and the recent-pass log. Reads the session's
//  in-memory history. Lives in the practice screen's INSPECTOR (Progress tab) —
//  promoted from a buried sheet so the "tutor" half of the app is first-class.
//

import SwiftUI

struct ProgressPanel: View {
    let song: Song
    let passes: [PracticePass]
    /// Named practice sections (e.g. per-scale in the scale books) — drives the mastery grid.
    var sections: [SavedSection] = []
    /// Seconds practised today (live, incl. the current session's unflushed time).
    var practicedToday: Double = 0
    /// The most recent pass broken down note-by-note (this session), for the summary.
    var lastPassDetail: PracticeSession.PassDetail? = nil
    /// The most recent pass's full report card (this session).
    var lastPassReport: PassReport? = nil
    /// Focus the practice section on a bar (drill a trouble spot).
    let onDrillBar: (Int) -> Void
    /// Recall a named section (tap a mastery-grid cell to drill that scale).
    var onApplySection: (SavedSection) -> Void = { _ in }
    /// Non-nil in the narrow inspector: shows an "Expand" button that opens the
    /// full-size progress sheet (the card/heatmap are designed for width).
    var onExpand: (() -> Void)? = nil
    /// Focus a bar AND drop the tempo ~30% with a ramp back (the remediation drill).
    var onDrillSlow: ((Int) -> Void)? = nil
    /// Flash a bar on the score (link the text feedback to the actual music).
    var onPeekBar: ((Int) -> Void)? = nil
    /// The full-size sheet passes true so the report card wraps its strip / shows all.
    var wide: Bool = false

    /// The saved-section name covering a bar, if any — lets a long-piece callout say
    /// "bar 42 — in Bridge".
    private func sectionName(for bar: Int) -> String? {
        sections.first { bar >= $0.start && bar <= $0.end }?.name
    }
    /// Wipe this song's history (called after the user confirms).
    let onReset: () -> Void

    @State private var confirmingReset = false
    @State private var totalTime: Double = 0

    private var fullRuns: [PracticePass] { passes.filter { $0.isFullPiece } }
    private var best: Double? { fullRuns.map(\.accuracy).max() }
    private var last: Double? { passes.last?.accuracy }
    private var trouble: [TroubleBar] { PracticeHistory.currentTroubleBars(passes) }

    var body: some View {
        if passes.isEmpty {
            ContentUnavailableView("No practice yet", systemImage: "chart.line.uptrend.xyaxis",
                description: Text("Play a Grade pass — turn on 🔁 Loop to bank several — and your accuracy, trends, and trouble spots show up here."))
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let onExpand {
                        Button { onExpand() } label: {
                            Label("Expand progress view", systemImage: "arrow.up.left.and.arrow.down.right")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .help("Open a full-size view — the report card and heatmap are easier to read wide")
                    }
                    statRow
                    suggestedFocus
                    if let report = lastPassReport {
                        PassReportCard(report: report, onDrillBar: onDrillBar,
                                       onDrillSlow: onDrillSlow, onPeekBar: onPeekBar,
                                       collapsible: !wide, expanded: wide, sectionName: sectionName)
                    }
                    lastPassSection
                    if sections.count >= 2 { masterySection }
                    trendSection
                    troubleSection
                    recentSection
                    Button(role: .destructive) { confirmingReset = true } label: {
                        Label("Reset progress…", systemImage: "trash")
                    }
                    .font(.caption)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .confirmationDialog("Reset all practice history for “\(song.title)”?",
                                isPresented: $confirmingReset, titleVisibility: .visible) {
                Button("Reset progress", role: .destructive) { onReset() }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This permanently clears every recorded pass, the trend, trouble spots, and best score for this song.")
            }
        }
    }

    // MARK: - Suggested focus (turn the data into a teacher's session plan)

    /// Up to three prescriptions, teacher-ordered: fix the worst spot slowly, call out
    /// neglected trouble (you practise what you can already play), finish with a run.
    @ViewBuilder
    private var suggestedFocus: some View {
        if passes.count >= 3 {
            let coverage = PracticeHistory.coverage(passes)
            let maxCov = coverage.values.max() ?? 0
            VStack(alignment: .leading, spacing: 6) {
                Text("Suggested focus").font(.headline)
                if let worst = trouble.first {
                    Button {
                        (onDrillSlow ?? onDrillBar)(worst.bar)
                    } label: {
                        Label("Drill bar \(worst.bar) slowly — your top trouble spot (\(worst.misses) misses)",
                              systemImage: "target")
                            .font(.caption).lineLimit(2).multilineTextAlignment(.leading)
                    }
                    .buttonStyle(.bordered)
                }
                if let neglected = trouble.first(where: { (coverage[$0.bar] ?? 0) * 3 < maxCov }) {
                    let row = Label("Bar \(neglected.bar) is weak but rarely practised (\(coverage[neglected.bar] ?? 0)× vs \(maxCov)× elsewhere) — don't just replay what already works",
                                    systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let onPeekBar {
                        Button { onPeekBar(neglected.bar) } label: { row.contentShape(Rectangle()) }
                            .buttonStyle(.plain)
                            .help("Show bar \(neglected.bar) on the score")
                    } else {
                        row
                    }
                }
                if !passes.contains(where: { $0.isFullPiece && Calendar.current.isDateInToday($0.date) }) {
                    Label("Finish with one full run-through to bank today's trend point",
                          systemImage: "flag.checkered")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Section mastery grid (per-scale for the scale books, or any named sections)

    private static let masteryThreshold = 0.95

    /// Best full-section Grade accuracy for a named section: passes whose bar range
    /// matches the section exactly (how the section is drilled) — nil if never played.
    private func best(for s: SavedSection) -> Double? {
        passes.filter { $0.sectionStart == s.start && $0.sectionEnd == s.end }
              .map(\.accuracy).max()
    }

    private var masterySection: some View {
        let mastered = sections.filter { (best(for: $0) ?? 0) >= Self.masteryThreshold }.count
        let cols = [GridItem(.adaptive(minimum: 128), spacing: 6)]
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Section mastery").font(.headline)
                Spacer()
                Text("\(mastered)/\(sections.count) mastered").font(.caption).foregroundStyle(.secondary)
            }
            Text("Best score per section (\(Int(Self.masteryThreshold * 100))% = mastered). Tap to drill.")
                .font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: cols, alignment: .leading, spacing: 6) {
                ForEach(sections) { s in
                    let b = best(for: s)
                    Button { onApplySection(s) } label: { masteryCell(s, best: b) }
                        .buttonStyle(.plain)
                }
            }
        }
    }

    private func masteryCell(_ s: SavedSection, best: Double?) -> some View {
        let tint = masteryColor(best)
        return HStack(spacing: 6) {
            Image(systemName: (best ?? 0) >= Self.masteryThreshold ? "checkmark.seal.fill"
                            : (best == nil ? "circle.dotted" : "circle.lefthalf.filled"))
                .foregroundStyle(tint)
                .font(.caption)
            Text(s.name).font(.caption).lineLimit(1)
            Spacer(minLength: 2)
            Text(best.map { "\(Int($0 * 100))%" } ?? "—")
                .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 7).fill(tint.opacity(0.14)))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(tint.opacity(0.35)))
        .accessibilityLabel("\(s.name): \(best.map { "best \(Int($0 * 100)) percent" } ?? "not yet played")")
    }

    private func masteryColor(_ best: Double?) -> Color {
        guard let b = best else { return .secondary }
        if b >= Self.masteryThreshold { return .green }
        if b >= 0.75 { return .blue }
        return .orange
    }

    // MARK: - Headline stats

    private var statRow: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                stat("Passes", "\(passes.count)")
                stat("Best full run", best.map { "\(Int($0 * 100))%" } ?? "—")
                stat("Last", last.map { "\(Int($0 * 100))%" } ?? "—")
            }
            HStack(spacing: 8) {
                stat("Today", PracticeTime.format(practicedToday))
                stat("Total time", PracticeTime.format(max(totalTime, practicedToday)))
            }
        }
        .onAppear { totalTime = PracticeTime.total(PracticeTime.load(from: song.folder)) }
    }

    // MARK: - Last pass, note by note ("exactly what went wrong")

    @ViewBuilder
    private var lastPassSection: some View {
        if let d = lastPassDetail {
            VStack(alignment: .leading, spacing: 6) {
                Text("Last pass · \(Int(d.accuracy * 100))%").font(.subheadline).bold()
                if d.missed.isEmpty && d.wrong.isEmpty {
                    Label("Clean — no missed or wrong notes.", systemImage: "checkmark.seal")
                        .font(.caption).foregroundStyle(.green)
                } else {
                    if !d.missed.isEmpty {
                        faultRow("Missed", d.missed, tint: Color(red: 0.83, green: 0.18, blue: 0.18),
                                 help: "expected notes you didn't play")
                    }
                    if !d.wrong.isEmpty {
                        faultRow("Wrong", d.wrong, tint: .orange, help: "extra notes you played")
                    }
                }
            }
        }
    }

    /// One line per bar: "bar 5 · F♯5, A4" — groups the note faults by bar.
    private func faultRow(_ title: String, _ faults: [PracticeSession.NoteFault], tint: Color, help: String) -> some View {
        let byBar = Dictionary(grouping: faults, by: \.bar).sorted { $0.key < $1.key }
        return VStack(alignment: .leading, spacing: 2) {
            Text("\(title) (\(faults.count)) — \(help)").font(.caption2).foregroundStyle(.secondary)
            ForEach(byBar, id: \.key) { bar, notes in
                Button { onDrillBar(bar) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("Bar \(bar)").font(.caption).bold().foregroundStyle(tint)
                            .frame(width: 48, alignment: .leading)
                        Text(notes.map(\.name).joined(separator: ", ")).font(.caption)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Practise bar \(bar)")
            }
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.headline).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6).padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.4)))
    }

    // MARK: - Accuracy + tempo trends

    @ViewBuilder
    private var trendSection: some View {
        let recent = Array(passes.suffix(24))
        if recent.count >= 2 {
            VStack(alignment: .leading, spacing: 4) {
                Text("Accuracy trend (last \(recent.count) passes)").font(.subheadline).bold()
                Sparkline(values: recent.map(\.accuracy))
                    .frame(height: 48)
            }
            // Tempo over time — the PRD's own success measure ("reaches target tempo
            // faster"). Normalised over the slider's 25–120% range.
            VStack(alignment: .leading, spacing: 4) {
                Text("Tempo trend · now \(Int(recent.last?.tempoPct ?? 100))%")
                    .font(.subheadline).bold()
                Sparkline(values: recent.map { ($0.tempoPct - 25) / 95 }, guide: (100.0 - 25) / 95)
                    .frame(height: 48)
            }
        }
    }

    // MARK: - Trouble spots

    private var troubleSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Trouble spots").font(.subheadline).bold()
            if trouble.isEmpty {
                Label("None outstanding — you've cleaned up every bar you'd missed.",
                      systemImage: "checkmark.seal")
                    .font(.caption).foregroundStyle(.green)
            } else {
                Text("Bars you keep missing — longest bar = most misses. Tap one to drill it. (Also shown as amber tint on the score — View ▸ Problem marks.)")
                    .font(.caption2).foregroundStyle(.secondary)
                let maxMiss = trouble.map(\.misses).max() ?? 1
                ForEach(trouble) { t in
                    Button { onDrillBar(t.bar) } label: {
                        HStack(spacing: 8) {
                            Text("Bar \(t.bar)").font(.caption).frame(width: 44, alignment: .leading)
                            GeometryReader { geo in
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(.red.opacity(0.55))
                                    .frame(width: max(6, geo.size.width * CGFloat(t.misses) / CGFloat(maxMiss)))
                            }
                            .frame(height: 10)
                            Text("\(t.misses)×").font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Recent passes

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Recent passes").font(.subheadline).bold()
            ForEach(Array(passes.reversed().prefix(12))) { p in
                VStack(alignment: .leading, spacing: 1) {
                    HStack {
                        Text(p.isFullPiece ? "Full piece" : "Bars \(p.sectionStart)–\(p.sectionEnd)")
                            .font(.caption)
                        Spacer()
                        Text("\(Int(p.accuracy * 100))%")
                            .font(.caption).monospacedDigit()
                            .foregroundStyle(p.accuracy >= 0.95 ? .green : .primary)
                    }
                    Text("\(p.date.formatted(date: .abbreviated, time: .shortened)) · \(Int(p.tempoPct))% · \(handLabel(p.handMode)) · miss \(p.missed) · wrong \(p.wrong)")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Divider()
            }
        }
    }

    private func handLabel(_ m: Int) -> String {
        switch m { case 1: return "R.H."; case 2: return "L.H."; default: return "both" }
    }
}

/// A minimal line sparkline for values in 0…1 (drawn bottom = 0, top = 1), with a
/// dashed guide line (default: the 95% accuracy target).
struct Sparkline: View {
    var values: [Double]
    var guide: Double = 0.95

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let n = values.count
            ZStack {
                Path { p in
                    let y = h * (1 - min(max(guide, 0), 1))
                    p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: w, y: y))
                }.stroke(.green.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                if n >= 2 {
                    Path { p in
                        for (i, v) in values.enumerated() {
                            let x = w * CGFloat(i) / CGFloat(n - 1)
                            let y = h * CGFloat(1 - min(max(v, 0), 1))
                            if i == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
                        }
                    }.stroke(.green, style: StrokeStyle(lineWidth: 2, lineJoin: .round))
                }
            }
        }
    }
}
