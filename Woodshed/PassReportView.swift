//
//  PassReportView.swift
//  Woodshed
//
//  The post-pass report card: a per-bar result strip (tap a bar to drill it), a
//  per-bar timing lane (rushing vs dragging), a per-hand split, and specific
//  callouts — wins first (PRD: encouraging, never punitive). Appears under the
//  header once a graded pass finishes and playback stops; dismissible.
//

import SwiftUI

struct PassReportCard: View {
    let report: PassReport
    /// Ordinal of this pass in the session (for the "Pass N" title).
    var passNumber: Int? = nil
    var onDrillBar: (Int) -> Void = { _ in }
    /// The remediation action: focus the bar AND drop to ~70% tempo with a ramp back.
    var onDrillSlow: ((Int) -> Void)? = nil
    /// Flash a bar on the score (tapping a callout answers "where IS bar 9?").
    var onPeekBar: ((Int) -> Void)? = nil
    /// nil = not dismissible (the Progress-tab copy); non-nil shows the ✕.
    var onDismiss: (() -> Void)? = nil
    /// Show a collapse chevron; collapsed = header verdict only (persisted, shared by
    /// the practice-area and inspector cards — the sheet stays always-open).
    var collapsible: Bool = false
    /// The full-size sheet passes true: the bar strip wraps into rows and every callout
    /// shows (no budget/collapse) — room to see everything on a long piece.
    var expanded: Bool = false
    /// Resolves a bar to the saved-section name covering it ("Bridge"), if any — lets a
    /// long-piece callout say "bar 42 — in Bridge", how you actually think about it.
    var sectionName: ((Int) -> String?)? = nil

    @State private var showAllCallouts = false
    @AppStorage("pref.passReportCollapsed") private var collapsed = false

