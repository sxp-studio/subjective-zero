// midi.macos — the built-in "MIDI Input" library node (NODE_LIBRARY.md). Self-contained CoreMIDI:
// this node owns the client, the input port, and the source connections; no entitlement or permission
// is involved (CoreMIDI is not TCC-gated). `reuse: copy-as-is`.
//
// It is the SOURCE of a control pipeline: hardware CC events land in a lock-guarded table, and
// `update()` emits one pre-scaled float output per entry of the `mappings` input — a JSON array
// `[{"key","port","min","max","label"}]` that IS the binding table (port data: persisted,
// host-readable). `key` is this node's wire identity `"ch<1-16>/cc<0-127>"`. The node's code is
// mapping-generic: outputs are emitted by the names the mappings declare, so a binding change edits
// data + the instance contract, never this file.
//
// `lastEvent` (float2 `[seq, value01]`) + `lastKey` (string) are the learn primitive: seq increments
// on every CC received, so an observer can detect "a knob moved" and which one, without any binding
// existing yet. Until a mapping's CC has been seen at least once, its output is NOT emitted — a
// connected target keeps its own default rather than snapping to the mapping's min (matters on
// project open, before the hardware sends anything).
//
// Live inputs: `source` — a DYNAMIC enum (like microphone.macos's `device`) listing MIDI sources by
// unique id, "all" connects every source; a setup-change notification (device plugged/unplugged,
// virtual source created) flags a reconnect that the next `update()` applies, so hot-plug just works.
// MIDI 1.0 channel-voice CC only (protocol ._1_0); notes/pitch-bend/NRPN are out of scope here.
import CoreMIDI
import Foundation

final class Node: SZNode {
    private var client = MIDIClientRef()
    private var inputPort = MIDIPortRef()
    private var connectedSources: [MIDIEndpointRef] = []
    private let state = MIDIState()

    private var requestedSource = "all"      // last-applied `source` selection value
    /// Set by the CoreMIDI notify block (its own thread) and consumed by update() (the render
    /// thread) — cross-thread, so lock-guarded (the microphone.macos discipline).
    private var needsReconnect = false
    private let reconnectFlagLock = NSLock()

    /// Parsed `mappings` cached by raw-string identity — one JSON parse per edit, not per frame.
    private var mappingsRaw = ""
    private var mappings: [Mapping] = []

    struct Mapping {
        let port: String
        let cc: Int
        let ch: Int
        let min: Float
        let max: Float
    }

    /// Dynamic enum options for the `source` port: "All sources" + one entry per MIDI source
    /// (label = display name, value = the endpoint's stable unique id). Re-queried when the
    /// dropdown opens, so plug/unplug is picked up automatically.
    func dynamicOptions(for port: String) -> [SZEnumOption] {
        guard port == "source" else { return [] }
        var options = [SZEnumOption(label: "All sources", value: "all")]
        for i in 0..<MIDIGetNumberOfSources() {
            let source = MIDIGetSource(i)
            options.append(SZEnumOption(label: Self.displayName(source),
                                        value: String(Self.uniqueID(source))))
        }
        return options
    }

    func setup(_ ctx: SZSetupContext) {
        let flagReconnect: () -> Void = { [weak self] in
            guard let self else { return }
            reconnectFlagLock.lock()
            needsReconnect = true
            reconnectFlagLock.unlock()
        }
        MIDIClientCreateWithBlock("midi.macos" as CFString, &client) { notification in
            // Any setup change (plug/unplug, a virtual source appearing) → reconnect on next update().
            if notification.pointee.messageID == .msgSetupChanged { flagReconnect() }
        }
        let state = self.state
        MIDIInputPortCreateWithProtocol(client, "input" as CFString, ._1_0, &inputPort) { eventList, _ in
            // CoreMIDI THREAD: decode MIDI 1.0 channel-voice CC words into the lock-guarded table;
            // no allocations beyond the lock scope, nothing else touched.
            state.ingest(eventList)
        }
        connectSources(matching: requestedSource)
    }

    func update(_ ctx: SZFrameContext) {
        // Live source selection + hot-plug both funnel through one reconnect path.
        let selection = ctx.inputString("source") ?? "all"
        reconnectFlagLock.lock()
        let wantsReconnect = needsReconnect || selection != requestedSource
        needsReconnect = false
        reconnectFlagLock.unlock()
        if wantsReconnect {
            requestedSource = selection
            connectSources(matching: selection)
        } else if connectedSources.isEmpty, MIDIGetNumberOfSources() > 0 {
            // Cold-start race: the first connect can run before the MIDI server has published the
            // source list (it arrives asynchronously after client creation), and with a fixed
            // device selection no setup-change ever retriggers it — the node would sit deaf next
            // to a connected controller (reproduced on a relaunch with a persisted selection).
            // Retry while we want sources and hold none; per-frame cost is one enumeration, and
            // only in that empty state.
            connectSources(matching: selection)
        }

        let raw = ctx.inputString("mappings") ?? "[]"
        if raw != mappingsRaw {
            mappingsRaw = raw
            mappings = Self.parseMappings(raw)
        }

        for mapping in mappings {
            // Emit only once the CC has been seen — see the header note about project-open defaults.
            guard let value01 = state.value(ch: mapping.ch, cc: mapping.cc) else { continue }
            ctx.setOutputFloats(mapping.port, [mapping.min + (mapping.max - mapping.min) * value01])
        }
        let last = state.last()
        ctx.setOutputFloats("lastEvent", [Float(last.seq), last.value01])
        if last.seq > 0 { ctx.setOutputString("lastKey", Self.key(ch: last.ch, cc: last.cc)) }
    }

