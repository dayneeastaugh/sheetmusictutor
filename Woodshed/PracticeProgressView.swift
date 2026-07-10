//
//  PracticeProgressView.swift
//  Woodshed
//
//  The per-song progress sheet: how your Grade passes are trending, the bars you keep
//  missing (tap to drill), and the recent-pass log. Reads the song's history.jsonl
//  (see PracticeHistory). Presented from the practice screen's More menu.
//

import SwiftUI

struct PracticeProgressView: View {
    let song: Song
    let passes: [PracticePass]
    /// Focus the practice section on a bar (drill a trouble spot) and close the sheet.
    let onDrillBar: (Int) -> Void
    /// Wipe this song's history (called after the user confirms).
    let onReset: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var confirmingReset = false

    private var fullRuns: [PracticePass] { passes.filter { $0.isFullPiece } }
    private var best: Double? { fullRuns.map(\.accuracy).max() }
    private var last: Double? { passes.last?.accuracy }
    private var trouble: [TroubleBar] { PracticeHistory.currentTroubleBars(passes) }

    var body: some View {
        NavigationStack {
            Group {
                if passes.isEmpty {
                    ContentUnavailableView("No practice yet", systemImage: "chart.line.uptrend.xyaxis",
                        description: Text("Play a Grade pass — turn on 🔁 Loop to bank several — and your accuracy, trends, and trouble spots show up here."))
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            statRow
                            trendSection
                            troubleSection
                            recentSection
                        }
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .navigationTitle("Progress — \(song.title)")
            .toolbar {
                if !passes.isEmpty {
                    Button(role: .destructive) { confirmingReset = true } label: { Label("Reset", systemImage: "trash") }
                }
                Button("Done") { dismiss() }
            }
            .confirmationDialog("Reset all practice history for “\(song.title)”?",
                                isPresented: $confirmingReset, titleVisibility: .visible) {
                Button("Reset progress", role: .destructive) { onReset(); dismiss() }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This permanently clears every recorded pass, the trend, trouble spots, and best score for this song.")
            }
        }
        .frame(minWidth: 500, minHeight: 560)
    }

    // MARK: - Headline stats

    private var statRow: some View {
        HStack(spacing: 12) {
            stat("Passes", "\(passes.count)")
            stat("Best full run", best.map { "\(Int($0 * 100))%" } ?? "—")
            stat("Last pass", last.map { "\(Int($0 * 100))%" } ?? "—")
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8).padding(.horizontal, 12)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.4)))
    }

    // MARK: - Accuracy trend

    @ViewBuilder
    private var trendSection: some View {
        let vals = passes.suffix(24).map(\.accuracy)
        if vals.count >= 2 {
            VStack(alignment: .leading, spacing: 6) {
                Text("Accuracy trend (last \(vals.count) passes)").font(.headline)
                Sparkline(values: Array(vals))
                    .frame(height: 60)
                    .overlay(alignment: .topLeading) { Text("100%").font(.caption2).foregroundStyle(.secondary) }
                    .overlay(alignment: .bottomLeading) { Text("0%").font(.caption2).foregroundStyle(.secondary) }
            }
        }
    }

    // MARK: - Trouble spots

    @ViewBuilder
    private var troubleSection: some View {
        if trouble.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Trouble spots").font(.headline)
                Label("Nothing outstanding — you've cleaned up every bar you'd missed.",
                      systemImage: "checkmark.seal")
                    .font(.subheadline).foregroundStyle(.green)
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Still need work").font(.headline)
                Text("Bars you're still missing (they drop off once you play them clean) — tap to drill just that bar.")
                    .font(.caption).foregroundStyle(.secondary)
                let maxMiss = trouble.map(\.misses).max() ?? 1
                ForEach(trouble) { t in
                    Button { onDrillBar(t.bar); dismiss() } label: {
                        HStack(spacing: 10) {
                            Text("Bar \(t.bar)").frame(width: 60, alignment: .leading)
                            GeometryReader { geo in
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(.red.opacity(0.55))
                                    .frame(width: max(6, geo.size.width * CGFloat(t.misses) / CGFloat(maxMiss)))
                            }
                            .frame(height: 12)
                            Text("\(t.misses)×").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                            Image(systemName: "arrow.right.circle").foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Recent passes

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Recent passes").font(.headline)
            ForEach(Array(passes.reversed().prefix(15))) { p in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(p.isFullPiece ? "Full piece" : "Bars \(p.sectionStart)–\(p.sectionEnd)")
                            .font(.subheadline)
                        Text("\(p.date.formatted(date: .abbreviated, time: .shortened)) · \(Int(p.tempoPct))% · \(handLabel(p.handMode))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("\(Int(p.accuracy * 100))%")
                        .font(.body).monospacedDigit()
                        .foregroundStyle(p.accuracy >= 0.95 ? .green : .primary)
                    Text("miss \(p.missed) · wrong \(p.wrong)")
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        .frame(width: 130, alignment: .trailing)
                }
                Divider()
            }
        }
    }

    private func handLabel(_ m: Int) -> String {
        switch m { case 1: return "R.H."; case 2: return "L.H."; default: return "both hands" }
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
