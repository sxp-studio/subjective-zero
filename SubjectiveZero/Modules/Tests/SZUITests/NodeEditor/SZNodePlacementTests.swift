// SPDX-License-Identifier: AGPL-3.0-only
// Agent placement without coordinates: beside the node it reads from, or beside the graph.
import CoreGraphics
import SZCore
import Testing
@testable import SZUI

private func node(at x: Double, _ y: Double) -> SZNode {
    SZNode(kind: .generated, title: "N",
           contract: SZNodeContract(title: "N", sfSymbol: "circle", summary: "s",
                                    outputs: [SZPort(name: "output", type: .texture)]),
           position: SZPoint(x: x, y: y), body: SZNodeBody(mode: .none))
}

private let size = SZNodeLayout.promptCardSize

@Test func afterLandsOneColumnRightOnTheAnchorsRow() throws {
    let anchor = node(at: 0, 0)
    let graph = SZGraph(nodes: [anchor])
    let card = SZNodeLayout.cardRect(of: anchor, previewsEnabled: true)
    let placed = SZNodePlacement.after(anchor, size: size, in: graph, previewsEnabled: true)
    #expect(placed.x == card.maxX + SZGraphLayout.layerGap + size.width / 2)
    #expect(placed.y == card.midY)
}

@Test func aSecondAfterOnTheSameAnchorStepsBelowTheFirst() throws {
    let anchor = node(at: 0, 0)
    let first = SZNodePlacement.after(anchor, size: size, in: SZGraph(nodes: [anchor]), previewsEnabled: true)
    let taken = node(at: first.x, first.y)
    let graph = SZGraph(nodes: [anchor, taken])
    let second = SZNodePlacement.after(anchor, size: size, in: graph, previewsEnabled: true)
    #expect(second.x == first.x)
    let takenCard = SZNodeLayout.cardRect(of: taken, previewsEnabled: true)
    #expect(second.y - size.height / 2 >= takenCard.maxY + SZGraphLayout.nodeGap)
}

@Test func besideSitsRightOfTheGraphAndLeftForASource() throws {
    let a = node(at: 0, 0), b = node(at: 600, 300)
    let graph = SZGraph(nodes: [a, b])
    let bounds = try #require(SZGraphCanvasModel.worldBounds(of: graph, previewsEnabled: true))
    let right = SZNodePlacement.beside(graph: graph, size: size, previewsEnabled: true)
    #expect(right.x == bounds.maxX + SZGraphLayout.layerGap + size.width / 2)
    #expect(right.y == bounds.midY)
    let left = SZNodePlacement.beside(graph: graph, size: size, previewsEnabled: true, source: true)
    #expect(left.x == bounds.minX - SZGraphLayout.layerGap - size.width / 2)
}

@Test func anEmptyGraphKeepsTheOldDefaultSpot() {
    #expect(SZNodePlacement.beside(graph: SZGraph(), size: size, previewsEnabled: true)
            == SZNodePlacement.emptyGraphDefault)
}
