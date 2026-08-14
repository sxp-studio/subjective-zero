// SPDX-License-Identifier: AGPL-3.0-only
// The brief renderer — the ONE place a turn's brief becomes bytes in the new architecture.
// It renders a pack template (a pack-relative `.md.mustache` path) against the traversal's
// facts document plus the delivered message's payload, and it is what a host puts behind
// `SZTraversalHost.renderBrief`. THE GATE lives on its output: `SZEquivalenceGateTests`
// pins these bytes against the fixtures recorded from the previous orchestrator, so every
// context value here must assemble EXACTLY what that path assembled.
//
// Split of labor, stated once:
//  - prompt PROSE lives in the pack's `prompts/*.md.mustache` files, never here;
//  - this file only ASSEMBLES values (graph projections, boundaries, section selection) and
//    substitutes them with the same flat `{{token}}` machinery the previous path used
//    (`SZPromptTemplate`, including its `{{`-defusing rules — defused exactly where the
//    previous path defused, nowhere else, or the bytes drift);
//  - shared value builders (`SZDirectorPrompt.graphSummary`/`blockerLines`, `SZBoundaryPrompt`,
//    `SZGraphPrompts.sourceBlock`/`steerBlock`, `SZAgentDocs`) are REUSED, not restated — one
//    home per value, so the two paths cannot disagree while both exist.
//
// A token is only computed when the template mentions it, so a brief never fails on context
// it does not use, and a substituted value can never leak into a template that has no slot
// for it. Facts field names follow the SZFacts spec (SZCore/AgentFacts); the document is
// read leniently because a kind's host projection may carry more than a template needs — a missing field is
// an error only when a template actually needs it.
import Foundation
import SZCore

/// Everything brief rendering can refuse — surfaced by the engine as a traversal defect.
public enum SZBriefRenderError: Error, Sendable, CustomStringConvertible {
    /// The pack has no template at this path (or the source could not read it).
    case missingTemplate(agent: String, path: String)
    /// A kind no turn brief renders for (`steer` never enters a graph; `settled` re-enters
    /// under its graph's own kind, so the engine never asks for it).
    case unrenderableKind(SZMessageKind)
    /// The facts document would not parse as JSON.
    case unreadableFacts(detail: String)
    /// The template needs a fact the document does not carry.
    case missingFact(String)
    /// The template needs delivery context the message did not carry.
    case missingDelivery(String)
    /// A `.work` delivery names a node the facts' graph does not contain.
    case unknownWorkNode(String)

    public var description: String {
        switch self {
        case .missingTemplate(let agent, let path): "\(agent) has no template '\(path)'"
        case .unrenderableKind(let kind): "no brief renders for '\(kind.rawValue)'"
        case .unreadableFacts(let detail): "unreadable facts document: \(detail)"
        case .missingFact(let name): "the facts document carries no '\(name)'"
        case .missingDelivery(let name): "the delivery carries no '\(name)'"
        case .unknownWorkNode(let node): "the facts' graph has no node '\(node)'"
        }
    }
}

/// The delivered message's payload as the renderer consumes it: message-scoped context that
/// is NOT (yet) projected into the kind's facts document. Kind-gated by use — a template
/// only reads the fields its kind's assembly names.
public struct SZBriefDelivery: Sendable {
    /// A build's free-text instruction (the chat trigger); nil/empty renders the explicit
    /// no-instruction fallback.
    public var instruction: String?
    /// A `.work` delivery's target node id.
    public var work: String?
    /// The work is a piece STAGED by a split/merge: its reference is the original's source,
    /// quoted in its seed prompt — the brief flips to the preserve-behavior framing.
    public var preserveBehavior: Bool
    /// The assembled node-library index to inline into a cold work brief (flips both the
    /// reference and the contract-schema sections to their inlined variants).
    public var libraryIndex: String?
    /// Node-anchored chat context, read by the host: the seed node's current contract JSON
    /// and full source.
    public var nodeContract: String?
    public var nodeSource: String?
    /// A `.request` delivery's structured graph-op payload (split/merge).
    public var graphOp: GraphOp?

    /// One split/merge operation as a piece's seed brief needs it: the original (split) or
    /// the constituents (merge), plus the reconciled boundary contract.
    public struct GraphOp: Sendable {
        /// Split: the original node's title.
        public var original: String?
        /// Split: the original node's intent.
        public var intent: String?
        /// Split: this piece's 1-based stage.
        public var stage: Int?
        /// Pieces in the op (split stages / merge constituents).
        public var count: Int
        /// Split: the original node's full source, when it was implemented.
        public var source: String?
        /// Merge: the constituents in pipeline order — non-empty means merge.
        public var constituents: [Constituent]
        /// The reconciled boundary contract this piece must honor.
        public var contract: SZNodeContract
        /// The user's steer for THIS op ("a blur stage then a sharpen stage").
        public var instruction: String?

