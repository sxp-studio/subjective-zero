// SPDX-License-Identifier: AGPL-3.0-only
// Panel layout (docs/STATE.md "App ├─ panel layout") — the window's arrangement of top-level panels
// as a binary split tree: a leaf is a panel, an interior node is a horizontal/vertical split with a
// fraction. Each panel kind appears at most once, so every mutation is addressed by SZPanelKind (no
// node ids); only divider drags address a split, via a root-relative branch path.
//
// This is the pure, Codable model: geometry (rects, drop-zone hit-testing) lives in SZUI, rendering
// in SZPanelLayoutContainerView, and the live instance on SZHost. Persisted as local per-machine app
// state (SZAppState → app-state.json), NEVER in project.json — a project is a portable document and
// says nothing about how this machine's window is arranged.
import Foundation

/// A top-level panel of the app window. The raw value is the persisted key.
public enum SZPanelKind: String, Codable, CaseIterable, Hashable, Sendable {
    case viewport
    case nodeEditor
    case chat

    /// The name shown in the panel's header (its drag handle).
    public var displayName: String {
        switch self {
        case .viewport: "Viewport"
        case .nodeEditor: "Node Editor"
        case .chat: "Chat"
        }
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
    case panel(SZPanelKind)
    case split(orientation: SZPanelSplitOrientation, fraction: Double,
               leading: SZPanelLayoutNode, trailing: SZPanelLayoutNode)

    /// All panel leaves, leading-first (document order).
    public var leafKinds: [SZPanelKind] {
        switch self {
        case .panel(let kind): [kind]
        case .split(_, _, let leading, let trailing): leading.leafKinds + trailing.leafKinds
        }
    }

    public func contains(_ kind: SZPanelKind) -> Bool {
        leafKinds.contains(kind)
    }
}

/// Where a closed panel goes when reopened: split `neighbor` on `zone`, taking `share` of the split
/// axis — recorded on close so a reopen restores the spot the panel occupied.
public struct SZPanelRestorePosition: Codable, Equatable, Sendable {
    public var neighbor: SZPanelKind
    public var zone: SZPanelDropZone
    public var share: Double

    public init(neighbor: SZPanelKind, zone: SZPanelDropZone, share: Double) {
        self.neighbor = neighbor
        self.zone = zone
        self.share = share
    }
}

/// The whole layout: the tree plus remembered reopen positions for closed panels.
public struct SZPanelLayoutState: Codable, Equatable, Sendable {
    public var root: SZPanelLayoutNode
    public var restorePositions: [SZPanelKind: SZPanelRestorePosition]

