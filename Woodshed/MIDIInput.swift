//
//  MIDIInput.swift
//  Woodshed
//
//  Phase 0 spike — live MIDI input via CoreMIDI.
//
//  Opens a CoreMIDI client + input port, connects every available source (USB or
//  Bluetooth MIDI), and publishes the set of currently-held notes so the UI can
//  light up a keyboard as you play. Native on macOS and iPadOS — no Web MIDI.
//
//  We use the modern MIDIEventList (Universal MIDI Packet) API. Each MIDI-1.0
//  channel-voice message is one 32-bit UMP word, which is trivial to unpack.
//

import Foundation
import CoreMIDI
import Combine

final class MIDIInput: ObservableObject {
    /// MIDI note numbers currently held down.
    @Published var activeNotes: Set<Int> = []
    /// Called on the main queue for every note-on with its velocity (take capture).
    var onNoteOn: ((_ pitch: Int, _ velocity: Int) -> Void)?
    /// Called on the main queue when the player's sustain pedal (CC64) moves —
    /// feeds the muddy-pedal analysis. true = down.
    var onPedal: ((_ down: Bool) -> Void)?
    /// Human-readable connection status for the UI.
    @Published var status: String = "Starting MIDI…"
    /// Names of connected input sources.
    @Published var sources: [String] = []

    private var client = MIDIClientRef()
    private var inputPort = MIDIPortRef()
    private var outputPort = MIDIPortRef()
    private var connected = Set<MIDIEndpointRef>()

    // Instance id + live count, to tell apart "many endpoints" from "leaked instances"
    // in the diagnostic log (duplicated MIDI input points at one or the other).
    private static var nextId = 0
    private static var liveCount = 0
    private let instanceId: Int

    init() {
        MIDIInput.nextId += 1; MIDIInput.liveCount += 1
        instanceId = MIDIInput.nextId
        DebugLog.shared.log("midi", "MIDIInput #\(instanceId) created (\(MIDIInput.liveCount) live)")
        setup()
    }

    deinit {
        MIDIInput.liveCount -= 1
        DebugLog.shared.log("midi", "MIDIInput #\(instanceId) deinit (\(MIDIInput.liveCount) live)")
        disposeClient()   // no weak-self capture here — forming one in deinit is unsafe
    }

    /// Stop receiving and release the CoreMIDI client. Idempotent — called on session
    /// shutdown (song switch) AND from deinit. Without an explicit teardown, a
    /// view-layer-retained session kept its client alive, so every song switch added
    /// another live input (the 2–3× duplicated-notes bug).
    func teardown() {
        disposeClient()
        DispatchQueue.main.async { [weak self] in self?.activeNotes = [] }
    }

    /// Re-create the client after a teardown, if this instance is reused (SwiftUI can
    /// detach and re-attach the same view, e.g. iPad sidebar transitions). No-op while
    /// the client is live.
    func reviveIfNeeded() {
        guard client == 0 else { return }
        DebugLog.shared.log("midi", "MIDIInput #\(instanceId) revived")
        setup()
    }

    /// Dispose the CoreMIDI client (which also disposes its ports/connections).
    private func disposeClient() {
        guard client != 0 else { return }
        MIDIClientDispose(client)
        client = 0
        inputPort = 0
        outputPort = 0
        connected = []
        DebugLog.shared.log("midi", "MIDIInput #\(instanceId) client disposed")
    }

    // MARK: - Setup

    private func setup() {
        var st = MIDIClientCreateWithBlock("Segno" as CFString, &client) { [weak self] _ in
            // The MIDI setup changed (device plugged/unplugged) — rescan.
            DispatchQueue.main.async { self?.connectSources() }
        }
        guard st == noErr else { status = "MIDI client error (\(st))"; return }

        st = MIDIInputPortCreateWithProtocol(client, "Input" as CFString, ._1_0, &inputPort) {
            [weak self] eventList, _ in
            self?.receive(eventList)
        }
        guard st == noErr else { status = "MIDI port error (\(st))"; return }

        MIDIOutputPortCreate(client, "Output" as CFString, &outputPort)   // for playback → piano

        connectSources()
    }

