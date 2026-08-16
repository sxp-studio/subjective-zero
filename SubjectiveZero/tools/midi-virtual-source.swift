#!/usr/bin/env swift
// midi-virtual-source.swift — test helper: a virtual CoreMIDI source that sweeps one CC, standing in
// for a hardware knob so the learn/bind flow can be driven headlessly. The virtual source appears in
// MIDIGetSource like any hardware port, so the app's midi node connects to it with no special casing.
//
//   swift tools/midi-virtual-source.swift <cc> <from> <to> [--ch N] [--rate hz] [--hold s]
//
//   cc     controller number 0–127
//   from   start value 0–127
//   to     end value 0–127 (equal to `from` sends a single event)
//   --ch   MIDI channel 0–15 (default 0)
//   --rate events per second during the sweep (default 60)
//   --hold seconds to keep the source alive after the sweep (default 1; receivers see the
//          source vanish afterwards and reconnect via the setup-change notification)
import CoreMIDI
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

var positional: [Int] = []
var channel = 0
var rate = 60.0
var hold = 1.0
var arguments = Array(CommandLine.arguments.dropFirst())
while !arguments.isEmpty {
    let argument = arguments.removeFirst()
    switch argument {
    case "--ch":   channel = Int(arguments.removeFirst()) ?? 0
    case "--rate": rate = Double(arguments.removeFirst()) ?? 60
    case "--hold": hold = Double(arguments.removeFirst()) ?? 1
    default:
        guard let value = Int(argument) else { fail("unrecognized argument: \(argument)") }
        positional.append(value)
    }
}
guard positional.count == 3 else {
    fail("usage: midi-virtual-source.swift <cc> <from> <to> [--ch N] [--rate hz] [--hold s]")
}
let (cc, from, to) = (positional[0], positional[1], positional[2])
guard (0...127).contains(cc), (0...127).contains(from), (0...127).contains(to),
      (0...15).contains(channel), rate > 0 else {
    fail("cc/from/to must be 0–127, ch 0–15, rate > 0")
}

var client = MIDIClientRef()
var source = MIDIEndpointRef()
guard MIDIClientCreate("sz-virtual-knob" as CFString, nil, nil, &client) == noErr,
      MIDISourceCreateWithProtocol(client, "SZ Virtual Knob" as CFString, ._1_0, &source) == noErr else {
    fail("could not create the virtual MIDI source")
}
defer {
    MIDIEndpointDispose(source)
    MIDIClientDispose(client)
}

func send(_ value: Int) {
    // One UMP MIDI-1.0 channel-voice word: control change on `channel`.
    let bits: Int = (0x2 << 28) | (0xB << 20) | (channel << 16) | (cc << 8) | value
    var word = UInt32(bits)
    var list = MIDIEventList()
    withUnsafeMutablePointer(to: &list) { pointer in
        let packet = MIDIEventListInit(pointer, ._1_0)
        _ = MIDIEventListAdd(pointer, MemoryLayout<MIDIEventList>.size, packet, 0, 1, &word)
        MIDIReceivedEventList(source, pointer)
    }
}

// Give receivers a beat to notice the new source (setup-change → reconnect) before the first event.
Thread.sleep(forTimeInterval: 0.3)

let step = from <= to ? 1 : -1
var value = from
while true {
    send(value)
    print("cc\(cc) ch\(channel) = \(value)")
    if value == to { break }
    value += step
    Thread.sleep(forTimeInterval: 1.0 / rate)
}
Thread.sleep(forTimeInterval: hold)
