// SPDX-License-Identifier: AGPL-3.0-only
// The auto-hiding header's reveal/hide state, shared by the docked tile header (SZPanelChromeView)
// and the pop-out window's strip (SZPopoutPanelShell): hover the top band to summon, a grace
// period before sliding away, hysteresis so the cursor sitting ON the revealed header never counts
// as "out of the band", and a pin for interactions that must keep the header up (a header drag).
import SwiftUI

@MainActor
final class SZHeaderRevealModel: ObservableObject {
    @Published private(set) var visible = false
    /// A pinned header stays shown whatever the cursor does (a rearrange-drag must not lose its handle).
    @Published var pinned = false
    /// Live truth of "cursor is in the reveal band" — the delayed hide re-checks it at fire time
    /// (the SZHoverTip pattern: re-check state after the sleep instead of juggling cancellation).
    private var inRevealBand = false
    private var hidePending = false
    /// The in-flight grace timer, so a test can await the hide instead of sleeping past it — under a
    /// busy MainActor (a sibling test compiling a node) a wall-clock sleep is not a deadline.
    private(set) var pendingHide: Task<Void, Never>?

    /// Grace before sliding away once the cursor leaves the band — absorbs brief overshoots
    /// (reaching for the ✕ and drifting past) without flicker. Injectable so tests don't sleep.
    let hideGrace: Duration
    /// The standard summon band from the top edge — taller than any header so the trigger is forgiving.
    static let defaultTriggerBand: CGFloat = 36

    init(hideGrace: Duration = .milliseconds(350)) { self.hideGrace = hideGrace }

    /// Whether the header is on screen: always when auto-hide is off, else revealed or pinned.
    func shown(autoHide: Bool) -> Bool { !autoHide || visible || pinned }

    /// Feed the tile's continuous hover (local coordinates, y from the top edge). `triggerBand` is
    /// the summoning band; once revealed, the header's own footprint keeps it alive.
    func hover(_ phase: HoverPhase, triggerBand: CGFloat, headerHeight: CGFloat) {
        switch phase {
        case .active(let p):
            let threshold = visible ? max(triggerBand, headerHeight) : triggerBand
            inRevealBand = p.y <= threshold
            if inRevealBand { reveal() } else { scheduleHide() }
        case .ended:
            inRevealBand = false
            scheduleHide()
        }
    }

    /// The pin's interaction ended (drag released). Hover events don't arrive while the mouse
    /// button is down, so band state is stale — assume "away" and let the very next mouse move
    /// correct it (worst case the header re-reveals on the first twitch after a drop).
    func unpin() {
        inRevealBand = false
        withAnimation(.easeInOut(duration: 0.18)) { pinned = false }
        scheduleHide()
    }

    private func reveal() {
        guard !visible else { return }
        withAnimation(.easeOut(duration: 0.12)) { visible = true }
    }

    private func scheduleHide() {
        guard visible, !hidePending else { return }
        hidePending = true
        pendingHide = Task { @MainActor in
            try? await Task.sleep(for: hideGrace)
            hidePending = false
            if !inRevealBand && !pinned {
                withAnimation(.easeInOut(duration: 0.18)) { visible = false }
            }
            pendingHide = nil
        }
    }
}
