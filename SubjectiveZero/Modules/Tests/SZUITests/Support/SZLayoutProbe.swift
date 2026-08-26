// SPDX-License-Identifier: AGPL-3.0-only
// Canvas geometry at one setting of the Live Previews gate. Production takes the gate as a
// required argument at every layout call, which is the point — but most assertions here are
// about the card anatomy, not the gate, so a suite states its setting once and its calls read
// as before. Argument labels mirror the real ones exactly, so a call site differs from the
// production spelling only in its prefix. No default: a suite says which gate it asserts about.
import CoreGraphics
import Foundation
@testable import SZUI
import SZCore

struct SZLayoutProbe {
    let previewsEnabled: Bool

    // MARK: card anatomy
    func height(of n: SZNode) -> CGFloat { SZNodeLayout.height(of: n, previewsEnabled: previewsEnabled) }
    func size(of n: SZNode) -> CGSize { SZNodeLayout.size(of: n, previewsEnabled: previewsEnabled) }
    func cardRect(of n: SZNode) -> CGRect { SZNodeLayout.cardRect(of: n, previewsEnabled: previewsEnabled) }
    func canFoldPlugs(_ n: SZNode) -> Bool { SZNodeLayout.canFoldPlugs(n, previewsEnabled: previewsEnabled) }
    func showsPlugs(of n: SZNode) -> Bool { SZNodeLayout.showsPlugs(of: n, previewsEnabled: previewsEnabled) }
    func foldDelta(of n: SZNode) -> CGFloat { SZNodeLayout.foldDelta(of: n, previewsEnabled: previewsEnabled) }
    func tier(of n: SZNode, zoomedOut: Bool) -> SZCardTier {
        SZNodeLayout.tier(of: n, zoomedOut: zoomedOut, previewsEnabled: previewsEnabled)
    }

    // MARK: sockets
    func flowY(of n: SZNode) -> CGFloat { SZNodeLayout.flowY(of: n, previewsEnabled: previewsEnabled) }
    func rowCenterY(of n: SZNode, row: Int) -> CGFloat {
        SZNodeLayout.rowCenterY(of: n, row: row, previewsEnabled: previewsEnabled)
    }
    func socketOffset(of n: SZNode, side: SZSocketSide, kind: SZConnectionKind, port: String) -> CGPoint {
        SZNodeLayout.socketOffset(of: n, side: side, kind: kind, port: port, previewsEnabled: previewsEnabled)
    }
    func socketPoint(of n: SZNode, side: SZSocketSide, kind: SZConnectionKind, port: String) -> CGPoint {
        SZGraphCanvasModel.socketPoint(of: n, side: side, kind: kind, port: port, previewsEnabled: previewsEnabled)
    }
    func sockets(of n: SZNode) -> [SZSocket] { SZGraphCanvasModel.sockets(of: n, previewsEnabled: previewsEnabled) }
    func sockets(in g: SZGraph) -> [SZSocket] { SZGraphCanvasModel.sockets(in: g, previewsEnabled: previewsEnabled) }
    func connectableSockets(of n: SZNode) -> [SZSocket] {
        SZGraphCanvasModel.connectableSockets(of: n, previewsEnabled: previewsEnabled)
    }

    // MARK: the graph
    func endpoints(of c: SZConnection, in g: SZGraph) -> (from: CGPoint, to: CGPoint)? {
        SZGraphCanvasModel.endpoints(of: c, in: g, previewsEnabled: previewsEnabled)
    }
    func worldBounds(of g: SZGraph) -> CGRect? { SZGraphCanvasModel.worldBounds(of: g, previewsEnabled: previewsEnabled) }
    func topmostNode(at p: CGPoint, in g: SZGraph, tiers: [SZNodeID: Int] = [:]) -> SZNode? {
        SZGraphCanvasModel.topmostNode(at: p, in: g, tiers: tiers, previewsEnabled: previewsEnabled)
    }
    func isOccluded(_ s: SZSocket, in g: SZGraph, tiers: [SZNodeID: Int] = [:]) -> Bool {
        SZGraphCanvasModel.isOccluded(s, in: g, tiers: tiers, previewsEnabled: previewsEnabled)
    }
    func isValidTarget(_ s: SZSocket, for source: SZSocket, in g: SZGraph, tiers: [SZNodeID: Int],
                       pickedConnectionID: SZConnectionID?, isLocked: (SZNodeID) -> Bool) -> Bool {
        SZGraphCanvasModel.isValidTarget(s, for: source, in: g, tiers: tiers,
                                         pickedConnectionID: pickedConnectionID,
                                         previewsEnabled: previewsEnabled, isLocked: isLocked)
    }
    func snapTarget(for source: SZSocket, at p: CGPoint, zoom: CGFloat, in g: SZGraph,
                    tiers: [SZNodeID: Int], pickedConnectionID: SZConnectionID?,
                    isLocked: (SZNodeID) -> Bool) -> SZSocket? {
        SZGraphCanvasModel.snapTarget(for: source, at: p, zoom: zoom, in: g, tiers: tiers,
                                      pickedConnectionID: pickedConnectionID,
                                      previewsEnabled: previewsEnabled, isLocked: isLocked)
    }
    func validTargets(for source: SZSocket, in g: SZGraph, tiers: [SZNodeID: Int],
                      pickedConnectionID: SZConnectionID?, isLocked: (SZNodeID) -> Bool) -> [SZSocket] {
        SZGraphCanvasModel.validTargets(for: source, in: g, tiers: tiers,
                                        pickedConnectionID: pickedConnectionID,
                                        previewsEnabled: previewsEnabled, isLocked: isLocked)
    }
    func pickupAnchor(detaching end: SZConnectionEnd, of c: SZConnection, in g: SZGraph) -> SZSocket? {
        SZGraphCanvasModel.pickupAnchor(detaching: end, of: c, in: g, previewsEnabled: previewsEnabled)
    }
    func detachableEnd(of c: SZConnection, grabbedAt p: CGPoint, in g: SZGraph) -> SZConnectionEnd? {
        SZGraphCanvasModel.detachableEnd(of: c, grabbedAt: p, in: g, previewsEnabled: previewsEnabled)
    }
    func visibleNodes(in g: SZGraph, camera: SZCanvasCamera, viewSize: CGSize) -> Set<SZNodeID> {
        SZCanvasVisibility.visibleNodes(in: g, camera: camera, viewSize: viewSize, previewsEnabled: previewsEnabled)
    }

    // MARK: wire drag
    func begin(from s: SZSocket, atWorld world: CGPoint, screen: CGPoint, in g: SZGraph,
               isLocked: (SZNodeID) -> Bool) -> SZWireDragSession? {
        SZWireDragSession.begin(from: s, atWorld: world, screen: screen, in: g,
                                previewsEnabled: previewsEnabled, isLocked: isLocked)
    }
    func begin(along c: SZConnection, atWorld world: CGPoint, screen: CGPoint,
               in g: SZGraph) -> SZWireDragSession? {
        SZWireDragSession.begin(along: c, atWorld: world, screen: screen, in: g, previewsEnabled: previewsEnabled)
    }
}
