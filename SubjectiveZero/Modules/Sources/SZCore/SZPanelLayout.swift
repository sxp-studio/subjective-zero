// SPDX-License-Identifier: AGPL-3.0-only
// Panel layout (docs/STATE.md "App ├─ panel layout") — the window's arrangement of top-level panels
// as a binary split tree: a leaf is a panel, an interior node is a horizontal/vertical split with a
// fraction. Each SZPanelID (a kind plus an instance ordinal — kinds may repeat up to their
// `maxInstances`) appears at most once, so every mutation is addressed by SZPanelID (no node ids);
// only divider drags address a split, via a root-relative branch path.
//
// This is the pure, Codable model: geometry (rects, drop-zone hit-testing) lives in SZUI, rendering
// in SZPanelLayoutContainerView, and the live instance on SZHost. Persisted as local per-machine app
// state (SZAppState → app-state.json), NEVER in project.json — a project is a portable document and
// says nothing about how this machine's window is arranged.
import Foundation

/// A top-level panel of the app window. The raw value is the persisted key.
/// The debug-only panels (`.profiler`, `.agentGraph`) are LAST in `allCases` so the
/// production panels' ⌘⌥1/2/3 shortcuts never shift.
public enum SZPanelKind: String, Codable, CaseIterable, Hashable, Sendable {
    case viewport
    case nodeEditor
    case chat
    case profiler
    case agentGraph

    /// The name shown in the panel's header (its drag handle). Instance-qualified tiles append
    /// their display ordinal via `SZPanelID.displayName` ("Viewport 2").
    public var displayName: String {
        switch self {
        case .viewport: "Viewport"
        case .nodeEditor: "Node Editor"
        case .chat: "Chat"
        case .profiler: "Profiler"
        case .agentGraph: "Agent Graph"
        }
    }

    /// How many simultaneous tiles of this panel the layout may hold. Only the viewport is
    /// cloneable today; the mechanism is generic — normalize()'s instance strip, clonePanel's
    /// allocator, and the MCP token enumeration all read this, nothing names the viewport.
    public var maxInstances: Int {
        self == .viewport ? 8 : 1
    }

    /// Whether the Profiler panel surface exists in this build — debug-only for now. The CASE
    /// ships everywhere (Codable tolerance: a release build must decode a layout a DEBUG build
    /// saved); the SURFACE doesn't: `normalize()` strips the leaf and the View menu filters the
    /// toggle.
    public static var profilerPanelAvailable: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    /// Debug-only surfaces. The Profiler is one — its numbers only mean something next to a
    /// trace. The Agent Graph panel is NOT: what an agent does is authored content now, and
    /// the panel is how you read it, so it ships everywhere the packs do.
    public var isDebugOnly: Bool {
        self == .profiler
    }

    /// The kinds this build offers in menus/layouts.
    public static var availableCases: [SZPanelKind] {
        allCases.filter { !$0.isDebugOnly || profilerPanelAvailable }
    }

    /// The persisted-string decode shared by the kind's own Codable and the SZPanelID token
    /// parser: raw values plus one legacy alias (the panel briefly shipped, dev builds only, as
    /// "debug" before its rename to Profiler).
    init?(persisted raw: String) {
        if let kind = SZPanelKind(rawValue: raw) {
            self = kind
        } else if raw == "debug" {
            self = .profiler
        } else {
            return nil
        }
    }

    // Hand-written decode routing through the alias map: a failed kind decode would take the
    // whole app-state down with it, so map rather than throw where we can.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let kind = SZPanelKind(persisted: raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "unknown panel kind \(raw)"))
        }
        self = kind
    }
}

