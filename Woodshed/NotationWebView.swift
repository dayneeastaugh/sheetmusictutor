//
//  NotationWebView.swift
//  Woodshed
//
//  Phase 0 spike — Increment 3: the notation surface.
//
//  A SwiftUI wrapper around WKWebView that hosts the offline OSMD page (Web/index.html
//  + the vendored opensheetmusicdisplay.min.js) and drives it from Swift:
//    • render a score (we hand OSMD the MusicXML as base64)
//    • step / reset the follow-cursor
//
//  WKWebView is an AppKit view on macOS and a UIKit view on iPadOS, so we implement
//  both NSViewRepresentable and UIViewRepresentable and share the real work in helpers.
//  The web layer stays "dumb" — Swift owns the data and the clock, per the PRD.
//

import SwiftUI
import WebKit
import Combine

/// Shared, observable status channel between the web view and SwiftUI. Using an
/// ObservableObject (not a captured closure) guarantees UI updates land reliably.
/// Keeps a short rolling trace so the on-screen panel shows the whole load sequence.
final class NotationBridge: ObservableObject {
    /// Latest status from the notation web view ("ready", "loaded svg=…", "error: …").
    @Published var status: String = ""
    /// Set by the web view once created; used to drive the cursor directly (no SwiftUI
    /// state churn) at the playback frame rate.
    weak var webView: WKWebView?
    /// Called when the user drags a bar selection on the score: (startBar, endBar), 1-based.
    var onSelect: ((Int, Int) -> Void)?
    /// Called when the user taps a flag marker on the score: the bar (1-based).
    var onFlagTap: ((Int) -> Void)?
    /// Called to clear the bar selection (Escape, or a click in the score's whitespace).
    var onDeselect: (() -> Void)?

    func post(_ s: String) {
        if s.hasPrefix("select:") {
            let parts = s.dropFirst(7).split(separator: ":")
            if parts.count == 2, let a = Int(parts[0]), let b = Int(parts[1]) {
                DispatchQueue.main.async { self.onSelect?(a, b) }
            }
            return
        }
        if s == "deselect" {
            DispatchQueue.main.async { self.onDeselect?() }
            return
        }
        if s.hasPrefix("flag:") {
            if let bar = Int(s.dropFirst(5)) { DispatchQueue.main.async { self.onFlagTap?(bar) } }
            return
        }
        DispatchQueue.main.async { self.status = s }
    }

    /// Run JS on the page, surfacing any exception into `status` — a bridge call that
    /// silently fails looks exactly like a broken feature (it took a real bug report
    /// to learn this), so failures must be visible.
    private func run(_ js: String) {
        webView?.evaluateJavaScript(js) { [weak self] _, error in
            if let error {
                let what = js.prefix(40)
                self?.post("error: JS \(what)… — \(error.localizedDescription)")
            }
        }
    }

    /// Highlight a bar range on the score (1-based) / clear the highlight.
    func setSelection(_ start: Int, _ end: Int) {
        run("window.setSelection(\(start),\(end))")
    }
    func clearSelection() {
        run("window.clearSelection()")
    }

    /// Smoothly position the cursor at a (fractional) notated beat.
    func seek(_ beat: Double) {
        run("window.cursorSeekBeat(\(beat))")
    }

    /// Colour noteheads by hand (RH blue, LH orange — the colour-blind-safe pair)
    /// or restore default black.
    func setHandColors(_ on: Bool) {
        run("window.setHandColorMode(\(on), '#1565C0', '#E65100')")
    }

    /// Force N measures per line/system (0 = automatic layout). A maximum: the
    /// status reports what actually fits at the current score size.
    func setMeasuresPerSystem(_ n: Int) {
        run("window.setMeasuresPerSystem(\(n))")
    }

    /// Scale the engraving (1.0 = 100%). Smaller sizes fit more bars per line.
    func setZoom(_ z: Double) {
        run("window.setZoom(\(z))")
    }