        public struct Constituent: Sendable {
            public var title: String
            public var intent: String
            public var source: String?
            public init(title: String, intent: String, source: String? = nil) {
                self.title = title
                self.intent = intent
                self.source = source
            }
        }

        public init(original: String? = nil, intent: String? = nil, stage: Int? = nil,
                    count: Int, source: String? = nil, constituents: [Constituent] = [],
                    contract: SZNodeContract, instruction: String? = nil) {
            self.original = original
            self.intent = intent
            self.stage = stage
            self.count = count
            self.source = source
            self.constituents = constituents
            self.contract = contract
            self.instruction = instruction
        }
    }

    public init(instruction: String? = nil, work: String? = nil, preserveBehavior: Bool = false,
                libraryIndex: String? = nil, nodeContract: String? = nil,
                nodeSource: String? = nil, graphOp: GraphOp? = nil) {
        self.instruction = instruction
        self.work = work
        self.preserveBehavior = preserveBehavior
        self.libraryIndex = libraryIndex
        self.nodeContract = nodeContract
        self.nodeSource = nodeSource
        self.graphOp = graphOp
    }
}

public struct SZBriefRenderer: Sendable {
    /// Where template text comes from: `(agent, pack-relative path)` → bytes. Injected — the
    /// host owns where packs live (bundled drafts today, user packs later).
    public typealias TemplateSource = @Sendable (_ agent: String, _ path: String) throws -> String

    private let template: TemplateSource

    public init(templates: @escaping TemplateSource) {
        self.template = templates
    }

