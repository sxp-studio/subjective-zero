// SPDX-License-Identifier: AGPL-3.0-only
// A run's work is not only code. A node can compile and read clean while an arrow into it was never
// wired, so its declared input reads nothing and it renders black. That state has to be able to start a
// run as well as keep one open, or Build answers "every node is built and current" over it.
import Foundation
import SZCore
import Testing
@testable import SubjectiveZero

@Suite("Arrows nobody wired are a run's work too")
@MainActor
struct SZHostUnwiredWorkTests {

    /// A built, clean node — nothing to implement, so `workSetCandidates` never sees it.
    private func built(_ title: String, inputs: [SZPort] = [], outputs: [SZPort] = []) -> SZNode {
        let contract = SZNodeContract(title: title, sfSymbol: "cube", summary: title,
                                      inputs: inputs, outputs: outputs)
        var node = SZNode(kind: .generated, title: title, contract: contract,
                          position: SZPoint(x: 0, y: 0))
        node.buildStamp = SZBuildStamp.trusting(contract: contract, prompt: node.prompt)
        return node
    }

    private func flow(_ a: SZNodeID, _ b: SZNodeID) -> SZConnection {
        SZConnection(from: SZPortRef(node: a, port: "flow"),
                     to: SZPortRef(node: b, port: "flow"), kind: .flow)
    }

    /// The reported graph: Depth Map → Point Cloud drawn, never wired, both built.
    private func pointCloudGraph() -> (SZGraph, SZNodeID, SZNodeID) {
        let depth = built("Depth Map", outputs: [SZPort(name: "depth", type: .texture)])
        let cloud = built("Point Cloud",
                          inputs: [SZPort(name: "depth", type: .texture),
                                   SZPort(name: "color", type: .texture)],
                          outputs: [SZPort(name: "scene", type: .texture)])
        return (SZGraph(nodes: [depth, cloud], connections: [flow(depth.id, cloud.id)]),
                depth.id, cloud.id)
    }

    @Test func aBuiltGraphWithNothingToCompileStillOffersWork() {
        let (graph, _, cloud) = pointCloudGraph()
        // The old read: nothing dirty, so nothing to run.
        let candidates = SZHost.workSetCandidates(in: graph.nodes, excluding: [])
        #expect(candidates.work.isEmpty)
        // The wiring read finds the node the arrow lands on, which is what lets Build proceed.
        #expect(SZHost.unwiredCandidates(in: graph, excluding: [], named: []) == [cloud])
    }

    @Test func aNodeAnotherRunHoldsIsNotThisRunsToWire() {
        let (graph, _, cloud) = pointCloudGraph()
        #expect(SZHost.unwiredCandidates(in: graph, excluding: [cloud], named: []).isEmpty)
    }

    @Test func aTaskThatNamedItsNodesTakesOnlyThose() {
        let (graph, depth, cloud) = pointCloudGraph()
        #expect(SZHost.unwiredCandidates(in: graph, excluding: [], named: [cloud]) == [cloud])
        // The arrow's source is not the work; wiring lands on the target.
        #expect(SZHost.unwiredCandidates(in: graph, excluding: [], named: [depth]).isEmpty)
    }

    @Test func anUndescribedNodeIsNotAdmittedByItsArrow() {
        // Dropping a flow wire on empty canvas mints a BLANK prompt node and an arrow into it in one
        // gesture. Admitting that node would brief a Coding Agent with no statement of what to build,
        // which is exactly what "an empty node is left as-is, never guessed" forbids — and unlike a
        // built target, a blank one IS `needsImplementation`, so it would really be dispatched.
        let source = built("Video File", outputs: [SZPort(name: "output", type: .texture)])
        let blank = SZNode(kind: .prompt, title: "New Node", prompt: "", position: SZPoint(x: 1, y: 0))
        let graph = SZGraph(nodes: [source, blank], connections: [flow(source.id, blank.id)])

        #expect(SZHost.unwiredCandidates(in: graph, excluding: [], named: []).isEmpty)
        #expect(SZHost.workSetCandidates(in: graph.nodes, excluding: []).work.isEmpty)

        // Described, it is ordinary build work and its arrow is ordinary wiring work.
        var described = graph
        described.nodes[1].prompt = "unproject the depth"
        #expect(SZHost.unwiredCandidates(in: described, excluding: [], named: []) == [blank.id])
    }