/// Stable identity of one panel tile: a kind plus an instance ordinal. Instance 0 is the primary —
/// the tile that existed before cloning; clones take 1..<kind.maxInstances. Persisted and
/// MCP-addressed as a single string token: "viewport" (the primary), "viewport:2", "viewport:3"…
/// The suffix is the DISPLAY ordinal (instance + 1), so "viewport:2" is exactly the tile titled
/// "Viewport 2" — one vocabulary for users, agents, and disk. Identity is STABLE: closing
/// Viewport 2 never renames Viewport 3 (restore records, popped-out windows, and future
/// per-instance render routing all hold these ids); the next clone fills the lowest free number,
/// so gaps are transient.
///
/// Deliberately NOT CodingKeyRepresentable: dictionaries keyed by SZPanelID must keep encoding as
/// the alternating flat array they used while keyed by SZPanelKind, so pre-instance app-state
/// bytes decode unchanged and clone-free state re-encodes byte-identically (old builds keep
/// reading new files until a clone actually exists).
public struct SZPanelID: Hashable, Codable, Sendable, Comparable {
    public var kind: SZPanelKind
    public var instance: Int

    public init(_ kind: SZPanelKind, instance: Int = 0) {
        self.kind = kind
        self.instance = instance
    }

    /// Primaries as named constants, so kind-literal call sites (`showPanel(.chat)`,
    /// `.panel(.viewport)`) read — and mostly compile — exactly as they did pre-instances.
    public static let viewport = SZPanelID(.viewport)
    public static let nodeEditor = SZPanelID(.nodeEditor)
    public static let chat = SZPanelID(.chat)
    public static let profiler = SZPanelID(.profiler)
    public static let agentGraph = SZPanelID(.agentGraph)

    /// The persisted/MCP token. The primary collapses to the bare kind string — that collapse is
    /// what keeps legacy app-state files and this model wire-compatible in both directions.
    public var token: String {
        instance == 0 ? kind.rawValue : "\(kind.rawValue):\(instance + 1)"
    }

    /// Lenient parse (any kind, any ordinal ≥ 2 — "chat:2" parses): normalize(), not the decoder,
    /// enforces per-kind caps, so a hand-edited overreach degrades one leaf instead of nuking the
    /// whole app-state decode. "viewport:0"/"viewport:1" are rejected — no second spelling of the
    /// primary — and the ordinal must be canonical (rejects "viewport:+2", "viewport:02").
    public init?(token: String) {
        let parts = token.split(separator: ":", omittingEmptySubsequences: false)
        guard let first = parts.first, let kind = SZPanelKind(persisted: String(first)) else { return nil }
        switch parts.count {
        case 1:
            self.init(kind)
        case 2:
            guard let ordinal = Int(parts[1]), ordinal >= 2, String(ordinal) == parts[1] else { return nil }
            self.init(kind, instance: ordinal - 1)
        default:
            return nil
        }
    }

    /// The IDENTITY name: "Viewport", "Viewport 2" — the token's ordinal, spelled out. Fallback
    /// only; user-facing surfaces show POSITIONAL titles from `displayTitles(for:)` instead, so
    /// visible numbers stay dense as instances come and go.
    public var displayName: String {
        instance == 0 ? kind.displayName : "\(kind.displayName) \(instance + 1)"
    }

    /// User-facing titles for the LIVE panel population (tiles + popped-out windows): a kind's
    /// lone instance keeps its plain name ("Viewport"); several live instances are numbered by
    /// POSITION in instance order — always a dense "Viewport 1", "Viewport 2", … whatever
    /// identity gaps exist underneath. Identity (tokens, records, routing) stays stable; only
    /// the label is positional, so closing "Viewport 2" of three relabels the third tile
    /// "Viewport 2" without renaming anything a record or agent holds.
    public static func displayTitles(for live: some Collection<SZPanelID>) -> [SZPanelID: String] {
        var titles: [SZPanelID: String] = [:]
        for group in Dictionary(grouping: Set(live), by: \.kind).values {
            let ranked = group.sorted()
            if ranked.count == 1 {
                titles[ranked[0]] = ranked[0].kind.displayName
            } else {
                for (rank, id) in ranked.enumerated() {
                    titles[id] = "\(id.kind.displayName) \(rank + 1)"
                }
            }
        }
        return titles
    }

