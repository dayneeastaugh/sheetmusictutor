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
    /// The full-size sheet passes true: the bar strip wraps into rows and every callout
    /// shows (no budget/collapse) — room to see everything on a long piece.
    var expanded: Bool = false
    /// Resolves a bar to the saved-section name covering it ("Bridge"), if any — lets a
    /// long-piece callout say "bar 42 — in Bridge", how you actually think about it.
    var sectionName: ((Int) -> String?)? = nil

    @State private var showAllCallouts = false

    private static let rhColor = Color(red: 21 / 255, green: 101 / 255, blue: 192 / 255)   // early/rushing (blue)
    private static let lateColor = Color(red: 230 / 255, green: 129 / 255, blue: 0 / 255)  // late/dragging (orange)
    /// Above this many bars, the compact card swaps the per-bar strip for problem chips
    /// (a per-bar sliver is unreadable and untappable). The sheet always wraps instead.
    private static let compactBarLimit = 24
    private var isLong: Bool { report.bars.count > Self.compactBarLimit }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if expanded {
                wrappedStrip
            } else if isLong {
                problemChips
            } else {
                barStrip
                if report.bars.contains(where: { $0.meanSignedMs != nil }) { timingLane }
            }
            if !report.hands.isEmpty { handChips }
            if let e = report.evenness { evennessGauges(e) }
            callouts
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
                .font(.caption).foregroundStyle(.secondary)
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
            Text("bars \(report.sectionStart)–\(report.sectionEnd) · \(Int(report.tempoPct))% tempo")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
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
            HStack(spacing: 6) {
                Text(h.hand == Hand.right ? "Right hand" : "Left hand")
                    .font(.caption2).foregroundStyle(.secondary)
                Text("\(Int(h.accuracy * 100))%")
                    .font(.callout).bold().monospacedDigit()
                    .foregroundStyle(h.accuracy >= 0.9 ? Color.primary : Color.orange)
                if let ms = h.meanSignedMs, abs(ms) >= 25 {
                    Text(ms > 0 ? "late ~\(Int(ms))ms" : "early ~\(Int(-ms))ms")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .fixedSize()
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7).fill(.quaternary.opacity(0.5)))
        }
        if let b = report.balance {
            HStack(spacing: 6) {
                Text("Balance").font(.caption2).foregroundStyle(.secondary)
                Text("RH \(Int(b.rhMeanVelocity)) · LH \(Int(b.lhMeanVelocity))")
                    .font(.callout).monospacedDigit()
                    .foregroundStyle(b.lhLouderBy >= 10 ? Color.orange : Color.primary)
            }
            .fixedSize()
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7).fill(.quaternary.opacity(0.5)))
            .help("Mean struck velocity per hand — is the melody voiced above the accompaniment?")
        }
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

    private struct Issue: Identifiable {
        let id = UUID(); let icon: String; let tint: Color; let text: String; var peek: Int? = nil
    }

    /// Secondary issues in teacher-priority order (recurring first — most actionable),
    /// budgeted on a long/rough pass so the card reads as a summary, not a wall.
    private var secondaryIssues: [Issue] {
        var out: [Issue] = []
        for r in report.recurring.prefix(2) {
            out.append(Issue(icon: "repeat", tint: .red,
                             text: "Bar \(r.bar): \(r.name) \(r.kind) — \(r.streak) passes in a row"
                                + (r.substitution.map { " (\($0))" } ?? ""), peek: r.bar))
        }
        if let hot = report.timingHotspot() {
            let where_ = hot.bars.count == 1 ? "bar \(hot.bars.lowerBound)"
                : "bars \(hot.bars.lowerBound)–\(hot.bars.upperBound)"
            out.append(Issue(icon: "clock", tint: .orange,
                             text: "You \(hot.meanMs < 0 ? "rush" : "drag") \(where_) by ~\(Int(abs(hot.meanMs))) ms",
                             peek: hot.bars.lowerBound))
        }
        if let hold = report.pedalHolds.first {
            out.append(Issue(icon: "waveform", tint: .orange,
                             text: "Pedal held through bars \(hold.lowerBound)–\(hold.upperBound) — lift at the harmony changes",
                             peek: hold.lowerBound))
        }
        if let roll = report.worstChordSpread {
            out.append(Issue(icon: "pianokeys", tint: .orange,
                             text: "Rolled chord in bar \(roll.bar) (~\(Int(roll.ms)) ms spread) — strike the notes together",
                             peek: roll.bar))
        }
        if let b = report.balance, b.lhLouderBy >= 10 {
            out.append(Issue(icon: "scalemass", tint: .orange,
                             text: "Left hand louder than right by \(Int(b.lhLouderBy)) — the melody may be buried"))
        }
        if let d = report.tempoDriftPct, abs(d) >= 3 {
            out.append(Issue(icon: "speedometer", tint: .orange,
                             text: d < 0 ? "You sped up through the pass — ~\(Int(-d))% faster by the end"
                                         : "You slowed through the pass — ~\(Int(d))% slower by the end"))
        }
        return out
    }

    @ViewBuilder
    private var callouts: some View {
        // Budget the secondary issues in the compact card so a rough long pass doesn't
        // wall you with nine lines; the expanded sheet (or "+N more") shows all.
        let issues = secondaryIssues
        let budget = 2
        let showAll = expanded || showAllCallouts || issues.count <= budget + 1
        let shown = showAll ? issues : Array(issues.prefix(budget))

        VStack(alignment: .leading, spacing: 4) {
            if report.personalBest {
                callout(icon: "trophy.fill", tint: .green, text: "Personal best on these bars")
            }
            if !report.fixedBars.isEmpty {
                callout(icon: "checkmark.circle.fill", tint: .green,
                        text: report.fixedBars.count <= 3
                            ? "Bar\(report.fixedBars.count == 1 ? "" : "s") \(report.fixedBars.map(String.init).joined(separator: ", ")) fixed — clean this pass"
                            : "\(report.fixedBars.count) bars fixed this pass ✓",
                        peek: report.fixedBars.first)
            } else if report.accuracy >= 0.95 && !report.personalBest {
                callout(icon: "checkmark.seal.fill", tint: .green, text: "Clean pass — nice.")
            }
            if let w = report.worstBar {
                let what = w.missedNames.isEmpty ? "\(w.missed + w.wrong) faults"
                    : "missed \(w.missedNames.joined(separator: ", "))" + (w.wrong > 0 ? " + \(w.wrong) wrong" : "")
                let loc = sectionName?(w.bar).map { " — in \($0)" } ?? ""
                HStack(spacing: 6) {
                    callout(icon: "target", tint: .red, text: "Bar \(w.bar)\(loc): \(what)", peek: w.bar)
                    if let onDrillSlow {
                        Button("Drill slowly") { onDrillSlow(w.bar) }
                            .font(.caption).buttonStyle(.borderless).fixedSize()
                            .help("Focus bar \(w.bar) at ~70% tempo and ramp back up with the mastery gate")
                    } else {
                        Button("Drill") { onDrillBar(w.bar) }
                            .font(.caption).buttonStyle(.borderless).fixedSize()
                    }
                }
            }
            ForEach(shown) { issue in
                callout(icon: issue.icon, tint: issue.tint, text: issue.text, peek: issue.peek)
            }
            if !showAll {
                Button("+\(issues.count - budget) more") { showAllCallouts = true }
                    .font(.caption2).buttonStyle(.borderless)
            }
            if let tip = report.advice {
                callout(icon: "lightbulb", tint: .blue, text: tip)
            }
        }
    }

    private func peek(_ bar: Int) { onPeekBar?(bar) }

    /// A feedback line. When it references a bar and a peek handler exists, tapping
    /// the line flashes that bar on the score — the text is linked to the music.
    private func callout(icon: String, tint: Color, text: String, peek: Int? = nil) -> some View {
        let row = HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: icon).font(.caption).foregroundStyle(tint)
            Text(text).font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
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
    private let cols = [GridItem(.adaptive(minimum: 92), spacing: 6, alignment: .leading)]

    var body: some View {
        LazyVGrid(columns: cols, alignment: .leading, spacing: 6) {
            ForEach(clusters) { c in
                let tint = c.severity == 2 ? Color.red : Color.orange
                Button { onTap(c) } label: {
                    Text(c.label).font(.caption2).lineLimit(1)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .frame(maxWidth: .infinity)
                        .background(RoundedRectangle(cornerRadius: 6).fill(tint.opacity(0.16)))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(tint.opacity(0.5)))
                        .foregroundStyle(tint)
                }
                .buttonStyle(.plain)
                .help("Show \(c.label) on the score")
            }
        }
    }
}
