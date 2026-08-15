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
    SZNode(kind: kind, title: title,
           contract: SZNodeContract(title: title, sfSymbol: "circle", summary: "",
                                    outputs: [SZPort(name: "output", type: .texture)]),
           position: SZPoint(x: 0, y: 0), rebuildReason: rebuildReason)
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
    #expect(SZDirectorPrompt.graphSummary(SZGraph(nodes: [drifted])).contains("NEEDS REBUILD"))

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
