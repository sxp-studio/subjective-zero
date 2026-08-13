// SPDX-License-Identifier: AGPL-3.0-only
// The little status pill that floats above a node, reflecting the node's workflow state. Derived in
// the panel from the node kind, the run-active flag, and the host's live per-node status
// (agent_report_status → queued/coding/ok/needsInput/error). Amber = working, green = ready,
// red = error.
import AppKit
import Foundation
import SwiftUI

/// A shared 0…1 pulse driven off the wall clock, so independent pulsing views — the status pill and the
/// structural-op glow — stay phase-locked (same `date` in → same phase out), rather than each running its
/// own `@State` animation that drifts. One full cycle = `period` seconds (0→1→0, smooth).
enum SZPulse {
    static let period: Double = 1.4
    static func phase(at date: Date) -> Double {
        0.5 - 0.5 * cos(date.timeIntervalSinceReferenceDate * 2 * .pi / period)
    }
}

public enum SZNodeStatus: Sendable {
    case draft           // a prompt node, not (yet) being worked on
    case planning        // queued / the Director is planning
    case building        // a Coding Agent is writing this node's Swift (mirrors the HUD Build button)
    case ready           // generated + compiled, and its code still fits its contract
    case outdated        // built and still rendering, but its contract declares ports its code hasn't implemented
    case reloading       // recompiling this node's hand-edited Node.swift (hot reload)
    case needsInput      // the agent asked for clarification
    case error           // the agent/build failed
    case splitting       // this node is being split (its stages are being implemented)
    case merging         // this node is being merged into another

    var label: String {
        switch self {
        case .draft: "Draft"
        case .planning: "Planning"
        case .building: "Building"
        case .ready: "Ready"
        case .outdated: "Outdated"
        case .reloading: "Reloading"
        case .needsInput: "Needs Input"
        case .error: "Error"
        case .splitting: "Splitting"
        case .merging: "Merging"
        }
    }

    var color: Color {
        switch self {
        case .draft: Color(red: 0.32, green: 0.52, blue: 0.85)   // blue — a resting draft, calmer than reloading
        case .planning, .building: .orange
        case .ready: .green
        // amber — the node still draws and nothing failed; its code just hasn't caught up with its contract
        case .outdated: Color(red: 0.85, green: 0.60, blue: 0.20)
        case .reloading: Color(red: 0.30, green: 0.55, blue: 0.95)   // blue — a hot recompile, not agent coding
        case .needsInput: Color(red: 0.98, green: 0.78, blue: 0.13)   // gold — "your turn"; distinct from the orange of coding/planning
        case .error: .red
        case .splitting, .merging: Color(red: 0.55, green: 0.45, blue: 0.95)   // indigo — a structural op, not coding
        }
    }

    /// Ink color for the pill text. White reads on every saturated background except the gold
    /// `needsInput`, which is too light to carry white — so that one gets near-black.
    var textColor: Color {
        switch self {
        case .needsInput: Color(white: 0.10)
        default: .white
        }
    }

    /// Whether this state means work is actively in flight on the node (→ blink the pill; an agent state
    /// also locks the node — see the panel's `isLocked`, which a `.reloading` user edit does NOT trip).
    var isWorking: Bool {
        switch self {
        case .planning, .building, .reloading, .splitting, .merging: true
        case .draft, .ready, .outdated, .needsInput, .error: false
        }
    }

    /// An in-flight structural op (split/merge) — drives the glowing card outline.
    var isStructuralOp: Bool {
        switch self {
        case .splitting, .merging: true
        default: false
        }
    }
}