    /// Whether the instance ordinal is one this build's cap allows — normalize()'s strip predicate.
    var isWithinInstanceCap: Bool {
        (0..<kind.maxInstances).contains(instance)
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let id = SZPanelID(token: raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "unknown panel token \(raw)"))
        }
        self = id
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(token)
    }

    /// (kind's allCases position, instance) — the stable tile order for ForEach identity and
    /// display listings; same guarantee `allCases` order gave kind-keyed tiles, now clone-aware.
    public static func < (a: SZPanelID, b: SZPanelID) -> Bool {
        let kinds = SZPanelKind.allCases
        let (ai, bi) = (kinds.firstIndex(of: a.kind)!, kinds.firstIndex(of: b.kind)!)
        return ai == bi ? a.instance < b.instance : ai < bi
    }
}

/// How a split arranges its two children.
public enum SZPanelSplitOrientation: String, Codable, Equatable, Sendable {
    case horizontal   // children side by side (the divider is a vertical line)
    case vertical     // children stacked (the divider is a horizontal line)
}

/// One step of a root-relative path into the tree (which child of a split to descend into).
public enum SZPanelSplitBranch: String, Codable, Equatable, Sendable {
    case leading      // left / top
    case trailing     // right / bottom
}

/// Root-relative address of a split node — the only tree addressing needed (divider drags).
public typealias SZPanelNodePath = [SZPanelSplitBranch]

/// Where on a target panel a dragged panel is dropped. Edges split the target; center swaps the two.
public enum SZPanelDropZone: String, Codable, Equatable, Sendable {
    case left, right, top, bottom, center
}

/// The layout tree. `fraction` is the leading child's share of the split axis (0…1).
public indirect enum SZPanelLayoutNode: Codable, Equatable, Sendable {
    case panel(SZPanelID)
    case split(orientation: SZPanelSplitOrientation, fraction: Double,
               leading: SZPanelLayoutNode, trailing: SZPanelLayoutNode)

    /// All panel leaves, leading-first (document order).
    public var leafIDs: [SZPanelID] {
        switch self {
        case .panel(let id): [id]
        case .split(_, _, let leading, let trailing): leading.leafIDs + trailing.leafIDs
        }
    }

    public func contains(_ id: SZPanelID) -> Bool {
        leafIDs.contains(id)
    }
}

/// Where a closed panel goes when reopened: split `neighbor` on `zone`, taking `share` of the split
/// axis — recorded on close so a reopen restores the spot the panel occupied. Docking a popped-out
/// panel back via its button rides the same record.
public struct SZPanelRestorePosition: Codable, Equatable, Sendable {
    public var neighbor: SZPanelID
    public var zone: SZPanelDropZone
    public var share: Double

    public init(neighbor: SZPanelID, zone: SZPanelDropZone, share: Double) {
        self.neighbor = neighbor
        self.zone = zone
        self.share = share
    }
}

/// The whole layout: the tree plus remembered reopen positions for closed panels.
public struct SZPanelLayoutState: Codable, Equatable, Sendable {
    public var root: SZPanelLayoutNode
    public var restorePositions: [SZPanelID: SZPanelRestorePosition]

    public init(root: SZPanelLayoutNode, restorePositions: [SZPanelID: SZPanelRestorePosition] = [:]) {
        self.root = root
        self.restorePositions = restorePositions
    }

    /// The launch layout (matches the pre-refactor SplitView arrangement): viewport over node editor,
    /// chat docked right.
    public static let `default` = SZPanelLayoutState(
        root: .split(orientation: .horizontal, fraction: 0.75,
                     leading: .split(orientation: .vertical, fraction: 0.6,
                                     leading: .panel(.viewport), trailing: .panel(.nodeEditor)),
                     trailing: .panel(.chat)))

    public var presentIDs: Set<SZPanelID> { Set(root.leafIDs) }
    public func contains(_ id: SZPanelID) -> Bool { root.contains(id) }

