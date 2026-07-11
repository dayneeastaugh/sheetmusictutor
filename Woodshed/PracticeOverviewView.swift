//
//  PracticeOverviewView.swift
//  Woodshed
//
//  Cross-song practice overview: totals and a "most due" list, aggregated by
//  scanning every song folder's history.jsonl on open. Deliberately NO database —
//  a personal library is tens of songs and the scan is instant; a store becomes
//  worthwhile only if this ever feels slow (ADR-021/034).
//

import SwiftUI

struct PracticeOverviewView: View {
    @ObservedObject var library: SongLibrary
    @Environment(\.dismiss) private var dismiss

    private struct Row: Identifiable {
        let id: UUID
        let title: String
        let passes: Int
        let best: Double?
        let last: Date?
        var daysAgo: Int? {
            last.map { Calendar.current.dateComponents([.day], from: $0, to: Date()).day ?? 0 }
        }
    }
    @State private var rows: [Row] = []

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    totals
                    dueList
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("Practice overview")
            .toolbar { Button("Done") { dismiss() } }
        }
        .frame(minWidth: 460, minHeight: 420)
        .onAppear { scan() }
    }

    private var practised: [Row] { rows.filter { $0.passes > 0 } }

    private var totals: some View {
        HStack(spacing: 10) {
            stat("Songs", "\(rows.count)")
            stat("Practised", "\(practised.count)")
            stat("Total passes", "\(rows.reduce(0) { $0 + $1.passes })")
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.4)))
    }

    /// Stalest first — the practical "what should I practise today?" order.
    private var dueList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Most due").font(.headline)
            Text("Songs you haven't touched for the longest (never-practised first).")
                .font(.caption).foregroundStyle(.secondary)
            let ordered = rows.sorted { ($0.last ?? .distantPast) < ($1.last ?? .distantPast) }
            ForEach(ordered) { r in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(r.title).font(.subheadline)
                        Text(subtitle(for: r))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let d = r.daysAgo, d >= 7 {
                        Label("\(d)d", systemImage: "clock.badge.exclamationmark")
                            .font(.caption).foregroundStyle(.orange)
                    } else if r.passes == 0 {
                        Label("new", systemImage: "sparkles")
                            .font(.caption).foregroundStyle(.blue)
                    }
                }
                Divider()
            }
        }
    }

    private func subtitle(for r: Row) -> String {
        guard r.passes > 0 else { return "Never practised" }
        var s = "\(r.passes) passes"
        if let best = r.best { s += " · best \(Int(best * 100))%" }
        if let d = r.daysAgo { s += d == 0 ? " · today" : " · \(d)d ago" }
        return s
    }

    private func scan() {
        rows = library.songs.map { song in
            let passes = PracticeHistory.load(from: song.folder)
            return Row(id: song.id, title: song.title, passes: passes.count,
                       best: passes.filter(\.isFullPiece).map(\.accuracy).max(),
                       last: passes.last?.date)
        }
    }
}