/// A pulsing glowing outline around a node card while it's under an in-flight split/merge, in the same
/// indigo as the Splitting/Merging pill — so the structural op reads at the card, not just the pill.
struct SZGraphOpGlow: ViewModifier {
    let status: SZNodeStatus
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content.overlay {
            if status.isStructuralOp {
                // Pulse off the SAME shared clock as the status pill, so the glow's halo swells in
                // lockstep with the pill's blink (period SZPulse.period).
                TimelineView(.animation) { ctx in
                    let p = SZPulse.phase(at: ctx.date)
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .stroke(status.color, lineWidth: 2)
                        .shadow(color: status.color.opacity(0.9), radius: 5 + 6 * p)
                        .shadow(color: status.color.opacity(0.6), radius: 5 + 6 * p)
                        .opacity(0.65 + 0.35 * p)
                }
                .allowsHitTesting(false)
            }
        }
    }
}

extension View {
    /// Glowing outline for a node under a structural op; no-op for any other status.
    func graphOpGlow(_ status: SZNodeStatus, cornerRadius: CGFloat) -> some View {
        modifier(SZGraphOpGlow(status: status, cornerRadius: cornerRadius))
    }
}

/// The badges that float above a node card: the status pill (shown only when informative) and a lock
/// badge while the node is locked (a run is in flight). Shared by the generated + prompt node views.
struct SZNodeBadges: View {
    let status: SZNodeStatus
    var showPill: Bool = true
    var locked: Bool = false
    /// The full build diagnostic for this node, when it failed. Non-nil → the pill becomes the clickable
    /// `SZNodeErrorPill` (copyable popover); nil → the plain status pill. Cleared when the error is fixed.
    var errorDetail: String? = nil
    /// Names what the diagnostic actually is — a failed compile, or a source that contradicts its contract.
    var errorTitle: String = "Build error"
    /// Compose a repair request to this node's Coding Agent. Given for a node that needs rebuilding, so both
    /// the amber `Outdated` pill and the red `Error` popover can offer a way out in one click.
    var onFix: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 4) {
            if locked {
                Image(systemName: "lock.fill")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: SZNodeLayout.statusPillHeight, height: SZNodeLayout.statusPillHeight)
                    .background(Circle().fill(Color(white: 0.32)))
            }
            if showPill {
                if let errorDetail {
                    SZNodeErrorPill(detail: errorDetail, title: errorTitle, onFix: onFix)
                } else if status == .outdated, let onFix {
                    SZNodeFixPill(status: status, help: "Its contract has ports its code doesn't implement — click to ask its agent to rebuild it",
                                  action: onFix)
                } else {
                    SZNodeStatusPill(status: status)
                }
            }
        }
    }
}

/// An inert-looking status pill made clickable: one click composes a repair request to the node's Coding Agent
/// (it lands in the composer — host-drafted messages COMPOSE, they never auto-send). Used by `Outdated`, whose
/// whole point is that the node has an obvious, one-step way out.
struct SZNodeFixPill: View {
    let status: SZNodeStatus
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Text(status.label)
                Image(systemName: "arrow.clockwise")
            }
            .font(SZNodeCardStyle.pillFont)
            .foregroundStyle(status.textColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(status.color.opacity(hovering ? 1 : 0.85)))
        }
        .buttonStyle(.plain)
        .onHover { h in
            hovering = h
            if h { NSCursor.pointingHand.push() } else { NSCursor.pop() }   // .pointerStyle is macOS 15+
        }
        .help(help)
    }
}

/// The Error pill, made interactive (the bundled choice): clicking it opens a popover with the full build
/// diagnostic + a Copy button. The appended info glyph, hover highlight, and pointing-hand cursor signal
/// it's a button — unlike the other, inert, status pills. Shown in place of the plain pill whenever a node
/// carries error detail; it (and the whole affordance) vanish when the error is fixed and the detail clears.
struct SZNodeErrorPill: View {
    let detail: String
    var title: String = "Build error"
    /// When the error is a repairable node state (its code names ports the contract dropped), the popover also
    /// offers to hand the diagnostic straight to the node's Coding Agent. nil for errors with no one-step fix.
    var onFix: (() -> Void)? = nil
    @State private var showPopover = false
    @State private var hovering = false

