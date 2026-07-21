// SPDX-License-Identifier: AGPL-3.0-only
// A RESUMED Director chat turn must carry the live graph.
//
// The bug these pin: after a run promoted two nodes to `generated`, the user asked the Director "which part is
// failing?" and it answered that they were still unimplemented `prompt` nodes — from a snapshot its session took
// before the run, having made no tool calls at all. `agent_read_graph` was always live; the Director simply never
// re-read. So the host hands it the truth every turn instead of hoping it asks.
import Foundation
import Testing
@testable import SZAI
@testable import SZCore

private func node(_ title: String, kind: SZNodeKind, rebuildReason: SZRebuildReason? = nil) -> SZNode {
    SZNode(kind: kind, title: title,
           contract: SZNodeContract(title: title, sfSymbol: "circle", summary: "",
                                    outputs: [SZPort(name: "output", type: .texture)]),
           position: SZPoint(x: 0, y: 0), rebuildReason: rebuildReason)
}

@Test func resumedDirectorTurnCarriesLiveNodeState() {
    let built = node("Microphone", kind: .generated)
    let draft = node("Audio Level", kind: .prompt)
    let graph = SZGraph(nodes: [built, draft])

    let prompt = SZDirectorPrompt.renderResumedChat(graph: graph, message: "which part of the graph is failing?")

    // Every node's id and its true state travel with the turn.
    #expect(prompt.contains(built.id.uuidString))
    #expect(prompt.contains(draft.id.uuidString))
    #expect(prompt.contains("generated"))
    #expect(prompt.contains("prompt"))
    // And the user's actual message survives.
    #expect(prompt.contains("which part of the graph is failing?"))
    // The block must outrank whatever the session remembers, or the model may still trust its snapshot.
    #expect(prompt.lowercased().contains("authoritative"))
}

/// The projection reads the graph it is handed — it cannot go stale, because it holds no state of its own.
@Test func resumedDirectorTurnReflectsAPromoteThatJustLanded() {
    let before = node("Audio Level", kind: .prompt)
    let stale = SZDirectorPrompt.renderResumedChat(graph: SZGraph(nodes: [before]), message: "status?")
    #expect(stale.contains("\(before.id.uuidString)` \"Audio Level\" — prompt"))

    var after = before
    after.kind = .generated            // exactly what promoteStagedNode does mid-run
    let fresh = SZDirectorPrompt.renderResumedChat(graph: SZGraph(nodes: [after]), message: "status?")
    #expect(fresh.contains("\(after.id.uuidString)` \"Audio Level\" — generated"))
}

/// A built node whose contract moved still reads `generated`, so `kind` alone would tell the Director it is done.
/// The summary must say otherwise, or the Director will not queue the rebuild it just caused.
@Test func graphSummaryFlagsANodeWhoseContractOutranItsBuild() {
    let drifted = node("Kaleidoscope", kind: .generated, rebuildReason: .contractChanged)
    let summary = SZDirectorPrompt.renderResumedChat(graph: SZGraph(nodes: [drifted]), message: "status?")
    #expect(summary.contains("NEEDS REBUILD"))

    let clean = node("Kaleidoscope", kind: .generated)
    #expect(!SZDirectorPrompt.renderResumedChat(graph: SZGraph(nodes: [clean]), message: "status?")
        .contains("NEEDS REBUILD"))
}

/// A prompt node the user never described must be projected as EXPLICITLY empty, not as a node with its
/// prompt clause simply absent. Otherwise the Director cannot tell "the user left this undecided" from
/// "this node has no intent" and fills the silence with an invented purpose — the bug where a blank node
/// became a fabricated Composite. The marker also carries the do-not-guess instruction inline.
@Test func graphSummaryMarksAnUndescribedPromptNodeAsEmpty() {
    var blank = node("Untitled", kind: .prompt)
    blank.prompt = nil
    let outNil = SZDirectorPrompt.renderResumedChat(graph: SZGraph(nodes: [blank]), message: "?")
    #expect(outNil.contains("empty"))
    #expect(outNil.contains("has not described"))
    #expect(outNil.lowercased().contains("do not invent"))

    // A whitespace-only prompt is undecided too, not a real intent.
    var whitespace = node("Untitled", kind: .prompt)
    whitespace.prompt = "   \n  "
    #expect(SZDirectorPrompt.renderResumedChat(graph: SZGraph(nodes: [whitespace]), message: "?")
        .contains("empty"))

    // A described node shows its prompt verbatim and never the empty marker.
    var described = node("Glow", kind: .prompt)
    described.prompt = "make the input texture glow"
    let outDesc = SZDirectorPrompt.renderResumedChat(graph: SZGraph(nodes: [described]), message: "?")
    #expect(outDesc.contains("make the input texture glow"))
    #expect(!outDesc.contains("has not described"))
}
