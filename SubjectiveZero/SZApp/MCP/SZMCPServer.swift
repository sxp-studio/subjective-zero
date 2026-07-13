// SPDX-License-Identifier: AGPL-3.0-only
// The host's MCP server — a TCP, newline-delimited JSON-RPC line server (ARCHITECTURE.md: "the MCP
// server lives in the host"). Coding agents reach it via `--mcp-config` running `nc 127.0.0.1 <port>`
// (the stdio→TCP bridge); it's also hand-drivable for closed-loop testing: `nc 127.0.0.1 <port>`
// (the listener binds IPv4 loopback only — `localhost` may resolve to ::1 first, which is refused).
//
// Connection callbacks run off the main thread; every tool call hops to the MainActor
// bridge. `@unchecked Sendable` is the standard shape for an NWListener wrapper (queue-confined).
import Foundation
import Network
import SZCore

final class SZMCPServer: @unchecked Sendable {
    let port: UInt16
    /// Which tool surface this listener serves. The host runs one of each: agents dial the `.agent`
    /// listener (no `debug_*`), closed-loop tests dial the `.full` one.
    let surface: SZHostBridge.Surface
    private let listener: NWListener
    private let bridge: SZHostBridge
    private let queue = DispatchQueue(label: "studio.sxp.subz.mcp")

    /// `initialize` identity. The full bus stays `subz` so an existing test client's discovery — which
    /// matches on that name — never lands on the agent bus and finds `debug_*` missing.
    var identity: String { surface == .full ? "subz" : "subz-agent" }

    /// Bind the first free port at or after `from`, within 42100–42199.
    ///
    /// `from` matters: `NWListener` does NOT throw when a port is already bound — it fails later, on its
    /// state handler — so a second listener started at the same base would "succeed", collide, and die
    /// quietly. The host starts its agent bus above the port the full bus took.
    @MainActor
    static func start(bridge: SZHostBridge, surface: SZHostBridge.Surface = .full,
                      from: UInt16 = 42100) throws -> SZMCPServer {
        var lastError: Error?
        for candidate in max(from, 42100)..<UInt16(42200) {
            do { return try SZMCPServer(port: candidate, bridge: bridge, surface: surface) }
            catch { lastError = error }
        }
        throw lastError ?? SZMCPError.message("no free MCP port in \(from)–42199")
    }

