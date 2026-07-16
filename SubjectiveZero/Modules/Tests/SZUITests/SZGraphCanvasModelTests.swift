// SPDX-License-Identifier: AGPL-3.0-only
// The pure canvas geometry — node layout (the vertical-stack anatomy), socket placement,
// connection endpoints, and the screen↔world transform. Headless so the visual editor's coordinates
// are pinned down without any rendering.
import CoreGraphics
import Foundation
import Testing
@testable import SZUI
import SZCore

private func cameraNode(at position: SZPoint = SZPoint(x: 100, y: 200)) -> SZNode {
    SZNode(
        kind: .generated, title: "MacBook Camera", sfSymbol: "camera",
        contract: SZNodeContract(
            title: "MacBook Camera", sfSymbol: "camera", summary: "live camera",
            inputs: [
                SZPort(name: "mirror", type: .bool, ui: SZPortUI(kind: .toggle), def: .bool(true)),
                SZPort(name: "camera", type: .enumeration, ui: SZPortUI(kind: .dropdown), def: .enumeration("default")),
            ],
            outputs: [SZPort(name: "texture", type: .texture, display: true)]),
        position: position,
        // Pin the COMPACT card: a texture output would otherwise auto-preview (nil body) and grow
        // every height/socket literal here by previewHeight. Preview geometry has its own file
        // (SZNodeLayoutPreviewTests); this one pins the classic anatomy.
        body: SZNodeBody(mode: .none))
}

private func promptNode(at position: SZPoint = SZPoint(x: 0, y: 0)) -> SZNode {
    SZNode(kind: .prompt, title: "New Node", prompt: "make it grayscale", position: position)
}

@Test func generatedNodeHeightCountsHeaderPlusEachPortRow() {
    // A LITERAL, not the same arithmetic `height(of:)` uses. Rebuilding `expected` from the very
    // constants under test makes the assertion move with any change to them — including `rowSpacing`,
    // which is currently 0 and so contributes nothing visible to a mirrored sum.
    // 40 header + 4 top + 3 rows × 24 + 2 gaps × 0 + 4 bottom = 120.
    let node = cameraNode()                      // 2 inputs + 1 output = 3 rows
    #expect(SZNodeLayout.height(of: node) == 120)
    #expect(SZNodeLayout.size(of: node).width == SZNodeLayout.width)
}

@Test func promptNodeIsASingleFieldRow() {
    #expect(SZNodeLayout.height(of: promptNode()) == SZNodeLayout.promptHeight)
}

@Test func inputSocketsSitOnLeftEdgeStackedByRow() {
    let node = cameraNode()
    let mirror = SZNodeLayout.socketOffset(of: node, side: .input, kind: .data, port: "mirror")
    let camera = SZNodeLayout.socketOffset(of: node, side: .input, kind: .data, port: "camera")
    #expect(mirror.x == -SZNodeLayout.width / 2)            // left edge
    #expect(camera.x == -SZNodeLayout.width / 2)
    #expect(camera.y > mirror.y)                            // 2nd input is below the 1st
    #expect(camera.y - mirror.y == SZNodeLayout.rowHeight + SZNodeLayout.rowSpacing)
}

@Test func outputTextureSocketSitsOnRightEdgeBelowInputs() {
    let node = cameraNode()
    let tex = SZNodeLayout.socketOffset(of: node, side: .output, kind: .data, port: "texture")
    let lastInput = SZNodeLayout.socketOffset(of: node, side: .input, kind: .data, port: "camera")
    #expect(tex.x == SZNodeLayout.width / 2)               // right edge
    #expect(tex.y > lastInput.y)                           // output row stacks after the inputs
}

@Test func flowSocketsRideTheHeaderSidesForGeneratedAndCenterForPrompt() {
    let gen = cameraNode()
    let outFlow = SZNodeLayout.socketOffset(of: gen, side: .output, kind: .flow, port: "")
    let inFlow = SZNodeLayout.socketOffset(of: gen, side: .input, kind: .flow, port: "")
    #expect(outFlow.x == SZNodeLayout.width / 2)
    #expect(inFlow.x == -SZNodeLayout.width / 2)
    #expect(outFlow.y == -SZNodeLayout.height(of: gen) / 2 + SZNodeLayout.headerHeight / 2)

    let prompt = promptNode()
    #expect(SZNodeLayout.socketOffset(of: prompt, side: .output, kind: .flow, port: "").y == 0)
}

