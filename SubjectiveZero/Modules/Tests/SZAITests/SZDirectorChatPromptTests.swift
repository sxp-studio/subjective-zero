// SPDX-License-Identifier: AGPL-3.0-only
// The graph projection every Director turn carries (`{{graph}}` — SZDirectorPrompt.graphSummary).
//
// The bug these pin: after a run promoted two nodes to `generated`, the user asked the Director
// "which part is failing?" and it answered from a stale session snapshot that they were still
// unimplemented. The chat-resumed brief re-projects the live graph every turn (its framing is
// byte-pinned by the equivalence gate); these pin the projection's SEMANTICS — live state, no
// state of its own, and the markers the Director routes on.
import Foundation
import Testing
@testable import SZAI
@testable import SZCore

private func node(_ title: String, kind: SZNodeKind, rebuildReason: SZRebuildReason? = nil) -> SZNode {
    let contract = SZNodeContract(title: title, sfSymbol: "circle", summary: "",
                                  outputs: [SZPort(name: "output", type: .texture)])
    // The reason is derived: a stamp whose surface the contract has outgrown reads `.contractChanged`.
    let stamp: SZBuildStamp? = kind == .generated
        ? (rebuildReason == .contractChanged ? SZBuildStamp(portSurface: [], prompt: nil) : .trusting(contract: contract, prompt: nil))
        : nil
    return SZNode(kind: kind, title: title, contract: contract, position: SZPoint(x: 0, y: 0), buildStamp: stamp)
}

@Test func theSummaryCarriesEveryNodesIdAndTrueState() {
    let built = node("Microphone", kind: .generated)
    let draft = node("Audio Level", kind: .prompt)
    let summary = SZDirectorPrompt.graphSummary(SZGraph(nodes: [built, draft]))
    #expect(summary.contains(built.id.uuidString))
    #expect(summary.contains(draft.id.uuidString))
    #expect(summary.contains("generated"))
    #expect(summary.contains("prompt"))
}

/// The projection reads the graph it is handed — it cannot go stale, because it holds no state of its own.
@Test func theSummaryReflectsAPromoteThatJustLanded() {
    let before = node("Audio Level", kind: .prompt)
    let stale = SZDirectorPrompt.graphSummary(SZGraph(nodes: [before]))
    #expect(stale.contains("\(before.id.uuidString)` \"Audio Level\" — prompt"))

    var after = before
    after.kind = .generated            // exactly what promoteStagedNode does mid-run
    let fresh = SZDirectorPrompt.graphSummary(SZGraph(nodes: [after]))
    #expect(fresh.contains("\(after.id.uuidString)` \"Audio Level\" — generated"))
}

/// A built node whose contract moved still reads `generated`, so `kind` alone would tell the Director it is done.
/// The summary must say otherwise, or the Director will not queue the rebuild it just caused.
@Test func theSummaryFlagsANodeWhoseContractOutranItsBuild() {
    let drifted = node("Kaleidoscope", kind: .generated, rebuildReason: .contractChanged)
    // The derived reason names itself, so the Director reads WHICH kind of drift — not a generic flag.
    #expect(SZDirectorPrompt.graphSummary(SZGraph(nodes: [drifted])).contains("NEEDS REBUILD — contractChanged"))

    let clean = node("Kaleidoscope", kind: .generated)
    #expect(!SZDirectorPrompt.graphSummary(SZGraph(nodes: [clean])).contains("NEEDS REBUILD"))
}

/// A prompt node the user never described must be projected as EXPLICITLY empty, not as a node with its
/// prompt clause simply absent. Otherwise the Director cannot tell "the user left this undecided" from
/// "this node has no intent" and fills the silence with an invented purpose — the bug where a blank node
/// became a fabricated Composite. The marker also carries the do-not-guess instruction inline.
@Test func theSummaryMarksAnUndescribedPromptNodeAsEmpty() {
    var blank = node("Untitled", kind: .prompt)
    blank.prompt = nil
    let outNil = SZDirectorPrompt.graphSummary(SZGraph(nodes: [blank]))
    #expect(outNil.contains("empty"))
    #expect(outNil.contains("has not described"))
    #expect(outNil.lowercased().contains("do not invent"))

    // A whitespace-only prompt is undecided too, not a real intent.
    var whitespace = node("Untitled", kind: .prompt)
    whitespace.prompt = "   \n  "
    #expect(SZDirectorPrompt.graphSummary(SZGraph(nodes: [whitespace])).contains("empty"))

    // A described node shows its prompt verbatim and never the empty marker.
    var described = node("Glow", kind: .prompt)
    described.prompt = "make the input texture glow"
    let outDesc = SZDirectorPrompt.graphSummary(SZGraph(nodes: [described]))
    #expect(outDesc.contains("make the input texture glow"))
    #expect(!outDesc.contains("has not described"))
}

/// A flow arrow the user dropped on a specific blue slot prints that slot (`node.port`), so the
/// Director wires THAT port; a plain node-to-node arrow prints nodes only.
@Test func theSummaryPrintsAFlowArrowsPinnedSlot() {
    let cam = node("Camera", kind: .generated)
    let blend = node("Blend", kind: .generated)
    let short = { (id: SZNodeID) in String(id.uuidString.prefix(8)) }
    let plain = SZConnection(from: SZPortRef.flow(node: cam.id), to: SZPortRef.flow(node: blend.id), kind: .flow)
    let pinned = SZConnection(from: SZPortRef(node: cam.id, port: "output"),
                              to: SZPortRef(node: blend.id, port: "mask"), kind: .flow)
    let summary = SZDirectorPrompt.graphSummary(SZGraph(nodes: [cam, blend], connections: [plain, pinned]))
    #expect(summary.contains("\(short(cam.id)) → \(short(blend.id)),"))
    #expect(summary.contains("\(short(cam.id)).output → \(short(blend.id)).mask"))
}

