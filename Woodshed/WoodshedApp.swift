//
//  WoodshedApp.swift
//  Woodshed
//
//  Created by Dayne Eastaugh on 8/7/2026.
//

import SwiftUI

@main
struct WoodshedApp: App {
    init() {
        AppSettings.registerDefaults()   // first-launch values for the persisted preferences
    }

    var body: some Scene {
        #if os(macOS)
        // Replace the (broken, unregistered) default "Segno Help" menu item with one
        // that opens our own in-app help window — no fragile Apple Help Book.
        WindowGroup {
            ContentView()
        }
        .commands { HelpCommands() }

        Window("Segno Help", id: HelpCommands.windowID) {
            HelpView()
        }
        .defaultSize(width: 780, height: 580)
        #else
        WindowGroup {
            ContentView()
        }
        #endif
    }
}

#if os(macOS)
/// The Help menu command that opens the in-app Help window (⌘?).
struct HelpCommands: Commands {
    static let windowID = "segno-help"
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("Segno Help") { openWindow(id: Self.windowID) }
                .keyboardShortcut("?", modifiers: .command)
        }
    }
}
#endif