    @Test func anArrowWhoseSourceAnotherRunHoldsIsNotAdmitted() {
        // `ui_connect` fences on both ends, so an arrow out of a node a sibling run holds is always
        // refused. Admitting its target bought a whole Director round to reach that refusal.
        let (graph, depth, cloud) = pointCloudGraph()
        #expect(SZHost.unwiredCandidates(in: graph, excluding: [depth], named: []).isEmpty)
        #expect(SZHost.unwiredCandidates(in: graph, excluding: [], named: []) == [cloud])
    }

    @Test func anArrowTheDataAlreadySatisfiesIsNotWork() {
        // An arrow can outlive its own realization: laying an edge that already exists returns early.
        // Left counted, every Build press restarted the same paid run over wiring already in place.
        let (graph, depth, cloud) = pointCloudGraph()
        var wired = graph
        wired.connections.append(SZConnection(from: SZPortRef(node: depth, port: "depth"),
                                              to: SZPortRef(node: cloud, port: "depth"), kind: .data))
        #expect(SZHost.unwiredCandidates(in: wired, excluding: [], named: []).isEmpty)
        #expect(wired.unwiredNodes(in: [depth, cloud]).isEmpty)
    }

    @Test func aWiringOnlyNodeIsNotCountedAsBuilt() {
        // The receipt lie this exists to kill: the node was already built and this run only wired it,
        // so it is neither implemented nor failed — the run speaks for the work it actually did.
        let (graph, _, cloud) = pointCloudGraph()
        let host = SZHost()
        host.store.setProject(SZProject(name: "t", graph: graph))
        let run = SZRunState(taskID: UUID(), claim: SZClaimToken(label: "run"), instruction: "",
                             ownsGraphOp: false, workSet: [cloud], wiringOnly: [cloud])
        host.activeRuns[run.taskID] = run

        let counts = host.surfaceUnresolvedNodes(run)
        #expect(counts.implemented == 0 && counts.failed == 0)
        #expect(host.store.messages(for: .director).isEmpty)     // nothing to narrate about it
    }

    @Test func aWiringOnlyNodeThatBecomesRealWorkIsCountedAgain() {
        // It rejoins the tally the moment it stops being wiring-only: a re-brief mid-run leaves it
        // dirty, and a node that needs building is the run's business again.
        let (graph, _, cloud) = pointCloudGraph()
        let host = SZHost()
        host.store.setProject(SZProject(name: "t", graph: graph))
        let run = SZRunState(taskID: UUID(), claim: SZClaimToken(label: "run"), instruction: "",
                             ownsGraphOp: false, workSet: [cloud], wiringOnly: [cloud])
        host.activeRuns[run.taskID] = run
        host.store.updateNode(id: cloud, prompt: "a different brief entirely")   // now dirty

        let counts = host.surfaceUnresolvedNodes(run)
        #expect(counts.implemented == 0 && counts.failed == 1)
    }

    @Test func theBuildControlIsOfferedForWiringAlone() {
        // The affordance that reaches the admission rule. Nothing needs building, so the badge counts
        // zero — but the control has to be there, or the feature is unreachable on the one graph it
        // exists to fix.
        let (graph, _, _) = pointCloudGraph()
        let host = SZHost()
        host.store.setProject(SZProject(name: "t", graph: graph))
        #expect(host.pendingNodeCount == 0)
        #expect(host.wiringWorkAvailable)
        #expect(host.pendingWorkAvailable)
    }

