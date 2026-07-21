// SPDX-License-Identifier: AGPL-3.0-only
// Agent system prompts — loaded from bundled markdown-mustache files (Resources/Prompts/<role>/…),
// not hardcoded in Swift, so prompt content stays cleanly separated and editable. Rendered with the
// flat-`{{token}}` SZPromptTemplate (our prompts don't need full mustache). Coding-agent prompts live
// under Prompts/coding/, Director Agent prompts under Prompts/director/.
import Foundation
import SZCore

enum SZPrompts {
    /// The coding-agent prompt. Its `{{abi}}` token embeds the `node-abi` agent doc
    /// (`SZAgentDocs.abiReference`) so the ABI prose lives in one file, not restated here, and its
    /// `{{reference}}` token selects how the agent should look for prior art (see below).
    static let nodeCompile = load("coding/node-compile.md.mustache")

    /// `{{reference}}` for a normal node: browse the built-in library in cheap-first tiers, and decide for
    /// yourself whether anything fits.
    static let referenceLibrary = load("coding/reference-library.md.mustache")

    /// `{{reference}}` for a node STAGED by a split/merge: its reference is the original's source, quoted in
    /// its own seed prompt. Without this the library section wins on recency — the agent goes shopping in
    /// `agent_library_index` and returns a reinterpretation instead of the same node, in pieces.
    static let referencePreserve = load("coding/reference-preserve.md.mustache")

    /// Cold-start chat prompt: a Coding Agent edits an EXISTING node from a user message. Leans on the
    /// node's current source as the ABI reference (no ABI re-statement), so it can't drift from the ABI.
    static let nodeChat = load("coding/node-chat.md.mustache")

    /// Re-grounding prompt for a RESUMED Coding Agent whose node didn't resolve on a prior dispatch:
    /// restates the prior blocker + the CURRENT (possibly Director-adjusted) boundary,
    /// leaning on the resumed session's memory for the rest. Used by the agentic strategy's reconcile loop.
    static let nodeReconcile = load("coding/node-reconcile.md.mustache")

    /// Seed prompt for one piece of a split node. Carries the original intent + this stage's boundary
    /// contract so the Coding Agent implements only its slice of the pipeline.
    static let splitStage = load("coding/split-stage.md.mustache")

    /// Seed prompt for a merged node. Carries the constituents + the reconciled boundary contract.
    static let merge = load("coding/merge.md.mustache")

    /// The `agent_library_index` framing (see SZAgentLibraryText).
    static func libraryIndex(categories: String) -> String {
        SZPromptTemplate.render(load("library/index.md.mustache"), ["categories": categories])
    }

    /// The Director Agent prompt: given the live graph, establish each node's typed contract + wiring
    /// via `ui_*`, adding nodes only when intent is under-specified. Does NOT implement node code.
    static let director = load("director/decompose.md.mustache")

    /// The Director Agent's RECONCILE prompt: after a dispatch, the nodes that didn't finish + their
    /// reported blockers, so the Director adjusts each one's contract/prompt via `ui_*` before it's retried.
    static let directorReconcile = load("director/reconcile.md.mustache")

    /// The Director Agent's cold-start CHAT framing: same coordination job as decompose, but
    /// conversational — and it can call `ui_run` to dispatch implementation (the run starts after
    /// its turn ends). The chat turn IS the decompose turn for a message-triggered run.
    static let directorChat = load("director/chat.md.mustache")

    /// The `ui_*` toolbelt + restraint + contract guidance SHARED by every Director framing —
    /// injected as the `{{toolbelt}}` token so decompose and chat can't drift apart.
    static let directorToolbelt = load("director/toolbelt.md.mustache")

    /// Load a prompt by its path under `Resources/Prompts/` (e.g. "coding/node-compile.md.mustache").
    private static func load(_ relativePath: String) -> String {
        let parts = relativePath.split(separator: "/")
        let file = String(parts.last ?? "")
        let subdirectory = (["Prompts"] + parts.dropLast().map(String.init)).joined(separator: "/")
        guard let url = Bundle.module.url(forResource: file, withExtension: nil, subdirectory: subdirectory),
              let content = try? String(contentsOf: url, encoding: .utf8) else {
            fatalError("SZAI: missing bundled prompt \(subdirectory)/\(file)")
        }
        return content
    }
}