@Test func promptNodeWithAContractStillSocketsAtTheFlowPosition() {
    // A camera prompt keeps its contract (to declare a permission) but renders as a short prompt
    // card with no port rows — so even a `data`/`texture` endpoint must sit at the flow side-center,
    // not at a generated-node row offset.
    let camera = SZNode(
        kind: .prompt, title: "MacBook Camera", sfSymbol: "camera",
        contract: SZNodeContract(title: "MacBook Camera", sfSymbol: "camera", summary: "cam",
                                 outputs: [SZPort(name: "texture", type: .texture, display: true)]),
        position: SZPoint(x: 0, y: 0))
    let tex = SZNodeLayout.socketOffset(of: camera, side: .output, kind: .data, port: "texture")
    #expect(tex.y == SZNodeLayout.flowY(of: camera))   // == 0, the prompt card center
    #expect(tex.x == SZNodeLayout.width / 2)
}

@Test func unknownDataPortFallsBackToFlowPosition() {
    let node = cameraNode()
    let bogus = SZNodeLayout.socketOffset(of: node, side: .input, kind: .data, port: "nope")
    #expect(bogus.y == SZNodeLayout.flowY(of: node))
}

@Test func socketPointIsCenteredOnNodePosition() {
    let node = cameraNode(at: SZPoint(x: 500, y: 300))
    let tex = SZGraphCanvasModel.socketPoint(of: node, side: .output, kind: .data, port: "texture")
    #expect(tex.x == 500 + SZNodeLayout.width / 2)
    #expect(tex.y == 300 + SZNodeLayout.socketOffset(of: node, side: .output, kind: .data, port: "texture").y)
}

@Test func connectionEndpointsResolveBothNodesOrNil() {
    let camera = cameraNode(at: SZPoint(x: 0, y: 0))
    let gray = SZNode(
        kind: .generated, title: "Grayscale", sfSymbol: "circle.lefthalf.filled",
        contract: SZNodeContract(title: "Grayscale", sfSymbol: "circle.lefthalf.filled", summary: "luma",
                                 inputs: [SZPort(name: "input", type: .texture)],
                                 outputs: [SZPort(name: "output", type: .texture, display: true)]),
        position: SZPoint(x: 400, y: 0))
    let conn = SZConnection(from: SZPortRef(node: camera.id, port: "texture"),
                            to: SZPortRef(node: gray.id, port: "input"), kind: .data)
    let graph = SZGraph(nodes: [camera, gray], connections: [conn],
                        renderEndpoint: SZPortRef(node: gray.id, port: "output"))
    let pts = SZGraphCanvasModel.endpoints(of: conn, in: graph)
    #expect(pts != nil)
    #expect(pts?.from.x == camera.position.x.cg + SZNodeLayout.width / 2)   // camera output right edge
    #expect(pts?.to.x == gray.position.x.cg - SZNodeLayout.width / 2)       // grayscale input left edge

    let dangling = SZConnection(from: SZPortRef(node: SZNodeID(), port: "x"),
                                to: SZPortRef(node: gray.id, port: "input"), kind: .data)
    #expect(SZGraphCanvasModel.endpoints(of: dangling, in: graph) == nil)
}

@Test func socketsEnumeratesFlowForAllPlusDataForGeneratedPorts() {
    let camera = cameraNode()                 // generated: 2 inputs + 1 output
    let prompt = promptNode()                 // prompt: flow only
    let graph = SZGraph(nodes: [camera, prompt])
    let cam = SZGraphCanvasModel.sockets(in: graph).filter { $0.nodeID == camera.id }
    let pr = SZGraphCanvasModel.sockets(in: graph).filter { $0.nodeID == prompt.id }
    // camera: 2 flow + 2 data-in + 1 data-out = 5
    #expect(cam.count == 5)
    #expect(cam.filter { $0.kind == .data }.map(\.port).sorted() == ["camera", "mirror", "texture"])
    // prompt: just the two flow sockets
    #expect(pr.count == 2)
    #expect(pr.allSatisfy { $0.kind == .flow })
}

@Test func canConnectEnforcesOppositeSidesSameKindAndDataTypes() {
    let camera = cameraNode(at: SZPoint(x: 0, y: 0))
    let gray = SZNode(
        kind: .generated, title: "Grayscale", sfSymbol: "circle.lefthalf.filled",
        contract: SZNodeContract(title: "Grayscale", sfSymbol: "circle.lefthalf.filled", summary: "luma",
                                 inputs: [SZPort(name: "input", type: .texture),
                                          SZPort(name: "amount", type: .float)],
                                 outputs: [SZPort(name: "output", type: .texture)]),
        position: SZPoint(x: 400, y: 0))
    let graph = SZGraph(nodes: [camera, gray])
    func sock(_ id: SZNodeID, _ side: SZSocketSide, _ kind: SZConnectionKind, _ port: String) -> SZSocket {
        SZGraphCanvasModel.sockets(in: graph).first { $0.nodeID == id && $0.side == side && $0.kind == kind && $0.port == port }!
    }
    let camTex = sock(camera.id, .output, .data, "texture")
    let grayIn = sock(gray.id, .input, .data, "input")
    let grayAmt = sock(gray.id, .input, .data, "amount")
    #expect(SZGraphCanvasModel.canConnect(camTex, grayIn, in: graph))        // texture→texture ✓
    #expect(SZGraphCanvasModel.canConnect(grayIn, camTex, in: graph))        // order-independent ✓
    #expect(!SZGraphCanvasModel.canConnect(camTex, grayAmt, in: graph))      // texture→float ✗
    #expect(!SZGraphCanvasModel.canConnect(camTex, sock(gray.id, .output, .data, "output"), in: graph)) // out→out ✗
    // flow is always allowed between opposite sides
    #expect(SZGraphCanvasModel.canConnect(sock(camera.id, .output, .flow, ""), sock(gray.id, .input, .flow, ""), in: graph))
    // no self-connection
    #expect(!SZGraphCanvasModel.canConnect(camTex, sock(camera.id, .input, .data, "mirror"), in: graph))
}

