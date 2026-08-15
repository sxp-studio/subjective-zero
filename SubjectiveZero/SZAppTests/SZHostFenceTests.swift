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
        let run = hold(node, on: host, label: "run")
        host.runClaim = run
        defer { host.runClaim = nil }
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