    // MARK: - Mutations (each caller should normalize() + persist after)

    /// Commit a header drag & drop: center → swap the two panels; edge → detach `id` and split
    /// `target` 50/50 with `id` on the zone's side. No-op if either panel is missing or they're
    /// the same.
    public mutating func movePanel(_ id: SZPanelID, onto target: SZPanelID, zone: SZPanelDropZone) {
        guard id != target, contains(id), contains(target) else { return }
        if zone == .center {
            root = root.swappingLeaves(id, target)
            return
        }
        // Detach first (target != id guarantees a leaf remains), then wrap the target leaf in a
        // fresh 50/50 split. The detach's restore record is irrelevant here — the panel is coming
        // right back — so restorePositions is left untouched.
        guard let detached = root.removingLeaf(id)?.remaining else { return }
        root = detached.replacingLeaf(target, with: Self.splitNode(around: target, inserting: id, zone: zone, share: 0.5))
    }

    /// Clone a tile: allocate the lowest free instance of `source.kind` and split the source
    /// 50/50 with the clone on `zone`'s side. `excluding` lets the caller reserve instances that
    /// live outside the tree (popped-out windows) so their identities are never reallocated.
    /// Returns the clone's id, or nil when the source is absent or every instance is taken.
    @discardableResult
    public mutating func clonePanel(_ source: SZPanelID, zone: SZPanelDropZone = .right,
                                    excluding: Set<SZPanelID> = []) -> SZPanelID? {
        guard contains(source) else { return nil }
        let used = Set(root.leafIDs.filter { $0.kind == source.kind }.map(\.instance))
            .union(excluding.filter { $0.kind == source.kind }.map(\.instance))
        guard let free = (0..<source.kind.maxInstances).first(where: { !used.contains($0) }) else { return nil }
        let clone = SZPanelID(source.kind, instance: free)
        root = root.replacingLeaf(source, with: Self.splitNode(around: source, inserting: clone, zone: zone, share: 0.5))
        return clone
    }

    /// Close a panel: collapse its parent split to the sibling and remember where it was so
    /// `insertPanel` can put it back. Refuses to remove the last panel.
    public mutating func removePanel(_ id: SZPanelID) {
        guard case .split = root, let removal = root.removingLeaf(id) else { return }
        root = removal.remaining
        if let record = removal.record { restorePositions[id] = record }
    }

    /// Reopen a panel at its remembered spot (fallback: a per-kind default edge of the whole window).
    /// Idempotent — no-op if the panel is already shown.
    public mutating func insertPanel(_ id: SZPanelID) {
        guard !contains(id) else { return }
        let fallback = Self.defaultRestorePosition(for: id)
        let position = restorePositions[id] ?? fallback
        if contains(position.neighbor) {
            root = root.replacingLeaf(position.neighbor,
                                      with: Self.splitNode(around: position.neighbor, inserting: id,
                                                           zone: position.zone, share: position.share))
        } else {
            // Remembered neighbor is gone (or the fallback names a hidden panel): split the whole
            // window instead, on the remembered side.
            root = Self.splitNodeAroundRoot(root, inserting: id, zone: position.zone, share: position.share)
        }
    }

    /// Dock a DETACHED panel at an explicit spot: split `target` with `id` on `zone`'s side taking
    /// `share` of the axis — the drag-to-dock commit, where the drop zone overrides any remembered
    /// position. No-op if `id` is already present or `target` absent. Callers resolve `.center` to
    /// an edge before committing (a detached panel has nothing to swap with).
    public mutating func insertPanel(_ id: SZPanelID, onto target: SZPanelID,
                                     zone: SZPanelDropZone, share: Double = 0.5) {
        guard !contains(id), contains(target) else { return }
        root = root.replacingLeaf(target, with: Self.splitNode(around: target, inserting: id, zone: zone, share: share))
    }

