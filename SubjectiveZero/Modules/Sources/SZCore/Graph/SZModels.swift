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
///
/// Never stored: `SZNode.rebuildReason` DERIVES it every read from evidence (the build stamp and the source
/// audit), so an edit that is undone heals by construction and a stale flag cannot outlive its cause.
public enum SZRebuildReason: String, Codable, Sendable {
    /// The contract's port surface differs from the one the build consumed (`SZBuildStamp.portSurface`).
    /// Nothing is wrong: the node draws, the new ports are simply inert until a Coding Agent writes them.
    /// The ordinary state between declaring an interface and building it — the sibling of a `.prompt` node's Draft.
    case contractChanged

    /// The node's intent moved: its prompt differs from the brief its build was written to (`SZBuildStamp.prompt`).
    /// Nothing is broken — the build still renders, it just implements what the prompt *used* to say — but the
    /// fleet must regenerate it against the new intent.
    case intentChanged

    /// The code names ports the contract does not declare, so those reads resolve to `nil` every frame and the
    /// node silently falls back to its hardcoded defaults. A real fault: `agent_compile_node` refuses to
    /// promote source in this state (`SZPortBindingAudit` calls it an error, not a warning). Ephemeral: the
    /// host re-audits at load, after every promote and after every hot reload (`SZNode.sourceMismatch`).
    case sourceMismatch
}

/// What a node's build CONSUMED — the evidence `SZNode.rebuildReason` is derived from. Written by
/// `promoteStagedNode` from what the compile actually saw (the merged contract's surface, the prompt the agent
/// was briefed with), and seeded once for a built node that has none ("trust the build": its current contract
/// + prompt). Persisted with the node in `project.json`.
public struct SZBuildStamp: Codable, Equatable, Sendable {
    /// The port surface the source was compiled against (`SZNodeContract.portSurface`).
    public var portSurface: Set<SZNodeContract.PortSignature>
    /// The brief the build implements — nil for a contract-first node built with no prompt.
    public var prompt: String?

    public init(portSurface: Set<SZNodeContract.PortSignature>, prompt: String?) {
        self.portSurface = portSurface
        self.prompt = prompt
    }

    /// The seed for a build nothing recorded: take the node's current contract + prompt as what it implements.
    public static func trusting(contract: SZNodeContract?, prompt: String?) -> SZBuildStamp {
        SZBuildStamp(portSurface: contract?.portSurface ?? [], prompt: prompt)
    }

    // The surface is written in a stable order (direction, name, type) so `project.json` does not churn
    // with Set iteration order between saves.
    private enum CodingKeys: String, CodingKey { case portSurface, prompt }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        portSurface = Set(try c.decode([SZNodeContract.PortSignature].self, forKey: .portSurface))
        prompt = try c.decodeIfPresent(String.self, forKey: .prompt)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        let ordered = portSurface.sorted {
            ($0.direction.rawValue, $0.name, $0.type.rawValue) < ($1.direction.rawValue, $1.name, $1.type.rawValue)
        }
        try c.encode(ordered, forKey: .portSurface)
        try c.encodeIfPresent(prompt, forKey: .prompt)
    }
}

/// What a generated node card renders between its header and its port rows. `nil` (the absent field on
/// every pre-existing `project.json`) means "unset" — the editor falls back to today's implicit behavior
/// (auto-preview a texture output). An explicit value pins the choice thereafter. Geometry-affecting, so it
/// is graph state (persisted with the node, like `position`), not page-local UI.
public enum SZNodeBodyMode: String, Codable, Sendable {
    /// Compact card: header + rows only, no body region.
    case none
    /// A live thumbnail of one of the node's texture outputs (TouchDesigner's Viewer).
    case preview
    /// An authored mini-UI — the node's runtime-compiled `Card.swift` — mounted into the body region.
    case custom
}

/// A `.custom` body's COMMITTED footprint — the region's `cols`/`rows` in GRID CELLS once auto-size or
/// the user set them (nil = the contract's `card` hints, then the defaults). The card itself is the
/// node's own `Card.swift`; there is nothing else to name. `pinned`: the user fixed the size — the
/// auto-measure loop must not override it.
public struct SZCustomCardRef: Codable, Equatable, Sendable {
    public var cols: Int?
    public var rows: Int?
    public var pinned: Bool?
    public init(cols: Int? = nil, rows: Int? = nil, pinned: Bool? = nil) {
        self.cols = cols
        self.rows = rows
        self.pinned = pinned
    }
}

