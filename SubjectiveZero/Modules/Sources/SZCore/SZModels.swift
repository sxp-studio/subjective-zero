// SPDX-License-Identifier: AGPL-3.0-only
// The canonical state model (docs/STATE.md, docs/BUILD_SPEC.md): App / Project / Graph / Node /
// Connection / Viewport. Pure value types, `Codable`, no Metal/macOS imports — the only package the
// others share.
//
// All public types take the `SZ` prefix (AGENTS.md guideline 1) even where BUILD_SPEC writes them bare.
// Connections live on the Graph (not the Node), so rewiring is a graph-level edit and nodes stay
// independently serializable.
import Foundation

// MARK: - Typed ids

// Just `UUID` under named aliases — zero-cost, but signatures read as intent (which UUID is which).
// `UUID` is already Codable (as a string), Hashable, and Sendable, so there's no wrapper to maintain.
// A node id is stable across the prompt → generated transition. (If we ever need compile-time
// node-vs-connection id safety, promote these to wrappers then.)
public typealias SZNodeID = UUID
public typealias SZConnectionID = UUID

// MARK: - Geometry

public struct SZPoint: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

public struct SZSize: Codable, Equatable, Sendable {
    public var width: Double
    public var height: Double
    public init(width: Double, height: Double) { self.width = width; self.height = height }
}

// MARK: - Viewport

public enum SZPixelFormat: String, Codable, Sendable {
    case bgra8Unorm
}

public struct SZViewport: Codable, Equatable, Sendable {
    public var zoom: Double
    public var translation: SZPoint
    public var fps: Int
    public var resolution: SZSize
    public var pixelFormat: SZPixelFormat

    public init(
        zoom: Double = 1.0,
        translation: SZPoint = SZPoint(x: 0, y: 0),
        fps: Int = 60,
        resolution: SZSize = SZSize(width: 1280, height: 720),
        pixelFormat: SZPixelFormat = .bgra8Unorm
    ) {
        self.zoom = zoom
        self.translation = translation
        self.fps = fps
        self.resolution = resolution
        self.pixelFormat = pixelFormat
    }
}

// MARK: - Nodes & connections

/// Whether a node HAS A BUILD — a compiled `Node.swift` the runtime can render. Monotonic: `promoteStagedNode`
/// is the only writer, and it only ever moves `prompt → generated`. Never flipped backward.
///
/// This is deliberately NOT "is the node up to date" — that is `SZNode.needsRebuild`, an orthogonal fact. A node
/// whose contract moved is both renderable (it still has last run's build) and pending work; `renderableSubgraph`
/// keys on `kind` alone, so flipping a drifted node back to `.prompt` would drop it from the render graph and
/// black it out.
public enum SZNodeKind: String, Codable, Sendable {
    case prompt, generated
}

/// Why a built node must be regenerated. Classified by the CONDITION of the code, not by who caused it — a
/// port the Director removed and a port a human deleted by hand leave the node equally broken.
public enum SZRebuildReason: String, Codable, Sendable {
    /// The contract declares ports the code doesn't implement yet. Nothing is wrong: the node draws, the new
    /// ports are simply inert until a Coding Agent writes them. The ordinary state between declaring an
    /// interface and building it — the sibling of a `.prompt` node's Draft.
    case contractChanged

    /// The code names ports the contract does not declare, so those reads resolve to `nil` every frame and the
    /// node silently falls back to its hardcoded defaults. A real fault: `agent_compile_node` refuses to
    /// promote source in this state (`SZPortBindingAudit` calls it an error, not a warning).
    case sourceMismatch
}

/// A graph node. Its `contract` is `nil` until a coding agent (or a hand-authored library node) drafts
/// it; on disk the contract lives in the node's folder (`node-contract.json`), not inline in
/// `project.json` — `SZProjectIO` splits/merges the two.
public struct SZNode: Codable, Identifiable, Equatable, Sendable {
    public let id: SZNodeID
    public var kind: SZNodeKind
    public var title: String
    public var sfSymbol: String
    public var prompt: String?
    public var contract: SZNodeContract?
    public var position: SZPoint

