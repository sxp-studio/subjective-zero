// SPDX-License-Identifier: AGPL-3.0-only
// The seam between the host and whatever renders a project: the Metal runtime for a native project, the
// browser runtime for a web one. Only what both implement for real; a backend's own extras (surfaces,
// captures, recording) stay on the concrete type.
import Foundation
import IOSurface

/// Result of a compile-check (`compileNodeSource`). `.failed` carries the compiler log for the agent's
/// fix loop / `debug_get_build_errors`.
public enum SZBuildResult: Sendable, Equatable {
    case ok
    case failed(String)
}

/// One published thumbnail frame, whichever renderer drew it: the surface goes straight to
/// `CALayer.contents`. Publishers alternate two surfaces per port (the compositor may still be reading
/// the one on screen), so every frame is a new identity, which is what makes the layer recomposite.
public struct SZNodePreviewSurface: @unchecked Sendable {
    public let node: SZNodeID
    public let port: String
    public let surface: IOSurface

    public init(node: SZNodeID, port: String, surface: IOSurface) {
        self.node = node
        self.port = port
        self.surface = surface
    }

    /// A BGRA8 surface sized for one thumbnail; row bytes rounded to IOSurface's own alignment.
    public static func makeSurface(width: Int, height: Int) -> IOSurface? {
        let bytesPerRow = IOSurfaceAlignProperty(kIOSurfaceBytesPerRow as CFString, width * 4)
        return IOSurface(properties: [
            .width: width,
            .height: height,
            .bytesPerElement: 4,
            .bytesPerRow: bytesPerRow,
            .pixelFormat: UInt32(0x4247_5241),   // 'BGRA'
        ])
    }
}

/// What a backend can do beyond drawing the graph. The host and UI gate features on these, never on
/// the project's target, so a backend that gains a feature changes one line here.
public struct SZBackendCapabilities: Sendable, Equatable {
    /// Records the viewport to a movie file.
    public var canRecord: Bool
    /// Streams node output thumbnails to the editor.
    public var streamsPreviews: Bool
    /// Mounts custom cards (a node's `Card.swift`).
    public var supportsCards: Bool
    /// Clones and pops out the viewport tile.
    public var supportsViewportClones: Bool
    /// Reads one node's output texture back (`agent_view_frame` with `node`).
    public var readsNodeOutputs: Bool
    /// Exports the project as one standalone web page.
    public var exportsWebApp: Bool

    public init(canRecord: Bool, streamsPreviews: Bool, supportsCards: Bool,
                supportsViewportClones: Bool, readsNodeOutputs: Bool, exportsWebApp: Bool) {
        self.canRecord = canRecord
        self.streamsPreviews = streamsPreviews
        self.supportsCards = supportsCards
        self.supportsViewportClones = supportsViewportClones
        self.readsNodeOutputs = readsNodeOutputs
        self.exportsWebApp = exportsWebApp
    }

    /// The Metal runtime.
    public static let native = SZBackendCapabilities(
        canRecord: true, streamsPreviews: true, supportsCards: true, supportsViewportClones: true,
        readsNodeOutputs: true, exportsWebApp: false)
    /// The browser page.
    public static let web = SZBackendCapabilities(
        canRecord: false, streamsPreviews: true, supportsCards: false, supportsViewportClones: false,
        readsNodeOutputs: false, exportsWebApp: true)
}

/// What the host drives a renderer through, on the main actor; each backend guards its own state
/// (the Metal runtime's witnesses are nonisolated and lock inside).
@MainActor
public protocol SZRenderBackend: AnyObject {
    var capabilities: SZBackendCapabilities { get }
    /// Load a project's graph, replacing any live one. `project` is the host's in-memory document,
    /// already saved under `url`, which is where node sources are read from.
    func loadProject(_ project: SZProject, at url: URL) throws
    /// Recompile + hot-swap a single node's source in place. No-op if the node isn't loaded.
    func reloadNode(id: SZNodeID, source: URL) throws
    /// The compile gate for one staged source, without loading it: swiftc for a Mac node, a parse and
    /// a run on the page for a web one. `node` supplies the contract the check seeds inputs from.
    func checkNodeSource(at source: URL, for node: SZNode) async -> SZBuildResult
    /// The viewport as drawn, as a PNG with the long edge at most `maxDimension`; nil before the
    /// first frame.
    func captureViewport(maxDimension: Int) async -> Data?
    /// True if `id` has a live, loaded module.
    func isNodeLoaded(_ id: SZNodeID) -> Bool
    /// Override a node's scalar input live.
    func setInputValue(node: SZNodeID, port: String, floats: [Float])
    /// Override a node's string/enum input live.
    func setInputString(node: SZNodeID, port: String, string: String)
    /// Drop a node's live override for one input.
    func clearInput(node: SZNodeID, port: String)
    /// Re-point the live render endpoint; nil clears it.
    func setRenderEndpoint(_ ref: SZPortRef?)
    /// Pause/resume the playback clock.
    func setPaused(_ paused: Bool)
    var isPaused: Bool { get }
    /// Rewind the playback clock to the start.
    func resetTimeline()
    /// Install the sink for node-reported faults. Fires only when the reported set changes and carries
    /// the whole set; runs off the main actor.
    func setNodeErrorCallback(_ callback: (@Sendable ([SZNodeID: String]) -> Void)?)
    /// Replace the node outputs streamed as thumbnails, `maxDimension` the long edge in pixels. Pushed on
    /// watch-list changes only, never per frame.
    func setWatchedPreviews(_ requests: [(node: SZNodeID, port: String)], maxDimension: Int)
    /// Install the thumbnail sink. Fires off the main actor after each publish; hop and return.
    func setPreviewFrameCallback(_ callback: (@Sendable ([SZNodePreviewSurface]) -> Void)?)
}