    // MARK: - Output (send playback to the piano)

    /// True if there's at least one MIDI destination (e.g. the piano) to play to.
    var hasDestination: Bool { MIDIGetNumberOfDestinations() > 0 }

    func sendNoteOn(_ note: Int, velocity: Int = 90) {
        DebugLog.shared.log("out", "→piano ON  \(note)")
        send([0x90, UInt8(note & 0x7F), UInt8(velocity & 0x7F)])
    }
    func sendNoteOff(_ note: Int) {
        DebugLog.shared.log("out", "→piano OFF \(note)")
        send([0x80, UInt8(note & 0x7F), 0])
    }
    /// Sustain pedal (CC64) on channel 1: value 127 = down, 0 = up.
    func sendSustain(_ down: Bool) {
        DebugLog.shared.log("out", "→piano PEDAL \(down ? "down" : "up")")
        send([0xB0, 64, down ? 127 : 0])
    }

    /// Metronome click on the piano via GM percussion (channel 10): wood-block hits,
    /// louder on the downbeat. Requires the instrument to support GM drums on ch. 10.
    func sendClick(_ level: ClickLevel) {
        let note: UInt8, vel: UInt8
        switch level {
        case .downbeat: note = 76; vel = 112   // Hi wood block
        case .beat:     note = 77; vel = 92     // Low wood block
        case .sub:      note = 77; vel = 55
        }
        send([0x99, note, vel])   // note-on,  channel 10
        send([0x89, note, 0])     // note-off, channel 10
    }
    /// Panic: silence everything (All Notes Off on all 16 channels).
    func allNotesOff() { for ch in 0..<16 { send([UInt8(0xB0 | ch), 123, 0]) } }

    private func send(_ bytes: [UInt8]) {
        let destCount = MIDIGetNumberOfDestinations()
        guard destCount > 0 else { return }
        var packetList = MIDIPacketList()
        let packet = MIDIPacketListInit(&packetList)
        _ = MIDIPacketListAdd(&packetList, MemoryLayout<MIDIPacketList>.size, packet, 0, bytes.count, bytes)
        for i in 0..<destCount {
            let dest = MIDIGetDestination(i)
            if dest != 0 { MIDISend(outputPort, dest, &packetList) }
        }
    }

    /// Reconcile our connections with the sources that currently exist: connect any
    /// new source, and DISCONNECT sources that have vanished (unplug / Bluetooth drop).
    /// When any source disappears we clear `activeNotes` — a note held at the moment of
    /// disconnect (or whose note-off was lost across a dropout) would otherwise stay
    /// lit forever and, in Wait mode, falsely count as already-played.
    private func connectSources() {
        guard client != 0 else { return }
        var current = Set<MIDIEndpointRef>()
        var names: [String] = []
        for i in 0..<MIDIGetNumberOfSources() {
            let src = MIDIGetSource(i)
            guard src != 0 else { continue }
            current.insert(src)
            names.append(name(of: src))
            if !connected.contains(src), MIDIPortConnectSource(inputPort, src, nil) == noErr {
                connected.insert(src)
            }
        }
        let vanished = connected.subtracting(current)
        for src in vanished {
            MIDIPortDisconnectSource(inputPort, src)
            connected.remove(src)
        }
        if !vanished.isEmpty {
            DebugLog.shared.log("midi", "#\(instanceId) \(vanished.count) source(s) vanished → clearing held notes")
            if !activeNotes.isEmpty { activeNotes = [] }   // drop stuck notes
        }
        // macOS fires the setup-changed notification several times per connect — only
        // publish/log when the source list actually changed, so the diagnostic log
        // stays clean and the session's output reconciliation isn't re-run needlessly.
        if names != sources {
            DebugLog.shared.log("midi", "#\(instanceId) sources (\(names.count)): \(names.joined(separator: ", "))")
            sources = names
        }
        status = names.isEmpty
            ? "No MIDI input detected — connect a piano (USB/Bluetooth)"
            : "Connected: \(names.joined(separator: ", "))"
    }

