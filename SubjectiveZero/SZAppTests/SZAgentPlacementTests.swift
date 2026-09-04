// SPDX-License-Identifier: AGPL-3.0-only
// Agent-added nodes: where an add without coordinates lands (`after` a node, else beside the
// graph) and the one-shot reveal the host raises so the editor can slide them into view.
import Foundation
import Testing
import SZCore
import SZUI
@testable import SubjectiveZero

@MainActor
struct SZAgentPlacementTests {
    private let cameraID = SZNodeID()

    private func host() -> SZHost {
        let camera = SZNode(id: cameraID, kind: .generated, title: "Camera",
                            contract: SZNodeContract(title: "Camera", sfSymbol: "s", summary: "",
                                                     inputs: [],
                                                     outputs: [SZPort(name: "output", type: .texture, display: true)]),
                            position: SZPoint(x: 0, y: 0))
        let host = SZHost()
        host.snapToGrid = false   // exact placement math, no lattice rounding
        host.store.setProject(SZProject(name: "t", graph: SZGraph(nodes: [camera])))
        return host
    }

    private func placed(_ host: SZHost, _ arguments: [String: Any]) throws -> CGPoint {
        guard case .text(let reply) = try SZHostBridge(host: host)
            .callTool(name: "ui_add_prompt_node", arguments: arguments, callerScope: .director)
        else { throw SZMCPError.message("ui_add_prompt_node returned no text") }
        let json = try #require(try JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any])
        return CGPoint(x: try #require(json["x"] as? Double), y: try #require(json["y"] as? Double))
    }

    @Test func afterLandsTheCardOneColumnRightOfTheNodeItReadsFrom() throws {
        let host = host()
        let camera = try #require(host.store.project?.graph.node(id: cameraID))
        let card = SZNodeLayout.cardRect(of: camera, previewsEnabled: host.livePreviews)
        let point = try placed(host, ["after": cameraID.uuidString])
        #expect(point.x > card.maxX)
        #expect(point.y == card.midY)
    }

    @Test func explicitCoordinatesStillWin() throws {
        let point = try placed(host(), ["x": 1234.0, "y": 56.0, "after": cameraID.uuidString])
        #expect(point == CGPoint(x: 1234, y: 56))
    }

    @Test func aSingleGivenAxisIsHonouredAndTheOtherPlaced() throws {
        let host = host()
        let camera = try #require(host.store.project?.graph.node(id: cameraID))
        let card = SZNodeLayout.cardRect(of: camera, previewsEnabled: host.livePreviews)
        let point = try placed(host, ["y": -500.0, "after": cameraID.uuidString])
        #expect(point.x > card.maxX)
        #expect(point.y == -500)
    }

    @Test func noCoordinatesAndNoAnchorLandsBesideTheGraphNotAtAFixedSpot() throws {
        let host = host()
        let camera = try #require(host.store.project?.graph.node(id: cameraID))
        let card = SZNodeLayout.cardRect(of: camera, previewsEnabled: host.livePreviews)
        #expect(try placed(host, [:]).x > card.maxX)
    }

    @Test func anUnknownAnchorIsRefused() {
        #expect(throws: (any Error).self) {
            try placed(host(), ["after": SZNodeID().uuidString])
        }
    }

    @Test func anAgentAddRaisesOneRevealPerBurst() async throws {
        let host = host()
        _ = try placed(host, [:])
        _ = try placed(host, [:])
        #expect(host.cameraCommand == nil)   // debounced: nothing yet
        // The 80ms debounce runs on the main actor, which a full suite run can starve for a while;
        // wait for the command rather than for a fixed interval.
        for _ in 0..<50 where host.cameraCommand == nil {
            try await Task.sleep(for: .milliseconds(100))
        }
        let added = Set(host.store.project?.graph.nodes.map(\.id) ?? []).subtracting([cameraID])
        #expect(added.count == 2)
        #expect(host.cameraCommand?.action == .reveal(nodes: added, askedAt: nil))
    }
}