@Test func incomingDataConnectionResolvesOnlyForWiredDataInputs() {
    let camera = cameraNode(at: SZPoint(x: 0, y: 0))
    let gray = SZNode(
        kind: .generated, title: "Grayscale", sfSymbol: "circle.lefthalf.filled",
        contract: SZNodeContract(title: "Grayscale", sfSymbol: "circle.lefthalf.filled", summary: "luma",
                                 inputs: [SZPort(name: "input", type: .texture),
                                          SZPort(name: "amount", type: .float)],
                                 outputs: [SZPort(name: "output", type: .texture)]),
        position: SZPoint(x: 400, y: 0))
    let conn = SZConnection(from: SZPortRef(node: camera.id, port: "texture"),
                            to: SZPortRef(node: gray.id, port: "input"), kind: .data)
    let flow = SZConnection(from: SZPortRef(node: camera.id, port: "flow"),
                            to: SZPortRef(node: gray.id, port: "flow"), kind: .flow)
    let graph = SZGraph(nodes: [camera, gray], connections: [conn, flow])
    func sock(_ id: SZNodeID, _ side: SZSocketSide, _ kind: SZConnectionKind, _ port: String) -> SZSocket {
        SZGraphCanvasModel.sockets(in: graph).first { $0.nodeID == id && $0.side == side && $0.kind == kind && $0.port == port }!
    }
    // the wired data input resolves to its edge — this is the socket a pickup drag starts from
    #expect(SZGraphCanvasModel.incomingDataConnection(to: sock(gray.id, .input, .data, "input"), in: graph)?.id == conn.id)
    // unwired input, output, and flow sockets don't pick anything up
    #expect(SZGraphCanvasModel.incomingDataConnection(to: sock(gray.id, .input, .data, "amount"), in: graph) == nil)
    #expect(SZGraphCanvasModel.incomingDataConnection(to: sock(camera.id, .output, .data, "texture"), in: graph) == nil)
    #expect(SZGraphCanvasModel.incomingDataConnection(to: sock(gray.id, .input, .flow, ""), in: graph) == nil)
}

@Test func connectedSocketIDsMarksBothEndsNormalizingFlowPorts() {
    let camera = cameraNode(at: SZPoint(x: 0, y: 0))
    let gray = SZNode(
        kind: .generated, title: "Grayscale", sfSymbol: "circle.lefthalf.filled",
        contract: SZNodeContract(title: "Grayscale", sfSymbol: "circle.lefthalf.filled", summary: "luma",
                                 inputs: [SZPort(name: "input", type: .texture),
                                          SZPort(name: "amount", type: .float)],
                                 outputs: [SZPort(name: "output", type: .texture)]),
        position: SZPoint(x: 400, y: 0))
    let data = SZConnection(from: SZPortRef(node: camera.id, port: "texture"),
                            to: SZPortRef(node: gray.id, port: "input"), kind: .data)
    // a flow ref's port may be "flow" (ensureFlow) — the socket set must key it as "" (portless)
    let flow = SZConnection(from: SZPortRef(node: camera.id, port: "flow"),
                            to: SZPortRef(node: gray.id, port: "flow"), kind: .flow)
    let graph = SZGraph(nodes: [camera, gray], connections: [data, flow])
    let connected = SZGraphCanvasModel.connectedSocketIDs(in: graph)
    func sock(_ id: SZNodeID, _ side: SZSocketSide, _ kind: SZConnectionKind, _ port: String) -> SZSocket {
        SZGraphCanvasModel.sockets(in: graph).first { $0.nodeID == id && $0.side == side && $0.kind == kind && $0.port == port }!
    }
    // both ends of each edge light up, matching the sockets' own ids
    #expect(connected.contains(sock(camera.id, .output, .data, "texture").id))
    #expect(connected.contains(sock(gray.id, .input, .data, "input").id))
    #expect(connected.contains(sock(camera.id, .output, .flow, "").id))
    #expect(connected.contains(sock(gray.id, .input, .flow, "").id))
    // unwired sockets stay dim
    #expect(!connected.contains(sock(gray.id, .input, .data, "amount").id))
    #expect(!connected.contains(sock(gray.id, .output, .data, "output").id))
    // a picked-up wire is excluded → both its sockets dim, the flow edge's stay lit
    let withoutData = SZGraphCanvasModel.connectedSocketIDs(in: graph, excluding: data.id)
    #expect(!withoutData.contains(sock(camera.id, .output, .data, "texture").id))
    #expect(!withoutData.contains(sock(gray.id, .input, .data, "input").id))
    #expect(withoutData.contains(sock(camera.id, .output, .flow, "").id))
}

