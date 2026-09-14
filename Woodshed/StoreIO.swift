//
//  StoreIO.swift
//  Woodshed
//
//  Shared IO for the per-song JSON stores (takes, flags, sections, time, report,
//  history). Two promises the stores used to break silently (audit 06 P2-8):
//
//  1. A WRITE failure is reported, not discarded — the UI can tell the player their
//     pass/flag/section may not survive a relaunch instead of showing saved state
//     that quietly evaporates.
//  2. A CORRUPT file is different from a MISSING one. Missing = fresh start. Corrupt
//     = the original is set aside as `<name>.corrupt-<timestamp>` (recoverable by
//     hand) and reported — never left in place to be overwritten by the next save.
//

import Foundation

enum StoreIO {
    /// Central sink for storage problems. Set once at startup (feeds the library's
    /// existing "Couldn't save" alert). Static because the stores are static enums;
    /// called on whatever thread the store ran on — the sink hops to main.
    static var onProblem: ((String) -> Void)?

    static func report(_ message: String) {
        DebugLog.shared.log("store", message)
        if let sink = onProblem { DispatchQueue.main.async { sink(message) } }
    }

    /// Decode a JSON store file. Missing file → nil with no problem (fresh start).
    /// Corrupt file → set aside + reported, then nil.
    static func load<T: Decodable>(_ type: T.Type, from url: URL,
                                   decoder: JSONDecoder = JSONDecoder()) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do { return try decoder.decode(T.self, from: data) }
        catch {
            let aside = url.deletingPathExtension()
                .appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970))")
                .appendingPathExtension("json")
            try? FileManager.default.moveItem(at: url, to: aside)
            report("“\(url.lastPathComponent)” couldn’t be read — the damaged file was kept as “\(aside.lastPathComponent)” and this song starts that data fresh.")
            return nil
        }
    }

    // MARK: Versioned store files (audit 06: versioned persistence + migration)
    //
    // Store files carry a schema version so a future format change can migrate
    // non-destructively instead of guessing. v1 = the bare pre-envelope payload
    // (still readable, forever); v2+ = `{"v": N, "data": <payload>}`. A legacy file
    // upgrades to the envelope on its next save; an unreadable file (neither shape
    // decodes) is set aside like any corrupt store.

    struct Versioned<T: Codable>: Codable { var v: Int; var data: T }

    /// Load a versioned store file: envelope first, then the bare legacy payload.
    static func loadVersioned<T: Decodable & Encodable>(_ type: T.Type, from url: URL,
                                                        decoder: JSONDecoder = JSONDecoder()) -> T? {
        guard let raw = try? Data(contentsOf: url) else { return nil }
        if let env = try? decoder.decode(Versioned<T>.self, from: raw) { return env.data }
        if let legacy = try? decoder.decode(T.self, from: raw) { return legacy }   // v1
        let aside = url.deletingPathExtension()
            .appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970))")
            .appendingPathExtension("json")
        try? FileManager.default.moveItem(at: url, to: aside)
        report("“\(url.lastPathComponent)” couldn’t be read — the damaged file was kept as “\(aside.lastPathComponent)” and this song starts that data fresh.")
        return nil
    }

    /// Write a versioned store file (`{"v": N, "data": …}`), atomically + reported.
    @discardableResult
    static func writeVersioned<T: Codable>(_ value: T, v: Int, to url: URL,
                                           encoder: JSONEncoder, what: String) -> Bool {
        write(Versioned(v: v, data: value), to: url, encoder: encoder, what: what)
    }

    /// Encode + write atomically. Returns true on success; failure is reported.
    @discardableResult
    static func write<T: Encodable>(_ value: T, to url: URL,
                                    encoder: JSONEncoder, what: String) -> Bool {
        do {
            try encoder.encode(value).write(to: url, options: .atomic)
            return true
        } catch {
            report("Couldn’t save \(what) — the change may not survive closing the app. Check free disk space. (\(error.localizedDescription))")
            return false
        }
    }
}
