// SPDX-License-Identifier: AGPL-3.0-only
// JSON-RPC 2.0 helpers + a newline-delimited line buffer — the portable transport plumbing the
// host's MCP server rides on. Lives in SZCore (no platform deps, agnostic) so SZApp stays thin.
import Foundation
import Synchronization

public enum SZJSONRPC {
    /// MCP protocol revision we advertise in `initialize`.
    public static let protocolVersion = "2024-11-05"

    public static func responseObject(id: Any, result: Any) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    public static func errorObject(id: Any, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
    }

    /// MCP `tools/call` text-result envelope.
    public static func textResult(_ text: String) -> [String: Any] {
        ["content": [["type": "text", "text": text]]]
    }

    /// MCP `tools/call` image-result envelope: a single image content block (base64 PNG).
    public static func imageResult(base64PNG: String) -> [String: Any] {
        ["content": [["type": "image", "data": base64PNG, "mimeType": "image/png"]]]
    }

    public static func encode(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else {
            return #"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"encode failed"}}"#
        }
        return String(decoding: data, as: UTF8.self)
    }

    public static func responseString(id: Any, result: Any) -> String { encode(responseObject(id: id, result: result)) }
    public static func errorString(id: Any, code: Int, message: String) -> String { encode(errorObject(id: id, code: code, message: message)) }
}

/// Accumulates bytes and yields complete `\n`-terminated lines. One instance per connection.
public final class SZLineBuffer: Sendable {
    private let buffer = Mutex<Data>(Data())

    public init() {}

    public func appendAndExtractLines(_ data: Data) -> [String] {
        buffer.withLock { buf in
            buf.append(data)
            var lines: [String] = []
            while let newline = buf.firstIndex(of: 0x0A) {
                let lineData = buf[..<newline]
                buf.removeSubrange(buf.startIndex...newline)
                if let line = String(data: lineData, encoding: .utf8),
                   !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    lines.append(line)
                }
            }
            return lines
        }
    }
}