@Test func detachableEndIsTheEndpointNearerTheGrab() {
    let camera = cameraNode(at: SZPoint(x: 0, y: 0))
    let gray = SZNode(
        kind: .generated, title: "Grayscale", sfSymbol: "circle.lefthalf.filled",
        contract: SZNodeContract(title: "Grayscale", sfSymbol: "circle.lefthalf.filled", summary: "luma",
                                 inputs: [SZPort(name: "input", type: .texture)],
                                 outputs: [SZPort(name: "output", type: .texture)]),
        position: SZPoint(x: 400, y: 0))
    let conn = SZConnection(from: SZPortRef(node: camera.id, port: "texture"),
                            to: SZPortRef(node: gray.id, port: "input"), kind: .data)
    let graph = SZGraph(nodes: [camera, gray], connections: [conn])
    let pts = SZGraphCanvasModel.endpoints(of: conn, in: graph)!
    // grabbing near the output end detaches `from`; near the input end detaches `to`
    #expect(SZGraphCanvasModel.detachableEnd(of: conn, grabbedAt: CGPoint(x: pts.from.x + 10, y: pts.from.y), in: graph) == .from)
    #expect(SZGraphCanvasModel.detachableEnd(of: conn, grabbedAt: CGPoint(x: pts.to.x - 10, y: pts.to.y), in: graph) == .to)
    // an unresolvable edge (dangling endpoint) can't be picked up
    let dangling = SZConnection(from: SZPortRef(node: SZNodeID(), port: "x"),
                                to: SZPortRef(node: gray.id, port: "input"), kind: .data)
    #expect(SZGraphCanvasModel.detachableEnd(of: dangling, grabbedAt: .zero, in: graph) == nil)
}

@Test func pickupAnchorIsTheKeptEndWithCanvasPortConventions() {
    let camera = cameraNode(at: SZPoint(x: 0, y: 0))
    let gray = SZNode(
        kind: .generated, title: "Grayscale", sfSymbol: "circle.lefthalf.filled",
        contract: SZNodeContract(title: "Grayscale", sfSymbol: "circle.lefthalf.filled", summary: "luma",
                                 inputs: [SZPort(name: "input", type: .texture)],
                                 outputs: [SZPort(name: "output", type: .texture)]),
        position: SZPoint(x: 400, y: 0))
    let data = SZConnection(from: SZPortRef(node: camera.id, port: "texture"),
                            to: SZPortRef(node: gray.id, port: "input"), kind: .data)
    let flow = SZConnection(from: SZPortRef(node: camera.id, port: "flow"),
                            to: SZPortRef(node: gray.id, port: "flow"), kind: .flow)
    let graph = SZGraph(nodes: [camera, gray], connections: [data, flow])
    // detaching the input end anchors at the source output, and vice versa
    let keptOut = SZGraphCanvasModel.pickupAnchor(detaching: .to, of: data, in: graph)!
    #expect(keptOut.nodeID == camera.id && keptOut.side == .output && keptOut.port == "texture")
    #expect(keptOut.point == SZGraphCanvasModel.socketPoint(of: camera, side: .output, kind: .data, port: "texture"))
    let keptIn = SZGraphCanvasModel.pickupAnchor(detaching: .from, of: data, in: graph)!
    #expect(keptIn.nodeID == gray.id && keptIn.side == .input && keptIn.port == "input")
    // a flow anchor's port normalizes to the canvas socket convention ("", not the ref's "flow")
    let flowAnchor = SZGraphCanvasModel.pickupAnchor(detaching: .to, of: flow, in: graph)!
    #expect(flowAnchor.kind == .flow && flowAnchor.port == "")
    #expect(flowAnchor.point == SZGraphCanvasModel.socketPoint(of: camera, side: .output, kind: .flow, port: ""))
}