    /// Why this node's build no longer satisfies its contract, or nil when it does. Orthogonal to `kind`: a
    /// node awaiting a rebuild keeps rendering its existing source rather than going black.
    ///
    /// Raised by the port-delta store edit, which is the only place that can *know* a surface moved: after the
    /// fact, a declared-but-unread port is indistinguishable from a port whose name the code builds by
    /// interpolation (`SZPortBindingAudit` is a string-literal scan; `NodeLibrary/audio-bands` does exactly
    /// this). Cleared only by `promoteStagedNode`. `SZProjectIO.load` re-establishes it for files nothing
    /// vouches for.
    public var rebuildReason: SZRebuildReason?

    /// This node has a build that no longer fits its contract.
    public var needsRebuild: Bool { rebuildReason != nil }

    /// The fleet must (re)implement this node: it never had a build, or its build no longer fits its contract.
    /// The single question every "is there work here" reader should ask — as opposed to `kind`, which answers
    /// only "can this be rendered".
    public var needsImplementation: Bool { kind == .prompt || needsRebuild }

    public init(
        id: SZNodeID = SZNodeID(),
        kind: SZNodeKind = .prompt,
        title: String,
        sfSymbol: String = "sparkles",
        prompt: String? = nil,
        contract: SZNodeContract? = nil,
        position: SZPoint,
        rebuildReason: SZRebuildReason? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.sfSymbol = sfSymbol
        self.prompt = prompt
        self.contract = contract
        self.position = position
        self.rebuildReason = rebuildReason
    }
}

public enum SZConnectionKind: String, Codable, Sendable {
    case flow, data
}

/// A reference to one port of one node (`{ node, port }`). Used by connection endpoints and the render
/// endpoint.
public struct SZPortRef: Codable, Equatable, Hashable, Sendable {
    public var node: SZNodeID
    public var port: String
    public init(node: SZNodeID, port: String) { self.node = node; self.port = port }
}

public struct SZConnection: Codable, Identifiable, Equatable, Sendable {
    public let id: SZConnectionID
    public var from: SZPortRef
    public var to: SZPortRef
    public var kind: SZConnectionKind

    public init(id: SZConnectionID = SZConnectionID(), from: SZPortRef, to: SZPortRef, kind: SZConnectionKind) {
        self.id = id
        self.from = from
        self.to = to
        self.kind = kind
    }
}

/// One end of a connection, named after `SZConnection`'s fields — `from` is the output side, `to` the
/// input side. Used when re-routing an existing edge (the editor's pick-up drag names which end moves).
public enum SZConnectionEnd: String, Codable, Sendable {
    case from, to
}

// MARK: - Graph & project

/// The node DAG. `renderEndpoint` names the single texture output blitted to the viewport
/// (docs/RUNTIME.md) — exactly one at a time, user-toggleable later.
public struct SZGraph: Codable, Equatable, Sendable {
    public var nodes: [SZNode]
    public var connections: [SZConnection]
    public var renderEndpoint: SZPortRef?

    public init(nodes: [SZNode] = [], connections: [SZConnection] = [], renderEndpoint: SZPortRef? = nil) {
        self.nodes = nodes
        self.connections = connections
        self.renderEndpoint = renderEndpoint
    }

    public func node(id: SZNodeID) -> SZNode? { nodes.first { $0.id == id } }
}

/// One effect / document.
public struct SZProject: Codable, Equatable, Sendable {
    public var name: String
    public var author: String
    public var viewport: SZViewport
    public var graph: SZGraph

    public init(name: String, author: String = "", viewport: SZViewport = SZViewport(), graph: SZGraph = SZGraph()) {
        self.name = name
        self.author = author
        self.viewport = viewport
        self.graph = graph
    }
}

// MARK: - App-level prefs

public enum SZTheme: String, Codable, Sendable {
    case system, light, dark
}

/// One provider's remembered generation choices (model / reasoning effort / fast mode). All fields
/// optional and opaque: nil means "the provider's default"; values are validated against the
/// provider at resolution time, never at decode time (a stale model id in app-state.json degrades
/// to the default instead of failing the load).
public struct SZProviderGenerationSettings: Codable, Equatable, Sendable {
    public var model: String?
    public var reasoningEffort: String?
    public var fastMode: Bool?

    public init(model: String? = nil, reasoningEffort: String? = nil, fastMode: Bool? = nil) {
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.fastMode = fastMode
    }
}