    public init(root: SZPanelLayoutNode, restorePositions: [SZPanelKind: SZPanelRestorePosition] = [:]) {
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

    public var presentKinds: Set<SZPanelKind> { Set(root.leafKinds) }
    public func contains(_ kind: SZPanelKind) -> Bool { root.contains(kind) }

    // MARK: - Mutations (each caller should normalize() + persist after)

    /// Commit a header drag: center → swap the two panels; edge → detach `kind` and split `target`
    /// 50/50 with `kind` on the zone's side. No-op if either panel is missing or they're the same.
    public mutating func movePanel(_ kind: SZPanelKind, onto target: SZPanelKind, zone: SZPanelDropZone) {
        guard kind != target, contains(kind), contains(target) else { return }
        if zone == .center {
            root = root.swappingLeaves(kind, target)
            return
        }
        // Detach first (target != kind guarantees a leaf remains), then wrap the target leaf in a
        // fresh 50/50 split. The detach's restore record is irrelevant here — the panel is coming
        // right back — so restorePositions is left untouched.
        guard let detached = root.removingLeaf(kind)?.remaining else { return }
        root = detached.replacingLeaf(target, with: Self.splitNode(around: target, inserting: kind, zone: zone, share: 0.5))
    }

    /// Close a panel: collapse its parent split to the sibling and remember where it was so
    /// `insertPanel` can put it back. Refuses to remove the last panel.
    public mutating func removePanel(_ kind: SZPanelKind) {
        guard case .split = root, let removal = root.removingLeaf(kind) else { return }
        root = removal.remaining
        if let record = removal.record { restorePositions[kind] = record }
    }

    /// Reopen a panel at its remembered spot (fallback: a per-kind default edge of the whole window).
    /// Idempotent — no-op if the panel is already shown.
    public mutating func insertPanel(_ kind: SZPanelKind) {
        guard !contains(kind) else { return }
        let fallback = Self.defaultRestorePosition(for: kind)
        let position = restorePositions[kind] ?? fallback
        if contains(position.neighbor) {
            root = root.replacingLeaf(position.neighbor,
                                      with: Self.splitNode(around: position.neighbor, inserting: kind,
                                                           zone: position.zone, share: position.share))
        } else {
            // Remembered neighbor is gone (or the fallback names a hidden panel): split the whole
            // window instead, on the remembered side.
            root = Self.splitNodeAroundRoot(root, inserting: kind, zone: position.zone, share: position.share)
        }
    }

    /// Divider drag commit: set a split's fraction (leading child's share), min-clamped by normalize().
    public mutating func setFraction(_ fraction: Double, at path: SZPanelNodePath) {
        root = root.settingFraction(fraction, at: path)
    }

    /// The post-drop autolayout + decode sanitizer: clamp every fraction to 0.1…0.9 so no panel
    /// collapses to nothing, and reset to `.default` if the tree is malformed (duplicate or zero
    /// leaves — possible via a hand-edited or stale app-state.json, never via the mutations above).
    public mutating func normalize() {
        let leaves = root.leafKinds
        guard !leaves.isEmpty, Set(leaves).count == leaves.count else {
            self = .default
            return
        }
        root = root.clampingFractions(to: 0.1...0.9)
    }

    // MARK: - Split construction

    /// A split placing `kind` on `zone`'s side of `around`, with `share` of the axis.
    private static func splitNode(around target: SZPanelKind, inserting kind: SZPanelKind,
                                  zone: SZPanelDropZone, share: Double) -> SZPanelLayoutNode {
        splitNodeAroundRoot(.panel(target), inserting: kind, zone: zone, share: share)
    }

    private static func splitNodeAroundRoot(_ existing: SZPanelLayoutNode, inserting kind: SZPanelKind,
                                            zone: SZPanelDropZone, share: Double) -> SZPanelLayoutNode {
        switch zone {
        case .left:
            .split(orientation: .horizontal, fraction: share, leading: .panel(kind), trailing: existing)
        case .right:
            .split(orientation: .horizontal, fraction: 1 - share, leading: existing, trailing: .panel(kind))
        case .top:
            .split(orientation: .vertical, fraction: share, leading: .panel(kind), trailing: existing)
        case .bottom, .center:   // center can't reach here via movePanel; treat like bottom for safety
            .split(orientation: .vertical, fraction: 1 - share, leading: existing, trailing: .panel(kind))
        }
    }

    /// First-launch / forgotten-position defaults, mirroring `.default`'s arrangement.
    private static func defaultRestorePosition(for kind: SZPanelKind) -> SZPanelRestorePosition {
        switch kind {
        case .viewport: SZPanelRestorePosition(neighbor: .nodeEditor, zone: .top, share: 0.6)
        case .nodeEditor: SZPanelRestorePosition(neighbor: .viewport, zone: .bottom, share: 0.4)
        case .chat: SZPanelRestorePosition(neighbor: .viewport, zone: .right, share: 0.25)
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

    /// Detach `kind`, collapsing its parent split to the sibling subtree. Returns nil if `kind` is
    /// absent or is the root itself (nothing would remain).
    func removingLeaf(_ kind: SZPanelKind) -> SZPanelLeafRemoval? {
        guard case .split(let orientation, let fraction, let leading, let trailing) = self else { return nil }
        if case .panel(kind) = leading {
            return SZPanelLeafRemoval(
                remaining: trailing,
                record: SZPanelRestorePosition(neighbor: trailing.leafKinds[0],
                                               zone: orientation == .horizontal ? .left : .top,
                                               share: fraction))
        }
        if case .panel(kind) = trailing {
            return SZPanelLeafRemoval(
                remaining: leading,
                record: SZPanelRestorePosition(neighbor: leading.leafKinds[0],
                                               zone: orientation == .horizontal ? .right : .bottom,
                                               share: 1 - fraction))
        }
        if let sub = leading.removingLeaf(kind) {
            return SZPanelLeafRemoval(
                remaining: .split(orientation: orientation, fraction: fraction, leading: sub.remaining, trailing: trailing),
                record: sub.record)
        }
        if let sub = trailing.removingLeaf(kind) {
            return SZPanelLeafRemoval(
                remaining: .split(orientation: orientation, fraction: fraction, leading: leading, trailing: sub.remaining),
                record: sub.record)
        }
        return nil
    }

    /// Replace the `kind` leaf with a subtree (used to wrap a drop target in a new split).
    func replacingLeaf(_ kind: SZPanelKind, with node: SZPanelLayoutNode) -> SZPanelLayoutNode {
        switch self {
        case .panel(kind):
            node
        case .panel:
            self
        case .split(let orientation, let fraction, let leading, let trailing):
            .split(orientation: orientation, fraction: fraction,
                   leading: leading.replacingLeaf(kind, with: node),
                   trailing: trailing.replacingLeaf(kind, with: node))
        }
    }

    /// Swap two panel leaves in place (the tree shape and all fractions stay put).
    func swappingLeaves(_ a: SZPanelKind, _ b: SZPanelKind) -> SZPanelLayoutNode {
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