@Test func dataEdgeHiddenUntilBothPortsExistThenSnapsToRealPorts() {
    // camera generated (texture output exists), grayscale still a prompt (no ports): the data edge is
    // hidden (nil) — no blue edge landing on a flow socket; the companion flow edge shows instead.
    let camera = cameraNode(at: SZPoint(x: 0, y: 0))
    let grayscale = promptNode(at: SZPoint(x: 400, y: 0))
    let conn = SZConnection(from: SZPortRef(node: camera.id, port: "texture"),
                            to: SZPortRef(node: grayscale.id, port: "input"), kind: .data)
    #expect(SZGraphCanvasModel.endpoints(of: conn, in: SZGraph(nodes: [camera, grayscale], connections: [conn])) == nil)
    // once grayscale generates (gains an `input` texture port), the data edge appears at the real ports:
    let grayGen = SZNode(id: grayscale.id, kind: .generated, title: "G", sfSymbol: "g",
                         contract: SZNodeContract(title: "G", sfSymbol: "g", summary: "",
                                                  inputs: [SZPort(name: "input", type: .texture)],
                                                  outputs: [SZPort(name: "output", type: .texture)]),
                         position: SZPoint(x: 400, y: 0))
    let pts = SZGraphCanvasModel.endpoints(of: conn, in: SZGraph(nodes: [camera, grayGen], connections: [conn]))!
    #expect(pts.from.y == camera.position.y.cg + SZNodeLayout.socketOffset(of: camera, side: .output, kind: .data, port: "texture").y)
}

@Test func screenToWorldRoundTripsAtNonUnitZoom() {
    let zoom: CGFloat = 1.8
    let offset = CGSize(width: 40, height: -25)
    let world = CGPoint(x: 123, y: 456)
    // forward (what the canvas .scaleEffect.offset does): screen = world*zoom + offset
    let screen = CGPoint(x: world.x * zoom + offset.width, y: world.y * zoom + offset.height)
    let back = SZNodeLayout.worldPoint(screen: screen, zoom: zoom, offset: offset)
    #expect(abs(back.x - world.x) < 0.0001)
    #expect(abs(back.y - world.y) < 0.0001)
}

@Test func cardDimensionsAreGridPitchMultiples() {
    let pitch = SZNodeLayout.gridPitch
    #expect(SZNodeLayout.width.truncatingRemainder(dividingBy: pitch) == 0)
    // prompt card, empty generated card, and generated cards for 1...6 port rows all land on the pitch
    #expect(SZNodeLayout.promptHeight.truncatingRemainder(dividingBy: pitch) == 0)
    let bare = SZNode(id: UUID(), kind: .generated, title: "B", sfSymbol: "b", contract: nil,
                      position: SZPoint(x: 0, y: 0))
    #expect(SZNodeLayout.height(of: bare).truncatingRemainder(dividingBy: pitch) == 0)
    for rows in 1...6 {
        let node = SZNode(id: UUID(), kind: .generated, title: "N", sfSymbol: "n",
                          contract: SZNodeContract(title: "N", sfSymbol: "n", summary: "",
                                                   inputs: (0..<rows).map { SZPort(name: "in\($0)", type: .texture) },
                                                   outputs: []),
                          position: SZPoint(x: 0, y: 0))
        #expect(SZNodeLayout.height(of: node).truncatingRemainder(dividingBy: pitch) == 0)
    }
}

@Test func snappedCenterPutsCardEdgesOnGridLines() {
    let pitch = SZNodeLayout.gridPitch
    let size = CGSize(width: SZNodeLayout.width, height: SZNodeLayout.promptHeight)
    let center = SZNodeLayout.snappedCenter(CGPoint(x: 131, y: -7), size: size)
    let left = center.x - size.width / 2, top = center.y - size.height / 2
    #expect(left.truncatingRemainder(dividingBy: pitch) == 0)
    #expect(top.truncatingRemainder(dividingBy: pitch) == 0)
    // right/bottom follow because the dims are pitch multiples
    #expect((left + size.width).truncatingRemainder(dividingBy: pitch) == 0)
    #expect((top + size.height).truncatingRemainder(dividingBy: pitch) == 0)
    // idempotent: a card already edge-on-grid stays put
    #expect(SZNodeLayout.snappedCenter(center, size: size) == center)
}

@Test func snappedRoundsEachAxisToNearestGridIntersection() {
    let pitch = SZNodeLayout.gridPitch                       // 24
    #expect(SZNodeLayout.snapped(CGPoint(x: 11, y: 13)) == CGPoint(x: 0, y: pitch))    // below/above midpoint
    #expect(SZNodeLayout.snapped(CGPoint(x: 12, y: -12)) == CGPoint(x: pitch, y: -pitch))  // .5 rounds away from zero
    #expect(SZNodeLayout.snapped(CGPoint(x: -30, y: -37)) == CGPoint(x: -pitch, y: -2 * pitch))  // negative space
    #expect(SZNodeLayout.snapped(CGPoint(x: 48, y: -72)) == CGPoint(x: 48, y: -72))    // on-grid is a fixed point
    #expect(SZNodeLayout.snapped(CGPoint(x: 7, y: 7), pitch: 10) == CGPoint(x: 10, y: 10))  // explicit pitch
}

