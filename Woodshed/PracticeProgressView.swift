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
    /// Focus the practice section on a bar (drill a trouble spot).
    let onDrillBar: (Int) -> Void
    /// Wipe this song's history (called after the user confirms).
    let onReset: () -> Void

    @State private var confirmingReset = false

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
                    statRow
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

    // MARK: - Headline stats

    private var statRow: some View {
        HStack(spacing: 8) {
            stat("Passes", "\(passes.count)")
            stat("Best full run", best.map { "\(Int($0 * 100))%" } ?? "—")
            stat("Last", last.map { "\(Int($0 * 100))%" } ?? "—")
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

    // MARK: - Accuracy trend

    @ViewBuilder
    private var trendSection: some View {
        let vals = passes.suffix(24).map(\.accuracy)
        if vals.count >= 2 {
            VStack(alignment: .leading, spacing: 4) {
                Text("Accuracy trend (last \(vals.count) passes)").font(.subheadline).bold()
                Sparkline(values: Array(vals))
                    .frame(height: 48)
            }
        }
    }

    // MARK: - Trouble spots

    @ViewBuilder
    private var troubleSection: some View {
        if trouble.isEmpty {
            Label("Nothing outstanding — you've cleaned up every bar you'd missed.",
                  systemImage: "checkmark.seal")
                .font(.caption).foregroundStyle(.green)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text("Still need work").font(.subheadline).bold()
                Text("Bars you're still missing — tap to drill just that bar.")
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

/// A minimal line sparkline for values in 0…1 (drawn bottom = 0, top = 1).
struct Sparkline: View {
    var values: [Double]

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let n = values.count
            ZStack {
                // 95% target guide
                Path { p in
                    let y = h * (1 - 0.95)
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