/// A node card's body: which mode, plus the datum that mode needs. `previewPort` names the texture output a
/// `.preview` shows (nil = the display-marked/first texture output); `custom` carries a `.custom` body's
/// committed footprint (nil = defaults). `preview` and `custom` share the one body slot and are mutually
/// exclusive.
public struct SZNodeBody: Codable, Equatable, Sendable {
    public var mode: SZNodeBodyMode
    public var previewPort: String?
    public var custom: SZCustomCardRef?
    public init(mode: SZNodeBodyMode, previewPort: String? = nil, custom: SZCustomCardRef? = nil) {
        self.mode = mode
        self.previewPort = previewPort
        self.custom = custom
    }
}

public extension Array where Element == SZPort {
    /// The preferred texture output of a port list: the display-marked one, else the first. The ONE
    /// encoding of the default "which texture output represents this node" pick — the preview-port
    /// fallback and `ui_set_node_body` both resolve through it, so they can never disagree.
    var preferredTextureOutput: SZPort? {
        let textures = filter { $0.type == .texture }
        return textures.first { $0.display == true } ?? textures.first
    }
}

public extension SZNode {
    /// The body region this card EFFECTIVELY renders: an explicit `body` pins the choice; `nil` falls
    /// back to the legacy rule (a texture output → auto-preview). Validated against the CURRENT
    /// contract — a `.preview` pin on a node whose texture outputs vanished (rebuild, port edit)
    /// degrades to `.none` instead of reserving a body region nothing can ever fill. A `.custom` pin
    /// needs no texture output (a knob card drives a float); whether the `Card.swift` behind it
    /// compiles is the mount's business (the region reserves either way, so geometry never depends
    /// on a build).
    var effectiveBodyMode: SZNodeBodyMode {
        guard kind == .generated else { return .none }
        if body?.mode == .custom { return .custom }
        guard contract?.outputs.contains(where: { $0.type == .texture }) == true else { return .none }
        guard let body else { return .preview }
        return body.mode == .preview ? .preview : .none
    }

    /// The texture output this card's body shows live: for `.preview`, the explicit `previewPort`
    /// when it still names a texture output on the current contract, else the preferred texture
    /// output; for `.custom`, the contract's `card.backdrop` port when it names a texture output
    /// (the thumbnail drawn UNDER the custom card). Nil otherwise — so `nil`/non-nil IS the "does this
    /// node stream a thumb" predicate the preview watch-set keys on; callers never need to consult
    /// `effectiveBodyMode` separately.
    var effectivePreviewPort: String? {
        let outputs = contract?.outputs ?? []
        switch effectiveBodyMode {
        case .preview:
            if let pinned = body?.previewPort,
               outputs.contains(where: { $0.name == pinned && $0.type == .texture }) { return pinned }
            return outputs.preferredTextureOutput?.name
        case .custom:
            guard let backdrop = contract?.card?.backdrop,
                  outputs.contains(where: { $0.name == backdrop && $0.type == .texture }) else { return nil }
            return backdrop
        case .none:
            return nil
        }
    }
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

    /// What this node's build consumed — the evidence behind `rebuildReason`. nil until the node is built (or
    /// seeded on load for a built node that predates the stamp). Only `promoteStagedNode` writes it from a
    /// real compile; the derived-binding edits carry it along with the table-generic surface they add.
    public var buildStamp: SZBuildStamp?

    /// The host's audit verdict: the live source names ports the contract does not declare. Ephemeral — never
    /// encoded; recomputed from `SZPortBindingAudit` at load, after a promote and after a hot reload.
    public var sourceMismatch: Bool = false

    /// What the card renders between header and rows (preview thumbnail / the node's custom card / nothing).
    /// `nil` = unset; the editor applies its legacy auto-preview fallback. Presentation-only: never affects
    /// the render graph or a rebuild.
    public var body: SZNodeBody?

    /// Why this node's build no longer satisfies its contract or intent, or nil when it does. DERIVED, never
    /// stored: the audit fault outranks the stamp comparisons; a built node with no stamp is trusted. Orthogonal
    /// to `kind`: a node awaiting a rebuild keeps rendering its existing source rather than going black.
    public var rebuildReason: SZRebuildReason? {
        guard kind == .generated else { return nil }
        if sourceMismatch { return .sourceMismatch }
        guard let stamp = buildStamp else { return nil }
        if (contract?.portSurface ?? []) != stamp.portSurface { return .contractChanged }
        if prompt != stamp.prompt { return .intentChanged }
        return nil
    }

    /// This node has a build that no longer fits its contract or intent.
    public var needsRebuild: Bool { rebuildReason != nil }

