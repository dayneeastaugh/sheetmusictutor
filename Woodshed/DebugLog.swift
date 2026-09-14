//
//  DebugLog.swift
//  Woodshed
//
//  Opt-in diagnostic logging. When enabled, timestamped lines are appended to a file
//  in Application Support (so they survive restarts) and mirrored to an in-memory tail
//  for the diagnostics view. Off by default — it's for chasing a specific problem, and
//  external testers can flip it on, reproduce, then Export the single log file to send
//  back. Cheap when off (an early `guard`), thread-safe (a serial queue).
//

import Foundation
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// A plain-text file for `.fileExporter` — used by the cross-platform diagnostic-log
/// export (macOS save panel + iPad share/save sheet from one code path).
struct TextFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }
    var text: String
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws {
        text = String(data: configuration.file.regularFileContents ?? Data(), encoding: .utf8) ?? ""
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

final class DebugLog: ObservableObject {
    static let shared = DebugLog()

    /// Persisted on/off. Default OFF (diagnosis is opt-in; avoids overhead + noise).
    @Published var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: "debug.logging"); if enabled { log("log", "logging enabled") } }
    }
    /// The most recent lines, for showing a live tail in the diagnostics view.
    @Published private(set) var tail: [String] = []
    /// Bytes currently on disk (for the diagnostics view).
    @Published private(set) var byteCount: Int = 0

    let fileURL: URL
    private let queue = DispatchQueue(label: "woodshed.debuglog")
    // Coalescing: publishing tail/byteCount per LINE made every log line a SwiftUI
    // invalidation — at piano-playback log rates that starved the main thread and
    // made the 50 Hz output tick (and so the piano) audibly uneven. Lines batch on
    // the log queue and publish at most ~4×/s.
    private var pending: [String] = []          // owned by `queue`
    private var pendingBytes = 0                // owned by `queue`
    private var flushScheduled = false          // owned by `queue`
    private let df: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f
    }()

    private init() {
        enabled = UserDefaults.standard.bool(forKey: "debug.logging")
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                 in: .userDomainMask, appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("Segno", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("debug.log")
        byteCount = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int) ?? 0 ?? 0
    }

    /// Append a line under a short category. The message is an autoclosure so building
    /// it costs nothing when logging is off.
    func log(_ category: String, _ message: @autoclosure () -> String) {
        guard enabled else { return }
        let line = "\(df.string(from: Date())) [\(category)] \(message())"
        queue.async { [weak self] in
            guard let self else { return }
            if let data = (line + "\n").data(using: .utf8) {
                if let h = try? FileHandle(forWritingTo: self.fileURL) {
                    h.seekToEndOfFile(); h.write(data); try? h.close()
                } else {
                    try? (line + "\n").data(using: .utf8)?.write(to: self.fileURL)
                }
            }
            self.pendingBytes = (try? FileManager.default.attributesOfItem(atPath: self.fileURL.path)[.size] as? Int) ?? 0 ?? 0
            self.pending.append(line)
            if !self.flushScheduled {
                self.flushScheduled = true
                self.queue.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.flushToMain() }
            }
        }
    }

    /// Publish the batched lines (runs on `queue`).
    private func flushToMain() {
        let batch = pending
        pending = []
        flushScheduled = false
        let size = pendingBytes
        guard !batch.isEmpty else { return }
        DispatchQueue.main.async {
            self.tail.append(contentsOf: batch)
            if self.tail.count > 200 { self.tail.removeFirst(self.tail.count - 200) }
            self.byteCount = size
        }
    }

    /// Wipe the log file and the in-memory tail.
    func clear() {
        queue.async { [weak self] in
            guard let self else { return }
            try? "".data(using: .utf8)?.write(to: self.fileURL)
            DispatchQueue.main.async { self.tail = []; self.byteCount = 0 }
        }
    }

    /// The log with a small header (app + device + date), written to a temp file ready
    /// to be saved/shared as a single container. Returns nil if there's nothing to send.
    func exportURL() -> URL? {
        let header = """
        Segno debug log
        Exported: \(ISO8601DateFormatter().string(from: Date()))
        macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        ------------------------------------------------------------
        """
        let body = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        guard !body.isEmpty else { return nil }
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("Segno-debug-\(Int(Date().timeIntervalSince1970)).log")
        try? (header + "\n" + body).data(using: .utf8)?.write(to: out)
        return out
    }
}

/// The diagnostics sheet's logging section — the ONLY view that observes the log
/// (its live tail). Kept out of the practice screen so log lines never invalidate
/// the playing surface.
struct DebugLogSection: View {
    var onExport: () -> Void
    @ObservedObject private var debugLog = DebugLog.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Diagnostic logging").font(.headline)
            Toggle("Record a detailed log (MIDI input, grading, drills)", isOn: $debugLog.enabled)
            Text("Off by default. Turn on, reproduce the issue, then Export the log — it's a single file you can send. The setting and the log survive restarts.")
                .font(.caption2).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button("Export log…") { onExport() }
                    .disabled(debugLog.byteCount == 0)
                Button("Clear log", role: .destructive) { debugLog.clear() }
                    .disabled(debugLog.byteCount == 0)
                Spacer()
                Text(debugLog.byteCount > 0 ? "\(debugLog.byteCount) bytes" : "empty")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if debugLog.enabled && !debugLog.tail.isEmpty {
                Text("Recent (live tail)").font(.caption).foregroundStyle(.secondary).padding(.top, 2)
                ScrollView {
                    Text(debugLog.tail.suffix(40).joined(separator: "\n"))
                        .font(.system(.caption2, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(height: 120)
                .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.4)))
            }
        }
    }
}
