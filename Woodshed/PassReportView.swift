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
    /// nil = not dismissible (the Progress-tab copy); non-nil shows the ✕.
    var onDismiss: (() -> Void)? = nil

    private static let rhColor = Color(red: 21 / 255, green: 101 / 255, blue: 192 / 255)   // early/rushing (blue)
    private static let lateColor = Color(red: 230 / 255, green: 129 / 255, blue: 0 / 255)  // late/dragging (orange)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            barStrip
            if report.bars.contains(where: { $0.meanSignedMs != nil }) { timingLane }
            if !report.hands.isEmpty { handChips }
            if let e = report.evenness { evennessGauges(e) }
            callouts
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.35)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary))
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

    private var header: some View {
        HStack(spacing: 8) {
            Text(title).font(.caption).bold()
            Text("bars \(report.sectionStart)–\(report.sectionEnd)")
                .font(.caption).foregroundStyle(.secondary)
            Text("\(Int(report.accuracy * 100))%")
                .font(.title3).bold().monospacedDigit()
                .foregroundStyle(report.accuracy >= 0.95 ? .green : .primary)
            if let d = report.deltaVsPrevious, abs(d) >= 0.005 {
                Text("\(d > 0 ? "▲" : "▼") \(abs(Int((d * 100).rounded())))%")
                    .font(.caption).monospacedDigit()
                    .foregroundStyle(d > 0 ? .green : .orange)
            }
            Spacer()
            Text("\(Int(report.tempoPct))% tempo").font(.caption).foregroundStyle(.secondary)
            if let onDismiss {
                Button { onDismiss() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.borderless)
                    .help("Hide this report (it stays in the Progress tab)")
                    .accessibilityLabel("Dismiss pass report")
            }
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

    private var handChips: some View {
        HStack(spacing: 8) {
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
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 7).fill(.quaternary.opacity(0.5)))
                .help("Mean struck velocity per hand — is the melody voiced above the accompaniment?")
            }
            Spacer()
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

    @ViewBuilder
    private var callouts: some View {
        VStack(alignment: .leading, spacing: 4) {
            if report.personalBest {
                callout(icon: "trophy.fill", tint: .green, text: "Personal best on these bars")
            }
            if !report.fixedBars.isEmpty {
                callout(icon: "checkmark.circle.fill", tint: .green,
                        text: report.fixedBars.count == 1
                            ? "Bar \(report.fixedBars[0]) fixed — clean this pass"
                            : "Bars \(report.fixedBars.map(String.init).joined(separator: ", ")) fixed — clean this pass")
            } else if report.accuracy >= 0.95 && !report.personalBest {
                callout(icon: "checkmark.seal.fill", tint: .green, text: "Clean pass — nice.")
            }
            if let w = report.worstBar {
                let what = w.missedNames.isEmpty ? "\(w.missed + w.wrong) faults"
                    : "missed \(w.missedNames.joined(separator: ", "))" + (w.wrong > 0 ? " + \(w.wrong) wrong" : "")
                HStack(spacing: 6) {
                    callout(icon: "target", tint: .red, text: "Bar \(w.bar): \(what)")
                    if let onDrillSlow {
                        Button("Drill bar \(w.bar) slowly") { onDrillSlow(w.bar) }
                            .font(.caption).buttonStyle(.borderless)
                            .help("Focus this bar at ~70% tempo and ramp back up with the mastery gate")
                    } else {
                        Button("Drill bar \(w.bar)") { onDrillBar(w.bar) }
                            .font(.caption).buttonStyle(.borderless)
                    }
                }
            }
            ForEach(report.recurring.prefix(2)) { r in
                callout(icon: "repeat", tint: .red,
                        text: "Bar \(r.bar): \(r.name) \(r.kind) — \(r.streak) passes in a row"
                            + (r.substitution.map { " (\($0))" } ?? ""))
            }
            if let hot = report.timingHotspot() {
                let where_ = hot.bars.count == 1 ? "bar \(hot.bars.lowerBound)"
                    : "bars \(hot.bars.lowerBound)–\(hot.bars.upperBound)"
                callout(icon: "clock", tint: .orange,
                        text: "You \(hot.meanMs < 0 ? "rush" : "drag") \(where_) by ~\(Int(abs(hot.meanMs))) ms")
            }
            if let d = report.tempoDriftPct, abs(d) >= 3 {
                callout(icon: "speedometer", tint: .orange,
                        text: d < 0 ? "You sped up through the pass — ~\(Int(-d))% faster by the end"
                                    : "You slowed through the pass — ~\(Int(d))% slower by the end")
            }
            if let hold = report.pedalHolds.first {
                callout(icon: "waveform", tint: .orange,
                        text: "Pedal held through bars \(hold.lowerBound)–\(hold.upperBound) — lift at the harmony changes")
            }
            if let roll = report.worstChordSpread {
                callout(icon: "pianokeys", tint: .orange,
                        text: "Rolled chord in bar \(roll.bar) (~\(Int(roll.ms)) ms spread) — strike the notes together")
            }
            if let b = report.balance, b.lhLouderBy >= 10 {
                callout(icon: "scalemass", tint: .orange,
                        text: "Left hand louder than right by \(Int(b.lhLouderBy)) — the melody may be buried")
            }
            if let tip = report.advice {
                callout(icon: "lightbulb", tint: .blue, text: tip)
            }
        }
    }

    private func callout(icon: String, tint: Color, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: icon).font(.caption).foregroundStyle(tint)
            Text(text).font(.caption)
        }
    }
}
