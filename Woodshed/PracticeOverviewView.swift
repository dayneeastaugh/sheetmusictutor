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
    @State private var totalSeconds: Double = 0
    @State private var weekSeconds: Double = 0
    @State private var streakDays = 0
    @State private var weekBars: [(day: Date, seconds: Double)] = []

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    habitStrip
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

    /// Habit at a glance: current streak + a 7-day practice-minutes strip. Turns the
    /// existing time ledger into the "weekly use" nudge the PRD hangs its success on.
    private var habitStrip: some View {
        let maxSec = max(weekBars.map(\.seconds).max() ?? 0, 1)
        return HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: "flame.fill").foregroundStyle(streakDays > 0 ? .orange : .secondary)
                    Text("\(streakDays)").font(.title.bold()).monospacedDigit()
                }
                Text(streakDays == 1 ? "day streak" : "day streak").font(.caption).foregroundStyle(.secondary)
            }
            .frame(minWidth: 74, alignment: .leading)
            Divider().frame(height: 40)
            HStack(alignment: .bottom, spacing: 6) {
                ForEach(weekBars, id: \.day) { bar in
                    VStack(spacing: 3) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(bar.seconds > 0 ? Color.accentColor : Color.secondary.opacity(0.25))
                            .frame(width: 16, height: max(3, 34 * CGFloat(bar.seconds / maxSec)))
                        Text(Self.weekdayLetter(bar.day)).font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("\(Self.weekdayLetter(bar.day)): \(PracticeTime.format(bar.seconds))")
                }
            }
            .frame(height: 52, alignment: .bottom)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary.opacity(0.35)))
    }

    private static func weekdayLetter(_ date: Date) -> String {
        let i = Calendar.current.component(.weekday, from: date) - 1   // 0 = Sunday
        return ["S", "M", "T", "W", "T", "F", "S"][max(0, min(6, i))]
    }

    private var totals: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                stat("Songs", "\(rows.count)")
                stat("Practised", "\(practised.count)")
                stat("Total passes", "\(rows.reduce(0) { $0 + $1.passes })")
            }
            HStack(spacing: 10) {
                stat("This week", PracticeTime.format(weekSeconds))
                stat("All time", PracticeTime.format(totalSeconds))
            }
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
        var total = 0.0, week = 0.0
        var timeDicts: [[String: Double]] = []
        rows = library.songs.map { song in
            let passes = PracticeHistory.load(from: song.folder)
            let time = PracticeTime.load(from: song.folder)
            timeDicts.append(time)
            total += PracticeTime.total(time)
            week += PracticeTime.recent(time, days: 7)
            return Row(id: song.id, title: song.title, passes: passes.count,
                       best: passes.filter(\.isFullPiece).map(\.accuracy).max(),
                       last: passes.last?.date)
        }
        totalSeconds = total
        weekSeconds = week
        let merged = PracticeTime.merge(timeDicts)              // library-wide, for streak + week strip
        streakDays = PracticeTime.streak(merged)
        weekBars = PracticeTime.lastDays(merged, days: 7)
    }
}
