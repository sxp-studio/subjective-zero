// osc-input — the built-in "OSC Input" library node (NODE_LIBRARY.md): any phone/tablet OSC app
// (TouchOSC, Lemur, …) or another program on the network as live control values — the wifi
// controller. Self-contained Network.framework: this node owns a UDP listener on `port`, advertised
// over Bonjour as `_osc._udp` so controller apps discover it by name; no third-party library (OSC 1.0
// is ~100 lines: address, type tags, big-endian args, 4-byte padding). `reuse: copy-as-is`.
//
// The wifi twin of midi.macos — the SAME binding contract: `mappings` is a JSON array
// `[{"key","port","min","max","label"}]` where `key` is an OSC address (`"/1/fader1"`; a message
// with several numeric args yields `"/addr"`, `"/addr[1]"`, `"/addr[2]"`, …). Each row emits a
// pre-scaled float output named `port` once that address has been seen. `lastEvent` (float2
// `[seq, value01]`) + `lastKey` (string) are the learn signal, so the host's binding-learn layer
// and the controller card work unchanged. Values: floats/doubles as sent (TouchOSC sends 0…1),
// ints/int64 clamped 0…1 (0/1 buttons), T/F as 1/0.
//
// Threading: the listener runs on its own queue and only writes the lock-guarded value table;
// `update()` reads it (midi.macos discipline). `teardown()` cancels the listener BEFORE the loader
// dlcloses this dylib; `setPaused` stops/starts it with the transport. A `port` change relistens.
import Foundation
import Network

final class Node: SZNode {
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private let queue = DispatchQueue(label: "osc-input")
    private let state = OSCState()
    private var listeningPort: UInt16 = 0
    private var paused = false

    /// Parsed `mappings` cached by raw-string identity — one JSON parse per edit, not per frame.
    private var mappingsRaw = ""
    private var mappings: [Mapping] = []

    struct Mapping {
        let port: String
        let key: String
        let min: Float
        let max: Float
    }

    func setup(_ ctx: SZSetupContext) {}

    func update(_ ctx: SZFrameContext) {
        let wanted = UInt16(clamping: Int(ctx.inputFloat("port") ?? 8000))
        if wanted != listeningPort, !paused { listen(on: wanted) }

        let raw = ctx.inputString("mappings") ?? "[]"
        if raw != mappingsRaw {
            mappingsRaw = raw
            mappings = Self.parseMappings(raw)
        }
        for mapping in mappings {
            // Emit only once the address has been seen — a connected target keeps its own default
            // on project open until the controller speaks.
            guard let value01 = state.value(for: mapping.key) else { continue }
            ctx.setOutputFloats(mapping.port, [mapping.min + (mapping.max - mapping.min) * value01])
        }
        let last = state.last()
        ctx.setOutputFloats("lastEvent", [Float(last.seq), last.value01])
        if last.seq > 0 { ctx.setOutputString("lastKey", last.key) }
    }

    func teardown() { stopListening() }

    func setPaused(_ paused: Bool) {
        self.paused = paused
        if paused { stopListening() }   // update() relistens on resume (port differs from 0)
    }

    // MARK: listener

    private func listen(on port: UInt16) {
        stopListening()
        listeningPort = port   // remembered even on failure so a busy/dead port isn't retried every frame
        guard port > 0, let nwPort = NWEndpoint.Port(rawValue: port),
              let listener = try? NWListener(using: .udp, on: nwPort) else { return }
        // Bonjour: controller apps (TouchOSC…) list this Mac by name under `_osc._udp`.
        listener.service = NWListener.Service(name: Host.current().localizedName ?? "Subjective Zero",
                                              type: "_osc._udp")
        let state = self.state
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.connections.append(connection)
            connection.stateUpdateHandler = { [weak self, weak connection] st in
                if case .failed = st, let self, let connection {
                    self.connections.removeAll { $0 === connection }
                } else if case .cancelled = st, let self, let connection {
                    self.connections.removeAll { $0 === connection }
                }
            }
            connection.start(queue: self.queue)
            Self.receive(on: connection, into: state)
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    private func stopListening() {
        listener?.cancel()
        listener = nil
        for connection in connections { connection.cancel() }
        connections = []
        listeningPort = 0
    }

    /// Re-armed receive loop: one datagram = one OSC packet (message or bundle).
    private static func receive(on connection: NWConnection, into state: OSCState) {
        connection.receiveMessage { data, _, _, error in
            if let data, !data.isEmpty { state.ingest(packet: data) }
            guard error == nil else { return }
            receive(on: connection, into: state)
        }
    }

    // MARK: mappings

    /// Parse the `mappings` JSON array; entries missing a port/key are skipped (a malformed table
    /// degrades to fewer bindings, never a crash). Range 0…1.
    private static func parseMappings(_ raw: String) -> [Mapping] {
        guard let data = raw.data(using: .utf8),
              let array = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            return []
        }
        return array.compactMap { entry in
            guard let port = entry["port"] as? String, !port.isEmpty,
                  let key = entry["key"] as? String, key.hasPrefix("/") else { return nil }
            return Mapping(
                port: port,
                key: key,
                min: (entry["min"] as? NSNumber)?.floatValue ?? 0,
                max: (entry["max"] as? NSNumber)?.floatValue ?? 1)
        }
    }
}

