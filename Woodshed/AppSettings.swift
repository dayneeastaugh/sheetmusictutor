//
//  AppSettings.swift
//  Woodshed
//
//  App-wide user preferences that persist across launches (and carry across song
//  switches), stored in UserDefaults. These are "how I like the app to behave"
//  settings — distinct from PER-SONG state (bars-per-line, score zoom, section
//  range), which lives in each song's metadata.json. And distinct from per-practice
//  CONTEXT (tempo %, which hand, the active section, whether a drill is running),
//  which deliberately starts fresh. See docs/DECISIONS.md ADR-036.
//
//  A plain enum wrapping UserDefaults (same style as BarFlagStore / PracticeTime),
//  read into `PracticeSession`'s @Published properties at init and written back from
//  their didSet. The `pref.` key prefix namespaces them.
//

import Foundation

enum AppSettings {
    private static let d = UserDefaults.standard

    /// Register first-launch defaults so a never-set key reads its intended value
    /// (UserDefaults.bool/integer/double otherwise return false/0). Called once at
    /// startup from `WoodshedApp`. Keys whose default is false/0 are omitted.
    static func registerDefaults() {
        d.register(defaults: [
            Key.cursorSmooth: true,
            Key.showScoreNotes: true,
            Key.showTroubleOnScore: true,
            Key.keyboardVisible: true,
            Key.gradeTolerance: 0.30,
            Key.speedTargetPct: 100.0,
            Key.speedStepPct: 5.0,
            Key.speedThreshold: 0.9,
            Key.speedPassesPerStep: 2,
        ])
    }

    private enum Key {
        static let cursorSmooth = "pref.cursorSmooth"
        static let colorHands = "pref.colorHands"
        static let showScoreNotes = "pref.showScoreNotes"
        static let showTroubleOnScore = "pref.showTroubleOnScore"
        static let keyboardVisible = "pref.keyboardVisible"   // read by PracticeView via @AppStorage
        static let outputMode = "pref.outputMode"
        static let metronomeStartsWithPlayback = "pref.metronomeStartsWithPlayback"
        static let metronomeStopsWithPlayback = "pref.metronomeStopsWithPlayback"
        static let countInBars = "pref.countInBars"
        static let startOnFirstNote = "pref.startOnFirstNote"
        static let gradeTolerance = "pref.gradeTolerance"
        static let speedTargetPct = "pref.speedTargetPct"
        static let speedStepPct = "pref.speedStepPct"
        static let speedThreshold = "pref.speedThreshold"
        static let speedPassesPerStep = "pref.speedPassesPerStep"
        static let handsProgression = "pref.handsProgression"
    }

    // View
    static var cursorSmooth: Bool { get { d.bool(forKey: Key.cursorSmooth) } set { d.set(newValue, forKey: Key.cursorSmooth) } }
    static var colorHands: Bool { get { d.bool(forKey: Key.colorHands) } set { d.set(newValue, forKey: Key.colorHands) } }
    static var showScoreNotes: Bool { get { d.bool(forKey: Key.showScoreNotes) } set { d.set(newValue, forKey: Key.showScoreNotes) } }
    static var showTroubleOnScore: Bool { get { d.bool(forKey: Key.showTroubleOnScore) } set { d.set(newValue, forKey: Key.showTroubleOnScore) } }
    /// The key PracticeView's @AppStorage("pref.keyboardVisible") binds to.
    static let keyboardVisibleKey = Key.keyboardVisible

    // Playback / routing
    static var outputMode: Int { get { d.integer(forKey: Key.outputMode) } set { d.set(newValue, forKey: Key.outputMode) } }
    static var metronomeStartsWithPlayback: Bool { get { d.bool(forKey: Key.metronomeStartsWithPlayback) } set { d.set(newValue, forKey: Key.metronomeStartsWithPlayback) } }
    static var metronomeStopsWithPlayback: Bool { get { d.bool(forKey: Key.metronomeStopsWithPlayback) } set { d.set(newValue, forKey: Key.metronomeStopsWithPlayback) } }

    // Start
    static var countInBars: Int { get { d.integer(forKey: Key.countInBars) } set { d.set(newValue, forKey: Key.countInBars) } }
    static var startOnFirstNote: Bool { get { d.bool(forKey: Key.startOnFirstNote) } set { d.set(newValue, forKey: Key.startOnFirstNote) } }

    // Grading
    static var gradeTolerance: Double { get { d.double(forKey: Key.gradeTolerance) } set { d.set(newValue, forKey: Key.gradeTolerance) } }

    // Speed-trainer configuration (its parameters, not whether a drill is running)
    static var speedTargetPct: Double { get { d.double(forKey: Key.speedTargetPct) } set { d.set(newValue, forKey: Key.speedTargetPct) } }
    static var speedStepPct: Double { get { d.double(forKey: Key.speedStepPct) } set { d.set(newValue, forKey: Key.speedStepPct) } }
    static var speedThreshold: Double { get { d.double(forKey: Key.speedThreshold) } set { d.set(newValue, forKey: Key.speedThreshold) } }
    static var speedPassesPerStep: Int { get { d.integer(forKey: Key.speedPassesPerStep) } set { d.set(newValue, forKey: Key.speedPassesPerStep) } }
    static var handsProgression: Bool { get { d.bool(forKey: Key.handsProgression) } set { d.set(newValue, forKey: Key.handsProgression) } }
}
