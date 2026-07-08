//
//  PianoKeyboardView.swift
//  Woodshed
//
//  Phase 0 spike — an on-screen piano that lights up the notes in `litNotes`
//  (driven by live MIDI input) and can also be played with the mouse/touch for
//  testing without hardware. Purely a view: it owns no MIDI or audio logic.
//

import SwiftUI

struct PianoKeyboardView: View {
    /// Notes you're playing on the MIDI piano (highlighted green).
    var litNotes: Set<Int>
    /// Score notes sounding now — right hand (blue) and left hand (red). When hand
    /// colouring is off, the app puts everything in `scoreRH` so it all shows blue.
    var scoreRH: Set<Int> = []
    var scoreLH: Set<Int> = []
    /// Called when a key is pressed / released by mouse or touch (for testing).
    var onPress: (Int) -> Void = { _ in }
    var onRelease: (Int) -> Void = { _ in }

    private let low = 21    // A0 — full 88-key piano
    private let high = 108  // C8

    // Match the notation's hand colours (RH #1565C0, LH #C62828).
    private static let rhColor = Color(red: 21 / 255, green: 101 / 255, blue: 192 / 255)
    private static let lhColor = Color(red: 198 / 255, green: 40 / 255, blue: 40 / 255)

    @State private var mouseNote: Int? = nil

    private var whiteNotes: [Int] { (low...high).filter { isWhite($0) } }
    private var blackNotes: [Int] { (low...high).filter { !isWhite($0) } }
    private func isWhite(_ n: Int) -> Bool { ![1, 3, 6, 8, 10].contains(((n % 12) + 12) % 12) }

    /// Everything to draw as "played by you": live MIDI notes plus the mouse-held note.
    private var lit: Set<Int> { mouseNote.map { litNotes.union([$0]) } ?? litNotes }

    /// Key colour: your notes win (green), then the score's notes by hand
    /// (RH blue, LH red), else the natural key colour.
    private func color(_ note: Int, white: Bool) -> Color {
        if lit.contains(note) { return white ? Color.green.opacity(0.75) : Color.green }
        if scoreRH.contains(note) { return white ? Self.rhColor.opacity(0.6) : Self.rhColor }
        if scoreLH.contains(note) { return white ? Self.lhColor.opacity(0.6) : Self.lhColor }
        return white ? .white : .black
    }

    var body: some View {
        GeometryReader { geo in
            let whiteW = geo.size.width / CGFloat(whiteNotes.count)
            let blackW = whiteW * 0.62
            let blackH = geo.size.height * 0.6

            ZStack(alignment: .topLeading) {
                // White keys
                ForEach(Array(whiteNotes.enumerated()), id: \.element) { j, note in
                    Rectangle()
                        .fill(color(note, white: true))
                        .overlay(Rectangle().stroke(Color.black.opacity(0.35), lineWidth: 0.5))
                        .frame(width: whiteW, height: geo.size.height)
                        .offset(x: CGFloat(j) * whiteW)
                }
                // Black keys (drawn on top)
                ForEach(blackNotes, id: \.self) { note in
                    if let wi = whiteNotes.firstIndex(of: note - 1) {
                        let x = CGFloat(wi + 1) * whiteW - blackW / 2
                        RoundedRectangle(cornerRadius: 2)
                            .fill(color(note, white: false))
                            .frame(width: blackW, height: blackH)
                            .offset(x: x)
                    }
                }
            }
            // Fill the whole area — `.offset` keys don't expand the ZStack, so without
            // this the hit-test region would be just one key wide.
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .contentShape(Rectangle())
            .highPriorityGesture(   // beat the enclosing ScrollView for clicks/drags
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        let n = note(at: g.location, size: geo.size, whiteW: whiteW, blackW: blackW, blackH: blackH)
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
        .frame(height: 90)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.secondary.opacity(0.4)))
    }

    /// Which note is at a point — black keys (upper area) take priority.
    private func note(at p: CGPoint, size: CGSize, whiteW: CGFloat, blackW: CGFloat, blackH: CGFloat) -> Int? {
        if p.y <= blackH {
            for note in blackNotes {
                guard let wi = whiteNotes.firstIndex(of: note - 1) else { continue }
                let x = CGFloat(wi + 1) * whiteW - blackW / 2
                if p.x >= x && p.x <= x + blackW { return note }
            }
        }
        let wi = Int(p.x / whiteW)
        return (0..<whiteNotes.count).contains(wi) ? whiteNotes[wi] : nil
    }
}
