// SPDX-License-Identifier: AGPL-3.0-only
// The mutation journal's append side: the origin-carrying host funnels (connect, disconnect,
// toggle display, delete, input default, content update, node body, add) each leave one entry,
// attributed by origin + the calling turn's scope — USER for the editor, DIRECTOR for a
// Director-scoped agent turn, that node's Coding Agent for a node-scoped one, EXTERNAL when the
// call carries no scope at all. A refused mutation leaves no entry, and neither does machinery
// re-applying card geometry.
import Foundation
import Testing
import SZCore
@testable import SubjectiveZero

@MainActor
struct SZHostMutationJournalTests {
    private let cameraID = SZNodeID()
    private let effectID = SZNodeID()

    private func host() -> SZHost {
        let camera = SZNode(id: cameraID, kind: .generated, title: "Camera",
                            contract: SZNodeContract(title: "Camera", sfSymbol: "s", summary: "",
                                                     inputs: [],
                                                     outputs: [SZPort(name: "output", type: .texture, display: true)]),
                            position: SZPoint(x: 0, y: 0))
        let effect = SZNode(id: effectID, kind: .generated, title: "Effect",
                            contract: SZNodeContract(title: "Effect", sfSymbol: "s", summary: "",
                                                     inputs: [SZPort(name: "input", type: .texture),
                                                              SZPort(name: "amount", type: .float)],
                                                     outputs: [SZPort(name: "output", type: .texture, display: true)]),
                            position: SZPoint(x: 1, y: 0))
        let host = SZHost()
        host.store.setProject(SZProject(name: "t", graph: SZGraph(nodes: [camera, effect])))
        return host
    }

    private var edge: (SZPortRef, SZPortRef) {
        (SZPortRef(node: cameraID, port: "output"), SZPortRef(node: effectID, port: "input"))
    }

    @Test func aUserEditIsJournaledAsUser() {
        let host = host()
        let (from, to) = edge
        #expect(host.addConnection(from: from, to: to, kind: .data, origin: .user) != nil)
        let entry = host.mutationJournal.entries.last
        #expect(entry?.actor == .user)
        #expect(entry?.kind == "connected")
        #expect(entry?.subjects == ["Camera.output → Effect.input"])
    }

    @Test func anAgentCallUnderTheRunClaimIsTheDirector() {
        let host = host()
        let run = SZClaimToken(label: "run")
        #expect(host.ledger.tryAcquire([.run, .node(effectID), .transcript(.node(effectID))], as: run))
        host.runClaim = run
        defer { host.runClaim = nil }
        let (from, to) = edge
        SZToolCaller.$claim.withValue(run) {
            SZToolCaller.$scope.withValue(.director) {
                #expect(host.addConnection(from: from, to: to, kind: .data, origin: .agent) != nil)
                #expect(host.toggleDisplay(node: effectID, port: "output", origin: .agent) != nil)
            }
        }
        #expect(host.mutationJournal.entries.map(\.actor) == [.director, .director])
        #expect(host.mutationJournal.entries.map(\.kind) == ["connected", "toggled display"])
        #expect(host.mutationJournal.entries.last?.subjects == ["→ Effect.output"])
    }

    @Test func aNodeScopedTurnUnderTheRunClaimIsThatNodesAgent() {
        let host = host()
        let run = SZClaimToken(label: "run")
        #expect(host.ledger.tryAcquire([.run, .node(effectID), .transcript(.node(effectID))], as: run))
        host.runClaim = run
        defer { host.runClaim = nil }
        let (from, to) = edge
        var id: SZConnectionID?
        SZToolCaller.$claim.withValue(run) {
            SZToolCaller.$scope.withValue(.node(effectID)) {
                id = host.addConnection(from: from, to: to, kind: .data, origin: .agent)
                #expect(host.deleteConnection(id: id!, origin: .agent))
            }
        }
        #expect(host.mutationJournal.entries.map(\.actor) == [.agent(effectID), .agent(effectID)])
        #expect(host.mutationJournal.entries.map(\.kind) == ["connected", "disconnected"])
        // The edge is named as it was BEFORE removal.
        #expect(host.mutationJournal.entries.last?.subjects == ["Camera.output → Effect.input"])
    }

