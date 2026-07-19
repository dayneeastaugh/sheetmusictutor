//
//  HelpView.swift
//  Woodshed
//
//  The in-app Help window (opened from the macOS Help menu → "Segno Help", ⌘?).
//  A topic list on the left, plain-language guidance on the right, written for
//  someone who has never used the app. We host help in-app rather than as an Apple
//  Help Book — the Help Book format is fragile (indexing + plist registration, and
//  a misregistration is exactly the "Help isn't available" error) and far less
//  maintainable than SwiftUI content we control.
//

import SwiftUI

struct HelpView: View {
    @State private var topic: Topic? = .welcome

    enum Topic: String, CaseIterable, Identifiable {
        case welcome = "Welcome"
        case need = "What you need"
        case adding = "Adding a song"
        case screen = "The practice screen"
        case sessions = "The four session types"
        case sections = "Sections & looping"
        case drills = "Drills"
        case progress = "Seeing how you did"
        case midi = "Your MIDI piano"
        case shortcuts = "Tips & shortcuts"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .welcome:  return "hand.wave"
            case .need:     return "checklist"
            case .adding:   return "plus.rectangle.on.folder"
            case .screen:   return "rectangle.3.group"
            case .sessions: return "graduationcap"
            case .sections: return "selection.pin.in.out"
            case .drills:   return "target"
            case .progress: return "chart.line.uptrend.xyaxis"
            case .midi:     return "pianokeys"
            case .shortcuts:return "keyboard"
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(Topic.allCases, selection: $topic) { t in
                Label(t.rawValue, systemImage: t.icon).tag(t)
            }
            .navigationTitle("Segno Help")
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    content(topic ?? .welcome)
                }
                .padding(24)
                .frame(maxWidth: 620, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private func content(_ t: Topic) -> some View {
        switch t {
        case .welcome:   welcome
        case .need:      need
        case .adding:    adding
        case .screen:    screen
        case .sessions:  sessions
        case .drills:    drills
        case .sections:  sections
        case .progress:  progress
        case .midi:      midi
        case .shortcuts: shortcuts
        }
    }

    private var welcome: some View {
        Group {
            title("Welcome to Segno", "hand.wave")
            p("**Segno turns a piece you've transcribed in MuseScore into a personal practice tutor.** You bring the notation and a MIDI file; Segno renders the score with a cursor that follows along, plays it back, and — if you connect a MIDI piano — listens to you play and shows how you did.")
            p("The name comes from the **segno** (𝄋), the musical \"go back to here\" sign — fitting for an app built around looping and drilling passages.")
            heading("A typical session")
            bullets([
                "**Add a song** — import the MusicXML + MIDI you exported from MuseScore.",
                "**Pick a training session type** — Practice, Wait, Grade, or Drill (explained under *The four session types*).",
                "**Choose a section** to focus on, or work the whole piece.",
                "**Press Play** (or start a drill), and Segno follows you and keeps score.",
                "**Check the Progress tab** to see your trouble spots and improvement over time.",
            ])
            tip("New here? Read *What you need*, then *Adding a song*, then *The four session types*. Those three cover 90% of daily use.")
        }
    }

    private var need: some View {
        Group {
            title("What you need", "checklist")
            heading("From MuseScore, two files per piece")
            p("Segno reads a **pair** of exports: the notation and the timing.")
            bullets([
                "**MusicXML** (`.musicxml`, `.xml`, or compressed `.mxl`) — the written notes, spelling, hands, and rhythm.",
                "**MIDI** (`.mid`) — the exact timing, so playback and the follow-cursor are accurate.",
            ])
            p("In MuseScore: **File ▸ Export**, and export the piece once as MusicXML and once as MIDI. Keep them together so they're easy to find.")
            callout("Segno supports **solo piano** (two staves). It won't fuse a multi-part score — export just the piano part.")
            heading("Optional but recommended: a MIDI piano")
            p("A USB or Bluetooth MIDI keyboard lets Segno hear what you play, so **Wait**, **Grade**, and **Drill** can give real feedback. Without one you can still read, listen, loop, and follow along, and play the on-screen keyboard with the mouse. See *Your MIDI piano*.")
        }
    }

    private var adding: some View {
        Group {
            title("Adding a song", "plus.rectangle.on.folder")
            p("From the **library** (the list on the left), there are two ways in:")
            heading("The + button")
            bullets([
                "Click **+** in the library toolbar.",
                "**Step 1** — choose the score file (`.musicxml` / `.xml` / `.mxl`).",
                "**Step 2** — choose the matching **MIDI** (`.mid`).",
            ])
            p("Segno checks the pair by actually combining them. If they don't line up cleanly, it imports anyway but shows an **orange warning banner** with a *Details* button — so you're never grading against a wrong model without knowing.")
            heading("Or drag & drop")
            p("Drag the score **and** its MIDI from Finder straight onto the library list.")
            heading("Managing songs")
            bullets([
                "Click a song to open it.",
                "The **⋯** button on each row: Rename, Edit tags, Favourite, Delete.",
                "**Search** by title or tag, and **Sort** by title, last-practised, or best score.",
                "The **Practice overview** button (top of the library) shows totals across all songs and what's most overdue.",
            ])
        }
    }

    private var screen: some View {
        Group {
            title("The practice screen", "rectangle.3.group")
            p("When you open a song, the screen has four areas:")
            heading("1. The top bar")
            bullets([
                "**Training session type** (left): Practice · Wait · Grade · Drill.",
                "**Metronome** toggle and the **transport**: ⏮ back to the section start, ◀ / ▶ step one bar, and the big **▶ Play / ◼ Stop**.",
            ])
            heading("2. The score (centre)")
            p("Your notation, with a green cursor that follows playback. Drag across bars to **select a section** (see *Sections & looping*).")
            heading("3. The inspector (right)")
            p("A panel with three tabs — toggle it with the sidebar button in the toolbar:")
            bullets([
                "**Controls** — every setting, and it only shows what's relevant to the current session type.",
                "**Progress** — your stats, trends, and trouble spots.",
                "**Flags** — your own pinned notes on bars to revisit.",
            ])
            heading("4. The keyboard (bottom)")
            p("An 88-key piano that lights up what you play (green) and, during playback, the score's notes. Collapsible via *Controls ▸ View ▸ Show keyboard*.")
        }
    }

    private var sessions: some View {
        Group {
            title("The four session types", "graduationcap")
            p("The segmented control at the top left picks **how** you want to work. They're the heart of the app — pick the one that matches what you're trying to do right now.")
            sessionRow("Practice", "play.circle", "Play & follow",
                       "Plays the piece back with the cursor following along. Mute a hand, slow the tempo, loop a section. No scoring — just read, listen, and play along. Great for learning a new piece or hearing how a passage should sound.")
            sessionRow("Wait", "pause.circle", "Learn the notes",
                       "The cursor waits at each note or chord until **you play the right notes**, then advances. Wrong notes are shown but don't block you. Perfect for learning the notes of a tricky passage hands-together, at your own pace. (Needs a MIDI piano.)")
            sessionRow("Grade", "checkmark.circle", "Play at tempo, get scored",
                       "Play along at tempo; afterwards Segno tells you your **accuracy**, which notes you **missed** or played **wrong** (marked on the score), and whether you were **rushing or dragging**. Turn on **Loop** to bank several passes and watch the trend.")
            sessionRow("Drill", "target", "Level a passage up",
                       "A looped, graded workout that gets harder as you improve — either **ramp the tempo** or **add a bar at a time**. See *Drills*.")
            tip("The inspector's Controls tab changes with the session type, so you only ever see settings that apply.")
        }
    }

    private var sections: some View {
        Group {
            title("Sections & looping", "selection.pin.in.out")
            p("Most practice happens on a **small section**, not the whole piece.")
            heading("Selecting bars")
            bullets([
                "**Click the loop's first bar, then its last bar** — the easiest way to select a range (the status line guides you; click the same bar twice for just that bar). You can also **drag across the bars** (drag past the top or bottom edge and it scrolls to reach more).",
                "Or set the **from / to** bars in *Controls ▸ Focus*.",
                "**Deselect** back to the whole piece by pressing **Escape** or **clicking in the empty space** around the music.",
            ])
            heading("Looping")
            bullets([
                "Turn on **Loop section** (Practice/Grade) to repeat it.",
                "A **Loop count-in** clicks a pickup before each pass so you can reset your hands.",
                "**Suggest a spot** picks a section for you — your worst trouble bar, an old flag, or a random spot.",
                "**Save current section** names a range (\"Bridge\") so you can jump back to it in one tap.",
            ])
            tip("A section scopes everything — playback, the cursor, the metronome, and grading all stay within it.")
        }
    }

    private var drills: some View {
        Group {
            title("Drills", "target")
            p("A **Drill** is a looped, graded session that levels a passage up as you improve. Choose a **Drill style** in the inspector, set it up, then press **▶ Play** to begin.")
            heading("Ramp the tempo")
            p("Loops your section and **speeds it up automatically**. Set a **start tempo**, a **goal tempo**, and a step. Choose how it advances:")
            bullets([
                "**When I play it clean** — the tempo only goes up after you play a pass at or above your chosen accuracy (a real mastery gate).",
                "**Every few loops** — it speeds up on a schedule, regardless of accuracy.",
                "Optionally **one hand at a time, then together** — it drills R.H., then L.H., then both.",
            ])
            heading("Add a bar at a time (progressive)")
            p("Builds the passage up **one bar at a time**. It starts on the first bar and, each time you play the **newest bar cleanly**, adds the next one. You only move on once that new bar is right — it's graded **on its own**, so a fumble on the fresh bar can't hide inside the whole passage's score. The selection visibly grows as you succeed, until *Passage complete*.")
            tip("Progressive is the classic \"add-a-note\" practice technique, automated. It's excellent for nailing a hard run without reinforcing mistakes.")
        }
    }

    private var progress: some View {
        Group {
            title("Seeing how you did", "chart.line.uptrend.xyaxis")
            p("Open the **Progress** tab in the inspector (it fills in after your first graded pass).")
            bullets([
                "**Headline stats** — passes, best full run, last score, and time practised.",
                "**Trends** — accuracy and tempo over your recent passes.",
                "**Last pass** — a note-by-note list of exactly what you **missed** and played **wrong**, grouped by bar (tap a bar to drill it).",
                "**Trouble spots** — the bars you keep missing, ranked; \"clear as you improve\" so a bar drops off once you play it clean. Also shown as an **amber tint on the score** (View ▸ Problem marks on score).",
            ])
            heading("Takes: hear yourself back")
            p("Every pass quietly records what you played. In *Controls ▸ Takes* you can **play back your last take**, or your **best graded take** for the section — a great way to hear what actually happened.")
            heading("Flags")
            p("In the **Flags** tab, pin a short note to a bar (\"LH jump\") to remember what to work on. Flagged bars show a ⚑ on the score.")
        }
    }

    private var midi: some View {
        Group {
            title("Your MIDI piano", "pianokeys")
            p("Connect a **USB or Bluetooth MIDI keyboard** and Segno detects it automatically — the status appears under the on-screen keyboard. It reconnects on its own if the connection drops.")
            heading("Where your playing goes")
            p("**Output** (in *Controls ▸ Hands & sound*) chooses where sound comes out:")
            bullets([
                "**Speakers** — Segno's built-in piano sound.",
                "**Piano** — send playback to your MIDI instrument.",
                "**Both**.",
            ])
            p("The on-screen keyboard is also **playable with the mouse** for a quick check without a piano — though Wait, Grade, and Drill feedback are best with a real MIDI keyboard.")
        }
    }

    private var shortcuts: some View {
        Group {
            title("Tips & shortcuts", "keyboard")
            heading("Keyboard")
            bullets([
                "**Space** — Play / Stop.",
                "**Escape** — clear the bar selection (back to the whole piece).",
                "**⌘?** — open this help.",
            ])
            heading("Handy to know")
            bullets([
                "**Reading gets crowded?** *Controls ▸ View*: set **Bars per line** and **Score size** — the score auto-shrinks so your chosen bars-per-line actually fit. These are remembered per song.",
                "**Colour the hands** (View) to tell right (blue) from left (orange) at a glance.",
                "**Start on my first note** (Start) — playback waits and begins the instant you play, so you're in sync.",
                "**Count-in** — give yourself a bar or two before playback starts.",
                "**Rhythm only** (Practice/Grade) — silences the pitches and ticks each note's onset, so you can drill just the rhythm.",
            ])
            callout("Your settings (how you like the view, output, metronome, grading) are remembered across songs and launches. Per-song things like the section you're on start fresh each time.")
        }
    }

    // MARK: - Building blocks

    private func title(_ s: String, _ icon: String) -> some View {
        Label(s, systemImage: icon).font(.title2).bold().padding(.bottom, 2)
    }
    private func heading(_ s: String) -> some View {
        Text(s).font(.headline).padding(.top, 6)
    }
    private func p(_ s: LocalizedStringKey) -> some View {
        Text(s).font(.body).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
    }
    private func bullets(_ items: [LocalizedStringKey]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("•").foregroundStyle(.secondary)
                    Text(item).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
    private func tip(_ s: LocalizedStringKey) -> some View {
        Label { Text(s).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: "lightbulb") }
            .font(.callout)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(.yellow.opacity(0.12)))
    }
    private func callout(_ s: LocalizedStringKey) -> some View {
        Label { Text(s).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: "info.circle") }
            .font(.callout)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(.blue.opacity(0.10)))
    }
    private func sessionRow(_ name: String, _ icon: String, _ tagline: String, _ body: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label { Text("\(name) — ").bold() + Text(tagline).foregroundStyle(.secondary) }
                icon: { Image(systemName: icon) }
                .font(.headline)
            Text(body).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }
}
