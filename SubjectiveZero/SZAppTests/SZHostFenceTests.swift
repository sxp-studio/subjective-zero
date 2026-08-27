// SPDX-License-Identifier: AGPL-3.0-only
// The mutation fence's agent rule, pinned from both directions: identity is the CALLER's
// claim token (`SZToolCaller`, bound per tool call by the turn's own listener) — never
// what the holder happens to also hold. Every claim site in the app pairs `.node(id)`
// with `.transcript(.node(id))` under one token, so a holder-side check alone is a
// tautology that would let ANY agent mutate ANY held node; and without the caller
// exemption, a turn cannot edit the node it is itself holding (the live bug that
// motivated the rule). Both regressions must redden here.
import Foundation
import Testing
import SZCore
@testable import SubjectiveZero

@MainActor
struct SZHostFenceTests {

    /// Hold a node the way every real claim site does: node + its transcript, one token.
    private func hold(_ node: SZNodeID, on host: SZHost, label: String = "chat turn") -> SZClaimToken {
        let token = SZClaimToken(label: label)
        #expect(host.ledger.tryAcquire([.node(node), .transcript(.node(node))], as: token))
        return token
    }

    @Test func aUserIsRefusedOnAHeldNode() {
        let host = SZHost()
        let node = SZNodeID()
        _ = hold(node, on: host)
        #expect(host.fenceDenial(nodes: [node], origin: .user) != nil)
    }

    @Test func anAgentWithNoCarriedIdentityIsRefusedOnAHeldNode() {
        let host = SZHost()
        let node = SZNodeID()
        _ = hold(node, on: host)
        // The shared bus carries no caller — the exemption must not fire on holder shape alone.
        #expect(host.fenceDenial(nodes: [node], origin: .agent) != nil)
    }

    @Test func theTurnMayMutateTheNodeItHolds() {
        let host = SZHost()
        let node = SZNodeID()
        let turn = hold(node, on: host)
        SZToolCaller.$claim.withValue(turn) {
            #expect(host.fenceDenial(nodes: [node], origin: .agent) == nil)
        }
    }

    @Test func aBystanderAgentIsRefusedOnAHeldNode() {
        let host = SZHost()
        let node = SZNodeID()
        _ = hold(node, on: host)
        // A different turn's identity (a Director chat, another node's agent) is not the holder.
        SZToolCaller.$claim.withValue(SZClaimToken(label: "director turn")) {
            #expect(host.fenceDenial(nodes: [node], origin: .agent) != nil)
        }
    }

    @Test func theRunsAgentsMayMutateItsWorkSet() {
        let host = SZHost()
        let node = SZNodeID()
        let claim = hold(node, on: host, label: "run")
        let run = SZRunState(taskID: UUID(), claim: claim, instruction: "",
                             ownsGraphOp: false, workSet: [node])
        host.activeRuns[run.taskID] = run
        defer { host.activeRuns = [:] }
        // The fleet steering its own work set needs no per-caller identity.
        #expect(host.fenceDenial(nodes: [node], origin: .agent) == nil)
        #expect(host.fenceDenial(nodes: [node], origin: .user) != nil)
    }

    @Test func theStoreBackstopAgreesWithTheFence() {
        let host = SZHost()
        host.installStoreFenceBackstop()
        let node = SZNodeID()
        let turn = hold(node, on: host)
        // A funnel-bypassing write on a held node trips the tripwire…
        #expect(host.store.fenceBackstop?([node]) != nil)
        // …unless the write is the holding turn's own (the identity rides the task-local
        // into the store op's stack).
        SZToolCaller.$claim.withValue(turn) {
            #expect(host.store.fenceBackstop?([node]) == nil)
        }
    }
}

/// With runs concurrent, the agent exemption must be the CALLER's run — a holder-side check let
/// one run's Director delete and rewire nodes another run was mid-implementing.
@MainActor
struct SZHostCrossRunFenceTests {

    private func run(_ host: SZHost, _ node: SZNodeID, _ label: String) -> SZRunState {
        let claim = SZClaimToken(label: label)
        #expect(host.ledger.tryAcquire([.node(node), .transcript(.node(node))], as: claim))
        let state = SZRunState(taskID: UUID(), claim: claim, instruction: label,
                               ownsGraphOp: false, workSet: [node])
        host.activeRuns[state.taskID] = state
        return state
    }

    @Test func aRunsAgentMayTouchItsOwnWorkSet() {
        let host = SZHost()
        let mine = SZNodeID()
        let a = run(host, mine, "run a")
        SZToolCaller.$claim.withValue(a.claim) {
            #expect(host.fenceDenial(nodes: [mine], origin: .agent) == nil)
        }
    }

    @Test func aRunsAgentMayNotTouchAnotherRunsWorkSet() {
        let host = SZHost()
        let mine = SZNodeID(), theirs = SZNodeID()
        let a = run(host, mine, "run a")
        run(host, theirs, "run b")
        // Both are live runs, so a holder-side "is this ANY run's claim?" would wave this through.
        SZToolCaller.$claim.withValue(a.claim) {
            #expect(host.fenceDenial(nodes: [theirs], origin: .agent) != nil)
        }
    }
}

