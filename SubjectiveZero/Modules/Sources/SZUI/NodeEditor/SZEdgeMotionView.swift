// SPDX-License-Identifier: AGPL-3.0-only
// The MOVING half of an edge (the data comet, the flow dashes): CAShapeLayers whose `lineDashPhase`
// is driven by a repeating Core Animation, so the motion runs entirely on the render server — zero
// main-thread frames. A per-edge `TimelineView(.animation)` would re-enter SwiftUI on every display
// frame for every animated edge and re-rasterize the stroked layers at canvas scale (cost ∝ zoom²).
// Animations are wall-clock phased (`timeOffset`), so every edge's motion stays in lockstep off one
// shared clock.
import AppKit
import SwiftUI

/// One dashed stroke riding the edge path (the comet is two: a wide faint halo + a bright core).
struct SZEdgeDashStroke: Equatable {
    let color: NSColor
    let lineWidth: CGFloat
    let dash: [CGFloat]
}

struct SZEdgeMotionView: NSViewRepresentable {
    let from: CGPoint
    let to: CGPoint
    let strokes: [SZEdgeDashStroke]
    let period: Double
    let animated: Bool
    let zoom: CGFloat

    func makeNSView(context: Context) -> SZEdgeMotionBackingView { SZEdgeMotionBackingView() }

    func updateNSView(_ view: SZEdgeMotionBackingView, context: Context) {
        // Endpoints normally move per drag tick, where a tween would just be lag — so the layer
        // snaps. They move ONE step at a time only under a SwiftUI animation (the plugs fold
        // restacking a card's dots), and there the layer glides on the same curve and duration as
        // the wire it rides, which SZConnectionShape interpolates.
        view.apply(from: from, to: to, strokes: strokes, period: period, animated: animated, zoom: zoom,
                   glide: context.transaction.animation == nil ? 0 : SZCardFold.duration)
    }
}

final class SZEdgeMotionBackingView: NSView {
    private var shapeLayers: [CAShapeLayer] = []
    private var appliedEndpoints: (CGPoint, CGPoint)?
    private var appliedStrokes: [SZEdgeDashStroke] = []
    private var appliedMotion: (cycle: CGFloat, period: Double, animated: Bool)?
    private var appliedScale: CGFloat = 0

    /// SwiftUI lays the edge layer out in top-left space; flipping makes the layer paths line up
    /// without per-point conversion.
    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    /// `glide` > 0 tweens an endpoint move over that many seconds instead of jumping (see
    /// SZEdgeMotionView.updateNSView); everything else here is always immediate.
    func apply(from: CGPoint, to: CGPoint, strokes: [SZEdgeDashStroke], period: Double,
               animated: Bool, zoom: CGFloat, glide: Double = 0) {
        // Layer count follows the stroke count (2 for a comet, 1 for flow dashes) — rebuilt only
        // when it changes, which in practice is never after the first update.
        if shapeLayers.count != strokes.count {
            shapeLayers.forEach { $0.removeFromSuperlayer() }
            shapeLayers = strokes.map { _ in
                let shape = CAShapeLayer()
                shape.fillColor = nil
                shape.lineCap = .round
                shape.lineJoin = .round
                layer?.addSublayer(shape)
                return shape
            }
            appliedEndpoints = nil
            appliedStrokes = []
            appliedMotion = nil
        }

        // Everything below mutates layer properties directly — implicit animations off, or every
        // drag tick's path update would get a 0.25s CA tween.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        if appliedEndpoints == nil || appliedEndpoints! != (from, to) {
            let hadEndpoints = appliedEndpoints != nil
            appliedEndpoints = (from, to)
            let path = CGMutablePath()
            path.move(to: from)
            let (c1, c2) = SZCubic.controls(from, to)
            path.addCurve(to: to, control1: c1, control2: c2)
            for shape in shapeLayers {
                // Where the layer is RIGHT NOW (mid-glide if one is running), so an interrupted
                // fold carries on from what's on screen rather than snapping back to start.
                let departing = shape.presentation()?.path ?? shape.path
                shape.path = path
                guard glide > 0, hadEndpoints, let departing else {
                    shape.removeAnimation(forKey: "glide")
                    continue
                }
                let move = CABasicAnimation(keyPath: "path")
                move.fromValue = departing
                move.toValue = path
                move.duration = glide
                move.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                shape.add(move, forKey: "glide")
            }
        }

        if appliedStrokes != strokes {
            appliedStrokes = strokes
            for (shape, stroke) in zip(shapeLayers, strokes) {
                shape.strokeColor = stroke.color.cgColor
                shape.lineWidth = stroke.lineWidth
                shape.lineDashPattern = stroke.dash.map { NSNumber(value: Double($0)) }
            }
        }

        // Crispness under the canvas scale transform: a shape layer rasterizes at contentsScale and
        // is THEN scaled by the ancestor — bump the raster resolution with the zoom (clamped).
        let scale = (window?.backingScaleFactor ?? 2) * min(max(zoom, 1), 3)
        if appliedScale != scale {
            appliedScale = scale
            for shape in shapeLayers { shape.contentsScale = scale }
        }

        // The motion: one full dash cycle per `period`, negative phase = toward the target — the
        // same math as the old flowPhase(date:cycle:period:). `timeOffset` phases the repeating
        // animation to the wall clock, so all edges march in lockstep like the shared TimelineView
        // clock did. Re-installed only when cycle/period/animated change (zoom quantization steps).
        let cycle = strokes.first.map { $0.dash.reduce(0, +) } ?? 0
        if appliedMotion == nil || appliedMotion! != (cycle, period, animated) {
            appliedMotion = (cycle, period, animated)
            for shape in shapeLayers {
                shape.removeAnimation(forKey: "flow")
                shape.lineDashPhase = 0
                guard animated, cycle > 0 else { continue }
                let anim = CABasicAnimation(keyPath: "lineDashPhase")
                anim.fromValue = 0
                anim.toValue = -cycle
                anim.duration = period
                anim.repeatCount = .infinity
                anim.timeOffset = CACurrentMediaTime().truncatingRemainder(dividingBy: period)
                shape.add(anim, forKey: "flow")
            }
        }
    }
}