    /// A renderer over an on-disk pack root: `<root>/<agent>/<pack-relative path>`.
    public init(packRoot: URL) {
        self.init { agent, path in
            let url = packRoot.appending(path: agent).appending(path: path)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                throw SZBriefRenderError.missingTemplate(agent: agent, path: path)
            }
            return text
        }
    }

    // MARK: - The authoring namespaces (the check tool's ground truth)

    /// The partial paths the assembly below pulls — named ONCE, used by both the `render`
    /// switch and the `requiredPartials` table, so the two cannot disagree.
    static let toolbeltPartial = "prompts/toolbelt.md.mustache"
    static let referencePreservePartial = "prompts/reference-preserve.md.mustache"
    static let referenceInlinePartial = "prompts/reference-inline.md.mustache"
    static let referenceLibraryPartial = "prompts/reference-library.md.mustache"
    static let schemaInlinePartial = "prompts/schema-inline.md.mustache"
    static let schemaFetchPartial = "prompts/schema-fetch.md.mustache"

    /// Every `{{token}}` the `kind` assembly in `render` can substitute — the namespace the
    /// pack gate checks turn briefs against. Kept here, beside the assembly, and tied to it:
    /// `add` asserts each token it computes is listed, so a token added to the switch without
    /// a table entry fails the first debug render that computes it (the whole test suite).
    static func knownTokens(kind: SZMessageKind) -> Set<String> {
        switch kind {
        case .build:
            ["graph", "instruction", "toolbelt", "round", "cap", "blockers", "inbox"]
        case .chat:
            ["graph", "message", "toolbelt", "node", "contract", "source"]
        case .work:
            ["node", "prompt", "inputs", "outputs", "boundary", "abi", "reference", "schema",
             "blocker", "director_message"]
        case .request:
            ["original", "intent", "stage", "count", "source", "boundary", "instruction",
             "constituents"]
        case .steer:
            []   // no brief renders for a steer (`unrenderableKind`)
        }
    }

    /// The pack partials the `kind` assembly renders when a brief mentions `token` — keyed by
    /// token, because a partial is only REQUIRED of a pack whose briefs actually pull it (the
    /// coding pack's chat brief never mentions `{{toolbelt}}`, so it owes no toolbelt file).
    /// A token lists every variant its section can select: which one a delivery picks is
    /// runtime state, so a valid pack carries them all.
    static func requiredPartials(kind: SZMessageKind) -> [String: [String]] {
        switch kind {
        case .build, .chat:
            ["toolbelt": [toolbeltPartial]]
        case .work:
            ["reference": [referencePreservePartial, referenceInlinePartial,
                           referenceLibraryPartial],
             "schema": [schemaInlinePartial, schemaFetchPartial]]
        case .request, .steer:
            [:]
        }
    }

    // MARK: - Rendering

    /// Render one turn's brief: the pack template at `path`, against `kind`'s facts document
    /// and the delivered message's payload. The bytes returned here are what the turn sends.
    public func render(agent: String, template path: String, kind: SZMessageKind,
                       factsJSON: String,
                       delivery: SZBriefDelivery = SZBriefDelivery()) throws -> String {
        let text = try template(agent, path)
        let facts = try Facts(json: factsJSON)
        var values: [String: String] = [:]
        // Compute a token only when the template mentions it — briefs never fail on context
        // they do not use.
        func add(_ token: String, _ make: () throws -> String) rethrows {
            assert(Self.knownTokens(kind: kind).contains(token),
                   "'\(token)' is computed by the \(kind.rawValue) assembly but missing from knownTokens — the pack gate would misreport it")
            guard text.contains("{{\(token)}}") else { return }
            values[token] = try make()
        }

        switch kind {
        case .build:
            try add("graph") { try graphSummary(facts) }
            try add("instruction") { SZDirectorPrompt.instructionLine(delivery.instruction ?? "") }
            try add("toolbelt") { try template(agent, Self.toolbeltPartial) }
            try add("round") { String(try require(facts.round, fact: "round")) }
            try add("cap") { String(try require(facts.roundCap, fact: "roundCap")) }
            try add("blockers") {
                let graph = try graph(facts)
                let unresolved = try require(facts.workSet, fact: "workSet")
                    .compactMap(SZNodeID.init(uuidString:))
                var statuses: [SZNodeID: String] = [:]
                for (key, status) in try require(facts.nodeStatuses, fact: "nodeStatuses") {
                    if let id = SZNodeID(uuidString: key) { statuses[id] = status }
                }
                return SZDirectorPrompt.blockerLines(graph: graph, unresolved: unresolved,
                                                     statuses: statuses)
            }
            try add("inbox") { SZDirectorPrompt.inboxLines(try require(facts.steers, fact: "steers")) }

        case .chat:
            try add("graph") { try graphSummary(facts) }
            try add("message") { try require(facts.sentMessage, fact: "sentMessage") }
            try add("toolbelt") { try template(agent, Self.toolbeltPartial) }
            try add("node") { try require(facts.nodeSeed, fact: "nodeSeed") }
            try add("contract") { try require(delivery.nodeContract, delivery: "nodeContract") }
            try add("source") { try require(delivery.nodeSource, delivery: "nodeSource") }

        case .work:
            let plan = try workPlan(facts: facts, delivery: delivery)
            add("node") { plan.node.id.uuidString }
            add("prompt") { SZPromptTemplate.defused(plan.node.prompt ?? plan.node.title) }
            add("inputs") { plan.inputs.map(\.name).joined(separator: ", ") }
            add("outputs") { plan.outputs.map(\.name).joined(separator: ", ") }
            add("boundary") {
                SZPromptTemplate.defused(SZBoundaryPrompt.render(
                    inputs: plan.inputs, outputs: plan.outputs, permissions: plan.permissions))
            }
            add("abi") { SZAgentDocs.abiReference }
            // The reference/schema SECTIONS are selected here, rendered from pack partials:
            // a staged piece preserves (its reference is quoted in its seed — and it keeps
            // the fetch schema); an inlined index flips BOTH sections to their inlined
            // variants; otherwise the tiered library framing + the fetch schema.
            try add("reference") {
                if delivery.preserveBehavior {
                    return try template(agent, Self.referencePreservePartial)
                }
                if let index = delivery.libraryIndex {
                    return SZPromptTemplate.render(
                        try template(agent, Self.referenceInlinePartial),
                        ["library_index": SZPromptTemplate.defused(index)])
                }
                return try template(agent, Self.referenceLibraryPartial)
            }
            try add("schema") {
                if !delivery.preserveBehavior, delivery.libraryIndex != nil {
                    return SZPromptTemplate.render(
                        try template(agent, Self.schemaInlinePartial),
                        ["contract_doc": SZPromptTemplate.defused(SZAgentDocs.contractReference)])
                }
                return try template(agent, Self.schemaFetchPartial)
            }
            add("blocker") { SZPromptTemplate.defused(facts.blocker ?? Self.fallbackBlocker) }
            add("director_message") {
                facts.senderNote.map {
                    "\n## A message from the Director — follow this\n\(SZPromptTemplate.defused($0))\n"
                } ?? ""
            }

        case .request:
            let op = try require(delivery.graphOp, delivery: "graphOp")
            try add("original") { try require(op.original, delivery: "graphOp.original") }
            try add("intent") { try require(op.intent, delivery: "graphOp.intent") }
            try add("stage") { String(try require(op.stage, delivery: "graphOp.stage")) }
            add("count") { String(op.count) }
            add("source") { SZGraphPrompts.sourceBlock(op.source) }
            add("boundary") { SZBoundaryPrompt.render(op.contract) }
            add("instruction") {
                SZGraphPrompts.steerBlock(op.instruction,
                                          verb: op.constituents.isEmpty ? "split" : "merge")
            }
            add("constituents") {
                op.constituents
                    .map { "- \($0.title): \($0.intent)\n\(SZGraphPrompts.sourceBlock($0.source))" }
                    .joined(separator: "\n\n")
            }

        case .steer:
            throw SZBriefRenderError.unrenderableKind(kind)
        }

        return SZPromptTemplate.render(text, values)
    }

    /// The `agent_library_index` payload framing, from the pack's template — the host serves
    /// this through the tool, not through a turn.
    public func libraryIndex(agent: String, categories: String) throws -> String {
        SZPromptTemplate.render(try template(agent, "prompts/library-index.md.mustache"),
                                ["categories": categories])
    }

    // MARK: - Value assembly

    /// The fallback blocker for re-delivered work that reported no status. The previous
    /// orchestrator used these exact words; the reconcile fixtures pin them.
    static let fallbackBlocker = "the previous attempt did not finish"

    /// A `.work` brief's plan: the target node plus its typed boundary — the contract's
    /// declared ports, or texture ports derived from the graph wiring for a contract-less
    /// node (`SZGraph+DerivedPorts`, the one home for the derivation).
    private func workPlan(facts: Facts, delivery: SZBriefDelivery) throws
        -> (node: SZNode, inputs: [SZPort], outputs: [SZPort], permissions: [SZEntitlement]) {
        let work = try require(delivery.work, delivery: "work")
        let graph = try graph(facts)
        guard let id = SZNodeID(uuidString: work), let node = graph.node(id: id) else {
            throw SZBriefRenderError.unknownWorkNode(work)
        }
        let inputs = node.contract?.inputs
            ?? graph.derivedDataInputPorts(of: id)
                .map { SZPort(name: $0, type: .texture) }
        let outputs = node.contract?.outputs
            ?? graph.derivedOutputPorts(of: id)
                .map { SZPort(name: $0, type: .texture) }
        return (node, inputs, outputs, node.contract?.requiredPermissions ?? [])
    }

    /// The `{{graph}}` projection — the facts' live graph through the ONE summary renderer.
    private func graphSummary(_ facts: Facts) throws -> String {
        SZDirectorPrompt.graphSummary(try graph(facts))
    }

    /// The agent-readable projection of a graph JSON document, exposed for the gate tests
    /// (the summary fixture pins its fallback branches through the new path).
    static func graphSummary(ofJSON json: String) throws -> String {
        SZDirectorPrompt.graphSummary(try decodeGraph(json))
    }

    private func graph(_ facts: Facts) throws -> SZGraph {
        try Self.decodeGraph(try require(facts.graphJSON, fact: "graphJSON"))
    }

    private static func decodeGraph(_ json: String) throws -> SZGraph {
        do {
            return try JSONDecoder().decode(SZGraph.self, from: Data(json.utf8))
        } catch {
            throw SZBriefRenderError.unreadableFacts(detail: "graphJSON: \(error)")
        }
    }

    private func require<T>(_ value: T?, fact name: String) throws -> T {
        guard let value else { throw SZBriefRenderError.missingFact(name) }
        return value
    }

    private func require<T>(_ value: T?, delivery name: String) throws -> T {
        guard let value else { throw SZBriefRenderError.missingDelivery(name) }
        return value
    }

    /// The facts document, read leniently: field names follow the SZFacts spec, unknown
    /// fields are ignored, and absence only matters when a template needs the value.
    private struct Facts: Decodable {
        // build
        var workSet: [String]?
        var nodeStatuses: [String: String]?
        var round: Int?
        var roundCap: Int?
        var steers: [String]?
        var graphJSON: String?
        // chat
        var sentMessage: String?
        var nodeSeed: String?
        // work
        var blocker: String?
        var senderNote: String?

        init(json: String) throws {
            do {
                self = try JSONDecoder().decode(Facts.self, from: Data(json.utf8))
            } catch {
                throw SZBriefRenderError.unreadableFacts(detail: String(describing: error))
            }
        }
    }
}
