//
//  PianoKeyboardView.swift
//  Woodshed
//
//  An on-screen 88-key piano that lights up the notes in `litNotes` (live MIDI
//  input) and the score's sounding notes, and can be played with the mouse/touch.
//  Purely a view: it owns no MIDI or audio logic.
//
//  Drawn with `Canvas` — a single immediate-mode draw pass. The previous version
//  built ~140 individual SwiftUI views (one per key) that were re-diffed on every
//  highlight change; at trill speeds that re-diffing dropped frames (audit ARCH-02).
//  A Canvas repaints the whole keyboard in one cheap pass with no per-key identity.
//

import SwiftUI

struct PianoKeyboardView: View {
    /// Notes you're playing on the MIDI piano (highlighted green).
    var litNotes: Set<Int>
    /// Score notes sounding now — right hand (blue) and left hand (red). When hand
    /// colouring is off, the app puts everything in `scoreRH` so it all shows blue.
    var scoreRH: Set<Int> = []
    var scoreLH: Set<Int> = []
    /// Wait mode: colour held notes that aren't currently required as wrong (red).
    var flagWrong: Bool = false
    /// Called when a key is pressed / released by mouse or touch (for testing).
    var onPress: (Int) -> Void = { _ in }
    var onRelease: (Int) -> Void = { _ in }

    // 88 keys, A0 (21) … C8 (108). The layout never changes, so compute it once.
    private static let low = 21, high = 108
    static let whiteNotes: [Int] = (low...high).filter { isWhite($0) }   // 52
    static let blackNotes: [Int] = (low...high).filter { !isWhite($0) }  // 36
    /// For each black key, the index of the white key it sits after.
    private static let blackAfterWhiteIndex: [(note: Int, whiteIndex: Int)] =
        blackNotes.compactMap { n in whiteNotes.firstIndex(of: n - 1).map { (n, $0) } }
    private static func isWhite(_ n: Int) -> Bool { ![1, 3, 6, 8, 10].contains(((n % 12) + 12) % 12) }

    // Match the notation's hand colours: RH blue #1565C0, LH orange #E65100.
    // Blue/orange is the colour-blind-safe pair (the old blue/red failed exactly the
    // most common red-green deficiency, and hand identity is load-bearing here).
    private static let rhColor = Color(red: 21 / 255, green: 101 / 255, blue: 192 / 255)
    private static let lhColor = Color(red: 230 / 255, green: 81 / 255, blue: 0 / 255)

    @State private var mouseNote: Int? = nil

    /// Everything to draw as "played by you": live MIDI notes plus the mouse-held note.
    private var lit: Set<Int> { mouseNote.map { litNotes.union([$0]) } ?? litNotes }

    /// Key colour: a held note is green if it's wanted (or any note outside Wait
    /// mode), red if it's a wrong note in Wait/Grade mode; otherwise the score's
    /// notes by hand (RH blue, LH red), else the natural key colour.
    private func color(_ note: Int, white: Bool) -> Color {
        if lit.contains(note) {
            let wanted = scoreRH.contains(note) || scoreLH.contains(note)
            if flagWrong && !wanted { return white ? Color.red.opacity(0.7) : Color.red }
            return white ? Color.green.opacity(0.75) : Color.green
        }
        if scoreRH.contains(note) { return white ? Self.rhColor.opacity(0.6) : Self.rhColor }
        if scoreLH.contains(note) { return white ? Self.lhColor.opacity(0.6) : Self.lhColor }
        return white ? .white : .black
    }

    var body: some View {
        GeometryReader { geo in
            let whiteW = geo.size.width / CGFloat(Self.whiteNotes.count)
            let blackW = whiteW * 0.62
            let blackH = geo.size.height * 0.6

            Canvas { ctx, size in
                // White keys: fills first, then one shared grid of separators.
                for (j, note) in Self.whiteNotes.enumerated() {
                    let rect = CGRect(x: CGFloat(j) * whiteW, y: 0, width: whiteW, height: size.height)
                    ctx.fill(Path(rect), with: .color(color(note, white: true)))
                }
                var grid = Path()
                for j in 1..<Self.whiteNotes.count {
                    let x = CGFloat(j) * whiteW
                    grid.move(to: CGPoint(x: x, y: 0))
                    grid.addLine(to: CGPoint(x: x, y: size.height))
                }
                ctx.stroke(grid, with: .color(.black.opacity(0.35)), lineWidth: 0.5)

                // Black keys on top.
                for (note, wi) in Self.blackAfterWhiteIndex {
                    let x = CGFloat(wi + 1) * whiteW - blackW / 2
                    let rect = CGRect(x: x, y: 0, width: blackW, height: blackH)
                    ctx.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(color(note, white: false)))
                }
            }
            .contentShape(Rectangle())
            .highPriorityGesture(   // beat any enclosing scroll view for clicks/drags
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        let n = note(at: g.location, whiteW: whiteW, blackW: blackW, blackH: blackH)
                        if n != mouseNote {
                            if let old = mouseNote { onRelease(old) }
                            mouseNote = n
                            if let n { onPress(n) }
                        }
                    }
                    .onEnded { _ in
                        if let old = mouseNote { onRelease(old) }
                        mouseNote = nil
                    }
            )
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.secondary.opacity(0.4)))
        // The keyboard is a single Canvas (no per-key views), so expose it to VoiceOver
        // as one element that announces what's currently lit/expected.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Piano keyboard")
        .accessibilityValue(accessibilityValue)
    }

    /// A spoken summary of the keyboard state for VoiceOver.
    private var accessibilityValue: String {
        func names(_ s: Set<Int>) -> String {
            s.sorted().map(Self.noteName).joined(separator: ", ")
        }
        var parts: [String] = []
        if !lit.isEmpty { parts.append("playing \(names(lit))") }
        let expected = scoreRH.union(scoreLH)
        if !expected.isEmpty { parts.append("expected \(names(expected))") }
        return parts.isEmpty ? "no notes" : parts.joined(separator: "; ")
    }

    /// A pitch name like "C4" / "F#3" for a MIDI number (middle C = C4 = 60).
    static func noteName(_ n: Int) -> String {
        let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        return "\(names[((n % 12) + 12) % 12])\(n / 12 - 1)"
    }

    /// Which note is at a point — black keys (upper area) take priority.
    private func note(at p: CGPoint, whiteW: CGFloat, blackW: CGFloat, blackH: CGFloat) -> Int? {
        if p.y <= blackH {
            for (note, wi) in Self.blackAfterWhiteIndex {
                let x = CGFloat(wi + 1) * whiteW - blackW / 2
                if p.x >= x && p.x <= x + blackW { return note }
            }
        }
        let wi = Int(p.x / whiteW)
        return (0..<Self.whiteNotes.count).contains(wi) ? Self.whiteNotes[wi] : nil
    }
}
