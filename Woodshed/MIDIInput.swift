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
    /// Human-readable connection status for the UI.
    @Published var status: String = "Starting MIDI…"
    /// Names of connected input sources.
    @Published var sources: [String] = []

    private var client = MIDIClientRef()
    private var inputPort = MIDIPortRef()
    private var outputPort = MIDIPortRef()
    private var connected = Set<MIDIEndpointRef>()

    init() { setup() }

    // MARK: - Setup

    private func setup() {
        var st = MIDIClientCreateWithBlock("Woodshed" as CFString, &client) { [weak self] _ in
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

    func sendNoteOn(_ note: Int, velocity: Int = 90) { send([0x90, UInt8(note & 0x7F), UInt8(velocity & 0x7F)]) }
    func sendNoteOff(_ note: Int) { send([0x80, UInt8(note & 0x7F), 0]) }

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

    /// Connect any sources we're not already listening to.
    private func connectSources() {
        var names: [String] = []
        for i in 0..<MIDIGetNumberOfSources() {
            let src = MIDIGetSource(i)
            names.append(name(of: src))
            if src != 0 && !connected.contains(src) {
                if MIDIPortConnectSource(inputPort, src, nil) == noErr {
                    connected.insert(src)
                }
            }
        }
        sources = names
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
        let eventList = eventListPtr.pointee
        var packet = eventList.packet
        for _ in 0..<eventList.numPackets {
            var pkt = packet
            withUnsafeBytes(of: &pkt.words) { raw in
                let words = raw.bindMemory(to: UInt32.self)
                for i in 0..<Int(pkt.wordCount) { parse(word: words[i]) }
            }
            packet = MIDIEventPacketNext(&packet).pointee
        }
    }

    private func parse(word: UInt32) {
        // Message type 0x2 = MIDI 1.0 channel voice. Byte layout in the word:
        // [mt|group][status][data1][data2].
        guard (word >> 28) & 0xF == 0x2 else { return }
        let status = UInt8((word >> 16) & 0xFF)
        let note = Int((word >> 8) & 0x7F)
        let velocity = Int(word & 0x7F)
        switch status & 0xF0 {
        case 0x90 where velocity > 0: noteOn(note)
        case 0x80, 0x90:              noteOff(note)   // 0x80, or note-on with velocity 0
        default: break
        }
    }

    private func noteOn(_ note: Int) {
        DispatchQueue.main.async { self.activeNotes.insert(note) }
    }
    private func noteOff(_ note: Int) {
        DispatchQueue.main.async { self.activeNotes.remove(note) }
    }
}