// MARK: - The build lane's blank-node rule (decompose + reconcile, through the shipped pack)

private let shippedPacksRoot = URL(filePath: #filePath)
    .deletingLastPathComponent()   // SZAITests
    .deletingLastPathComponent()   // Tests
    .deletingLastPathComponent()   // Modules
    .appending(path: "Sources/SZAI/Resources/Agents")

/// The rule both run briefs state next to their job description — not only in the toolbelt. (Asserted by
/// fragments that never straddle the templates' line wraps.)
private let blankNodeRule = "`(empty — …)` are the user's undecided placeholders"
private let blankNodeHandsOff = "no prompt, no ports, no wiring"

/// A described node plus one blank placeholder, as a Build sees them.
private func graphWithBlank() -> (SZGraph, SZNode) {
    var described = node("Glow", kind: .prompt)
    described.prompt = "make the input texture glow"
    let blank = SZNode(kind: .prompt, title: "New Node", prompt: "", position: SZPoint(x: 0, y: 0))
    return (SZGraph(nodes: [described, blank]), blank)
}

/// A Build with no instruction once "set up the one missing contract" for a blank node the user had left
/// undecided — the decompose brief said "give every prompt node a contract" and only the toolbelt at the
/// bottom disagreed. The brief now scopes its job to described nodes and states the rule beside it, and
/// the blank node arrives marked `(empty — …)` so the rule has something to bind to.
@Test func theDecomposeBriefTellsTheDirectorToLeaveBlankNodesAlone() throws {
    let (graph, blank) = graphWithBlank()
    let out = try SZBriefRenderer(packRoot: shippedPacksRoot).render(
        agent: "director", template: "decompose", message: "",
        world: SZWorld(graph: graph, run: SZRun(workSet: [], round: 1, roundCap: 1, steers: [], instruction: "")))
    #expect(out.contains("that the user has described"))
    #expect(out.contains(blankNodeRule))
    #expect(out.contains(blankNodeHandsOff))
    #expect(out.contains("\(blank.id.uuidString)` \"New Node\" — prompt, no contract yet — prompt: (empty —"))
    // The rule sits with the job description, before the graph — not only in the toolbelt at the end.
    #expect(out.range(of: blankNodeRule)!.lowerBound < out.range(of: "## The current graph")!.lowerBound)
}

/// Reconcile carries no toolbelt, so it saw the `(empty — …)` marker with no rule at all.
@Test func theReconcileBriefTellsTheDirectorToLeaveBlankNodesAlone() throws {
    let (graph, blank) = graphWithBlank()
    let out = try SZBriefRenderer(packRoot: shippedPacksRoot).render(
        agent: "director", template: "reconcile", message: "",
        world: SZWorld(graph: graph, run: SZRun(workSet: [], round: 1, roundCap: 2, steers: [], instruction: "")))
    #expect(out.contains(blankNodeRule))
    #expect(out.contains(blankNodeHandsOff))
    #expect(out.contains("\(blank.id.uuidString)` \"New Node\" — prompt, no contract yet — prompt: (empty —"))
}

// MARK: - The split-into-pipeline rule (decompose + chat, through the shipped toolbelt)

/// The reused node's prompt is re-authored to its one stage, never left carrying the user's whole
/// sentence. Stated in the toolbelt, so both briefs that can split — decompose and chat — carry it.
/// (Fragments never straddle the template's line wraps.)
@Test func theToolbeltBriefsTellTheDirectorToReauthorTheReusedNodesPrompt() throws {
    let (graph, _) = graphWithBlank()
    let renderer = SZBriefRenderer(packRoot: shippedPacksRoot)
    let decompose = try renderer.render(
        agent: "director", template: "decompose", message: "",
        world: SZWorld(graph: graph, run: SZRun(workSet: [], round: 1, roundCap: 1, steers: [], instruction: "")))
    let chat = try renderer.render(
        agent: "director", template: "chat", message: "make the camera grayscale",
        world: SZWorld(graph: graph))
    for out in [decompose, chat] {
        #expect(out.contains("including the node you are reusing"))
        #expect(out.contains("Never leave the user's whole sentence"))
        #expect(out.contains("not-yet-built node raises no rebuild"))
    }
}

/// The audit-semantics section is agent-facing truth: `agent_docs_read {topic:"node-contract"}` (and the
/// cold-start brief that embeds it) must state BOTH faults the port audit raises (undeclared port names, a
/// live AV resource with no `setPaused`) and the three derived rebuild reasons, so no agent theorizes about
/// byte-level file equality again — and so a video node is never sent hunting port names.
@Test func theContractDocStatesWhatTheAuditComparesAndTheThreeReasons() {
    let doc = SZAgentDocs.read("node-contract") ?? ""
    for needle in ["sourceMismatch", "contractChanged", "intentChanged", "rebuildDetail",
                   "the audit compares the names", "can never cause or clear a mismatch",
                   "func setPaused(", "merges per port, by name"] {
        #expect(doc.contains(needle), "node-contract.md lost: \(needle)")
    }
}
