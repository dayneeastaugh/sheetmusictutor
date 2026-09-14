//
//  SavedSection.swift
//  Woodshed
//
//  Named practice sections ("Bridge", "Left-hand run") persisted per song as
//  sections.json — same pattern as flags.json: a small array, atomic rewrite.
//  Applying one sets the practice section's bar range.
//

import Foundation

struct SavedSection: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var start: Int          // 1-based bars, inclusive
    var end: Int
}

enum SavedSectionStore {
    static func fileURL(in folder: URL) -> URL {
        folder.appendingPathComponent("sections.json")
    }

    static let schemaVersion = 2   // 1 = bare array (pre-envelope)

    static func load(from folder: URL) -> [SavedSection] {
        StoreIO.loadVersioned([SavedSection].self, from: fileURL(in: folder)) ?? []
    }

    static func save(_ sections: [SavedSection], to folder: URL) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        StoreIO.writeVersioned(sections, v: schemaVersion, to: fileURL(in: folder),
                               encoder: enc, what: "your saved sections")
    }
}