@Test func gridSpacingScalesWithZoomAndDoublesBelowMinimum() {
    let pitch = SZNodeLayout.gridPitch                       // 24
    #expect(SZDotGridView.effectiveSpacing(pitch: pitch, zoom: 1) == pitch)
    #expect(SZDotGridView.effectiveSpacing(pitch: pitch, zoom: 2.4) == pitch * 2.4)
    // min zoom (0.35): 24·0.35 = 8.4 < 16 → one doubling lands at 16.8
    #expect(abs(SZDotGridView.effectiveSpacing(pitch: pitch, zoom: 0.35) - 16.8) < 0.0001)
    // pathological zoom guard (max(zoom, 0.1)) still yields a finite spacing above the floor
    #expect(SZDotGridView.effectiveSpacing(pitch: pitch, zoom: 0) >= 16)
}

@Test func gridPhaseWrapsPanOffsetIntoOneTile() {
    #expect(SZDotGridView.phase(offset: 50, spacing: 24) == 2)
    #expect(SZDotGridView.phase(offset: -50, spacing: 24) == 22)   // negative pan → still in [0, spacing)
    #expect(SZDotGridView.phase(offset: 0, spacing: 24) == 0)
    let p = SZDotGridView.phase(offset: -0.0001, spacing: 24)
    #expect(p >= 0 && p < 24)
}

private extension Double { var cg: CGFloat { CGFloat(self) } }

// MARK: - Content-driven card width

private func zooNode() -> SZNode {
    SZNode(
        kind: .generated, title: "Control Zoo", sfSymbol: "slider.horizontal.3",
        contract: SZNodeContract(
            title: "Control Zoo", sfSymbol: "slider.horizontal.3", summary: "all the value widgets",
            inputs: [
                SZPort(name: "background", type: .float3, ui: SZPortUI(kind: .field), def: .float3([0, 0, 0])),
                SZPort(name: "corners", type: .float4, ui: SZPortUI(kind: .field), def: .float4([1, 1, 1, 1])),
            ],
            outputs: [SZPort(name: "texture", type: .texture, display: true)]),
        position: SZPoint(x: 0, y: 0))
}

@Test func shortContractsKeepTheBaseWidth() {
    #expect(SZNodeLayout.width(of: cameraNode()) == SZNodeLayout.width)
    #expect(SZNodeLayout.width(of: promptNode()) == SZNodeLayout.width)
}

@Test func wideRowsGrowTheCardGridAlignedAndCapped() {
    let node = zooNode()                                 // "background" + 3 fields needs > 216
    let w = SZNodeLayout.width(of: node)
    #expect(w > SZNodeLayout.width)
    #expect(w.truncatingRemainder(dividingBy: SZNodeLayout.gridPitch) == 0)
    #expect(w <= SZNodeLayout.gridPitch * 18)
    let fw = SZNodeLayout.numericFieldWidth(of: node)
    #expect(w >= SZNodeLayout.inputRowWidth(node.contract!.inputs[0], fieldWidth: fw))   // no truncation by construction
    #expect(w >= SZNodeLayout.inputRowWidth(node.contract!.inputs[1], fieldWidth: fw))
}

@Test func socketsRideTheAutoSizedEdges() {
    let node = zooNode()
    let w = SZNodeLayout.width(of: node)
    #expect(SZNodeLayout.socketOffset(of: node, side: .input, kind: .data, port: "corners").x == -w / 2)
    #expect(SZNodeLayout.socketOffset(of: node, side: .output, kind: .data, port: "texture").x == w / 2)
    #expect(SZNodeLayout.size(of: node).width == w)
}

// MARK: - Slider semantics (the clamp/step predicate itself now lives in SZCoreTests/SZPortSliderTests)

@Test func sliderKindWithoutValidRangeMeasuresAsNumericField() {
    // ui.kind == .slider but no min/max → the view renders numeric fields, so the width model must
    // include the default in the shared cell width instead of budgeting a slider row.
    let port = SZPort(name: "scale", type: .float, ui: SZPortUI(kind: .slider), def: .float(123.456))
    #expect(port.sliderRange == nil)
    #expect(!SZNodeLayout.numericComponents(port).isEmpty)
    let fw = SZNodeLayout.numericFieldWidth(values: [123.456])
    #expect(SZNodeLayout.controlWidth(port, fieldWidth: fw) == SZNodeLayout.numericFieldsRowWidth(count: 1, fieldWidth: fw))
}