    private func name(of endpoint: MIDIEndpointRef) -> String {
        var cf: Unmanaged<CFString>?
        MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &cf)
        return (cf?.takeRetainedValue() as String?) ?? "MIDI device"
    }

    // MARK: - Receive (runs on a CoreMIDI thread)

    private func receive(_ eventListPtr: UnsafePointer<MIDIEventList>) {
        // CoreMIDI packets are VARIABLE length: `wordCount` may legally exceed the
        // 64-word tuple in the imported Swift struct, so the packet must never be
        // copied into a local and indexed (that read past the copy's buffer — a real
        // 65-word packet crashed; audit 06 P1-1). Walk pointers into the original
        // callback buffer: `unsafeSequence()` advances packet-by-packet within it,
        // and the words are read at their true offsets with unaligned loads.
        for packetPtr in eventListPtr.unsafeSequence() {
            let count = Int(packetPtr.pointee.wordCount)
            let words = UnsafeRawPointer(packetPtr) + Self.wordsOffset
            for m in Self.messages(words: words, wordCount: count) { apply(m) }
        }
    }

    /// Byte offset of the flexible `words` array inside a `MIDIEventPacket`.
    static let wordsOffset = MemoryLayout<MIDIEventPacket>.offset(of: \MIDIEventPacket.words)!

    /// One decoded input event. Pure value so packet parsing is unit-testable.
    enum Message: Equatable {
        case noteOn(pitch: Int, velocity: Int)
        case noteOff(pitch: Int)
        case pedal(down: Bool)
    }

    /// UMP message sizes in 32-bit words by message-type nibble (MIDI 2.0 spec).
    /// Walking at message width matters for correctness, not just speed: a SysEx or
    /// MIDI-2 message's *data* words can coincidentally look like channel-voice
    /// words and must never be decoded as notes.
    static func umpWordCount(messageType mt: UInt32) -> Int {
        switch mt {
        case 0x0, 0x1, 0x2, 0x6, 0x7: return 1
        case 0x3, 0x4, 0x8, 0x9, 0xA: return 2
        case 0xB, 0xC:                return 3
        default:                      return 4   // 0x5, 0xD–0xF
        }
    }

    /// Decode a packet's words into events. Steps whole UMP messages; decodes only
    /// MIDI 1.0 channel voice (mt 0x2), which is what our MIDI-1 protocol port carries.
    static func messages(words: UnsafeRawPointer, wordCount: Int) -> [Message] {
        var out: [Message] = []
        var i = 0
        while i < wordCount {
            let word = words.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self)
            let mt = (word >> 28) & 0xF
            defer { i += umpWordCount(messageType: mt) }
            guard mt == 0x2 else { continue }
            // Byte layout in the word: [mt|group][status][data1][data2].
            let status = UInt8((word >> 16) & 0xFF)
            let note = Int((word >> 8) & 0x7F)
            let velocity = Int(word & 0x7F)
            switch status & 0xF0 {
            case 0x90 where velocity > 0: out.append(.noteOn(pitch: note, velocity: velocity))
            case 0x80, 0x90:              out.append(.noteOff(pitch: note))   // or note-on vel 0
            case 0xB0 where note == 64:   out.append(.pedal(down: velocity >= 64))
            default: break
            }
        }
        return out
    }

    private func apply(_ m: Message) {
        switch m {
        case .noteOn(let p, let v): noteOn(p, velocity: v)
        case .noteOff(let p):       noteOff(p)
        case .pedal(let down):
            DebugLog.shared.log("midi", "#\(instanceId) pedal \(down ? "down" : "up")")
            DispatchQueue.main.async { [weak self] in self?.onPedal?(down) }
        }
    }

    private func noteOn(_ note: Int, velocity: Int) {
        DebugLog.shared.log("midi", "#\(instanceId) noteOn \(note) vel \(velocity)")
        DispatchQueue.main.async {
            self.activeNotes.insert(note)
            self.onNoteOn?(note, velocity)
        }
    }
    private func noteOff(_ note: Int) {
        DispatchQueue.main.async { self.activeNotes.remove(note) }
    }
}