    /// Mark noteheads red for review: `pairs` are (notated beat, MIDI pitch).
    func markMistakes(_ pairs: [(beat: Double, pitch: Int)]) {
        let js = pairs.map { "[\($0.beat),\($0.pitch)]" }.joined(separator: ",")
        run("window.markMistakes([\(js)])")
    }
    /// Restore normal note colours (clear the mistake marks).
    func clearMistakes() {
        run("window.clearMistakes()")
    }

    /// Ring the missed notes (cheap overlay, no re-render — safe to call every pass).
    func markMissed(_ pairs: [(beat: Double, pitch: Int)]) {
        let js = pairs.map { "[\($0.beat),\($0.pitch)]" }.joined(separator: ",")
        run("window.markMissed([\(js)])")
    }
    func clearMissed() {
        run("window.clearMissed()")
    }

    /// Draw the WRONG notes you played on the score (`pairs` = notated beat, MIDI
    /// pitch) — a red mark at that beat's x, at the pitch's height, labelled.
    func markWrong(_ pairs: [(beat: Double, pitch: Int)]) {
        let js = pairs.map { "[\($0.beat),\($0.pitch)]" }.joined(separator: ",")
        run("window.markWrong([\(js)])")
    }

    /// Tint whole bars amber as "still needs work" trouble spots (1-based bar numbers).
    func setTroubleBars(_ bars: [Int]) {
        let js = bars.map(String.init).joined(separator: ",")
        run("window.setTroubleBars([\(js)])")
    }
    func clearTroubleBars() {
        run("window.clearTroubleBars()")
    }

    /// Mark bars with a tappable flag marker (1-based). Tapping posts `flag:<bar>`.
    func setFlaggedBars(_ bars: [Int]) {
        let js = bars.map(String.init).joined(separator: ",")
        run("window.setFlaggedBars([\(js)])")
    }
}

/// A cursor command with a nonce, so SwiftUI can tell us "run this again" by
/// bumping the number even if the action string is unchanged.
struct CursorCommand: Equatable {
    var nonce: Int = 0
    var action: String = ""   // "next" | "reset" | "toBeat"
    var beat: Double = 0      // target notated beat (quarters), for "toBeat"
}

struct NotationWebView {
    /// The score as base64-encoded UTF-8 MusicXML. Empty = nothing to show yet.
    var xmlBase64: String
    var command: CursorCommand
    var bridge: NotationBridge

    func makeCoordinator() -> Coordinator { Coordinator(bridge: bridge) }

    // MARK: Shared construction / updates

    fileprivate func makeWebView(_ context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "osmd")
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        context.coordinator.webView = web
        bridge.webView = web   // let the bridge drive the cursor directly during playback

        // Paint under/around the page white so an empty or still-loading webview
        // never shows a black backdrop in Dark Mode.
        #if os(macOS)
        web.setValue(false, forKey: "drawsBackground")   // let SwiftUI's white show through
        #else
        web.isOpaque = false
        web.backgroundColor = .white
        web.scrollView.backgroundColor = .white
        #endif