/// Delete is fenced one notch tighter than the rest: a node the fleet is still implementing keeps its
/// card live (it renders, and its knobs and wires are the user's) but cannot be removed, because there
/// is no undo. The hold releases at that node's own promote, not at run end.
@MainActor
struct SZHostDeleteHoldTests {

    /// A generated node whose contract sits ahead of what its build was compiled against.
    private func node(ports: [String], built: [String]) -> SZNode {
        let contract = SZNodeContract(title: "Plasma", sfSymbol: "waveform", summary: "",
                                      inputs: ports.map { SZPort(name: $0, type: .float) })
        let builtContract = SZNodeContract(title: "Plasma", sfSymbol: "waveform", summary: "",
                                           inputs: built.map { SZPort(name: $0, type: .float) })
        return SZNode(kind: .generated, title: "Plasma", contract: contract,
                      position: SZPoint(x: 0, y: 0),
                      buildStamp: SZBuildStamp(portSurface: builtContract.portSurface, prompt: nil))
    }

    /// Put one node in a host's project and hand it to a run that holds it.
    private func host(with node: SZNode, held: Bool = true) -> SZHost {
        let host = SZHost()
        host.store.setProject(SZProject(name: "t", graph: SZGraph(nodes: [node])))
        guard held else { return host }
        let claim = SZClaimToken(label: "run")
        #expect(host.ledger.tryAcquire([.node(node.id), .transcript(.node(node.id))], as: claim))
        let run = SZRunState(taskID: UUID(), claim: claim, instruction: "",
                             ownsGraphOp: false, workSet: [node.id])
        host.activeRuns[run.taskID] = run          // keyed by its OWN id, as the run path does
        return host
    }

    @Test func aNodeBeingRebuiltRefusesDeleteButStaysEditable() {
        let n = node(ports: ["amount", "warp"], built: ["amount"])
        let host = host(with: n)
        #expect(host.deleteDenial(nodes: [n.id], origin: .user) != nil)
        #expect(host.deleteHeldNodes.contains(n.id))
        // The card is NOT locked: it renders, so its knobs and wires stay the user's.
        #expect(host.fenceDenial(nodes: [n.id], origin: .user) == nil)
        #expect(!host.lockedNodes.contains(n.id))
    }

    @Test func theHoldReleasesAtThisNodesOwnPromote() {
        let n = node(ports: ["amount"], built: ["amount"])   // stamp caught up with the contract
        let host = host(with: n)
        // The run still holds it (siblings may still be building) — but this node is settled.
        #expect(host.ledger.holder(of: .node(n.id)) != nil)
        #expect(host.deleteDenial(nodes: [n.id], origin: .user) == nil)
        #expect(!host.deleteHeldNodes.contains(n.id))
    }

    @Test func aRebuildNobodyIsWorkingOnDeletesFreely() {
        let n = node(ports: ["amount", "warp"], built: ["amount"])
        let host = host(with: n, held: false)   // run ended without fixing it
        #expect(n.needsImplementation)
        #expect(host.deleteDenial(nodes: [n.id], origin: .user) == nil)
        #expect(host.deleteHeldNodes.isEmpty)
    }

    @Test func theDeleteFunnelItselfRefusesAndKeepsTheNode() {
        // `deleteDenial` in isolation proves the rule; this proves the rule is actually WIRED into the
        // one funnel every delete path goes through, and that it says why.
        let n = node(ports: ["amount", "warp"], built: ["amount"])
        let host = host(with: n)
        #expect(host.deleteNodes(ids: [n.id], origin: .user) == false)
        #expect(host.store.project?.graph.node(id: n.id) != nil)
        #expect(host.status.contains("rebuilt"))
    }

    @Test func theFunnelDeletesOnceThatNodeIsBuilt() {
        let n = node(ports: ["amount"], built: ["amount"])
        let host = host(with: n)
        #expect(host.deleteNodes(ids: [n.id], origin: .user))
        #expect(host.store.project?.graph.node(id: n.id) == nil)
    }

    @Test func theFleetMayStillDeleteItsOwnWorkSet() {
        let n = node(ports: ["amount", "warp"], built: ["amount"])
        let host = host(with: n)
        #expect(host.deleteDenial(nodes: [n.id], origin: .agent) == nil)
    }

    @Test func everythingTheLockAlreadyRefusedIsStillRefused() {
        let n = node(ports: ["amount"], built: ["amount"])   // settled, so only the lock can hold it
        let host = SZHost()
        host.store.setProject(SZProject(name: "t", graph: SZGraph(nodes: [n])))
        // A chat turn's claim is not a run claim, so the card locks outright.
        let turn = SZClaimToken(label: "chat turn 'Plasma'")
        #expect(host.ledger.tryAcquire([.node(n.id), .transcript(.node(n.id))], as: turn))
        #expect(host.lockedNodes.contains(n.id))
        #expect(host.deleteHeldNodes.contains(n.id))
        #expect(host.deleteDenial(nodes: [n.id], origin: .user) != nil)
    }
}