@Test func sliderValueColumnFitsTheRangesWidestValue() {
    let narrow = SZNodeLayout.sliderValueColumnWidth(0...1)          // "0.00"/"1.00" → base 26
    let wide = SZNodeLayout.sliderValueColumnWidth(-0.5...20)        // "-0.50"/"20.00" → 5 chars
    #expect(narrow == 26)
    #expect(wide > narrow)
}

// MARK: - Width-model fidelity (review findings: grouping, spacing, padding)

@Test func numericLengthCountsGroupingSeparatorsTheCellsRender() {
    // The estimate must count characters with the SAME FormatStyle the cells render with — grouping
    // separators included (a %.3f mirror undercounted every |v| >= 1000).
    //
    // These are LITERALS on purpose. Asserting against `v.formatted(.number.precision(...)).count` is
    // the exact expression the implementation evaluates (SZNodeLayout.formattedNumericLength), so it
    // only proved Foundation is deterministic — a mirror that dropped grouping would have satisfied it
    // on both sides. Assumes a grouping locale (the separator, not its glyph, is what's counted).
    #expect(SZNodeLayout.formattedNumericLength(0) == 1)              // "0"
    #expect(SZNodeLayout.formattedNumericLength(-0.1) == 4)           // "-0.1"
    #expect(SZNodeLayout.formattedNumericLength(0.35) == 4)           // "0.35"
    #expect(SZNodeLayout.formattedNumericLength(123.456) == 7)        // "123.456" — below the group
    #expect(SZNodeLayout.formattedNumericLength(1234.5) == 7)         // "1,234.5" — one separator
    #expect(SZNodeLayout.formattedNumericLength(1234567.891) == 13)   // "1,234,567.891" — two separators

    // Grouped values must measure WIDER than their unseparated spelling — the property the %.3f mirror
    // violated, stated without reference to any format style at all.
    #expect(SZNodeLayout.formattedNumericLength(1234.5) > "1234.5".count)
    #expect(SZNodeLayout.formattedNumericLength(1234567.891) > "1234567.891".count)

    // Memoized behind a Mutex (SZNodeLayout.swift): a repeat read must agree with the first.
    #expect(SZNodeLayout.formattedNumericLength(1234.5) == 7)
}

@Test func inputRowWidthCountsBothSpacerSideGaps() {
    // 24 row padding + 1 char × 6.7 + BOTH 8pt spacer gaps + 40pt mini switch = 86.7. A literal, not the
    // implementation's own summands: mirroring them made the `2 *` (the whole point of this test) fold
    // into an identity, so dropping one gap would have moved both sides together.
    let port = SZPort(name: "x", type: .bool, ui: SZPortUI(kind: .toggle), def: .bool(false))
    #expect(SZNodeLayout.inputRowWidth(port, fieldWidth: 28) == 86.7)
}

@Test func numericComponentsZeroPadToTheRenderedCellCount() {
    let noDefault = SZPort(name: "m", type: .float3x3)
    #expect(SZNodeLayout.numericComponents(noDefault) == [0, 0, 0, 0])
    let vec = SZPort(name: "v", type: .float3, def: .float3([0.5]))
    #expect(SZNodeLayout.numericComponents(vec) == [0.5, 0, 0])
}

@Test func readOnlyStringBudgetsTheContentSizedChip() {
    let long = SZPort(name: "path", type: .string, ui: SZPortUI(kind: .field),
                      def: .string("assets/textures/noise-01.png"))
    #expect(SZNodeLayout.controlWidth(long, fieldWidth: 28)
        > SZNodeLayout.controlWidth(SZPort(name: "s", type: .string, def: .string("hi")), fieldWidth: 28))
}

// MARK: - Occlusion (review findings: buried dots must not catch wire drops)

@Test func socketUnderAHigherCardIsOccludedUntilItsNodeIsRaised() {
    // Two cards overlapping enough that A's right-edge sockets sit under B's card.
    let a = cameraNode(at: SZPoint(x: 100, y: 200))
    let b = cameraNode(at: SZPoint(x: 100 + Double(SZNodeLayout.width) / 2, y: 200))
    let graph = SZGraph(nodes: [a, b], connections: [])
    let buried = SZGraphCanvasModel.sockets(of: a).first { $0.side == .output && $0.kind == .data }!
    // Array order: B is later → above A → A's output dot is buried.
    #expect(SZGraphCanvasModel.isOccluded(buried, in: graph))
    // Raising A (selection tier) lifts its dots above B.
    #expect(!SZGraphCanvasModel.isOccluded(buried, in: graph, tiers: [a.id: 2]))
    // B's own dots are never occluded by B's card, and A's card is below them.
    let bSocket = SZGraphCanvasModel.sockets(of: b).first { $0.side == .input && $0.kind == .data }!
    #expect(!SZGraphCanvasModel.isOccluded(bSocket, in: graph))
}