    var body: some View {
        Button { showPopover.toggle() } label: {
            HStack(spacing: 3) {
                Text(SZNodeStatus.error.label)
                Image(systemName: "info.circle")
            }
            .font(SZNodeCardStyle.pillFont)
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(SZNodeStatus.error.color.opacity(hovering ? 1 : 0.85)))
        }
        .buttonStyle(.plain)
        .onHover { h in
            hovering = h
            if h { NSCursor.pointingHand.push() } else { NSCursor.pop() }   // .pointerStyle is macOS 15+
        }
        .help("Show \(title.lowercased()) — click for detail")
        .popover(isPresented: $showPopover, arrowEdge: .top) {
            SZBuildErrorPopover(detail: detail, title: title,
                                onFix: onFix.map { fix in { showPopover = false; fix() } })
        }
    }
}

/// The copyable build-error detail shown from `SZNodeErrorPill`: the full diagnostic in a bounded,
/// scrollable, selectable monospaced block, with a Copy button that puts it on the pasteboard.
struct SZBuildErrorPopover: View {
    let detail: String
    /// What kind of fault this is. A compile failure really is a "Build error"; a node whose source names ports
    /// its contract dropped compiled fine and is still rendering — calling that a build error sends the reader
    /// hunting for a compiler problem that does not exist.
    var title: String = "Build error"
    /// Hand this diagnostic to the node's Coding Agent as a drafted repair request. nil when the error has no
    /// one-step fix (a compile failure the agent is already looping on).
    var onFix: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 11, weight: .semibold))

            // Hug short diagnostics (most are one line) and scroll only when there's genuinely more.
            ScrollView {
                Text(detail)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 180)
            .fixedSize(horizontal: false, vertical: true)

            // Both actions in one place, weighted: repairing the node is the point of this popover; copying the
            // text is a utility beside it. The scroll view above is height-capped, so a long diagnostic can
            // never push this row out of reach.
            HStack(spacing: 8) {
                Spacer()
                SZPopoverActionButton(title: "Copy", systemImage: "doc.on.doc", prominent: false,
                                      help: "Copy the diagnostic") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(detail, forType: .string)
                }
                if let onFix {
                    SZPopoverActionButton(title: "Fix it", systemImage: "arrow.clockwise", prominent: true,
                                          help: "Compose a repair request to this node's Coding Agent",
                                          action: onFix)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(12)
        .frame(width: 360)
    }
}

/// A popover footer action that reacts to the pointer: SwiftUI's `.borderless` and `.borderedProminent` give no
/// hover feedback on macOS, so a row of them reads as inert text. Same affordance the error pill itself uses —
/// hover highlight plus the pointing-hand cursor — so "this is clickable" is signalled the same way everywhere.
struct SZPopoverActionButton: View {
    let title: String
    let systemImage: String
    let prominent: Bool
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 11, weight: prominent ? .semibold : .regular))
                .foregroundStyle(prominent ? Color.white : .primary)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background {
                    let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
                    if prominent {
                        shape.fill(Color.accentColor.opacity(hovering ? 1 : 0.85))
                    } else {
                        shape.fill(Color.primary.opacity(hovering ? 0.12 : 0))
                    }
                }
        }
        .buttonStyle(.plain)
        .onHover { h in
            hovering = h
            if h { NSCursor.pointingHand.push() } else { NSCursor.pop() }   // .pointerStyle is macOS 15+
        }
        .help(help)
    }
}

struct SZNodeStatusPill: View {
    let status: SZNodeStatus

    var body: some View {
        // While an agent is working the node, blink the pill (gentle opacity pulse) instead of a spinner —
        // off the shared clock so the structural-op glow pulses in lockstep with it.
        TimelineView(.animation(paused: !status.isWorking)) { ctx in
            Text(status.label)
                .font(SZNodeCardStyle.pillFont)
                .foregroundStyle(status.textColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(status.color))
                .opacity(status.isWorking ? 0.45 + 0.55 * SZPulse.phase(at: ctx.date) : 1)
        }
    }
}