    private init(port: UInt16, bridge: SZHostBridge, surface: SZHostBridge.Surface) throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw SZMCPError.message("invalid MCP port \(port)")
        }
        self.port = port
        self.bridge = bridge
        self.surface = surface
        // LOOPBACK ONLY. Plain `NWListener(using: .tcp, on:)` binds every interface (lsof shows
        // `*:<port>`), so on a shared network any host could drive this bus — and its tools include
        // `ui_run`, which spawns a coding agent that writes and executes code with no approval gate.
        // `requiredLocalEndpoint` pins the bind to 127.0.0.1; every client dials IPv4 loopback (the
        // `nc 127.0.0.1` bridge, the pi extension's `net.connect(port,"127.0.0.1")`, test clients).
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: nwPort)
        self.listener = try NWListener(using: params)
        let identity = surface == .full ? "subz" : "subz-agent"
        self.listener.newConnectionHandler = { [bridge] connection in
            connection.start(queue: DispatchQueue(label: "studio.sxp.subz.mcp.conn.\(port)"))
            Self.receive(on: connection, bridge: bridge, surface: surface, identity: identity,
                         buffer: SZLineBuffer())
        }
        let startup = SZMCPStartupProbe()
        // A busy port surfaces here, not from init — fail startup so the caller can try another port.
        self.listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                startup.complete(.ready)
            case .waiting(let error):
                print("[SZMCPServer] \(identity) listener on \(port) waiting: \(error)")
            case .failed(let error):
                print("[SZMCPServer] \(identity) listener on \(port) failed: \(error)")
                startup.complete(.failed("\(error)"))
            default:
                break
            }
        }
        self.listener.start(queue: queue)
        switch startup.wait(timeout: .milliseconds(750)) {
        case .ready:
            break
        case .failed(let message):
            listener.cancel()
            throw SZMCPError.message("\(identity) listener on \(port) failed: \(message)")
        case nil:
            listener.cancel()
            throw SZMCPError.message("\(identity) listener on \(port) did not become ready")
        }
    }

    func stop() { listener.cancel() }

    private static func receive(on connection: NWConnection, bridge: SZHostBridge,
                               surface: SZHostBridge.Surface, identity: String, buffer: SZLineBuffer) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
            if let data, !data.isEmpty {
                for line in buffer.appendAndExtractLines(data) {
                    // Serialize: handle this line (hopping to the MainActor bridge) before the next.
                    // Signal once the response is *dispatched* — NOT from send's completion, which NW
                    // delivers on this same (blocked) connection queue and would deadlock.
                    let done = DispatchSemaphore(value: 0)
                    Task {
                        if let response = await handle(line: line, bridge: bridge,
                                                      surface: surface, identity: identity) {
                            connection.send(content: Data((response + "\n").utf8), completion: .contentProcessed { _ in })
                        }
                        done.signal()
                    }
                    done.wait()
                }
            }
            guard !isComplete, error == nil else { connection.cancel(); return }
            receive(on: connection, bridge: bridge, surface: surface, identity: identity, buffer: buffer)
        }
    }

    /// Decode one JSON-RPC request and produce its response string (nil for notifications).
    private static func handle(line: String, bridge: SZHostBridge,
                              surface: SZHostBridge.Surface, identity: String) async -> String? {
        let request = (try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]) ?? [:]
        let id = request["id"] ?? NSNull()
        guard let method = request["method"] as? String else {
            return SZJSONRPC.errorString(id: id, code: -32600, message: "missing method")
        }

        switch method {
        case "initialize":
            return SZJSONRPC.responseString(id: id, result: [
                "protocolVersion": SZJSONRPC.protocolVersion,
                "serverInfo": ["name": identity, "version": "0.3"],
                "capabilities": ["tools": [:] as [String: Any]],
            ])
        case "notifications/initialized":
            return nil
        case "tools/list":
            return SZJSONRPC.responseString(id: id, result: ["tools": SZHostBridge.toolDefinitions(for: surface)])
        case "tools/call":
            let params = request["params"] as? [String: Any] ?? [:]
            let name = params["name"] as? String ?? ""
            // Cross the actor boundary as Data (Sendable), not [String: Any]; re-decode on the main actor.
            let argsData = (try? JSONSerialization.data(withJSONObject: params["arguments"] ?? [:])) ?? Data("{}".utf8)
            do {
                let result = try await MainActor.run {
                    let arguments = (try? JSONSerialization.jsonObject(with: argsData) as? [String: Any]) ?? [:]
                    return try bridge.callTool(name: name, arguments: arguments, surface: surface)
                }
                let payload: [String: Any]
                switch result {
                case .text(let text):    payload = SZJSONRPC.textResult(text)
                case .image(let base64): payload = SZJSONRPC.imageResult(base64PNG: base64)
                }
                return SZJSONRPC.responseString(id: id, result: payload)
            } catch {
                return SZJSONRPC.errorString(id: id, code: -32603, message: "\(error)")
            }
        default:
            return SZJSONRPC.errorString(id: id, code: -32601, message: "unknown method \(method)")
        }
    }
}

private final class SZMCPStartupProbe: @unchecked Sendable {
    enum Outcome {
        case ready
        case failed(String)
    }

    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var outcome: Outcome?

    func complete(_ newOutcome: Outcome) {
        lock.lock()
        defer { lock.unlock() }
        guard outcome == nil else { return }
        outcome = newOutcome
        semaphore.signal()
    }

    func wait(timeout: DispatchTimeInterval) -> Outcome? {
        _ = semaphore.wait(timeout: .now() + timeout)
        lock.lock()
        defer { lock.unlock() }
        return outcome
    }
}
