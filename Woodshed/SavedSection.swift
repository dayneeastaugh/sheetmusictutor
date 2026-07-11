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

    static func load(from folder: URL) -> [SavedSection] {
        guard let data = try? Data(contentsOf: fileURL(in: folder)),
              let sections = try? JSONDecoder().decode([SavedSection].self, from: data) else { return [] }
        return sections
    }

    static func save(_ sections: [SavedSection], to folder: URL) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(sections) {
            try? data.write(to: fileURL(in: folder), options: .atomic)
        }
    }
}