// MARK: - what the canvas draws vs what a connection may target

/// The Director's core loop is: give a draft prompt node a contract, then wire it. Those ports exist as
/// soon as the contract lands, even though the prompt card keeps drawing only flow dots until the node is
/// implemented. Validating `ui_connect` against the DRAWING rule made that loop impossible — the Director
/// set three contracts, watched every data connect fail, and retried forever.
@Test func aPromptNodeWithAContractIsWirableEvenThoughItsCardDrawsNoDataDots() {
    var draft = SZNode(kind: .prompt, title: "Draft", position: SZPoint(x: 0, y: 0))
    draft.contract = SZNodeContract(
        title: "Draft", sfSymbol: "circle", summary: "",
        inputs: [SZPort(name: "input", type: .texture)],
        outputs: [SZPort(name: "output", type: .texture)])

    let connectable = SZGraphCanvasModel.connectableSockets(of: draft)
    #expect(connectable.contains { $0.kind == .data && $0.side == .input && $0.port == "input" })
    #expect(connectable.contains { $0.kind == .data && $0.side == .output && $0.port == "output" })

    // …while the canvas still draws only its flow sockets.
    let drawn = SZGraphCanvasModel.sockets(of: draft)
    #expect(drawn.allSatisfy { $0.kind == .flow })

    // And the edge itself is legal: a texture output into a texture input on another draft.
    var other = draft
    other = SZNode(kind: .prompt, title: "Other", position: SZPoint(x: 200, y: 0))
    other.contract = draft.contract
    var graph = SZGraph()
    graph.nodes = [draft, other]
    let out = SZGraphCanvasModel.connectableSockets(of: draft).first { $0.kind == .data && $0.side == .output }!
    let inp = SZGraphCanvasModel.connectableSockets(of: other).first { $0.kind == .data && $0.side == .input }!
    #expect(SZGraphCanvasModel.canConnect(out, inp, in: graph))
}

@Test func aContractlessDraftExposesOnlyFlowSockets() {
    let draft = SZNode(kind: .prompt, title: "Draft", position: SZPoint(x: 0, y: 0))
    #expect(SZGraphCanvasModel.connectableSockets(of: draft).allSatisfy { $0.kind == .flow })
}

// MARK: - Card rects, hit-testing, world bounds (the ONE cardRect shared by all geometry consumers)

@Test func cardRectIsCenteredOnNodePosition() {
    let node = promptNode(at: SZPoint(x: 100, y: 200))
    let rect = SZNodeLayout.cardRect(of: node)
    #expect(rect.midX == 100)
    #expect(rect.midY == 200)
    #expect(rect.size == SZNodeLayout.size(of: node))
}

@Test func worldBoundsUnionsEveryCardAndIsNilWhenEmpty() {
    let a = promptNode(at: SZPoint(x: 0, y: 0))
    let b = cameraNode(at: SZPoint(x: 600, y: 300))
    let bounds = SZGraphCanvasModel.worldBounds(of: SZGraph(nodes: [a, b], connections: []))
    #expect(bounds == SZNodeLayout.cardRect(of: a).union(SZNodeLayout.cardRect(of: b)))
    #expect(SZGraphCanvasModel.worldBounds(of: SZGraph(nodes: [], connections: [])) == nil)
}

@Test func topmostNodeBreaksTiesByDeclarationOrderAndRespectsTiers() {
    // Two prompt cards overlapping at the probe point: same tier → the LATER declaration renders
    // above and wins the hit; raising the first via `tiers` (selection) flips it — the mirror of
    // isOccluded's what-you-see-is-what-you-hit rule.
    let below = promptNode(at: SZPoint(x: 0, y: 0))
    let above = promptNode(at: SZPoint(x: 10, y: 10))
    let graph = SZGraph(nodes: [below, above], connections: [])
    let point = CGPoint(x: 5, y: 5)   // inside both cards
    #expect(SZGraphCanvasModel.topmostNode(at: point, in: graph)?.id == above.id)
    #expect(SZGraphCanvasModel.topmostNode(at: point, in: graph, tiers: [below.id: 2])?.id == below.id)
}

@Test func topmostNodeMissesOffCardPointsAndEmptyCanvas() {
    let node = promptNode(at: SZPoint(x: 0, y: 0))
    let graph = SZGraph(nodes: [node], connections: [])
    #expect(SZGraphCanvasModel.topmostNode(at: CGPoint(x: 10_000, y: 0), in: graph) == nil)
    #expect(SZGraphCanvasModel.topmostNode(at: .zero, in: SZGraph(nodes: [], connections: [])) == nil)
}
