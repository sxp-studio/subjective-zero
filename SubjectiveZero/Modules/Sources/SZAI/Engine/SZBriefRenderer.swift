// SPDX-License-Identifier: AGPL-3.0-only
// The prompt assembler — the ONE place a template becomes the bytes a turn (or ask) sends.
// Host internals, not kit surface: pack authors see templates and tokens; steps see ctx.
//
// ONE flat table: token → recipe over (message text, world, extras). Every token has one
// meaning; a few recipes select their source by what the world carries (a staged op's
// boundary vs the graph's), which is data selection, not a kind. A token is only computed
// when the template mentions it, and after substitution any leftover `{{token}}` throws —
// a literal token can never ship to a model. That refusal judges AUTHORED text only
// (templates and partials): every value carrying outside words — user prose, node
// titles/prompts, agent statuses, file contents — is `defused` on its way in, so data
// that happens to spell a token neither expands nor trips the check.
//
// THE PINS live on this output: SZBriefPinTests pins every shipped brief's bytes; a
// deliberate prose change re-records its pin there. Value assembly reuses the shared builders
// (SZDirectorPrompt, SZBoundaryPrompt, SZGraphPrompts, SZAgentDocs) — one home per value.
import Foundation
import SZCore

/// Everything brief rendering can refuse — surfaced by the engine as a traversal defect.
public enum SZBriefRenderError: Error, Sendable, CustomStringConvertible {
    /// The pack has no template at this path (or the source could not read it).
    case missingTemplate(agent: String, path: String)
    /// A mentioned token needs data this delivery does not carry.
    case missing(token: String, need: String)
    /// The delivery's node is not in the world's graph.
    case unknownNode(String)
    /// Rendered output still carries live tokens — nothing may ship literal.
    case literalTokens(template: String, tokens: [String])

    public var description: String {
        switch self {
        case .missingTemplate(let agent, let path): "\(agent) has no template '\(path)'"
        case .missing(let token, let need): "'{{\(token)}}' needs \(need), which this delivery does not carry"
        case .unknownNode(let node): "the world's graph has no node '\(node)'"
        case .literalTokens(let template, let tokens):
            "\(template) rendered with live tokens (\(tokens.joined(separator: ", "))) — a literal token never ships"
        }
    }
}

/// Host-READ render input the world cannot carry: files read off disk at delivery time and
/// the split/merge render bundle. Never step-visible, never sender-authored.
public struct SZBriefExtras: Sendable {
    /// A staged piece preserves the original's behavior (its reference is quoted in its
    /// seed) — flips the reference/schema sections.
    public var preserveBehavior: Bool
    /// The assembled node-library index to inline into a cold work brief.
    public var libraryIndex: String?
    /// A node chat's cold seed: the node's current contract JSON and full source.
    public var nodeContract: String?
    public var nodeSource: String?
    /// The split/merge render bundle.
    public var graphOp: GraphOp?
    /// Whether the active routing profile maps a work grade — flips the `{{grading}}`
    /// teaching in the Director's briefing templates. Off renders it empty, so an inactive
    /// profile leaves every prompt byte-identical.
    public var gradingEnabled: Bool = false

    /// One split/merge operation as a piece's seed brief needs it: the original (split) or
    /// the constituents (merge), plus the reconciled boundary contract.
    public struct GraphOp: Sendable {
        public var original: String?
        public var intent: String?
        public var stage: Int?
        public var count: Int
        public var source: String?
        /// Constituents in pipeline order — non-empty means merge.
        public var constituents: [Constituent]
        public var contract: SZNodeContract
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

    public init(preserveBehavior: Bool = false, libraryIndex: String? = nil,
                nodeContract: String? = nil, nodeSource: String? = nil,
                graphOp: GraphOp? = nil, gradingEnabled: Bool = false) {
        self.preserveBehavior = preserveBehavior
        self.libraryIndex = libraryIndex
        self.nodeContract = nodeContract
        self.nodeSource = nodeSource
        self.graphOp = graphOp
        self.gradingEnabled = gradingEnabled
    }
}

public struct SZBriefRenderer: Sendable {
    /// Where template text comes from: `(agent, pack-relative path)` → bytes. Injected —
    /// the host owns where packs live.
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

