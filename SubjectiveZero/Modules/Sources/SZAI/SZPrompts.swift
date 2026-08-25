// SPDX-License-Identifier: AGPL-3.0-only
// HOST-owned prompt prose (Resources/Prompts/) — what is left after the packs became the one
// home for AGENT prose: today exactly the ask-repair wrapper, which belongs to the query
// service, not to any agent. Rendered with the flat-`{{token}}` SZPromptTemplate.
import Foundation
import SZCore

enum SZPrompts {
    /// The repair wrapper the query service appends to a step ask's retry prompt (attempt > 0):
    /// the decode error + the previous reply, as `{{error}}` / `{{previousReply}}` tokens.
    static let askRepair = load("ask-repair.md.mustache")

    /// Load a prompt by its path under `Resources/Prompts/` (e.g. "coding/node-chat.md.mustache").
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

/// Value builders shared by the brief renderer's split/merge recipes — the production seed
/// path renders the coding pack's `split-stage`/`merge` templates through `SZBriefRenderer`
/// (SZHost+SplitMerge `renderSeed`); these assemble the values its tokens substitute.
public enum SZGraphPrompts {
    /// A fenced Swift block for a node's source, or a "no source yet" note for an un-implemented node.
    /// Internal (not private): the brief renderer assembles the same value.
    static func sourceBlock(_ source: String?) -> String {
        guard let source, !source.isEmpty else { return "_(no source yet — this node was not implemented)_" }
        return "```swift\n\(source)\n```"
    }

