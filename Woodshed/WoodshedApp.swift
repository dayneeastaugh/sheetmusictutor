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
        WindowGroup {
            ContentView()
        }
    }
}