    @Test func anAgentCallCarryingNoScopeIsExternal() {
        let host = host()
        let (from, to) = edge
        // The standing `.full` bus and an outside driver present no turn identity — the Director must
        // never be told those edits were its own.
        #expect(host.addConnection(from: from, to: to, kind: .data, origin: .agent) != nil)
        #expect(host.mutationJournal.entries.last?.actor == .external)
    }

    @Test func aRefusedMutationLeavesNoEntry() {
        let host = host()
        let hold = SZClaimToken(label: "chat turn")
        #expect(host.ledger.tryAcquire([.node(effectID), .transcript(.node(effectID))], as: hold))
        let (from, to) = edge
        #expect(host.addConnection(from: from, to: to, kind: .data, origin: .user) == nil)
        #expect(host.mutationJournal.entries.isEmpty)
    }

    @Test func theOtherFunnelsJournalTheirKinds() {
        let host = host()
        _ = host.setInputDefault(node: effectID, port: "amount", value: .float(0.5), origin: .user)
        _ = host.updateNodeContent(id: effectID, title: "Blur", origin: .user)
        _ = host.updateNodeContent(id: effectID, prompt: "blur it more", origin: .user)
        _ = host.updateNodeContent(id: effectID, prompt: "blur it more", origin: .user)   // no-op: no entry
        #expect(host.deleteNode(id: cameraID, origin: .user))
        #expect(host.mutationJournal.entries.map(\.kind)
                == ["set default", "retitled", "re-prompted", "removed node"])
        #expect(host.mutationJournal.entries.map(\.subjects)
                == [["Effect.amount = 0.5"], ["Effect → Blur"], ["Blur"], ["Camera"]])
        #expect(host.mutationJournal.entries.allSatisfy { $0.actor == .user })
    }

    /// Auto-size settle and the backdrop aspect follow re-apply `.custom` with fresh rows all
    /// session; only a change of what the card SHOWS is a decision worth journaling.
    @Test func cardGeometryIsNotADecisionButTheCardModeIs() {
        let host = host()
        #expect(host.setNodeBody(node: effectID, body: SZNodeBody(mode: .custom, custom: SZCustomCardRef(rows: 4))))
        #expect(host.setNodeBody(node: effectID, body: SZNodeBody(mode: .custom, custom: SZCustomCardRef(rows: 9))))
        #expect(host.setNodeBody(node: effectID, body: SZNodeBody(mode: .preview, previewPort: "output")))
        #expect(host.mutationJournal.entries.map(\.kind) == ["set card body", "set card body"])
        #expect(host.mutationJournal.entries.map(\.subjects) == [["Effect: custom"], ["Effect: preview"]])
    }

    @Test func aCanvasAddIsJournaledAtThePanelsCallback() {
        let host = host()
        host.noteNodeAdded(cameraID)
        #expect(host.mutationJournal.entries.map(\.kind) == ["added node"])
        #expect(host.mutationJournal.entries.last?.actor == .user)
        #expect(host.mutationJournal.entries.last?.subjects == ["Camera"])
    }

    @Test func anAgentsAddedNodeGoesThroughTheSameFunnel() throws {
        // `ui_add_prompt_node` journals via `noteNodeAdded` like the canvas add does — one entry, the
        // node's title, attributed to the calling turn's scope.
        let host = host()
        _ = try SZHostBridge(host: host).callTool(name: "ui_add_prompt_node", arguments: [:],
                                                  callerScope: .director)
        #expect(host.mutationJournal.entries.map(\.kind) == ["added node"])
        #expect(host.mutationJournal.entries.last?.actor == .director)
        #expect(host.mutationJournal.entries.last?.subjects == [SZNode.placeholderTitle])
    }

    /// A journaled number is prose the model reads — plain decimals, never `1.23e+03`.
    @Test func journaledNumbersArePlainDecimals() {
        #expect(SZHost.mutationValue(.float(1234.5)) == "1234.5")
        #expect(SZHost.mutationValue(.float(10_000_000)) == "10000000")
        #expect(SZHost.mutationValue(.float(3)) == "3")
        #expect(SZHost.mutationValue(.float(0.25)) == "0.25")
        #expect(SZHost.mutationValue(.string("hi")) == "\"hi\"")
    }
}