    /// Divider drag commit: set a split's fraction (leading child's share), min-clamped by normalize().
    public mutating func setFraction(_ fraction: Double, at path: SZPanelNodePath) {
        root = root.settingFraction(fraction, at: path)
    }

    /// The post-drop autolayout + decode sanitizer: clamp every fraction to 0.1…0.9 so no panel
    /// collapses to nothing, drop leaves this build can't host (Profiler without the surface,
    /// instances beyond the kind's cap — possible via a hand-edited or stale app-state.json), and
    /// reset to `.default` if the tree is malformed (duplicate or zero leaves).
    public mutating func normalize(allowingProfiler: Bool = SZPanelKind.profilerPanelAvailable) {
        // A layout saved by a DEBUG build may carry the Profiler into a build without the
        // surface — drop the leaves (collapse to their siblings) rather than render empty tiles.
        // Out-of-cap instances degrade the same way: one bad leaf, not the whole state.
        let hostable: (SZPanelID) -> Bool = { $0.isWithinInstanceCap && (allowingProfiler || !$0.kind.isDebugOnly) }
        while let bad = root.leafIDs.first(where: { !hostable($0) }) {
            if let removal = root.removingLeaf(bad) {
                root = removal.remaining
            } else {
                // The unhostable leaf IS the whole tree (e.g. a DEBUG session closed everything
                // but the Profiler) — land on the default layout, not an unremovable empty tile.
                self = .default
                return
            }
        }
        // One sweep prunes every unhostable restore record, stripped leaves included.
        restorePositions = restorePositions.filter { hostable($0.key) }
        let leaves = root.leafIDs
        guard !leaves.isEmpty, Set(leaves).count == leaves.count else {
            self = .default
            return
        }
        root = root.clampingFractions(to: 0.1...0.9)
    }

    // MARK: - Split construction

    /// A split placing `id` on `zone`'s side of `around`, with `share` of the axis.
    private static func splitNode(around target: SZPanelID, inserting id: SZPanelID,
                                  zone: SZPanelDropZone, share: Double) -> SZPanelLayoutNode {
        splitNodeAroundRoot(.panel(target), inserting: id, zone: zone, share: share)
    }

    private static func splitNodeAroundRoot(_ existing: SZPanelLayoutNode, inserting id: SZPanelID,
                                            zone: SZPanelDropZone, share: Double) -> SZPanelLayoutNode {
        switch zone {
        case .left:
            .split(orientation: .horizontal, fraction: share, leading: .panel(id), trailing: existing)
        case .right:
            .split(orientation: .horizontal, fraction: 1 - share, leading: existing, trailing: .panel(id))
        case .top:
            .split(orientation: .vertical, fraction: share, leading: .panel(id), trailing: existing)
        case .bottom, .center:   // center can't reach here via movePanel; treat like bottom for safety
            .split(orientation: .vertical, fraction: 1 - share, leading: existing, trailing: .panel(id))
        }
    }

    /// First-launch / forgotten-position defaults. Primaries mirror `.default`'s arrangement;
    /// a clone's fallback home is beside its own primary.
    private static func defaultRestorePosition(for id: SZPanelID) -> SZPanelRestorePosition {
        guard id.instance == 0 else {
            return SZPanelRestorePosition(neighbor: SZPanelID(id.kind), zone: .right, share: 0.5)
        }
        return switch id.kind {
        case .viewport: SZPanelRestorePosition(neighbor: .nodeEditor, zone: .top, share: 0.6)
        case .nodeEditor: SZPanelRestorePosition(neighbor: .viewport, zone: .bottom, share: 0.4)
        case .chat: SZPanelRestorePosition(neighbor: .viewport, zone: .right, share: 0.25)
        case .profiler: SZPanelRestorePosition(neighbor: .chat, zone: .bottom, share: 0.4)
        case .agentGraph: SZPanelRestorePosition(neighbor: .nodeEditor, zone: .right, share: 0.5)
        }
    }
}

// MARK: - Tree surgery (pure, non-public)

