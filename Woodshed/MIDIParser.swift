//
//  MIDIParser.swift
//  Woodshed
//
//  Phase 0 spike — a small, dependency-free Standard MIDI File (SMF) parser.
//
//  Why hand-roll this instead of using a library? For the spike we want to (a)
//  add zero package dependencies, (b) understand exactly what we're reading, and
//  (c) treat MIDI timing as the source of truth. A .mid file is a compact binary
//  format: a header chunk (MThd) followed by one or more track chunks (MTrk).
//  Each track is a stream of <delta-time, event> pairs. We walk that stream,
//  keep a running absolute tick count, pair note-on with note-off, and convert
//  ticks -> seconds using the tempo map.
//

import Foundation

enum MIDIParser {

    /// Parse a Standard MIDI File into our `MidiScore`.
    static func parse(data: Data) throws -> MidiScore {
        var reader = ByteReader(data)

        // ---- Header chunk: "MThd" <len:4> <format:2> <ntracks:2> <division:2> ----
        guard reader.readString(4) == "MThd" else { throw MIDIError.notAMIDIFile }
        let headerLen = reader.readUInt32()
        let _format = reader.readUInt16()
        let trackCount = Int(reader.readUInt16())
        let division = Int(reader.readUInt16())
        _ = _format
        // If the top bit of `division` is set the file uses SMPTE timing; MuseScore
        // exports musical (ticks-per-quarter) timing, which is what we support here.
        guard division & 0x8000 == 0 else { throw MIDIError.unsupportedTiming }
        let ticksPerQuarter = division
        // Skip any extra header bytes beyond the 6 we read (spec allows headerLen > 6).
        reader.skip(Int(headerLen) - 6)

        // ---- Collect raw events from every track ----
        // A tempo change is (absoluteTick, microsecondsPerQuarter).
        var tempoMap: [(tick: Int, usPerQuarter: Int)] = []
        var timeSignature: (num: Int, den: Int)? = nil

        // We gather note events per track so we can assign hands per track later.
        // Each note: (startTick, endTick, pitch).
        struct RawNote { var start: Int; var end: Int; var pitch: Int }
        var notesPerTrack: [[RawNote]] = []

        for _ in 0..<trackCount {
            guard reader.readString(4) == "MTrk" else { throw MIDIError.malformed }
            let trackLen = Int(reader.readUInt32())
            let trackEnd = reader.offset + trackLen

            var absoluteTick = 0
            var runningStatus: UInt8 = 0
            // Open note-ons awaiting their note-off, keyed by pitch (channel folded
            // in via key = channel*128 + pitch to avoid cross-channel mismatches).
            var openNotes: [Int: Int] = [:]   // key -> startTick
            var trackNotes: [RawNote] = []

            while reader.offset < trackEnd {
                let delta = reader.readVarLen()
                absoluteTick += delta

                var status = reader.peekUInt8()
                if status & 0x80 != 0 {
                    reader.skip(1)               // consume the status byte
                    runningStatus = status
                } else {
                    status = runningStatus        // running status: reuse last status byte
                }

                switch status {
                case 0xFF:                        // Meta event
                    let metaType = reader.readUInt8()
                    let len = reader.readVarLen()
                    let payload = reader.readBytes(len)
                    switch metaType {
                    case 0x51 where payload.count == 3:  // Set Tempo (us per quarter)
                        let us = (Int(payload[0]) << 16) | (Int(payload[1]) << 8) | Int(payload[2])
                        tempoMap.append((absoluteTick, us))
                    case 0x58 where payload.count >= 2:  // Time Signature
                        if timeSignature == nil {
                            timeSignature = (Int(payload[0]), 1 << Int(payload[1]))
                        }
                    default:
                        break
                    }

                case 0xF0, 0xF7:                   // SysEx — skip
                    let len = reader.readVarLen()
                    reader.skip(len)

                default:                           // Channel voice message
                    let high = status & 0xF0
                    let channel = Int(status & 0x0F)
                    switch high {
                    case 0x80, 0x90:               // note-off / note-on
                        let pitch = Int(reader.readUInt8())
                        let velocity = Int(reader.readUInt8())
                        let key = channel * 128 + pitch
                        if high == 0x90 && velocity > 0 {
                            openNotes[key] = absoluteTick               // note starts
                        } else {
                            if let start = openNotes.removeValue(forKey: key) {
                                trackNotes.append(RawNote(start: start, end: absoluteTick, pitch: pitch))
                            }
                        }
                    case 0xA0, 0xB0, 0xE0:         // 2-byte messages we ignore
                        reader.skip(2)
                    case 0xC0, 0xD0:               // 1-byte messages we ignore
                        reader.skip(1)
                    default:
                        throw MIDIError.malformed
                    }
                }
            }
            // Jump exactly to the track end in case a track had trailing bytes.
            reader.offset = trackEnd
            notesPerTrack.append(trackNotes)
        }

        // ---- Tempo map -> a tick->seconds converter ----
        if tempoMap.isEmpty { tempoMap = [(0, 500_000)] } // default 120 BPM if none
        tempoMap.sort { $0.tick < $1.tick }
        let toSeconds = makeTickToSeconds(tempoMap: tempoMap, ticksPerQuarter: ticksPerQuarter)
        let firstTempoBPM = 60_000_000.0 / Double(tempoMap[0].usPerQuarter)

        // ---- Assign a hand to each track ----
        // Heuristic for the spike: with two tracks, the one whose notes average a
        // higher pitch is the right hand. (Increment 2 will cross-check this against
        // the MusicXML <staff> assignment, which is the real authority.)
        let averagePitches: [Double] = notesPerTrack.map { track in
            track.isEmpty ? 0 : Double(track.map(\.pitch).reduce(0, +)) / Double(track.count)
        }
        let handForTrack = assignHands(averagePitches: averagePitches)

        // ---- Flatten into the final note list, converting ticks -> seconds ----
        var notes: [MidiNote] = []
        for (t, trackNotes) in notesPerTrack.enumerated() {
            for n in trackNotes {
                let onset = toSeconds(n.start)
                let end = toSeconds(n.end)
                notes.append(MidiNote(pitch: n.pitch,
                                      onsetSeconds: onset,
                                      durationSeconds: max(0, end - onset),
                                      onsetBeats: Double(n.start) / Double(ticksPerQuarter),
                                      track: t,
                                      hand: handForTrack[t]))
            }
        }
        notes.sort { ($0.onsetSeconds, $0.pitch) < ($1.onsetSeconds, $1.pitch) }

        // Convert any (possibly fractional) quarter-beat position to seconds via the
        // tempo map — used to time the metronome clicks (follows tempo changes/rubato).
        let secondsAtBeat: (Double) -> Double = { beat in
            toSeconds(Int((beat * Double(ticksPerQuarter)).rounded()))
        }

        return MidiScore(ticksPerQuarter: ticksPerQuarter,
                         tempoBPM: firstTempoBPM,
                         timeSignature: timeSignature,
                         notes: notes,
                         secondsAtBeat: secondsAtBeat,
                         trackHands: handForTrack)
    }