    private static let rhColor = Color(red: 21 / 255, green: 101 / 255, blue: 192 / 255)   // early/rushing (blue)
    private static let lateColor = Color(red: 230 / 255, green: 129 / 255, blue: 0 / 255)  // late/dragging (orange)
    /// Above this many bars, the compact card swaps the per-bar strip for problem chips
    /// (a per-bar sliver is unreadable and untappable). The sheet always wraps instead.
    private static let compactBarLimit = 24
    private var isLong: Bool { report.bars.count > Self.compactBarLimit }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            header
            if !(collapsible && collapsed) {            // collapsed = header verdict only
                if expanded {
                    wrappedStrip
                } else if isLong {
                    problemChips
                } else {
                    barStrip
                    if report.bars.contains(where: { $0.meanSignedMs != nil }) { timingLane }
                }
                if !report.hands.isEmpty || report.balance != nil {
                    Divider().opacity(0.5)
                    handChips
                }
                if let e = report.evenness { evennessGauges(e) }
                Divider().opacity(0.5)
                callouts
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.35)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary))
    }

    // MARK: Compact long-score view — problem chips instead of a sliver strip

    private var problemChips: some View {
        let clusters = report.problemClusters()
        return VStack(alignment: .leading, spacing: 5) {
            Text("\(report.cleanBarCount) of \(report.bars.count) bars clean")
                .font(.caption2).foregroundStyle(.secondary)
            if clusters.isEmpty {
                Label("No trouble spots this pass", systemImage: "checkmark.seal")
                    .font(.caption).foregroundStyle(.green)
            } else {
                FlowChips(clusters: Array(clusters.prefix(showAllCallouts ? clusters.count : 6)),
                          onTap: { peek($0.range.lowerBound) })
                if !showAllCallouts && clusters.count > 6 {
                    Button("+\(clusters.count - 6) more trouble spots") { showAllCallouts = true }
                        .font(.caption2).buttonStyle(.borderless)
                }
            }
        }
    }

    // MARK: Expanded view — the strip wrapped into score-like rows

    private var wrappedStrip: some View {
        let rows = stride(from: 0, to: report.bars.count, by: 20).map {
            Array(report.bars[$0..<min($0 + 20, report.bars.count)])
        }
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                VStack(spacing: 2) {
                    HStack(spacing: 3) {
                        ForEach(row) { b in barCell(b) }
                        if row.count < 20 { Spacer(minLength: 0) }
                    }
                    HStack(spacing: 3) {
                        ForEach(row) { b in
                            Text("\(b.bar)").font(.system(size: 9)).monospacedDigit()
                                .foregroundStyle(.secondary).frame(width: cellWidth)
                        }
                        if row.count < 20 { Spacer(minLength: 0) }
                    }
                }
            }
            Text("timing above the line = dragging, below = rushing")
                .font(.system(size: 9)).foregroundStyle(.secondary)
        }
    }

    // Fixed cell width so wrapped rows align regardless of bar count.
    private var cellWidth: CGFloat { 26 }

    private func barCell(_ b: PassReport.BarResult) -> some View {
        Button { onDrillBar(b.bar) } label: {
            VStack(spacing: 1) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(color(for: b))
                    .overlay(RoundedRectangle(cornerRadius: 3)
                        .stroke(report.fixedBars.contains(b.bar) ? Color.green : .clear, lineWidth: 2))
                    .frame(width: cellWidth, height: 22)
                timingTick(b)
            }
        }
        .buttonStyle(.plain)
        .help(help(for: b))
        .accessibilityLabel("Bar \(b.bar): \(help(for: b))")
    }

    /// A small up/down tick under a wrapped cell showing that bar's timing lean.
    @ViewBuilder
    private func timingTick(_ b: PassReport.BarResult) -> some View {
        if let ms = b.meanSignedMs, abs(ms) >= 8 {
            let h = CGFloat(min(abs(ms), 120) / 120) * 8
            Rectangle().fill(ms > 0 ? Self.lateColor : Self.rhColor)
                .frame(width: cellWidth * 0.5, height: max(2, h))
        } else {
            Color.clear.frame(width: cellWidth * 0.5, height: 8)
        }
    }

    /// "Pass 3" during a session; a reloaded report says when it's from — "Last pass ·
    /// 16 Jul" (or just "Last pass" if it was earlier today).
    private var title: String {
        if let n = passNumber, n > 0 { return "Pass \(n)" }
        if let d = report.date, !Calendar.current.isDateInToday(d) {
            return "Last pass · " + d.formatted(.dateTime.day().month(.abbreviated))
        }
        return "Last pass"
    }

    // MARK: Header

    // Two lines so the card never letter-wraps in the narrow inspector: the verdict
    // (title · % · delta) on top, the context (bars · tempo) beneath.
    private var header: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 8) {
                if collapsible {
                    Button { withAnimation(.easeInOut(duration: 0.15)) { collapsed.toggle() } } label: {
                        Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help(collapsed ? "Expand the pass report" : "Collapse to just the score line")
                    .accessibilityLabel(collapsed ? "Expand pass report" : "Collapse pass report")
                }
                Text(title).font(.caption).bold().lineLimit(1)
                Text("\(Int(report.accuracy * 100))%")
                    .font(.title3).bold().monospacedDigit().fixedSize()
                    .foregroundStyle(report.accuracy >= 0.95 ? .green : .primary)
                if let d = report.deltaVsPrevious, abs(d) >= 0.005 {
                    Text("\(d > 0 ? "▲" : "▼") \(abs(Int((d * 100).rounded())))%")
                        .font(.caption).monospacedDigit().fixedSize()
                        .foregroundStyle(d > 0 ? .green : .orange)
                }
                Spacer(minLength: 4)
                if let onDismiss {
                    Button { onDismiss() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.borderless)
                        .help("Hide this report (it stays in the Progress tab)")
                        .accessibilityLabel("Dismiss pass report")
                }
            }
            Text("bars \(report.sectionStart)–\(report.sectionEnd) · \(Int(report.tempoPct))% tempo"
                 + collapsedSummary)
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    /// When collapsed, the header line carries the one-glance verdict.
    private var collapsedSummary: String {
        guard collapsible, collapsed else { return "" }
        let n = report.problemClusters().count
        return n == 0 ? " · clean" : " · \(n) trouble spot\(n == 1 ? "" : "s")"
    }

    // MARK: Bar strip

    private var barStrip: some View {
        VStack(spacing: 2) {
            HStack(spacing: 3) {
                ForEach(report.bars) { b in
                    Button { onDrillBar(b.bar) } label: {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(color(for: b))
                            .overlay(RoundedRectangle(cornerRadius: 3)
                                .stroke(report.fixedBars.contains(b.bar) ? Color.green : .clear, lineWidth: 2))
                            .frame(height: 22)
                    }
                    .buttonStyle(.plain)
                    .help(help(for: b))
                    .accessibilityLabel("Bar \(b.bar): \(help(for: b))")
                }
            }
            if report.bars.count <= 24 {   // labels get unreadable past this
                HStack(spacing: 3) {
                    ForEach(report.bars) { b in
                        Text("\(b.bar)").font(.system(size: 9)).monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    private func color(for b: PassReport.BarResult) -> Color {
        if b.total == 0 { return Color.secondary.opacity(0.15) }          // rest bar
        if b.isClean { return Color.green.opacity(0.55) }
        if b.accuracy >= 0.8 && b.missed + b.wrong <= 2 { return Color.orange.opacity(0.65) }
        return Color.red.opacity(0.6)
    }

    private func help(for b: PassReport.BarResult) -> String {
        if b.total == 0 { return "no notes" }
        if b.isClean { return report.fixedBars.contains(b.bar) ? "clean — fixed this pass ✓" : "clean" }
        var parts: [String] = []
        if b.missed > 0 { parts.append("\(b.missed) missed" + (b.missedNames.isEmpty ? "" : " (\(b.missedNames.joined(separator: ", ")))")) }
        if b.wrong > 0 { parts.append("\(b.wrong) wrong") }
        return parts.joined(separator: ", ") + " — tap to drill"
    }

    // MARK: Timing lane

    private var timingLane: some View {
        VStack(alignment: .leading, spacing: 2) {
            GeometryReader { geo in
                let laneH = geo.size.height
                let cap = 120.0                                     // ms mapped to a full half-lane
                ZStack {
                    Rectangle().fill(.quaternary).frame(height: 1)  // the zero line
                    HStack(spacing: 3) {
                        ForEach(report.bars) { b in
                            timingBar(b, laneH: laneH, cap: cap)
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
            .frame(height: 34)
            Text("timing per bar — above the line = dragging, below = rushing")
                .font(.system(size: 9)).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func timingBar(_ b: PassReport.BarResult, laneH: CGFloat, cap: Double) -> some View {
        if let ms = b.meanSignedMs, abs(ms) >= 8 {                 // ≈even → just the dot on the line
            let h = CGFloat(min(abs(ms), cap) / cap) * (laneH / 2 - 2)
            RoundedRectangle(cornerRadius: 1.5)
                .fill(ms > 0 ? Self.lateColor : Self.rhColor)
                .frame(height: max(3, h))
                .offset(y: ms > 0 ? (h / 2) : -(h / 2))
                .accessibilityLabel("Bar \(b.bar): \(ms > 0 ? "dragging" : "rushing") by \(Int(abs(ms))) milliseconds")
        } else {
            Circle().fill(.quaternary).frame(width: 3, height: 3)
        }
    }

    // MARK: Hands

    // The chips never letter-wrap (.fixedSize); when the row doesn't fit the narrow
    // inspector, ViewThatFits stacks them vertically instead.
    private var handChips: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { chipViews; Spacer(minLength: 0) }
            VStack(alignment: .leading, spacing: 6) { chipViews }
        }
    }

    @ViewBuilder
    private var chipViews: some View {
        ForEach(report.hands) { (h: PassReport.HandResult) in
            statColumn(h.hand == Hand.right ? "Right hand" : "Left hand",
                       value: "\(Int(h.accuracy * 100))%",
                       detail: h.meanSignedMs.flatMap { abs($0) >= 25 ? ($0 > 0 ? "late ~\(Int($0))ms" : "early ~\(Int(-$0))ms") : nil },
                       tint: h.accuracy >= 0.9 ? Color.primary : Color.orange)
        }
        if let b = report.balance {
            statColumn("Balance",
                       value: "\(Int(b.rhMeanVelocity)) · \(Int(b.lhMeanVelocity))",
                       detail: "RH · LH",
                       tint: b.lhLouderBy >= 10 ? Color.orange : Color.primary)
                .help("Mean struck velocity per hand — is the melody voiced above the accompaniment?")
        }
    }

    /// A quiet label-over-value stat (same idiom as the drill bar's stats).
    private func statColumn(_ label: String, value: String, detail: String?, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value).font(.callout).bold().monospacedDigit().foregroundStyle(tint)
                if let detail { Text(detail).font(.caption2).foregroundStyle(.secondary) }
            }
        }
        .fixedSize()
    }

    // MARK: Evenness (Technical Practice: what a teacher listens for in a scale)

    private func evennessGauges(_ e: PassReport.Evenness) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            evennessRow("Rhythm evenness", score: e.timingScore)
            evennessRow("Dynamic evenness", score: e.dynamicScore)
            if let s = e.softest, let l = e.loudest, l.velocity - s.velocity >= 30 {
                callout(icon: "speaker.wave.2", tint: .orange,
                        text: "Uneven touch — softest \(s.name) (\(s.velocity)), loudest \(l.name) (\(l.velocity))")
            }
        }
    }

    private func evennessRow(_ label: String, score: Double) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            ProgressView(value: score)
                .tint(score >= 0.8 ? .green : (score >= 0.5 ? .orange : .red))
            Text(evennessWord(score)).font(.caption2).foregroundStyle(.secondary)
                .frame(width: 66, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(evennessWord(score))")
    }

    private func evennessWord(_ s: Double) -> String {
        s >= 0.8 ? "very even" : (s >= 0.5 ? "a bit uneven" : "uneven")
    }

    // MARK: Callouts (wins first)

    // MARK: Themed callouts (ADR-052) — tier 1: wins + theme rows; tier 2: details

    @State private var openThemes: Set<String> = []

    @ViewBuilder
    private var callouts: some View {
        let themes = report.themes()
        let concerning = themes.filter { $0.status != .good }
        let fine = themes.filter { $0.status == .good }
        VStack(alignment: .leading, spacing: 5) {
            if let wins = report.winsSummary {
                callout(icon: "trophy.fill", tint: .green, text: wins,
                        peek: report.fixedBars.first)
            }
            ForEach(concerning) { theme in
                themeRow(theme)
                if openThemes.contains(theme.id) || expanded {
                    themeDetails(theme.kind).padding(.leading, 22)
                }
                // The coach's one instruction rides with the top (focus) theme.
                if theme.id == concerning.first?.id, let tip = report.advice {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "lightbulb").font(.caption2).foregroundStyle(.blue)
                        Text(tip).font(.caption).foregroundStyle(.secondary).italic()
                    }
                    .padding(.leading, 29)
                }
            }
            if !fine.isEmpty {
                Text(fine.map { "\($0.kind.title) ✓ \($0.goodWord)" }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.green.opacity(0.9))
            }
        }
    }

    /// One theme row: status dot · name · one-line summary. Tap the text to peek its
    /// bar; the chevron (or the expanded sheet) opens the detailed findings beneath.
    private func themeRow(_ theme: PassReport.ThemeSummary) -> some View {
        let tint: Color = theme.status == .focus ? .red : .orange
        return HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: theme.kind.icon).font(.caption).foregroundStyle(.secondary)
                .frame(width: 16, alignment: .center)
            Group {
                if let peekBar = theme.peek, let onPeekBar {
                    Button { onPeekBar(peekBar) } label: {
                        themeText(theme, tint: tint).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Show bar \(peekBar) on the score")
                } else {
                    themeText(theme, tint: tint)
                }
            }
            if !expanded {
                Button {
                    if openThemes.contains(theme.id) { openThemes.remove(theme.id) }
                    else { openThemes.insert(theme.id) }
                } label: {
                    Image(systemName: openThemes.contains(theme.id) ? "chevron.down" : "chevron.right")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Show the detailed findings for \(theme.kind.title)")
                .accessibilityLabel("\(openThemes.contains(theme.id) ? "Hide" : "Show") \(theme.kind.title) details")
            }
        }
    }

    private func themeText(_ theme: PassReport.ThemeSummary, tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Circle().fill(tint).frame(width: 6, height: 6)
                .accessibilityLabel(theme.status == .focus ? "needs focus" : "watch")
            (Text("\(theme.kind.title)  ").fontWeight(.semibold)
                + Text(theme.summary).foregroundColor(.secondary))
                .font(.caption)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Tier 2 — the detailed findings, grouped under their theme.
    @ViewBuilder
    private func themeDetails(_ kind: PassReport.ThemeSummary.Kind) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            switch kind {
            case .notes:
                if let w = report.worstBar {
                    let n = w.missed + w.wrong
                    let what = w.missedNames.isEmpty ? "\(n) fault\(n == 1 ? "" : "s")"
                        : "missed \(w.missedNames.joined(separator: ", "))" + (w.wrong > 0 ? " + \(w.wrong) wrong" : "")
                    let loc = sectionName?(w.bar).map { " — in \($0)" } ?? ""
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        callout(icon: "target", tint: .red, text: "Bar \(w.bar)\(loc): \(what)",
                                peek: w.bar, expand: false)
                        if let onDrillSlow {
                            Button("Drill slowly") { onDrillSlow(w.bar) }
                                .font(.caption).buttonStyle(.borderless).fixedSize()
                                .help("Focus bar \(w.bar) at ~70% tempo and ramp back up with the mastery gate")
                        } else {
                            Button("Drill") { onDrillBar(w.bar) }
                                .font(.caption).buttonStyle(.borderless).fixedSize()
                        }
                        Spacer(minLength: 0)
                    }
                }
                ForEach(report.recurring) { r in
                    callout(icon: "repeat", tint: .red,
                            text: "Bar \(r.bar): \(r.name) \(r.kind) — \(r.streak) passes in a row"
                                + (r.substitution.map { " (\($0))" } ?? ""), peek: r.bar)
                }
            case .rhythm:
                if let hot = report.timingHotspot() {
                    let where_ = hot.bars.count == 1 ? "bar \(hot.bars.lowerBound)"
                        : "bars \(hot.bars.lowerBound)–\(hot.bars.upperBound)"
                    callout(icon: "clock", tint: .orange,
                            text: "You \(hot.meanMs < 0 ? "rush" : "drag") \(where_) by ~\(Int(abs(hot.meanMs))) ms",
                            peek: hot.bars.lowerBound)
                }
                if let d = report.tempoDriftPct, abs(d) >= 3 {
                    callout(icon: "speedometer", tint: .orange,
                            text: d < 0 ? "You sped up through the pass — ~\(Int(-d))% faster by the end"
                                        : "You slowed through the pass — ~\(Int(d))% slower by the end")
                }
            case .touch:
                if let hold = report.pedalHolds.first {
                    callout(icon: "waveform", tint: .orange,
                            text: "Pedal held through bars \(hold.lowerBound)–\(hold.upperBound) — lift at the harmony changes",
                            peek: hold.lowerBound)
                }
                if let roll = report.worstChordSpread {
                    callout(icon: "pianokeys", tint: .orange,
                            text: "Rolled chord in bar \(roll.bar) (~\(Int(roll.ms)) ms spread) — strike the notes together",
                            peek: roll.bar)
                }
                if let b = report.balance, b.lhLouderBy >= 10 {
                    callout(icon: "scalemass", tint: .orange,
                            text: "Left hand louder than right by \(Int(b.lhLouderBy)) — the melody may be buried")
                }
            }
        }
    }

    private func peek(_ bar: Int) { onPeekBar?(bar) }

    /// A feedback line. When it references a bar and a peek handler exists, tapping
    /// the line flashes that bar on the score — the text is linked to the music.
    private func callout(icon: String, tint: Color, text: String, peek: Int? = nil,
                         expand: Bool = true) -> some View {
        let row = HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: icon).font(.caption).foregroundStyle(tint)
            Text(text).font(.caption)
                .frame(maxWidth: expand ? .infinity : nil, alignment: .leading)
        }
        return Group {
            if let peek, let onPeekBar {
                Button { onPeekBar(peek) } label: { row.contentShape(Rectangle()) }
                    .buttonStyle(.plain)
                    .help("Show bar \(peek) on the score")
            } else {
                row
            }
        }
    }
}

/// Wrapping row of tappable problem-range chips (compact long-score view). A grid with
/// adaptive columns wraps naturally; each chip is tinted by its worst bar's severity.
private struct FlowChips: View {
    let clusters: [PassReport.ProblemCluster]
    let onTap: (PassReport.ProblemCluster) -> Void
    private let cols = [GridItem(.adaptive(minimum: 84), spacing: 5, alignment: .leading)]

    var body: some View {
        LazyVGrid(columns: cols, alignment: .leading, spacing: 5) {
            ForEach(clusters) { c in
                let tint = c.severity == 2 ? Color.red : Color.orange
                Button { onTap(c) } label: {
                    Text(c.label).font(.caption2).lineLimit(1).fixedSize()
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Capsule().fill(tint.opacity(0.14)))
                        .foregroundStyle(tint)
                }
                .buttonStyle(.plain)
                .help("Show \(c.label) on the score")
            }
        }
    }
}
