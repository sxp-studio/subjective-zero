// SPDX-License-Identifier: AGPL-3.0-only
// The reconcile brief's `{{unwired}}` section — the arrows the run owes, named so the Director can lay
// each edge. The gate and this list share one derivation, so a run cannot loop back over an arrow the
// brief then fails to mention.
import Foundation
import Testing
import SZCore
@testable import SZAI

struct SZUnwiredBriefTests {

    private func renderer(_ templates: [String: String]) -> SZBriefRenderer {
        SZBriefRenderer { agent, path in
            guard let text = templates[path] else {
                throw SZBriefRenderError.missingTemplate(agent: agent, path: path)
            }
            return text
        }
    }

    private func flow(_ a: SZNodeID, _ b: SZNodeID, toPort: String = "flow") -> SZConnection {
        SZConnection(from: SZPortRef(node: a, port: "flow"),
                     to: SZPortRef(node: b, port: toPort), kind: .flow)
    }

    /// The Point Cloud shape: built, contract declares `depth` + `color`, both still just arrows.
    /// `unwiredArrows` is the run's captured set, as the host freezes it at admission.
    private func pointCloudWorld() -> (SZWorld, SZNodeID, SZNodeID) {
        let depth = SZNode(kind: .generated, title: "Depth Map",
                           contract: SZNodeContract(title: "Depth Map", sfSymbol: "cube", summary: "d",
                                                    outputs: [SZPort(name: "depth", type: .texture)]),
                           position: SZPoint(x: 0, y: 0))
        let cloud = SZNode(kind: .generated, title: "Point Cloud",
                           contract: SZNodeContract(title: "Point Cloud", sfSymbol: "rotate.3d", summary: "pc",
                                                    inputs: [SZPort(name: "depth", type: .texture),
                                                             SZPort(name: "color", type: .texture)],
                                                    outputs: [SZPort(name: "scene", type: .texture)]),
                           position: SZPoint(x: 1, y: 0))
        let arrow = flow(depth.id, cloud.id)
        var world = SZWorld(graph: SZGraph(nodes: [depth, cloud], connections: [arrow]))
        world.run = SZRun(workSet: [], round: 1, roundCap: 2, steers: [],
                          instruction: "build it", unwired: [cloud.id])
        world.unwiredArrows = [arrow]
        return (world, depth.id, cloud.id)
    }

    @Test func theBriefNamesBothEndsAndTheTargetsDeclaredPorts() throws {
        let r = renderer(["prompts/reconcile.md.mustache": "{{unwired}}"])
        let (world, depth, cloud) = pointCloudWorld()
        let out = try r.render(agent: "director", template: "reconcile", message: "", world: world)

        #expect(out.contains(depth.uuidString))
        #expect(out.contains(cloud.uuidString))
        #expect(out.contains("\"Depth Map\""))
        #expect(out.contains("\"Point Cloud\""))
        // The declared boundary rides along, so the Director knows which slot it is wiring into.
        #expect(out.contains("depth") && out.contains("color"))
    }

    @Test func aPinnedEndNamesTheExactSlotToWire() throws {
        let r = renderer(["prompts/reconcile.md.mustache": "{{unwired}}"])
        var (world, depth, cloud) = pointCloudWorld()
        let pinned = flow(depth, cloud, toPort: "color")
        world.graph?.connections = [pinned]
        world.unwiredArrows = [pinned]
        let out = try r.render(agent: "director", template: "reconcile", message: "", world: world)
        #expect(out.contains(".color"))
    }

    @Test func aRunOwingNoArrowsRendersTheEmptyLine() throws {
        let r = renderer(["prompts/reconcile.md.mustache": "{{unwired}}"])
        var (world, _, _) = pointCloudWorld()
        world.run?.unwired = []
        world.unwiredArrows = []
        let out = try r.render(agent: "director", template: "reconcile", message: "", world: world)
        #expect(out == "- (none)")
    }

    @Test func aLiveRunSeesOnlyTheArrowsItCapturedInTheGraphSection() throws {
        // The graph section a run reads lists that run's own arrows, same as `{{unwired}}`: the user
        // keeps drawing while the fleet works.
        let r = renderer(["prompts/decompose.md.mustache": "{{graph}}"])
        var (world, depth, cloud) = pointCloudWorld()
        world.graph?.connections.append(flow(cloud, depth))     // drawn after the run started

        let out = try r.render(agent: "director", template: "decompose", message: "", world: world)
        let arrows = out.split(separator: "\n").first { $0.hasPrefix("Flow edges") }.map(String.init) ?? ""
        #expect(arrows.contains(String(depth.uuidString.prefix(8))))
        #expect(arrows.components(separatedBy: "→").count == 2)   // exactly one arrow listed
    }

    @Test func aTurnWithNoRunStillSeesEveryArrow() throws {
        // The gate is the run, never the list being empty. A chat or debug turn has no run and no
        // captured arrows; reading emptiness as "scope to none" would tell it the graph has none.
        let r = renderer(["prompts/chat.md.mustache": "{{graph}}"])
        var (world, depth, cloud) = pointCloudWorld()
        world.run = nil
        world.unwiredArrows = []
        let out = try r.render(agent: "director", template: "chat", message: "", world: world)
        let arrows = out.split(separator: "\n").first { $0.hasPrefix("Flow edges") }.map(String.init) ?? ""
        #expect(arrows.contains(String(depth.uuidString.prefix(8))))
        #expect(arrows.contains(String(cloud.uuidString.prefix(8))))
    }

    @Test func anArrowTheRunNeverCapturedIsNotBriefed() throws {
        // `{{unwired}}` renders the run's captured arrows, never a live sweep. One drawn after the run
        // started is the next run's work; briefing it here would race the user's own drag.
        let r = renderer(["prompts/reconcile.md.mustache": "{{unwired}}"])
        var (world, depth, cloud) = pointCloudWorld()
        world.graph?.connections.append(flow(depth, cloud, toPort: "depth"))
        let out = try r.render(agent: "director", template: "reconcile", message: "", world: world)
        #expect(!out.contains(".depth"))                    // the mid-run pin is absent
        #expect(out.contains(cloud.uuidString))             // the captured arrow is still there
    }
}