/// Public seed-prompt builders for split/merge pieces. The host (SZApp) renders these onto each new
/// prompt node during a split/merge re-save, keeping the prose in templates (SZCore stays prose-free).
/// The Coding Agents author the real title/contract/source at Run from these seeds.
public enum SZGraphPrompts {
    /// One stage of a split: the original node's intent + full source (so the agent divides real code) +
    /// this stage's reconciled boundary contract. `instruction` is the user's steer for THIS split
    /// ("a blur stage then a sharpen stage") — every stage sees it, so they divide along the same seam.
    public static func splitStage(original: String, intent: String, stage: Int, count: Int,
                                  source: String?, contract: SZNodeContract,
                                  instruction: String? = nil) -> String {
        SZPromptTemplate.render(SZPrompts.splitStage, [
            "original": original, "intent": intent,
            "stage": String(stage), "count": String(count),
            "source": sourceBlock(source),
            "boundary": SZBoundaryPrompt.render(contract),
            "instruction": steerBlock(instruction, verb: "split"),
        ])
    }

    /// A merged node: its constituents (title + intent + full source, in pipeline order) so the agent
    /// fuses real code + the reconciled boundary contract. `instruction` is the user's steer for THIS
    /// merge ("merge favouring performance").
    public static func merge(constituents: [(title: String, intent: String, source: String?)],
                             contract: SZNodeContract, instruction: String? = nil) -> String {
        let blocks = constituents.map { "- \($0.title): \($0.intent)\n\(sourceBlock($0.source))" }
            .joined(separator: "\n\n")
        return SZPromptTemplate.render(SZPrompts.merge, [
            "count": String(constituents.count),
            "constituents": blocks,
            "boundary": SZBoundaryPrompt.render(contract),
            "instruction": steerBlock(instruction, verb: "merge"),
        ])
    }

    /// A fenced Swift block for a node's source, or a "no source yet" note for an un-implemented node.
    private static func sourceBlock(_ source: String?) -> String {
        guard let source, !source.isEmpty else { return "_(no source yet — this node was not implemented)_" }
        return "```swift\n\(source)\n```"
    }

    /// The user's steer for this graph op, or "" when they gave none. `SZPromptTemplate` is a flat
    /// token replacer with no conditional sections, so the empty case has to collapse to nothing here —
    /// the template puts `{{instruction}}` alone on a line, and "" leaves a clean paragraph break.
    /// Framed as HOW to perform the op, so an agent can't mistake it for the node's own intent.
    private static func steerBlock(_ instruction: String?, verb: String) -> String {
        let steer = instruction?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !steer.isEmpty else { return "" }
        // Defuse `{{…}}` in the steer. This is the only USER-authored value we hand to SZPromptTemplate,
        // and `render` walks an unordered dictionary: a steer containing a live token (`{{source}}`,
        // `{{boundary}}`, …) would be expanded, or left literal, depending on Swift's per-process hash
        // seed — the same instruction rendering two different prompts on two runs.
        let safe = steer.replacingOccurrences(of: "{{", with: "{ {")
        return "\nHow the user asked for this \(verb) to be done — follow it:\n\(safe)\n"
    }
}

/// Shared renderer for a node's typed boundary in agent prompts — each port's type, ui/default, and the
/// EXACT live-read call in `update()`. ONE renderer used by the coding prompt (node-compile) AND the
/// split/merge seed prompts, so every agent both PRESERVES the typed contract and READS its scalar inputs
/// (never hardcodes them → no dead controls). The host pins the boundary at promote; this makes
/// the agent's SOURCE honor it.
enum SZBoundaryPrompt {
    /// Describe a contract's whole declared boundary (inputs + outputs + permissions).
    static func render(_ contract: SZNodeContract) -> String {
        render(inputs: contract.inputs, outputs: contract.outputs, permissions: contract.requiredPermissions)
    }

    /// Describe an explicit set of ports (the coding plan derives texture ports for a contract-less node).
    static func render(inputs: [SZPort], outputs: [SZPort], permissions: [SZEntitlement]) -> String {
        let ins = inputs.isEmpty ? "- (none)" : inputs.map(inputLine).joined(separator: "\n")
        let outs = outputs.isEmpty ? "- (none)" : outputs.map(outputLine).joined(separator: "\n")
        let perms = permissions.isEmpty ? ""
            : "\n\nDeclared permissions (host-granted before your `setup()` runs — keep them in the contract): \(permissions.map(\.rawValue).joined(separator: ", "))."
        return "Inputs:\n\(ins)\n\nOutputs:\n\(outs)\(perms)"
    }

