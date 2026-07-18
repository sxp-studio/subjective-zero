// SPDX-License-Identifier: AGPL-3.0-only
// A cursor-reactive layer over the dotted grid. Near the cursor the grid dots morph into Matrix-style
// glyphs (katakana / digits / symbols) in the grid's own dim tone — no brightening, no accent — and as the
// cursor moves on they dim and shrink back into dots along a short trail. Drawn in the SAME SCREEN space as
// SZDotGridView (a sibling, not inside the camera transform), reading the same zoom/offset so its cells
// land exactly on the base grid's dots. Purely decorative; the caller disables hit testing.
//
// Each cell's intensity is a single MAX over influence sources: the live cursor (full weight) and every
// recent trail sample (weight fading with age). The max makes a cell ramp UP to its peak as the cursor
// passes closest and then only ever shrink (decaying purely by time), instead of snapping back down when
// it reaches the ring's edge. A lit cell paints the canvas background over its base dot so the dot reads as
// BECOMING the glyph rather than dot + glyph stacked.
//
// Performance: the base grid is untouched, and this overlay is idle-dormant. With no trail it's a plain
// Canvas that redraws only on cursor movement (like the grid redraws on pan). Only while trail samples are
// still fading is it wrapped in a `TimelineView(.animation)`; a still or off-canvas pointer drains the
// trail within `fadeWindow` and the timeline dismounts, so it then costs nothing per frame.
import SwiftUI

struct SZGridCursorTrailView: View {
    let cursor: CGPoint?
    let zoom: CGFloat
    let offset: CGSize
    /// Peak glyph opacity. Defaults to the node editor's dim, grid-matching tone; the welcome window
    /// passes a brighter value so the effect reads as a foreground flourish there (one view, no copy).
    var glyphOpacity: Double = SZGridCursorTrailView.defaultGlyphOpacity

    /// A past cursor position and when it was recorded (seconds, reference-date based — same clock the
    /// TimelineView reads from `context.date`, so the fade math lines up).
    private struct Sample { let point: CGPoint; let birth: TimeInterval }
    /// Grid index of a dot, so overlapping influence collapses to one draw (the max) per dot.
    private struct DotKey: Hashable { let kx: Int; let ky: Int }

    @State private var trail: [Sample] = []
    /// The last RECORDED sample position — the sample gate compares against this, not `trail.last`,
    /// because `trail` prunes itself to empty: gating on the pruned array meant any ≥1px jitter of a
    /// resting hand re-appended a sample and remounted the TimelineView for another full fade window,
    /// forever. This survives pruning, so a resting pointer's sub-`sampleGap` jitter appends nothing
    /// and the timeline stays dismounted.
    @State private var lastSamplePoint: CGPoint?

    // Tuning. Base grid dots are 1pt-radius, white @ 0.16.
    private static let fadeWindow: TimeInterval = 0.8   // how long a passed-over cell takes to settle back ("slow")
    private static let sampleGap: CGFloat = 7           // min pointer travel before a new trail sample
    private static let trailCap = 128                   // safety bound; the real bound is age (fadeWindow), so a
                                                        // long swipe still fades evenly instead of being truncated
    private static let baseReach: CGFloat = 72          // constant on-screen reach (px) at normal / zoomed-out levels
    private static let reachInSpacings: CGFloat = 1.6   // floor: always cover ~this many dot-rings even when zoomed in
    private static let glyphs = Array("0123456789ｱｲｳｴｵｶｷｸｹｺｻｼｽｾｿﾀﾁﾂﾃ<>+*=/#¥$%&")
    private static let glyphSize: CGFloat = 11          // fixed on-screen glyph size (pt) at full intensity
    private static let defaultGlyphOpacity = 0.16       // same tone as the base grid dot — no brightening
    private static let glyphMinScale: CGFloat = 0.18    // as intensity fades, the glyph shrinks toward a dot
    private static let dotKnockoutRadius: CGFloat = 1.8 // covers the base grid dot as a glyph takes its cell over

    /// The base grid's on-screen dot spacing at the current zoom (shared geometry, so our dots coincide).
    private var spacing: CGFloat { SZDotGridView.effectiveSpacing(pitch: SZNodeLayout.gridPitch, zoom: zoom) }

    /// How far dots react, in screen px. Constant (`baseReach`) at normal / zoomed-out levels so the
    /// highlighted area is the same size regardless of zoom; floored to a few dot-rings so that zooming
    /// far in (spacing > baseReach) still lights the ring around the cursor instead of nothing.
    private var reach: CGFloat { max(Self.baseReach, spacing * Self.reachInSpacings) }

    var body: some View {
        Group {
            if trail.isEmpty {
                // Idle / resting: no fading to animate, so just draw the live cursor field. Redraws only
                // when `cursor` changes — no per-frame loop.
                Canvas { context, _ in drawField(context, now: nil) }
            } else {
                // A trail is settling: animate until it drains, then the branch above takes over (dormant).
                TimelineView(.animation) { timeline in
                    let now = timeline.date.timeIntervalSinceReferenceDate
                    Canvas { context, _ in drawField(context, now: now) }
                        // Drop settled samples so the trail empties and this timeline can dismount. Runs in
                        // an action handler (not during body eval) and only mutates on the rare frame where
                        // a sample crosses the fade threshold — not a per-frame write.
                        .onChange(of: timeline.date) { _, _ in prune(now: now) }
                }
            }
        }
        // Record trail samples as the pointer moves. Distance-gated so a fast sweep yields a bounded number
        // of samples and an idle hover yields none.
        .onChange(of: cursor) { _, new in
            guard let new else { lastSamplePoint = nil; return }
            if let last = lastSamplePoint, hypot(new.x - last.x, new.y - last.y) < Self.sampleGap {
                return
            }
            lastSamplePoint = new
            trail.append(Sample(point: new, birth: Date().timeIntervalSinceReferenceDate))
            if trail.count > Self.trailCap { trail.removeFirst(trail.count - Self.trailCap) }
        }
    }