    /// The pack-relative path a template stem resolves to. A name that already carries a
    /// path is taken as written.
    public static func templatePath(_ name: String) -> String {
        name.contains("/") ? name : "prompts/\(name).md.mustache"
    }

    // MARK: - The authoring namespace (the pack gate's ground truth)

    static let toolbeltPartial = "prompts/toolbelt.md.mustache"
    static let gradingPartial = "prompts/grading.md.mustache"
    static let cardsPartial = "prompts/cards.md.mustache"
    static let referencePreservePartial = "prompts/reference-preserve.md.mustache"
    static let referenceInlinePartial = "prompts/reference-inline.md.mustache"
    static let referenceLibraryPartial = "prompts/reference-library.md.mustache"
    static let schemaInlinePartial = "prompts/schema-inline.md.mustache"
    static let schemaFetchPartial = "prompts/schema-fetch.md.mustache"

    /// Every `{{token}}` a template may mention — the ONE namespace the pack gate checks
    /// briefs against. Tied to the assembly: `add` asserts each computed token is listed.
    public static let knownTokens: Set<String> = [
        "graph", "message", "toolbelt", "cards", "node", "contract", "source",
        "round", "cap", "blockers", "unwired", "inbox", "mutations", "instruction", "tasks",
        "prompt", "title", "symbol", "inputs", "outputs", "boundary", "abi", "reference", "schema",
        "blocker", "director_message", "retry_note", "grading",
        "original", "intent", "stage", "count", "constituents",
    ]

    /// The pack partials a mentioned token renders from — required of a pack whose briefs
    /// mention the token. A token lists every variant its section can select.
    public static let requiredPartials: [String: [String]] = [
        "toolbelt": [toolbeltPartial],
        "grading": [gradingPartial],
        "cards": [cardsPartial],
        "reference": [referencePreservePartial, referenceInlinePartial, referenceLibraryPartial],
        "schema": [schemaInlinePartial, schemaFetchPartial],
    ]

    // MARK: - Rendering