    /// The identity a drawn node wears until someone names it. A promote treats these as unset — the
    /// agent's authored title/symbol fill them once — where a chosen identity is kept.
    public static let placeholderTitle = "New Node"
    public static let placeholderSymbol = "sparkles"

    /// The fleet must (re)implement this node: it never had a build, or its build no longer fits its contract.
    /// The single question every "is there work here" reader should ask — as opposed to `kind`, which answers
    /// only "can this be rendered".
    public var needsImplementation: Bool { kind == .prompt || needsRebuild }

    public init(
        id: SZNodeID = SZNodeID(),
        kind: SZNodeKind = .prompt,
        title: String,
        sfSymbol: String = SZNode.placeholderSymbol,
        prompt: String? = nil,
        contract: SZNodeContract? = nil,
        position: SZPoint,
        buildStamp: SZBuildStamp? = nil,
        sourceMismatch: Bool = false,
        body: SZNodeBody? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.sfSymbol = sfSymbol
        self.prompt = prompt
        self.contract = contract
        self.position = position
        self.buildStamp = buildStamp
        self.sourceMismatch = sourceMismatch
        self.body = body
    }

    /// `sourceMismatch` is host state, not document state: it stays out of `project.json`. A legacy stored
    /// `rebuildReason` key is ignored on decode — the reason is derived now.
    private enum CodingKeys: String, CodingKey {
        case id, kind, title, sfSymbol, prompt, contract, position, buildStamp, body
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

    /// The port marker of a node-to-node flow ref — the one home for the literal. (Flow SOCKETS key
    /// port as "".) A flow end naming any OTHER port is PINNED to that slot (`SZConnection.pinnedPort`).
    public static let flowMarker = "flow"

    /// A plain (unpinned) flow endpoint: `port` is the marker.
    public static func flow(node: SZNodeID) -> SZPortRef { SZPortRef(node: node, port: flowMarker) }

    /// Whether this ref's port is a flow marker ("" or "flow") rather than a pinned slot.
    public var isFlowMarker: Bool { port.isEmpty || port == Self.flowMarker }

    /// The port normalized for flow comparison: markers collapse to "flow", a pinned slot stays itself.
    public var flowPort: String { isFlowMarker ? Self.flowMarker : port }
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

    /// The contract port a flow edge's `end` is pinned to — the user dropped the flow wire on that
    /// specific data socket ("feed THIS slot") — or nil for a plain node-to-node flow end / data edge.
    public func pinnedPort(_ end: SZConnectionEnd) -> String? {
        guard kind == .flow else { return nil }
        let ref = end == .from ? from : to
        return ref.isFlowMarker ? nil : ref.port
    }

    /// Whether this is a flow arrow that the data edge `from`→`to` realizes: same node pair, and each
    /// pinned end (if any) is the very port the data edge uses.
    public func isFlowIntent(realizedBy from: SZPortRef, _ to: SZPortRef) -> Bool {
        kind == .flow && self.from.node == from.node && self.to.node == to.node
            && (pinnedPort(.from) ?? from.port) == from.port
            && (pinnedPort(.to) ?? to.port) == to.port
    }