/// App-level preferences (docs/STATE.md), persisted per-machine by SZAppStateIO (app-state.json in
/// Application Support — never in a project). `panelLayout` is live; windowSize/theme are still
/// dormant placeholders.
public struct SZAppState: Codable, Equatable, Sendable {
    public var windowSize: SZSize
    public var theme: SZTheme
    public var openProjectPath: String?
    /// The window's panel split tree + remembered reopen spots. Optional so files predating the
    /// rearrangeable layout (or hand-trimmed ones) still decode.
    public var panelLayout: SZPanelLayoutState?
    /// Node-editor snap-to-grid. Optional for the same decode-compatibility reason; nil means ON.
    public var snapToGrid: Bool?
    /// Panel headers hide until the cursor nears a tile's top edge (View ▸ Auto-Hide Panel
    /// Headers). Optional for the same decode-compatibility reason; nil means OFF.
    public var autoHidePanelHeaders: Bool?
    /// Node-editor cursor trail — grid dots morph into glyphs near the pointer (Graph ▸ Grid Cursor
    /// Trail). Optional for the same decode-compatibility reason; nil means ON.
    public var gridCursorTrail: Bool?
    /// Rounded corners on the viewport tile (View ▸ Rounded Viewport Corners). Off squares just the
    /// viewport; other tiles stay rounded. Optional for the same decode-compatibility reason; nil means ON.
    public var viewportRoundedCorners: Bool?
    /// The provider confirmed as default in the Agent Providers setup sheet. Optional for the
    /// same decode-compatibility reason; nil means setup hasn't been confirmed yet (the sheet
    /// auto-presents on launch until it is).
    public var defaultProviderID: String?
    /// File ▸ Open Recent, most recent first (`.subz` paths). Optional for the same
    /// decode-compatibility reason; nil means no recents yet.
    public var recentProjectPaths: [String]?
    /// Per-provider generation choices (model / reasoning effort / fast mode), keyed by provider
    /// id. Persisted immediately on change (a preference, unlike defaultProviderID's first-run
    /// confirmation gate). Optional for the same decode-compatibility reason; nil means all
    /// providers run on their defaults.
    public var providerGenerationSettings: [String: SZProviderGenerationSettings]?
    /// Show the welcome/home window on cold launch (Help ▸ Welcome reopens it any time). Optional
    /// for the same decode-compatibility reason; nil means ON (show by default).
    public var showWelcomeAtStartup: Bool?
    /// Show per-turn token counts next to the duration under chat replies (View ▸ Show Token
    /// Counts). Optional for the same decode-compatibility reason; nil means OFF. Display-only:
    /// usage is always captured into the transcript regardless.
    public var showTokenCounts: Bool?

    /// Open Recent's cap — recents beyond this fall off the end.
    public static let maxRecentProjects = 10

    public init(
        windowSize: SZSize = SZSize(width: 1440, height: 900),
        theme: SZTheme = .system,
        openProjectPath: String? = nil,
        panelLayout: SZPanelLayoutState? = nil,
        snapToGrid: Bool? = nil,
        autoHidePanelHeaders: Bool? = nil,
        gridCursorTrail: Bool? = nil,
        viewportRoundedCorners: Bool? = nil,
        defaultProviderID: String? = nil,
        recentProjectPaths: [String]? = nil,
        providerGenerationSettings: [String: SZProviderGenerationSettings]? = nil,
        showWelcomeAtStartup: Bool? = nil,
        showTokenCounts: Bool? = nil
    ) {
        self.windowSize = windowSize
        self.theme = theme
        self.openProjectPath = openProjectPath
        self.panelLayout = panelLayout
        self.snapToGrid = snapToGrid
        self.autoHidePanelHeaders = autoHidePanelHeaders
        self.gridCursorTrail = gridCursorTrail
        self.viewportRoundedCorners = viewportRoundedCorners
        self.defaultProviderID = defaultProviderID
        self.recentProjectPaths = recentProjectPaths
        self.providerGenerationSettings = providerGenerationSettings
        self.showWelcomeAtStartup = showWelcomeAtStartup
        self.showTokenCounts = showTokenCounts
    }

    /// Fold a just-opened project into the MRU list: dedupe (an existing entry moves to the front,
    /// not duplicates), newest first, capped at `maxRecentProjects`.
    public mutating func noteRecentProject(path: String) {
        var recents = recentProjectPaths ?? []
        recents.removeAll { $0 == path }
        recents.insert(path, at: 0)
        recentProjectPaths = Array(recents.prefix(Self.maxRecentProjects))
    }
}