    @Test func aBackwardsArrowDoesNotBuyARun() {
        // Drawn against an existing dependency, so its data edge would close a cycle and `ui_connect`
        // refuses it every time. Left admitted, a graph whose only arrow is this one started a full
        // Director round on every Build press to be told the same thing again.
        let (graph, depth, cloud) = pointCloudGraph()
        var backwards = graph
        backwards.connections = [
            SZConnection(from: SZPortRef(node: depth, port: "depth"),
                         to: SZPortRef(node: cloud, port: "depth"), kind: .data),
            flow(cloud, depth),
        ]
        #expect(SZHost.unwiredCandidates(in: backwards, excluding: [], named: []).isEmpty)
        // It is still unresolved intent, so a run started for other reasons still briefs it and the
        // Director still says why. Admission is the only thing it cannot trigger.
        #expect(backwards.unwiredNodes(in: [depth, cloud]) == [depth])
    }

    @Test func aFullyWiredGraphOffersNothing() {
        var (graph, depth, cloud) = pointCloudGraph()
        graph.connections = [SZConnection(from: SZPortRef(node: depth, port: "depth"),
                                          to: SZPortRef(node: cloud, port: "depth"), kind: .data)]
        #expect(SZHost.unwiredCandidates(in: graph, excluding: [], named: []).isEmpty)
        #expect(SZHost.unwiredCandidates(in: nil, excluding: [], named: []).isEmpty)
    }
}

/// What Build says when it finds nothing to build. The old line answered "every node is built and
/// current" over an arrow the user could see on the canvas, which is the same shape of lie as a green
/// badge over a black output.
@Suite("Build names the arrow it cannot wire")
@MainActor
struct SZNothingToImplementTests {

    private func built(_ title: String) -> SZNode {
        let contract = SZNodeContract(title: title, sfSymbol: "cube", summary: title,
                                      inputs: [SZPort(name: "in", type: .texture)],
                                      outputs: [SZPort(name: "out", type: .texture)])
        var node = SZNode(kind: .generated, title: title, contract: contract,
                          position: SZPoint(x: 0, y: 0))
        node.buildStamp = SZBuildStamp.trusting(contract: contract, prompt: node.prompt)
        return node
    }

    @Test func aCleanGraphStillSaysEverythingIsCurrent() {
        let a = built("A"), b = built("B")
        let graph = SZGraph(nodes: [a, b], connections: [
            SZConnection(from: SZPortRef(node: a.id, port: "out"),
                         to: SZPortRef(node: b.id, port: "in"), kind: .data)])
        #expect(SZHost.nothingToImplementNarration(in: graph).line
            == "Nothing to implement. Every node is built and current.")
        #expect(SZHost.nothingToImplementNarration(in: nil).status == "nothing to implement")
    }

    @Test func oneStuckArrowIsNamedWithBothWaysOut() {
        // A already feeds B, so the arrow back from B can never become a wire.
        let a = built("A"), b = built("B")
        let graph = SZGraph(nodes: [a, b], connections: [
            SZConnection(from: SZPortRef(node: a.id, port: "out"),
                         to: SZPortRef(node: b.id, port: "in"), kind: .data),
            SZConnection(from: .flow(node: b.id), to: .flow(node: a.id), kind: .flow)])

        let answer = SZHost.nothingToImplementNarration(in: graph)
        #expect(answer.line.contains("One arrow cannot be wired"))
        #expect(answer.line.contains("B → A → B"))            // the circle, in card names
        #expect(answer.line.contains("Delete it, or draw it the other way."))
        #expect(answer.status == "one arrow cannot be wired")
        #expect(!answer.line.contains("every node is built"))  // the old denial is gone
    }

    @Test func severalStuckArrowsAreCounted() {
        let a = built("A"), b = built("B"), c = built("C")
        let graph = SZGraph(nodes: [a, b, c], connections: [
            SZConnection(from: SZPortRef(node: a.id, port: "out"),
                         to: SZPortRef(node: b.id, port: "in"), kind: .data),
            SZConnection(from: SZPortRef(node: b.id, port: "out"),
                         to: SZPortRef(node: c.id, port: "in"), kind: .data),
            SZConnection(from: .flow(node: b.id), to: .flow(node: a.id), kind: .flow),
            SZConnection(from: .flow(node: c.id), to: .flow(node: a.id), kind: .flow)])

        let answer = SZHost.nothingToImplementNarration(in: graph)
        #expect(answer.line.contains("2 arrows cannot be wired"))
        #expect(answer.status == "2 arrows cannot be wired")
    }
}