/// Lock-guarded value state shared between the network queue (writer) and the render thread
/// (reader): latest 0…1 value per key, plus the last event with a running sequence number — the
/// learn signal. Also the OSC 1.0 decoder (messages + `#bundle`, recursive).
final class OSCState {
    private let lock = NSLock()
    private var values: [String: Float] = [:]
    private var lastSeq = 0
    private var lastKey = ""
    private var lastValue01: Float = 0

    func ingest(packet: Data) {
        var decoded: [(key: String, value01: Float)] = []
        Self.decode(packet, into: &decoded)
        guard !decoded.isEmpty else { return }
        lock.lock()
        for event in decoded {
            values[event.key] = event.value01
            lastSeq += 1
            lastKey = event.key
            lastValue01 = event.value01
        }
        lock.unlock()
    }

    func value(for key: String) -> Float? {
        lock.lock(); defer { lock.unlock() }
        return values[key]
    }

    func last() -> (seq: Int, key: String, value01: Float) {
        lock.lock(); defer { lock.unlock() }
        return (lastSeq, lastKey, lastValue01)
    }

    // MARK: OSC 1.0 decoding

    /// A packet is a message (`/address`) or a bundle (`#bundle` + 8-byte timetag + size-prefixed
    /// elements). Every numeric/bool argument becomes one event: the first keyed by the address,
    /// the rest `address[i]`. Malformed bytes end decoding of that packet — never a crash.
    private static func decode(_ data: Data, into events: inout [(key: String, value01: Float)]) {
        let bytes = [UInt8](data)
        guard !bytes.isEmpty else { return }
        if bytes.starts(with: Array("#bundle".utf8)) {
            var cursor = 16   // "#bundle\0" (8) + timetag (8)
            while cursor + 4 <= bytes.count {
                let size = Int(readUInt32(bytes, at: cursor)); cursor += 4
                guard size > 0, cursor + size <= bytes.count else { return }
                decode(Data(bytes[cursor..<cursor + size]), into: &events)
                cursor += size
            }
            return
        }
        var cursor = 0
        guard let address = readString(bytes, &cursor), address.hasPrefix("/"),
              let tags = readString(bytes, &cursor), tags.hasPrefix(",") else { return }
        var index = 0
        for tag in tags.dropFirst() {
            var value: Float?
            switch tag {
            case "f":
                guard cursor + 4 <= bytes.count else { return }
                value = Float(bitPattern: readUInt32(bytes, at: cursor)); cursor += 4
            case "i":
                guard cursor + 4 <= bytes.count else { return }
                value = Float(Int32(bitPattern: readUInt32(bytes, at: cursor))); cursor += 4
            case "d":
                guard cursor + 8 <= bytes.count else { return }
                value = Float(Double(bitPattern: readUInt64(bytes, at: cursor))); cursor += 8
            case "h":
                guard cursor + 8 <= bytes.count else { return }
                value = Float(Int64(bitPattern: readUInt64(bytes, at: cursor))); cursor += 8
            case "T": value = 1
            case "F": value = 0
            case "N", "I": break
            case "s", "S":
                guard readString(bytes, &cursor) != nil else { return }
            case "b":
                guard cursor + 4 <= bytes.count else { return }
                let size = Int(readUInt32(bytes, at: cursor)); cursor += 4 + ((size + 3) & ~3)
            case "c", "r", "m":
                cursor += 4
            case "t":
                cursor += 8
            default:
                return   // unknown tag: argument size unknown, stop here
            }
            if let value {
                let clamped = value.isFinite ? min(1, max(0, value)) : 0
                events.append((key: index == 0 ? address : "\(address)[\(index)]", value01: clamped))
                index += 1
            }
        }
    }

    /// A NUL-terminated string padded to a 4-byte boundary; nil if unterminated.
    private static func readString(_ bytes: [UInt8], _ cursor: inout Int) -> String? {
        guard cursor < bytes.count, let end = bytes[cursor...].firstIndex(of: 0) else { return nil }
        let string = String(decoding: bytes[cursor..<end], as: UTF8.self)
        cursor = (end + 4) & ~3   // past the NUL, rounded up to the next multiple of 4
        return string
    }

    private static func readUInt32(_ bytes: [UInt8], at i: Int) -> UInt32 {
        UInt32(bytes[i]) << 24 | UInt32(bytes[i + 1]) << 16 | UInt32(bytes[i + 2]) << 8 | UInt32(bytes[i + 3])
    }

    private static func readUInt64(_ bytes: [UInt8], at i: Int) -> UInt64 {
        UInt64(readUInt32(bytes, at: i)) << 32 | UInt64(readUInt32(bytes, at: i + 4))
    }
}

enum SZNodeMain { static func make() -> SZNode { Node() } }