    private static func inputLine(_ p: SZPort) -> String {
        let meta = portMeta(p)
        switch p.type {
        case .texture:
            return "- `\(p.name)` — texture\(meta) — read with `ctx.inputTexture(\"\(p.name)\")` (may be nil before a frame arrives)"
        case .bool:
            return "- `\(p.name)` — bool\(meta) — read LIVE each frame with `(ctx.inputFloat(\"\(p.name)\") ?? 1) > 0.5`"
        case .float:
            return "- `\(p.name)` — float\(meta) — read LIVE each frame with `ctx.inputFloat(\"\(p.name)\")`"
        case .float2, .float3, .float4, .colorRGB, .colorRGBA, .float3x3, .float4x4:
            return "- `\(p.name)` — \(p.type.rawValue)\(meta) — read LIVE each frame with `ctx.inputFloats(\"\(p.name)\")`"
        case .enumeration, .string:
            return "- `\(p.name)` — \(p.type.rawValue)\(meta) — read LIVE each frame with `ctx.inputString(\"\(p.name)\")` (an enum delivers the selected option's value; nil until one is set)"
        case .floatArray:
            return "- `\(p.name)` — floatArray\(meta) — a connected variable-length `[Float]` (e.g. audio samples or an FFT spectrum); read LIVE each frame with `ctx.inputFloatArray(\"\(p.name)\")` (nil until the upstream emits)"
        case .event:
            return "- `\(p.name)` — event\(meta) — declared for the UI; NOT delivered to the node at runtime yet, so declare it but don't depend on its value"
        }
    }

    private static func outputLine(_ p: SZPort) -> String {
        let display = p.display == true ? ", display" : ""
        switch p.type {
        case .texture:
            return "- `\(p.name)` — texture\(display) — fill with `ctx.outputTexture(\"\(p.name)\")`"
        case .float:
            return "- `\(p.name)` — float — emit LIVE each frame with `ctx.setOutputFloat(\"\(p.name)\", value)`"
        case .float2, .float3, .float4, .colorRGB, .colorRGBA, .float3x3, .float4x4, .bool:
            return "- `\(p.name)` — \(p.type.rawValue) — emit LIVE each frame with `ctx.setOutputFloats(\"\(p.name)\", values)`"
        case .floatArray:
            return "- `\(p.name)` — floatArray — emit a variable-length `[Float]` each frame with `ctx.setOutputFloats(\"\(p.name)\", values)`; the connected downstream reads it with `ctx.inputFloatArray`"
        case .enumeration, .string, .event:
            return "- `\(p.name)` — \(p.type.rawValue) — declared for the UI; not emitted to a downstream node at runtime"
        }
    }

    private static func portMeta(_ p: SZPort) -> String {
        var bits: [String] = []
        if let ui = p.ui { bits.append(ui.kind.rawValue) }
        if let def = p.def, let s = defaultString(def) { bits.append("default \(s)") }
        return bits.isEmpty ? "" : " (\(bits.joined(separator: ", ")))"
    }

    private static func defaultString(_ v: SZPortValue) -> String? {
        switch v {
        case .bool(let b): b ? "true" : "false"
        case .float(let f): String(f)
        case .enumeration(let s), .string(let s): "\"\(s)\""
        default: nil
        }
    }
}

/// Builds the Director Agent's turn prompt — the live graph as context + the user's instruction.
/// Public so the host renders it when it spawns the Director turn (`SZAgenticDirectorStrategy`).
public enum SZDirectorPrompt {
    public static func render(graph: SZGraph, instruction: String) -> String {
        SZPromptTemplate.render(SZPrompts.director, [
            "graph": graphSummary(graph),
            "instruction": instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "(none — make the current graph as drawn ready to implement)"
                : instruction,
            "toolbelt": SZPrompts.directorToolbelt,
        ])
    }

    /// The Director Agent's cold-start CHAT turn: the live graph + the user's (mention-expanded)
    /// message, framed conversationally with the shared toolbelt. Resumed chat turns send the raw
    /// message — their context is the session.
    public static func renderChat(graph: SZGraph, message: String) -> String {
        SZPromptTemplate.render(SZPrompts.directorChat, [
            "graph": graphSummary(graph),
            "message": message,
            "toolbelt": SZPrompts.directorToolbelt,
        ])
    }

    /// A RESUMED Director chat turn. Its session already holds the persona and the toolbelt, but the graph it
    /// remembers is a snapshot from whenever it last looked — and runs mutate the graph underneath it. (A run's
    /// last Director turn renders node kinds *before* the coding fleet's promotes land, so the session's final
    /// memory of the graph is reliably out of date.) Re-project the live graph every turn rather than trusting
    /// the model to re-read it: the host has the truth, so hand it over.
    public static func renderResumedChat(graph: SZGraph, message: String) -> String {
        """
        Live graph state, as of this message. This and `agent_read_graph` are authoritative — trust them over \
        any description of the graph earlier in our conversation, which may predate a run.

        \(graphSummary(graph))

        ---

        \(message)
        """
    }