    /// The user's steer for this graph op, or "" when they gave none. `SZPromptTemplate` is a flat
    /// token replacer with no conditional sections, so the empty case has to collapse to nothing here —
    /// the template puts `{{instruction}}` alone on a line, and "" leaves a clean paragraph break.
    /// Framed as HOW to perform the op, so an agent can't mistake it for the node's own intent.
    /// Internal (not private): the brief renderer assembles the same value.
    static func steerBlock(_ instruction: String?, verb: String) -> String {
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
/// EXACT live-read call in `update()`. ONE renderer used by the coding brief (node-compile, via the
/// brief renderer) AND the split/merge seed prompts, so every agent both PRESERVES the typed contract and READS its scalar inputs
/// (never hardcodes them → no dead controls). The promote merge holds the live boundary's types; this
/// makes the agent's SOURCE honor it.
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
            return "- `\(p.name)` — bool\(meta) — read LIVE each frame with `ctx.inputBool(\"\(p.name)\")`"
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
        // What a file port accepts is part of its boundary: an agent editing the node must carry the
        // list forward, and one adding a file port needs to see the shape.
        let accepted = p.ui?.acceptedExtensions ?? []
        if !accepted.isEmpty { bits.append("accepts \(accepted.map { ".\($0)" }.joined(separator: "/"))") }
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

/// The Director Agent's prompt VALUE BUILDERS — graph projections and per-turn context lines.
/// The brief renderer (`SZBriefRenderer`) assembles run-turn briefs from these; the host renders
/// the chat framings below directly when it spawns a Director chat turn.
public enum SZDirectorPrompt {
    /// The decompose brief's `{{instruction}}` value: the user's words verbatim, or the
    /// explicit no-instruction fallback.
    static func instructionLine(_ instruction: String) -> String {
        instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "(none — make the current graph as drawn ready to implement)"
            : instruction
    }

    /// The reconcile brief's `{{blockers}}` value: one block per unresolved node — its typed
    /// boundary, its intent, and what its Coding Agent last reported (or the explicit
    /// no-status fallback).
    static func blockerLines(graph: SZGraph, unresolved: [SZNodeID],
                             statuses: [SZNodeID: String]) -> String {
        let blocks = unresolved.map { id -> String in
            let node = graph.node(id: id)
            let title = node?.title ?? "node"
            let io = contractIO(node?.contract, fallback: "no contract")
            let intent = (node?.prompt?.isEmpty == false) ? " — intent: \"\(node!.prompt!)\"" : ""
            let status = statuses[id] ?? "(no status reported — it did not finish)"
            return "- `\(id.uuidString)` \"\(title)\" — \(io)\(intent)\n  reported: \(status)"
        }.joined(separator: "\n")
        return blocks.isEmpty ? "- (none)" : blocks
    }

    /// The reconcile brief's `{{inbox}}` value — the fleet's messages, FIFO, verbatim.
    static func inboxLines(_ inbox: [String]) -> String {
        inbox.isEmpty ? "- (none)" : inbox.map { "- \($0)" }.joined(separator: "\n")
    }

    /// The triage/amend briefs' `{{tasks}}` value — the work in hand, oldest first, each line led
    /// by the id an amend or cancel names and marked with its state. Running work is listed too, or
    /// a message about what is being built can only schedule that same work a second time.
    static func taskLines(_ tasks: [SZTask]) -> String {
        guard !tasks.isEmpty else { return "- (nothing scheduled or running)" }
        return tasks.map { task in
            let nodes: String
            if task.workSet.isEmpty {
                nodes = ""
            } else if task.state == .running {
                // Running work is steered node by node, so the amend turn needs the ids: a
                // count says there is something to message, not where to send it.
                nodes = " — on " + task.workSet.map { "`\($0.uuidString)`" }
                    .sorted().joined(separator: ", ")
            } else {
                nodes = " — \(task.workSet.count) node" + (task.workSet.count == 1 ? "" : "s")
            }
            let state = task.state == .running ? " [BUILDING NOW]" : " [scheduled]"
            return "- `\(task.id.uuidString)`\(state) \"\(task.title)\"\(nodes)\n  asked: \(task.instruction)"
        }.joined(separator: "\n")
    }

    /// How many mutation lines a brief prints — the rest are summarized as a count, so a long run's
    /// delta stays a readable list instead of a wall the model skims past.
    static let mutationLineCap = 40

    /// The reconcile brief's `{{mutations}}` value — one line per graph edit since the Director's
    /// last turn, oldest first, each led by its actor: `USER`, `DIRECTOR`, `EXTERNAL`, or the Coding
    /// Agent named by its node's title. A repeated edit collapses to its latest state with a `×N`.
    static func mutationLines(_ mutations: [SZGraphMutation], graph: SZGraph?) -> String {
        guard !mutations.isEmpty else { return "- (nothing changed since your last turn)" }
        var folded: [(mutation: SZGraphMutation, repeats: Int)] = []
        for m in mutations {
            if let last = folded.last, last.mutation.coalescingKey == m.coalescingKey {
                folded[folded.count - 1] = (m, last.repeats + 1)   // keep the LATEST state
            } else {
                folded.append((m, 1))
            }
        }
        var lines = folded.suffix(mutationLineCap).map { entry -> String in
            let m = entry.mutation
            let subjects = m.subjects.isEmpty ? "" : " " + m.subjects.joined(separator: ", ")
            let times = entry.repeats > 1 ? " (×\(entry.repeats))" : ""
            return "- \(actorLabel(m.actor, graph: graph)) \(m.kind)\(subjects)\(times)"
        }
        if folded.count > mutationLineCap {
            lines.insert("- (… and \(folded.count - mutationLineCap) earlier edits)", at: 0)
        }
        return lines.joined(separator: "\n")
    }

    /// How a mutation's actor is named in the brief.
    private static func actorLabel(_ actor: SZGraphMutation.Actor, graph: SZGraph?) -> String {
        switch actor {
        case .user: return "USER"
        case .director: return "DIRECTOR"
        case .external: return "EXTERNAL"
        case .agent(let id):
            return "Coding Agent (\(graph?.node(id: id)?.title ?? String(id.uuidString.prefix(8))))"
        }
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
            // `generated`, and the Director must see that it is nonetheless pending work. The derived reason
            // rides along; the toolbelt defines the three and `agent_read_node` carries the detail.
            let rebuild = n.rebuildReason.map { " (NEEDS REBUILD — \($0.rawValue))" } ?? ""
            return "- `\(n.id.uuidString)` \"\(n.title)\" — \(n.kind.rawValue)\(rebuild), \(io)\(prompt)"
        }.joined(separator: "\n")

        // A pinned end prints as `node.port` — the user dropped the arrow on that exact slot.
        let flow = graph.connections.filter { $0.kind == .flow }
            .map { c in
                let from = short(c.from.node) + (c.pinnedPort(.from).map { ".\($0)" } ?? "")
                let to = short(c.to.node) + (c.pinnedPort(.to).map { ".\($0)" } ?? "")
                return "\(from) → \(to)"
            }
        let data = graph.connections.filter { $0.kind == .data }
            .map { "\(short($0.from.node)).\($0.from.port) → \(short($0.to.node)).\($0.to.port)" }
        let endpoint = graph.renderEndpoint.map { "\(short($0.node)).\($0.port)" } ?? "none"

        return """
        Nodes:
        \(nodes.isEmpty ? "- (none)" : nodes)

        Flow edges (drawing intent — realize each into typed data wiring; laying the data edge resolves the arrow; an end written `node.port` was dropped on that exact slot — wire that port, not another): \(flow.isEmpty ? "none" : flow.joined(separator: ", "))
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