extension SZPanelLayoutNode {
    /// Result of detaching a leaf: the collapsed remaining tree, and where the leaf was (nil when the
    /// leaf WAS the whole tree — the caller decides whether that's allowed).
    struct SZPanelLeafRemoval {
        var remaining: SZPanelLayoutNode
        var record: SZPanelRestorePosition?
    }

    /// Detach `id`, collapsing its parent split to the sibling subtree. Returns nil if `id` is
    /// absent or is the root itself (nothing would remain).
    func removingLeaf(_ id: SZPanelID) -> SZPanelLeafRemoval? {
        guard case .split(let orientation, let fraction, let leading, let trailing) = self else { return nil }
        if case .panel(id) = leading {
            return SZPanelLeafRemoval(
                remaining: trailing,
                record: SZPanelRestorePosition(neighbor: trailing.leafIDs[0],
                                               zone: orientation == .horizontal ? .left : .top,
                                               share: fraction))
        }
        if case .panel(id) = trailing {
            return SZPanelLeafRemoval(
                remaining: leading,
                record: SZPanelRestorePosition(neighbor: leading.leafIDs[0],
                                               zone: orientation == .horizontal ? .right : .bottom,
                                               share: 1 - fraction))
        }
        if let sub = leading.removingLeaf(id) {
            return SZPanelLeafRemoval(
                remaining: .split(orientation: orientation, fraction: fraction, leading: sub.remaining, trailing: trailing),
                record: sub.record)
        }
        if let sub = trailing.removingLeaf(id) {
            return SZPanelLeafRemoval(
                remaining: .split(orientation: orientation, fraction: fraction, leading: leading, trailing: sub.remaining),
                record: sub.record)
        }
        return nil
    }

    /// Replace the `id` leaf with a subtree (used to wrap a drop target in a new split).
    func replacingLeaf(_ id: SZPanelID, with node: SZPanelLayoutNode) -> SZPanelLayoutNode {
        switch self {
        case .panel(id):
            node
        case .panel:
            self
        case .split(let orientation, let fraction, let leading, let trailing):
            .split(orientation: orientation, fraction: fraction,
                   leading: leading.replacingLeaf(id, with: node),
                   trailing: trailing.replacingLeaf(id, with: node))
        }
    }

    /// Swap two panel leaves in place (the tree shape and all fractions stay put).
    func swappingLeaves(_ a: SZPanelID, _ b: SZPanelID) -> SZPanelLayoutNode {
        switch self {
        case .panel(a): .panel(b)
        case .panel(b): .panel(a)
        case .panel: self
        case .split(let orientation, let fraction, let leading, let trailing):
            .split(orientation: orientation, fraction: fraction,
                   leading: leading.swappingLeaves(a, b), trailing: trailing.swappingLeaves(a, b))
        }
    }

    func settingFraction(_ fraction: Double, at path: SZPanelNodePath) -> SZPanelLayoutNode {
        guard case .split(let orientation, let current, let leading, let trailing) = self else { return self }
        guard let step = path.first else {
            return .split(orientation: orientation, fraction: fraction, leading: leading, trailing: trailing)
        }
        let rest = Array(path.dropFirst())
        return switch step {
        case .leading:
            .split(orientation: orientation, fraction: current,
                   leading: leading.settingFraction(fraction, at: rest), trailing: trailing)
        case .trailing:
            .split(orientation: orientation, fraction: current,
                   leading: leading, trailing: trailing.settingFraction(fraction, at: rest))
        }
    }

    func clampingFractions(to range: ClosedRange<Double>) -> SZPanelLayoutNode {
        switch self {
        case .panel:
            self
        case .split(let orientation, let fraction, let leading, let trailing):
            .split(orientation: orientation,
                   fraction: min(max(fraction, range.lowerBound), range.upperBound),
                   leading: leading.clampingFractions(to: range),
                   trailing: trailing.clampingFractions(to: range))
        }
    }
}