    /// Build the Director's reconcile-turn prompt: the live graph + the unresolved nodes with each
    /// one's current contract/intent and its last reported blocker, so the Director decides per node how to
    /// unblock it (adjust contract/prompt via `ui_*`) before the fleet retries.
    public static func renderReconcile(
        graph: SZGraph, unresolved: [SZNodeID], statuses: [SZNodeID: String],
        inbox: [String] = [], round: Int, cap: Int
    ) -> String {
        let blocks = unresolved.map { id -> String in
            let node = graph.node(id: id)
            let title = node?.title ?? "node"
            let io = contractIO(node?.contract, fallback: "no contract")
            let intent = (node?.prompt?.isEmpty == false) ? " — intent: \"\(node!.prompt!)\"" : ""
            let status = statuses[id] ?? "(no status reported — it did not finish)"
            return "- `\(id.uuidString)` \"\(title)\" — \(io)\(intent)\n  reported: \(status)"
        }.joined(separator: "\n")
        return SZPromptTemplate.render(SZPrompts.directorReconcile, [
            "graph": graphSummary(graph),
            "blockers": blocks.isEmpty ? "- (none)" : blocks,
            // The coding agents' mid-run `ui_send_chat scope=director` messages — previously a
            // silent black hole (appended to the tab, read by no LLM). FIFO, verbatim.
            "inbox": inbox.isEmpty ? "- (none)" : inbox.map { "- \($0)" }.joined(separator: "\n"),
            "round": String(round),
            "cap": String(cap),
        ])
    }

    /// A compact, agent-readable description of the graph: each node's id/title/kind/contract-state/prompt,
    /// then the flow (drawing-intent) + data edges and the render endpoint — enough for the Director to
    /// target `ui_*` calls. Flow edges are the user's intent to realize; laying a data edge resolves them.
    static func graphSummary(_ graph: SZGraph) -> String {
        func short(_ id: SZNodeID) -> String { String(id.uuidString.prefix(8)) }
        let nodes = graph.nodes.map { n -> String in
            let io = contractIO(n.contract, fallback: "no contract yet")
            // A blank prompt node is rendered EXPLICITLY, not as an absent clause: the Director must be
            // able to tell "the user left this undecided" from "this node never carries a prompt", so it
            // leaves the node alone (or asks) instead of manufacturing intent from the surrounding layout.
            let prompt: String
            if let p = n.prompt, !p.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                prompt = " — prompt: \"\(p)\""
            } else if n.kind == .prompt {
                prompt = " — prompt: (empty — the user has not described this node yet; do not invent its purpose)"
            } else {
                prompt = ""
            }
            // `needsRebuild` is not implied by `kind` — a built node whose contract moved still reads
            // `generated`, and the Director must see that it is nonetheless pending work.
            let rebuild = n.needsRebuild ? " (NEEDS REBUILD — its code predates the current contract)" : ""
            return "- `\(n.id.uuidString)` \"\(n.title)\" — \(n.kind.rawValue)\(rebuild), \(io)\(prompt)"
        }.joined(separator: "\n")

        let flow = graph.connections.filter { $0.kind == .flow }
            .map { "\(short($0.from.node)) → \(short($0.to.node))" }
        let data = graph.connections.filter { $0.kind == .data }
            .map { "\(short($0.from.node)).\($0.from.port) → \(short($0.to.node)).\($0.to.port)" }
        let endpoint = graph.renderEndpoint.map { "\(short($0.node)).\($0.port)" } ?? "none"

        return """
        Nodes:
        \(nodes.isEmpty ? "- (none)" : nodes)

        Flow edges (drawing intent — realize each into typed data wiring; laying the data edge resolves the arrow): \(flow.isEmpty ? "none" : flow.joined(separator: ", "))
        Data edges: \(data.isEmpty ? "none" : data.joined(separator: ", "))
        Render endpoint (blitted to the viewport): \(endpoint)
        """
    }

    /// A node's typed boundary as `contract[in: …; out: …]` for an agent prompt, or `fallback` when it has
    /// no contract yet — one source for both the decompose summary and the reconcile blockers (which word the
    /// absence slightly differently: "no contract yet" vs "no contract").
    private static func contractIO(_ contract: SZNodeContract?, fallback: String) -> String {
        guard let contract else { return fallback }
        return "contract[in: \(portList(contract.inputs)); out: \(portList(contract.outputs))]"
    }

    private static func portList(_ ports: [SZPort]) -> String {
        ports.isEmpty ? "—" : ports.map { "\($0.name):\($0.type.rawValue)" }.joined(separator: ", ")
    }
}

/// Public prompt builders the host (SZApp) uses to seed agent turns it spawns directly (chat).
public enum SZChatPrompts {
    /// Seed a fresh Coding Agent turn to edit an existing node from a user message — used when a node
    /// is chatted but has no resumable session yet (e.g. a hand-authored node, no prior run).
    public static func nodeColdStart(node: String, userMessage: String, currentContract: String, currentSource: String) -> String {
        SZPromptTemplate.render(SZPrompts.nodeChat, [
            "node": node,
            "message": userMessage,
            "contract": currentContract,
            "source": currentSource,
        ])
    }
}
