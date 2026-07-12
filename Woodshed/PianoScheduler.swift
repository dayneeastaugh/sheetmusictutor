//
//  PianoScheduler.swift
//  Woodshed
//
//  Edge-triggered scheduler for playback to the connected piano (MIDI out).
//
//  The old piano output sampled "which pitches are sounding now?" every ~20ms and
//  diffed the set. That level-triggered approach silently DROPPED anything shorter
//  than a tick (grace notes, trill/turn realizations) and could not re-articulate a
//  repeated pitch — so ornaments and graces never reached the piano (see ADR-042).
//
//  This scheduler instead pre-computes a sorted list of note-on / note-off / pedal
//  EDGES and, each tick, fires every edge whose time has passed. Short notes always
//  get their on AND off; a repeated pitch is re-struck; the sustain pedal (CC64) is
//  driven from the captured timeline. Pure and unit-tested — no engine/UI refs; the
//  caller (`PracticeSession`) turns the returned commands into MIDI sends.
//

import Foundation

struct PianoScheduler {
    /// A MIDI action for the caller to send to the piano.
    enum Command: Equatable {
        case noteOn(Int)
        case noteOff(Int)
        case pedal(Bool)
    }

    private struct Edge {
        let time: Double
        let kind: Kind
        enum Kind {
            case on(pitch: Int, hand: Hand, off: Double)
            case off(pitch: Int, release: Double)
            case pedal(Bool)
        }
        // At equal times, releases & pedal changes go before note-ons so a repeated
        // pitch re-articulates cleanly (off, then on).
        var order: Int { if case .on = kind { return 1 } else { return 0 } }
    }

    private var edges: [Edge] = []
    private var nextIdx = 0
    private var lastT = -Double.infinity
    private var reposition = true
    private var sounding: [Int: (hand: Hand, release: Double)] = [:]  // pitch → current instance
    private var pedalDown = false

    init() {}

    /// Build the edge list from the playable notes (fused events + realized ornament
    /// extras) and the pedal timeline. Very short notes are floored to `minDuration`
    /// so the piano actually registers them. Call once per song / score change.
    mutating func load(notes: [NoteEvent], pedal: [(time: Double, down: Bool)],
                       minDuration: Double = 0.05) {
        var e: [Edge] = []
        e.reserveCapacity(notes.count * 2 + pedal.count)
        for n in notes {
            let off = n.onsetSeconds + max(n.durationSeconds, minDuration)
            e.append(Edge(time: n.onsetSeconds, kind: .on(pitch: n.pitch, hand: n.hand, off: off)))
            e.append(Edge(time: off, kind: .off(pitch: n.pitch, release: off)))
        }
        for p in pedal { e.append(Edge(time: p.time, kind: .pedal(p.down))) }
        e.sort { $0.time != $1.time ? $0.time < $1.time : $0.order < $1.order }
        edges = e
        reset()
    }

    /// Forget schedule position + sounding state (loop, seek, stop). The next
    /// `advance` re-finds its place without re-firing passed edges. The caller must
    /// separately flush the piano (all-notes-off + pedal up).
    mutating func reset() {
        nextIdx = 0
        lastT = -.infinity
        reposition = true
        sounding = [:]
        pedalDown = false
    }

    private func handOn(_ h: Hand, rhOn: Bool, lhOn: Bool) -> Bool {
        switch h { case .right: return rhOn; case .left: return lhOn; case .unknown: return true }
    }

    /// Advance to playback time `t`, returning the MIDI commands to send now.
    /// `rhOn`/`lhOn` gate which hands sound; a note whose hand is muted mid-sustain is
    /// released. A backward jump (loop/seek) or an explicit `reset()` repositions
    /// without firing the skipped edges, re-applying a pedal held across the boundary.
    mutating func advance(to t: Double, rhOn: Bool, lhOn: Bool) -> [Command] {
        var out: [Command] = []

        if reposition || t < lastT {
            reposition = false
            // Rebuild the state AT `t` from the edges up to it, without emitting the
            // historical commands, then strike whatever is genuinely ringing at `t`
            // (a note that spans the seek/loop point, or the section's first note).
            sounding = [:]
            pedalDown = false
            nextIdx = 0
            while nextIdx < edges.count && edges[nextIdx].time <= t {
                switch edges[nextIdx].kind {
                case let .on(pitch, hand, off): sounding[pitch] = (hand, off)   // re-strike: last wins
                case let .off(pitch, release): if sounding[pitch]?.release == release { sounding[pitch] = nil }
                case let .pedal(down): pedalDown = down
                }
                nextIdx += 1
            }
            for (pitch, s) in sounding {
                if handOn(s.hand, rhOn: rhOn, lhOn: lhOn) { out.append(.noteOn(pitch)) }
                else { sounding[pitch] = nil }
            }
            if pedalDown { out.append(.pedal(true)) }
        }
        lastT = t

        while nextIdx < edges.count && edges[nextIdx].time <= t {
            let edge = edges[nextIdx]
            nextIdx += 1
            switch edge.kind {
            case let .on(pitch, hand, off):
                guard handOn(hand, rhOn: rhOn, lhOn: lhOn) else { continue }
                if sounding[pitch] != nil { out.append(.noteOff(pitch)) }   // re-articulate
                out.append(.noteOn(pitch))
                sounding[pitch] = (hand, off)
            case let .off(pitch, release):
                // Release only the current instance — a re-strike with a later release
                // supersedes this (now stale) off edge.
                if let s = sounding[pitch], s.release == release {
                    out.append(.noteOff(pitch))
                    sounding[pitch] = nil
                }
            case let .pedal(down):
                if down != pedalDown { pedalDown = down; out.append(.pedal(down)) }
            }
        }

        // Release anything whose hand was just muted (filter copies, so mutating is safe).
        for (pitch, _) in sounding.filter({ !handOn($0.value.hand, rhOn: rhOn, lhOn: lhOn) }) {
            out.append(.noteOff(pitch))
            sounding[pitch] = nil
        }
        return out
    }
}