    /// Render one brief: the pack template at `template` (a stem or pack-relative path),
    /// against the delivered message's words, the world, and the host-read extras. The
    /// bytes returned are what the turn sends.
    public func render(agent: String, template name: String, message: String,
                       world: SZWorld, extras: SZBriefExtras = SZBriefExtras()) throws -> String {
        let path = Self.templatePath(name)
        let text = try template(agent, path)
        var values: [String: String] = [:]
        // Compute a token only when the template mentions it — briefs never fail on
        // context they do not use.
        func add(_ token: String, _ make: () throws -> String) rethrows {
            assert(Self.knownTokens.contains(token),
                   "'\(token)' is computed but missing from knownTokens — the pack gate would misreport it")
            guard text.contains("{{\(token)}}") else { return }
            values[token] = try make()
        }
        func need<T>(_ value: T?, _ token: String, _ what: String) throws -> T {
            guard let value else { throw SZBriefRenderError.missing(token: token, need: what) }
            return value
        }

        // — the world — (values built on outside words are defused: a user asking about
        // "{{node}}", a node title or agent status spelling a token, must ship as words)
        // A live run reads the arrows it captured, never a fresh sweep: the user keeps drawing while
        // the fleet works. Gated on the run, never on the list being empty — a chat or debug turn has
        // no run and must still see every arrow.
        try add("graph") { SZPromptTemplate.defused(
            SZDirectorPrompt.graphSummary(try need(world.graph, "graph", "a project"),
                                          arrows: world.run == nil ? nil : world.unwiredArrows)) }
        add("message") { SZPromptTemplate.defused(message) }
        try add("toolbelt") { try template(agent, Self.toolbeltPartial) }
        // Rendered only when the active profile maps a grade — teaching an assessment
        // nothing reads would spend prompt budget on a no-op.
        try add("grading") { extras.gradingEnabled ? try template(agent, Self.gradingPartial) : "" }
        try add("cards") { try template(agent, Self.cardsPartial) }
        try add("node") { try need(world.node, "node", "a bound node").uuidString }
        try add("round") { String(try need(world.run, "round", "a live run").round) }
        try add("cap") { String(try need(world.run, "cap", "a live run").roundCap) }
        try add("blockers") {
            let run = try need(world.run, "blockers", "a live run")
            return SZPromptTemplate.defused(SZDirectorPrompt.blockerLines(
                graph: try need(world.graph, "blockers", "a project"),
                unresolved: run.workSet, statuses: world.statuses))
        }
        try add("unwired") {
            SZPromptTemplate.defused(SZDirectorPrompt.unwiredLines(
                graph: try need(world.graph, "unwired", "a project"),
                arrows: world.unwiredArrows))
        }
        try add("inbox") { SZPromptTemplate.defused(
            SZDirectorPrompt.inboxLines(try need(world.run, "inbox", "a live run").steers)) }
        add("mutations") { SZPromptTemplate.defused(
            SZDirectorPrompt.mutationLines(world.mutations, graph: world.graph)) }
        add("tasks") { SZPromptTemplate.defused(SZDirectorPrompt.taskLines(
            (world.runningTasks + world.pendingTasks).sorted { $0.createdAt < $1.createdAt })) }

        // — the sender's instruction: a staged op's steer, else the run's standing one —
        add("instruction") {
            if let op = extras.graphOp {
                return SZPromptTemplate.defused(SZGraphPrompts.steerBlock(op.instruction,
                                                verb: op.constituents.isEmpty ? "split" : "merge"))
            }
            return SZPromptTemplate.defused(SZDirectorPrompt.instructionLine(world.run?.instruction ?? ""))
        }

        // — the node chat's cold seed (host-read files) —
        try add("contract") { SZPromptTemplate.defused(
            try need(extras.nodeContract, "contract", "the node's contract file")) }
        try add("source") {
            if let op = extras.graphOp { return SZPromptTemplate.defused(SZGraphPrompts.sourceBlock(op.source)) }
            return SZPromptTemplate.defused(try need(extras.nodeSource, "source", "the node's source file"))
        }

        // — the work brief: the bound node against its typed boundary —
        func plan() throws -> (node: SZNode, inputs: [SZPort], outputs: [SZPort],
                               permissions: [SZEntitlement]) {
            try workPlan(world: world)
        }
        try add("prompt") {
            let p = try plan()
            return SZPromptTemplate.defused(p.node.prompt ?? p.node.title)
        }
        // The card's current identity — shown so the agent keeps it in the contract it authors
        // (a promote keeps the boundary's title/symbol; a rename is an explicit `ui_update_node`).
        try add("title") { SZPromptTemplate.defused(try plan().node.title) }
        try add("symbol") { SZPromptTemplate.defused(try plan().node.sfSymbol) }
        try add("inputs") { try plan().inputs.map(\.name).joined(separator: ", ") }
        try add("outputs") { try plan().outputs.map(\.name).joined(separator: ", ") }
        try add("boundary") {
            if let op = extras.graphOp { return SZBoundaryPrompt.render(op.contract) }
            let p = try plan()
            return SZPromptTemplate.defused(SZBoundaryPrompt.render(
                inputs: p.inputs, outputs: p.outputs, permissions: p.permissions))
        }
        add("abi") { SZAgentDocs.abiReference }
        // The reference/schema SECTIONS: a staged piece preserves (and keeps the fetch
        // schema); an inlined index flips BOTH to their inlined variants; otherwise the
        // tiered library framing + the fetch schema.
        try add("reference") {
            if extras.preserveBehavior {
                return try template(agent, Self.referencePreservePartial)
            }
            if let index = extras.libraryIndex {
                return SZPromptTemplate.render(
                    try template(agent, Self.referenceInlinePartial),
                    ["library_index": SZPromptTemplate.defused(index)])
            }
            return try template(agent, Self.referenceLibraryPartial)
        }
        try add("schema") {
            if !extras.preserveBehavior, extras.libraryIndex != nil {
                return SZPromptTemplate.render(
                    try template(agent, Self.schemaInlinePartial),
                    ["contract_doc": SZPromptTemplate.defused(SZAgentDocs.contractReference)])
            }
            return try template(agent, Self.schemaFetchPartial)
        }
        try add("blocker") {
            let node = try need(world.node, "blocker", "a bound node")
            return SZPromptTemplate.defused(world.statuses[node] ?? Self.fallbackBlocker)
        }
        add("director_message") {
            world.assignment?.note.map {
                "\n## A message from the Director — follow this\n\(SZPromptTemplate.defused($0))\n"
            } ?? ""
        }
        // A retry on a fresh session: what stopped the previous attempt, else nothing.
        add("retry_note") {
            guard let job = world.assignment, job.attempt > 1, let node = world.node else { return "" }
            return "\n## What blocked the previous attempt\n"
                + SZPromptTemplate.defused(world.statuses[node] ?? Self.fallbackBlocker) + "\n"
        }

        // — the split/merge seed bundle —
        try add("original") { SZPromptTemplate.defused(
            try need(extras.graphOp?.original, "original", "a staged op")) }
        try add("intent") { SZPromptTemplate.defused(
            try need(extras.graphOp?.intent, "intent", "a staged op")) }
        try add("stage") { String(try need(extras.graphOp?.stage, "stage", "a staged split")) }
        try add("count") { String(try need(extras.graphOp, "count", "a staged op").count) }
        try add("constituents") {
            SZPromptTemplate.defused(
                try need(extras.graphOp, "constituents", "a staged op").constituents
                    .map { "- \($0.title): \($0.intent)\n\(SZGraphPrompts.sourceBlock($0.source))" }
                    .joined(separator: "\n\n"))
        }

        // With every data-borne value defused above, anything still spelling `{{token}}`
        // was AUTHORED — by this template or a partial it pulled in — and must not ship.
        let rendered = SZPromptTemplate.render(text, values)
        let leftover = SZPromptTemplate.tokens(in: rendered)
        guard leftover.isEmpty else {
            throw SZBriefRenderError.literalTokens(template: path, tokens: leftover.sorted())
        }
        return rendered
    }