        // Load the page as a single self-contained HTML string with the OSMD script
        // INLINED — no file:// URLs, no sibling-resource loading, no read-access rules.
        if let html = context.coordinator.buildInlineHTML() {
            bridge.post("makeWebView: loadHTMLString len=\(html.count)")
            web.loadHTMLString(html, baseURL: nil)
        } else {
            bridge.post("error: OSMD resources missing from bundle")
        }
        return web
    }

    fileprivate func updateWebView(_ context: Context) {
        context.coordinator.apply(xmlBase64: xmlBase64, command: command)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        weak var webView: WKWebView?
        private let bridge: NotationBridge
        private var pageLoaded = false
        private var lastLoadedB64 = ""
        private var pendingB64: String?
        private var pendingCommand: CursorCommand?
        private var lastNonce = 0

        init(bridge: NotationBridge) { self.bridge = bridge }

        /// Read the bundled page + OSMD script and splice them into one self-contained
        /// HTML string (script inlined in place of the `<script src=…>` tag).
        func buildInlineHTML() -> String? {
            let htmlURL = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "Web")
                ?? Bundle.main.url(forResource: "index", withExtension: "html")
            // The file is opensheetmusicdisplay.min.js → resource name "opensheetmusicdisplay.min".
            let jsURL = Bundle.main.url(forResource: "opensheetmusicdisplay.min", withExtension: "js", subdirectory: "Web")
                ?? Bundle.main.url(forResource: "opensheetmusicdisplay.min", withExtension: "js")
            guard let htmlURL, let jsURL,
                  let html = try? String(contentsOf: htmlURL, encoding: .utf8),
                  var js = try? String(contentsOf: jsURL, encoding: .utf8) else { return nil }
            js = js.replacingOccurrences(of: "</script>", with: "<\\/script>")
            return html.replacingOccurrences(
                of: #"<script src="opensheetmusicdisplay.min.js"></script>"#,
                with: "<script>\n\(js)\n</script>")
        }

        // Called by SwiftUI's updateView. Loads a new score and/or runs a cursor command.
        func apply(xmlBase64: String, command: CursorCommand) {
            if !xmlBase64.isEmpty && xmlBase64 != lastLoadedB64 {
                lastLoadedB64 = xmlBase64
                if pageLoaded { loadScore(xmlBase64) } else { pendingB64 = xmlBase64 }
            }
            if command.nonce != lastNonce {
                lastNonce = command.nonce
                // Queue until the page is up — a command fired before `window.*` exists
                // errors and vanishes, silently desyncing the cursor from the session.
                if pageLoaded { runCommand(command) } else { pendingCommand = command }
            }
        }

        private func runCommand(_ command: CursorCommand) {
            let js: String
            switch command.action {
            case "reset":  js = "window.cursorReset()"
            // seekBeat is anchor-table based and handles BACKWARD motion; the old
            // forward-only cursorToBeat silently no-op'd on any backward seek.
            case "toBeat": js = "window.cursorSeekBeat(\(command.beat))"
            default:       js = "window.cursorNext()"
            }
            webView?.evaluateJavaScript(js) { [weak self] _, error in
                if let error { self?.bridge.post("error: cursor \(command.action) — \(error.localizedDescription)") }
            }
        }

        private func loadScore(_ b64: String) {
            bridge.post("swift: loadScoreB64 (\(b64.count) chars)")
            // base64 chars are quote/backslash-free, so embedding in a JS string is safe.
            webView?.evaluateJavaScript("window.loadScoreB64(\"\(b64)\"); 'ok'") { [weak self] _, error in
                if let error { self?.bridge.post("error: JS eval — \(error.localizedDescription)") }
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            bridge.post("didFinish (page loaded)")
            pageLoaded = true
            if let p = pendingB64 { pendingB64 = nil; loadScore(p) }
            if let c = pendingCommand { pendingCommand = nil; runCommand(c) }
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            bridge.post("error: nav — \(error.localizedDescription)")
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            bridge.post("error: provisional — \(error.localizedDescription)")
        }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            // WebKit content processes do get killed (memory pressure, GPU resets).
            // Reload the page and re-send the score; the "loaded" status then triggers
            // the session's re-push of layout/overlays — instead of a dead blank pane.
            bridge.post("web content process terminated — recovering")
            pageLoaded = false
            pendingB64 = lastLoadedB64.isEmpty ? nil : lastLoadedB64
            if let html = buildInlineHTML() { webView.loadHTMLString(html, baseURL: nil) }
        }

        func userContentController(_ controller: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            if let s = message.body as? String { bridge.post(s) }
        }
    }
}

// MARK: - Platform conformances

#if os(macOS)
extension NotationWebView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { makeWebView(context) }
    func updateNSView(_ nsView: WKWebView, context: Context) { updateWebView(context) }
}
#else
extension NotationWebView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { makeWebView(context) }
    func updateUIView(_ uiView: WKWebView, context: Context) { updateWebView(context) }
}
#endif