    // MARK: - Helpers

    /// Build a closure that converts an absolute tick to elapsed seconds, honoring
    /// every tempo change (a "tempo map"). We integrate segment by segment.
    private static func makeTickToSeconds(tempoMap: [(tick: Int, usPerQuarter: Int)],
                                          ticksPerQuarter: Int) -> (Int) -> Double {
        return { tick in
            var seconds = 0.0
            var i = 0
            while i < tempoMap.count {
                let segStart = tempoMap[i].tick
                let segTempo = tempoMap[i].usPerQuarter
                let segEnd = (i + 1 < tempoMap.count) ? tempoMap[i + 1].tick : Int.max
                if tick <= segStart { break }
                let upper = min(tick, segEnd)
                let ticksInSeg = upper - segStart
                let secondsPerTick = (Double(segTempo) / 1_000_000.0) / Double(ticksPerQuarter)
                seconds += Double(ticksInSeg) * secondsPerTick
                if tick <= segEnd { break }
                i += 1
            }
            return seconds
        }
    }

    /// Map each track index to a Hand using each track's average pitch.
    private static func assignHands(averagePitches: [Double]) -> [Hand] {
        guard averagePitches.count == 2 else {
            // 1 track or >2 tracks: we can't reliably guess; leave to MusicXML.
            return Array(repeating: .unknown, count: averagePitches.count)
        }
        return averagePitches[0] >= averagePitches[1] ? [.right, .left] : [.left, .right]
    }
}

// MARK: - Errors

enum MIDIError: Error, CustomStringConvertible {
    case notAMIDIFile, unsupportedTiming, malformed
    var description: String {
        switch self {
        case .notAMIDIFile: return "Not a Standard MIDI File (missing MThd)."
        case .unsupportedTiming: return "SMPTE timing not supported (expected ticks-per-quarter)."
        case .malformed: return "Malformed MIDI data."
        }
    }
}

// MARK: - ByteReader

/// A tiny cursor over `Data` for big-endian reads and MIDI variable-length ints.
private struct ByteReader {
    let bytes: [UInt8]
    var offset: Int = 0
    init(_ data: Data) { bytes = [UInt8](data) }

    mutating func skip(_ n: Int) { offset += max(0, n) }
    func peekUInt8() -> UInt8 { bytes[offset] }

    mutating func readUInt8() -> UInt8 {
        defer { offset += 1 }
        return bytes[offset]
    }
    mutating func readUInt16() -> UInt16 {
        let v = (UInt16(bytes[offset]) << 8) | UInt16(bytes[offset + 1])
        offset += 2
        return v
    }
    mutating func readUInt32() -> UInt32 {
        var v: UInt32 = 0
        for i in 0..<4 { v = (v << 8) | UInt32(bytes[offset + i]) }
        offset += 4
        return v
    }
    mutating func readBytes(_ n: Int) -> [UInt8] {
        let slice = Array(bytes[offset..<offset + n])
        offset += n
        return slice
    }
    mutating func readString(_ n: Int) -> String {
        String(bytes: readBytes(n), encoding: .ascii) ?? ""
    }
    /// MIDI variable-length quantity: 7 bits per byte, high bit = "more follows".
    mutating func readVarLen() -> Int {
        var value = 0
        while true {
            let b = readUInt8()
            value = (value << 7) | Int(b & 0x7F)
            if b & 0x80 == 0 { break }
        }
        return value
    }
}