    private func prune(now: TimeInterval) {
        let live = trail.filter { now - $0.birth < Self.fadeWindow }
        if live.count != trail.count { trail = live }
    }

    // MARK: - Drawing

    /// Draw the whole reactive field in one pass. Every cell's intensity is the MAX over: the live cursor
    /// (full weight) and each trail sample (weight fading with age). Overlapping influence collapses to one
    /// draw per cell, so a cell latches its peak as the cursor passes and then decays only with time.
    /// `now == nil` means "no clock" (resting state) — cursor only, no trail.
    private func drawField(_ context: GraphicsContext, now: TimeInterval?) {
        let R = reach
        var lift: [DotKey: (x: CGFloat, y: CGFloat, t: CGFloat)] = [:]

        func add(around p: CGPoint, weight: CGFloat) {
            guard weight > 0.001 else { return }
            forDots(near: p) { kx, ky, x, y, d in
                let t = weight * (1 - d / R)
                let key = DotKey(kx: kx, ky: ky)
                if let cur = lift[key], cur.t >= t { return }
                lift[key] = (x, y, t)
            }
        }

        if let cursor { add(around: cursor, weight: 1) }   // the live cursor — a steady full-weight source
        if let now {
            for s in trail {
                let age = now - s.birth
                guard age >= 0, age < Self.fadeWindow else { continue }
                add(around: s.point, weight: CGFloat(1 - age / Self.fadeWindow))
            }
        }

        var cache: [Character: GraphicsContext.ResolvedText] = [:]   // resolve each glyph once per frame
        for (key, v) in lift {
            drawGlyph(context, cache: &cache, kx: key.kx, ky: key.ky, x: v.x, y: v.y, intensity: v.t)
        }
    }

    /// A grid cell rendered as a Matrix-style glyph, in the grid's own tone (no brightening). The character
    /// is a stable hash of the cell index (so it doesn't flicker while stationary). As intensity fades the
    /// glyph both dims and scales down, collapsing back toward the plain dot.
    private func drawGlyph(_ context: GraphicsContext,
                           cache: inout [Character: GraphicsContext.ResolvedText],
                           kx: Int, ky: Int, x: CGFloat, y: CGFloat, intensity: CGFloat) {
        let t = min(max(intensity, 0), 1)
        guard t > 0.02 else { return }
        let hash: Int = (kx &* 73856093) ^ (ky &* 19349663)
        let count: Int = Self.glyphs.count
        let index: Int = ((hash % count) + count) % count
        let ch = Self.glyphs[index]
        let resolved: GraphicsContext.ResolvedText
        if let r = cache[ch] {
            resolved = r
        } else {
            resolved = context.resolve(Text(String(ch))
                .font(.system(size: Self.glyphSize, weight: .semibold, design: .monospaced))
                .foregroundColor(.white))
            cache[ch] = resolved
        }
        // Knock the base grid dot (a layer below) out from under the glyph so it reads as the dot BECOMING
        // the character, not dot + character stacked. Paints the canvas background over the dot, ramping in
        // faster than the glyph so the two are never both visible.
        let knock = min(1.0, Double(t) * 1.6)
        let er = Self.dotKnockoutRadius
        context.fill(Path(ellipseIn: CGRect(x: x - er, y: y - er, width: er * 2, height: er * 2)),
                     with: .color(SZDotGridView.canvasBackground.opacity(knock)))

        let scale = Self.glyphMinScale + (1 - Self.glyphMinScale) * t
        var c = context
        c.opacity = Double(t) * glyphOpacity
        c.translateBy(x: x, y: y)
        c.scaleBy(x: scale, y: scale)
        c.draw(resolved, at: .zero, anchor: .center)
    }

    /// Visit every grid dot within `reach` of `p`, using SZDotGridView's exact spacing/phase so the cells
    /// coincide with the base grid. Only the point's neighbourhood is walked, never the whole grid. Body
    /// receives the dot's grid index (kx, ky), its screen position (x, y), and its distance d.
    private func forDots(near p: CGPoint, _ body: (Int, Int, CGFloat, CGFloat, CGFloat) -> Void) {
        let spacing = self.spacing
        let phaseX = SZDotGridView.phase(offset: offset.width, spacing: spacing)
        let phaseY = SZDotGridView.phase(offset: offset.height, spacing: spacing)
        let R = reach
        let kx0 = Int(floor((p.x - R - phaseX) / spacing)), kx1 = Int(ceil((p.x + R - phaseX) / spacing))
        let ky0 = Int(floor((p.y - R - phaseY) / spacing)), ky1 = Int(ceil((p.y + R - phaseY) / spacing))
        guard kx1 >= kx0, ky1 >= ky0 else { return }
        for ky in ky0...ky1 {
            let y = phaseY + CGFloat(ky) * spacing
            for kx in kx0...kx1 {
                let x = phaseX + CGFloat(kx) * spacing
                let d = hypot(x - p.x, y - p.y)
                if d <= R { body(kx, ky, x, y, d) }
            }
        }
    }
}
