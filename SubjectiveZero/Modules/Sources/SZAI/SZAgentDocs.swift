// SPDX-License-Identifier: AGPL-3.0-only
// Agent-fetchable reference docs (the `agent_docs_*` MCP surface). Bundled markdown the coding / Director
// agents pull ON DEMAND instead of guessing schemas — the same "earn the tokens" tiering as the node
// library (index → read). Content is authored to match SZCore (`SZContract`) + the runtime ABI; keep it in
// sync when those change. The host's `agent_docs_index` / `agent_docs_read` tools call straight through.
import Foundation

/// One fetchable agent-docs topic: a stable `id` (the `topic` arg), a title, and a one-line summary for
/// the index.
public struct SZAgentDocsTopic: Sendable {
    public let id: String
    public let title: String
    public let summary: String
}

public enum SZAgentDocs {
    /// The catalog — cheap to list; an agent reads a topic's body only when it needs it.
    public static let topics: [SZAgentDocsTopic] = [
        SZAgentDocsTopic(id: "node-contract", title: "Node contract schema",
              summary: "node-contract.json: port types, the `ui` OBJECT + valid kinds, `default`/`options` shapes, permissions, and what reaches the node at runtime."),
        SZAgentDocsTopic(id: "node-abi", title: "Node runtime ABI",
              summary: "Node.swift shape + the injected SZNode/SZFrameContext accessors (textures + live scalar/string inputs); BGRA8; don't-redeclare rules."),
    ]

    /// The node-abi doc body — ALSO embedded verbatim into the coding compile prompt (its `{{abi}}`
    /// token), so the ABI prose lives in exactly one file (derive-don't-duplicate). The code-level
    /// source of truth stays SZRuntime's `SZRuntimeSupport.source`; this doc mirrors it for agents.
    public static let abiReference: String = {
        guard let doc = read("node-abi") else { fatalError("SZAI: missing bundled doc node-abi.md") }
        return doc
    }()

    /// The markdown body for a topic id, or nil if the id isn't a known topic.
    public static func read(_ id: String) -> String? {
        guard topics.contains(where: { $0.id == id }),
              let url = Bundle.module.url(forResource: id, withExtension: "md", subdirectory: "Docs"),
              let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return content
    }
}