    /// Whether two flow ends mean the same thing: same node, and same pin (markers "" / "flow" agree).
    public static func sameFlowEnd(_ a: SZPortRef, _ b: SZPortRef) -> Bool {
        a.node == b.node && a.flowPort == b.flowPort
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

/// A panel living in its own window instead of the main window's tile tree, with the window's
/// frame in AppKit screen coordinates (bottom-left origin) — enough to put the window back on
/// relaunch. The panel's dock-back spot rides `panelLayout.restorePositions`, not this record.
public struct SZPoppedOutPanel: Codable, Equatable, Sendable {
    public var panel: SZPanelID
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(panel: SZPanelID, x: Double, y: Double, width: Double, height: Double) {
        self.panel = panel
        self.x = x
        self.y = y
        self.width = width
        self.height = height
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
    /// Node-editor live previews — the global gate over per-node preview bodies (Graph ▸ Live
    /// Previews). Off collapses every preview region back to a compact card and stops the capture
    /// loop. Optional for the same decode-compatibility reason; nil means ON.
    public var livePreviews: Bool?
    /// Panel headers hide until the cursor nears a tile's top edge (View ▸ Auto-Hide Panel
    /// Headers). Optional for the same decode-compatibility reason; nil means OFF.
    public var autoHidePanelHeaders: Bool?
    /// Node-editor cursor trail — grid dots morph into glyphs near the pointer (Graph ▸ Grid Cursor
    /// Trail). Optional for the same decode-compatibility reason; nil means ON.
    public var gridCursorTrail: Bool?
    /// Node-editor mini map — the corner overview thumbnail (Graph ▸ Mini Map). Optional for the same
    /// decode-compatibility reason; nil means ON.
    public var showMiniMap: Bool?
    /// Rounded corners on the viewport tile (View ▸ Rounded Viewport Corners). Off squares just the
    /// viewport; other tiles stay rounded. Optional for the same decode-compatibility reason; nil means ON.
    public var viewportRoundedCorners: Bool?
    /// The provider confirmed as default in the Agent Providers setup sheet. Optional for the
    /// same decode-compatibility reason; nil means setup hasn't been confirmed yet (the sheet
    /// auto-presents on launch until it is).
    public var defaultProviderID: String?
    /// Providers the user disabled from the Agent Providers sheet: skipped by health checks and
    /// probes, dimmed in the composer picker, refused by pre-flights — the sheet card is the way
    /// back (Enable). Optional for the same decode-compatibility reason; nil means none disabled.
    public var disabledProviderIDs: [String]?
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
    /// Anonymous usage telemetry (the welcome screen's "Share anonymous usage data"). Optional
    /// for the same decode-compatibility reason; nil means ON.
    public var telemetryEnabled: Bool?
    /// Expandable per-turn debug breakdown under chat replies (Debug ▸ Show Turn Breakdown).
    /// Optional for the same decode-compatibility reason; nil means OFF. Display-only: collection
    /// is gated separately (the host's trace flag).
    public var showTurnBreakdown: Bool?
    /// Panels living in their own windows (pop-outs), with their screen frames — restored on
    /// relaunch as part of the workspace arrangement. Optional for the same decode-compatibility
    /// reason; nil means none popped out.
    public var poppedOutPanels: [SZPoppedOutPanel]?
    /// Saved routing profiles (AI Settings ▸ Routing). Stored raw, validated at resolution like
    /// every preference. Optional for the same decode-compatibility reason; nil means none saved.
    public var routingProfiles: [SZRoutingProfile]?
    /// The active profile's name; nil = routing off (every request byte-identical to no
    /// routing). A name no saved profile carries degrades to off at resolution, never at decode.
    public var activeRoutingProfileName: String?
    /// Open Recent's cap — recents beyond this fall off the end.
    public static let maxRecentProjects = 10

    public init(
        windowSize: SZSize = SZSize(width: 1440, height: 900),
        theme: SZTheme = .system,
        openProjectPath: String? = nil,
        panelLayout: SZPanelLayoutState? = nil,
        snapToGrid: Bool? = nil,
        livePreviews: Bool? = nil,
        autoHidePanelHeaders: Bool? = nil,
        gridCursorTrail: Bool? = nil,
        showMiniMap: Bool? = nil,
        viewportRoundedCorners: Bool? = nil,
        defaultProviderID: String? = nil,
        disabledProviderIDs: [String]? = nil,
        recentProjectPaths: [String]? = nil,
        providerGenerationSettings: [String: SZProviderGenerationSettings]? = nil,
        showWelcomeAtStartup: Bool? = nil,
        showTokenCounts: Bool? = nil,
        telemetryEnabled: Bool? = nil,
        showTurnBreakdown: Bool? = nil,
        poppedOutPanels: [SZPoppedOutPanel]? = nil,
        routingProfiles: [SZRoutingProfile]? = nil,
        activeRoutingProfileName: String? = nil
    ) {
        self.windowSize = windowSize
        self.theme = theme
        self.openProjectPath = openProjectPath
        self.panelLayout = panelLayout
        self.snapToGrid = snapToGrid
        self.livePreviews = livePreviews
        self.autoHidePanelHeaders = autoHidePanelHeaders
        self.gridCursorTrail = gridCursorTrail
        self.showMiniMap = showMiniMap
        self.viewportRoundedCorners = viewportRoundedCorners
        self.defaultProviderID = defaultProviderID
        self.disabledProviderIDs = disabledProviderIDs
        self.recentProjectPaths = recentProjectPaths
        self.providerGenerationSettings = providerGenerationSettings
        self.showWelcomeAtStartup = showWelcomeAtStartup
        self.showTokenCounts = showTokenCounts
        self.telemetryEnabled = telemetryEnabled
        self.showTurnBreakdown = showTurnBreakdown
        self.poppedOutPanels = poppedOutPanels
        self.routingProfiles = routingProfiles
        self.activeRoutingProfileName = activeRoutingProfileName
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
