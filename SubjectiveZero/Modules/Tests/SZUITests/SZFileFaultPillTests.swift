// SPDX-License-Identifier: AGPL-3.0-only
// The pill for a node whose file input can't be used — the case that used to be INVISIBLE. Such a
// node builds fine, renders black, and (before this) showed no pill at all, because `showPill` hides
// a `.ready` node's. Both halves are asserted: the status, and that it is actually shown.
import Testing
import SZCore
@testable import SZUI

private func fileFaultNode(_ reasons: [String: String] = ["path": "no file at /Users/c/Downloads/IMG.MOV"]) -> SZNode {
    var n = SZNode(kind: .generated, title: "Video File", position: SZPoint(x: 0, y: 0))
    n.unreadableInputs = reasons
    return n
}

@MainActor
@Test func aNodeWhoseFileIsMissingShowsAnErrorPill() {
    let node = fileFaultNode()
    let status = SZNodeCanvasContentView.pillStatus(for: node, agentState: [:], ops: [:], isRunning: false)
    #expect(status == .error)
    #expect(SZNodeCanvasContentView.showPill(status, isRunning: false),
            "the pill must actually be shown — a hidden one is how this failed silently")
}

@MainActor
@Test func aHealthyNodeIsStillJustReady() {
    let node = SZNode(kind: .generated, title: "Video File", position: SZPoint(x: 0, y: 0))
    #expect(SZNodeCanvasContentView.pillStatus(for: node, agentState: [:], ops: [:], isRunning: false) == .ready)
}

/// A draft has no build and no contract, so it must not wear a red pill before anyone has built it.
@MainActor
@Test func aPromptNodeIsNeverRedForAFile() {
    var node = SZNode(kind: .prompt, title: "New Node", position: SZPoint(x: 0, y: 0))
    node.unreadableInputs = ["path": "no file at /nope"]
    #expect(SZNodeCanvasContentView.pillStatus(for: node, agentState: [:], ops: [:], isRunning: false) == .draft)
}

/// Work in flight does not hide it. A built node with a clean stamp reads Ready even while its agent
/// codes, so yielding to that would put the node back to claiming Ready with a file it cannot open.
@MainActor
@Test func workInFlightDoesNotHideTheFault() {
    let node = fileFaultNode()
    var coding = SZNodeAgentState(); coding.phase = .coding
    #expect(SZNodeCanvasContentView.pillStatus(for: node, agentState: [node.id: coding], ops: [:],
                                               isRunning: true) == .error)
    #expect(SZNodeCanvasContentView.pillStatus(for: node, agentState: [:], ops: [:],
                                               isRunning: true, workSet: [node.id]) == .error)
}

/// A structural op still wins: the node is mid-split/merge and about to be replaced outright.
@MainActor
@Test func aSplitStillOutranksTheFault() {
    let node = fileFaultNode()
    #expect(SZNodeCanvasContentView.pillStatus(for: node, agentState: [:], ops: [node.id: "Splitting"],
                                               isRunning: false) == .splitting)
}

/// The node's own build error outranks the file fault in the popover; both are red.
@MainActor
@Test func theDiagnosticPrefersABuildErrorAndOtherwiseNamesThePort() {
    let node = fileFaultNode()
    let fromFile = SZNodeCanvasContentView.nodeDiagnostic(for: node, agentState: nil)
    #expect(fromFile?.title == "Input file")
    #expect(fromFile?.detail == "path — no file at /Users/c/Downloads/IMG.MOV")

    var built = SZNodeAgentState()
    built.errorDetail = "error: cannot find 'foo'"
    #expect(SZNodeCanvasContentView.nodeDiagnostic(for: node, agentState: built)?.title == "Build error")

    let clean = SZNode(kind: .generated, title: "T", position: SZPoint(x: 0, y: 0))
    #expect(SZNodeCanvasContentView.nodeDiagnostic(for: clean, agentState: nil) == nil)
}

/// Two file inputs, one broken: the card has to say WHICH.
@MainActor
@Test func theDiagnosticListsEveryBrokenPortInAStableOrder() {
    let node = fileFaultNode(["modelPath": "no file at /a", "lutPath": "no file at /b"])
    #expect(SZNodeCanvasContentView.nodeDiagnostic(for: node, agentState: nil)?.detail
            == "lutPath — no file at /b\nmodelPath — no file at /a")
}
