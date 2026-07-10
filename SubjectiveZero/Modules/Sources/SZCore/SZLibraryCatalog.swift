// SPDX-License-Identifier: AGPL-3.0-only
// The Tier-1 reuse-library catalog (docs/NODE_LIBRARY.md) — the cheap, load-the-whole-thing index a
// coding agent (and, once wired, the Director) reasons over to pick a reference node. Pure value types,
// `Codable`, no Metal/macOS imports.
//
// Single source of truth: a node's identity + typed I/O are DERIVED from its `node-contract.json`; only the
// fields that can't be (`useWhen`/`avoidWhen`/`purpose`/`tags`/…) are hand-curated in `NodeLibrary/index.json`
// and merged over the top. So `io` can never drift from the contract — the historic `resolution` bug (an
// input restated in the index that the contract never declared) can't recur, because the restated copy is
// ignored.
import Foundation

/// The hand-curated discovery fields for one library node, keyed by folder `id` — the metadata that isn't
/// in its `node-contract.json`. Stored as one entry per node in `NodeLibrary/index.json`. Any `io`/`title`/
/// `permissions` also present in that file are ignored (they're derived from the contract).
public struct SZLibraryCurationEntry: Codable, Sendable {
    public var id: String
    public var tags: [String]?
    public var purpose: String?
    public var useWhen: String?
    public var avoidWhen: String?
    public var reuse: String?
    public var platform: String?

    public init(
        id: String,
        tags: [String]? = nil,
        purpose: String? = nil,
        useWhen: String? = nil,
        avoidWhen: String? = nil,
        reuse: String? = nil,
        platform: String? = nil
    ) {
        self.id = id
        self.tags = tags
        self.purpose = purpose
        self.useWhen = useWhen
        self.avoidWhen = avoidWhen
        self.reuse = reuse
        self.platform = platform
    }
}

/// The `NodeLibrary/index.json` root — a list of per-node curation records. (Legacy `io`/`title` fields on
/// each entry are tolerated but ignored on decode: they're derived from the node's `node-contract.json`.)
public struct SZLibraryCurationFile: Codable, Sendable {
    public var nodes: [SZLibraryCurationEntry]

    public init(nodes: [SZLibraryCurationEntry]) { self.nodes = nodes }

    /// id → curation, for merging against each contract. Later duplicates lose to the first.
    public var byID: [String: SZLibraryCurationEntry] {
        Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }
}

/// One assembled Tier-1 record served by `agent_library_index`: a node's identity + typed I/O (DERIVED from
/// its `node-contract.json`) merged with its hand-curated discovery fields. The high-signal shape an agent
/// reasons over to pick — or reject — a reference node.
public struct SZLibraryIndexEntry: Codable, Equatable, Sendable {
    /// A port's name + type, projected from the contract's `SZPort` (drops ui/default — irrelevant to picking).
    public struct Port: Codable, Equatable, Sendable {
        public var name: String
        public var type: SZPortType
        public init(name: String, type: SZPortType) { self.name = name; self.type = type }
    }
    public struct IO: Codable, Equatable, Sendable {
        public var inputs: [Port]
        public var outputs: [Port]
        public init(inputs: [Port], outputs: [Port]) { self.inputs = inputs; self.outputs = outputs }
    }

    public var id: String
    public var title: String
    public var sfSymbol: String
    public var summary: String
    public var io: IO
    public var permissions: [SZEntitlement]?
    public var tags: [String]?
    public var purpose: String?
    public var useWhen: String?
    public var avoidWhen: String?
    public var reuse: String?
    public var platform: String?

    /// Assemble a record: identity + I/O + permissions from the contract (authoritative); the discovery
    /// fields from the node's curation entry (if any). A node with no curation entry degrades to the
    /// contract-derived subset — still a superset of the old `{id, title, summary}`.
    public init(id: String, contract: SZNodeContract, curation: SZLibraryCurationEntry?) {
        self.id = id
        self.title = contract.title
        self.sfSymbol = contract.sfSymbol
        self.summary = contract.summary
        self.io = IO(
            inputs: contract.inputs.map { Port(name: $0.name, type: $0.type) },
            outputs: contract.outputs.map { Port(name: $0.name, type: $0.type) })
        self.permissions = contract.permissions
        self.tags = curation?.tags
        self.purpose = curation?.purpose
        self.useWhen = curation?.useWhen
        self.avoidWhen = curation?.avoidWhen
        self.reuse = curation?.reuse
        self.platform = curation?.platform
    }
}