    func teardown() {
        // Dispose BEFORE the loader dlcloses this dylib: the client dispose tears down the port and
        // its receive block, so no CoreMIDI callback can land in unloaded code.
        if inputPort != 0 { MIDIPortDispose(inputPort); inputPort = 0 }
        if client != 0 { MIDIClientDispose(client); client = 0 }
        connectedSources = []
    }

    // MARK: source connections

    /// (Re)connect the input port to the sources matching `selection`: every source for "all", else
    /// the one whose unique id matches. Disconnect-then-connect keeps the set exact after hot-plug.
    private func connectSources(matching selection: String) {
        guard inputPort != 0 else { return }
        for source in connectedSources { MIDIPortDisconnectSource(inputPort, source) }
        connectedSources = []
        for i in 0..<MIDIGetNumberOfSources() {
            let source = MIDIGetSource(i)
            if selection == "all" || String(Self.uniqueID(source)) == selection {
                if MIDIPortConnectSource(inputPort, source, nil) == noErr {
                    connectedSources.append(source)
                }
            }
        }
    }

    private static func displayName(_ endpoint: MIDIEndpointRef) -> String {
        var name: Unmanaged<CFString>?
        MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &name)
        return (name?.takeRetainedValue() as String?) ?? "MIDI source"
    }

    private static func uniqueID(_ endpoint: MIDIEndpointRef) -> Int32 {
        var id: Int32 = 0
        MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyUniqueID, &id)
        return id
    }

    // MARK: mappings

    /// The wire key this node reports and matches: `"ch<1-16>/cc<0-127>"` — channels 1-based, the
    /// way controllers label them (the wire carries 0–15).
    private static func key(ch: Int, cc: Int) -> String { "ch\(ch + 1)/cc\(cc)" }

    /// Inverse of `key(ch:cc:)`; nil for anything else (an OSC address in a copied table, a typo).
    private static func parseKey(_ key: String) -> (ch: Int, cc: Int)? {
        let parts = key.split(separator: "/")
        guard parts.count == 2, parts[0].hasPrefix("ch"), parts[1].hasPrefix("cc"),
              let ch = Int(parts[0].dropFirst(2)), let cc = Int(parts[1].dropFirst(2)),
              (1...16).contains(ch), (0...127).contains(cc) else { return nil }
        return (ch - 1, cc)
    }

    /// Parse the `mappings` JSON array; entries missing a port or with a key that isn't this node's
    /// shape are skipped (a malformed table degrades to fewer bindings, never a crash). Range 0…1.
    private static func parseMappings(_ raw: String) -> [Mapping] {
        guard let data = raw.data(using: .utf8),
              let array = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            return []
        }
        return array.compactMap { entry in
            guard let port = entry["port"] as? String, !port.isEmpty,
                  let key = entry["key"] as? String, let wire = parseKey(key) else { return nil }
            return Mapping(
                port: port,
                cc: wire.cc,
                ch: wire.ch,
                min: (entry["min"] as? NSNumber)?.floatValue ?? 0,
                max: (entry["max"] as? NSNumber)?.floatValue ?? 1)
        }
    }
}

/// Lock-guarded CC state shared between the CoreMIDI receive thread (writer) and the render thread
/// (reader): latest 0…1 value per (channel, controller), plus the last event with a running sequence
/// number — the learn signal.
final class MIDIState {
    private let lock = NSLock()
    private var values: [Int: Float] = [:]     // key: ch << 8 | cc
    private var lastSeq = 0
    private var lastCh = 0
    private var lastCC = 0
    private var lastValue01: Float = 0

    /// Decode every MIDI 1.0 channel-voice CC in the event list (UMP message type 0x2, status 0xB).
    func ingest(_ eventList: UnsafePointer<MIDIEventList>) {
        var decoded: [(ch: Int, cc: Int, value01: Float)] = []
        for packet in eventList.unsafeSequence() {
            let wordCount = Int(packet.pointee.wordCount)
            withUnsafeBytes(of: packet.pointee.words) { words in
                for i in 0..<min(wordCount, words.count / 4) {
                    let word = words.load(fromByteOffset: i * 4, as: UInt32.self)
                    guard (word >> 28) & 0xF == 0x2, (word >> 20) & 0xF == 0xB else { continue }
                    decoded.append((ch: Int((word >> 16) & 0xF),
                                    cc: Int((word >> 8) & 0x7F),
                                    value01: Float(word & 0x7F) / 127))
                }
            }
        }
        guard !decoded.isEmpty else { return }
        lock.lock()
        for event in decoded {
            values[event.ch << 8 | event.cc] = event.value01
            lastSeq += 1
            lastCh = event.ch
            lastCC = event.cc
            lastValue01 = event.value01
        }
        lock.unlock()
    }

    /// Latest 0…1 value for (ch, cc), nil until that controller has been seen.
    func value(ch: Int, cc: Int) -> Float? {
        lock.lock(); defer { lock.unlock() }
        return values[ch << 8 | cc]
    }

    func last() -> (seq: Int, ch: Int, cc: Int, value01: Float) {
        lock.lock(); defer { lock.unlock() }
        return (lastSeq, lastCh, lastCC, lastValue01)
    }
}

enum SZNodeMain { static func make() -> SZNode { Node() } }