    /// The `agent_library_index` payload framing, from the pack's template — the host
    /// serves this through the tool, not through a turn.
    public func libraryIndex(agent: String, categories: String) throws -> String {
        SZPromptTemplate.render(try template(agent, "prompts/library-index.md.mustache"),
                                ["categories": categories])
    }

    // MARK: - Value assembly

    /// The fallback blocker for re-delivered work that reported no status. The previous
    /// orchestrator used these exact words; the reconcile fixtures pin them.
    static let fallbackBlocker = "the previous attempt did not finish"

    /// The work brief's plan: the bound node plus its typed boundary — the contract's
    /// declared ports, or texture ports derived from the graph wiring for a contract-less
    /// node (`SZGraph+DerivedPorts`, the one home for the derivation).
    private func workPlan(world: SZWorld) throws
        -> (node: SZNode, inputs: [SZPort], outputs: [SZPort], permissions: [SZEntitlement]) {
        guard let id = world.node else {
            throw SZBriefRenderError.missing(token: "node", need: "a bound node")
        }
        guard let graph = world.graph, let node = graph.node(id: id) else {
            throw SZBriefRenderError.unknownNode(id.uuidString)
        }
        let inputs = node.contract?.inputs
            ?? graph.derivedDataInputPorts(of: id)
                .map { SZPort(name: $0, type: .texture) }
        let outputs = node.contract?.outputs
            ?? graph.derivedOutputPorts(of: id)
                .map { SZPort(name: $0, type: .texture) }
        return (node, inputs, outputs, node.contract?.requiredPermissions ?? [])
    }
}
