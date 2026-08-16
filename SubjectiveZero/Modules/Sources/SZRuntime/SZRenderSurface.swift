// SPDX-License-Identifier: AGPL-3.0-only
// SZRenderSurface — one attached viewport layer the render loop presents into. The driver surface is
// presented synchronously by the loop thread (`presentNow`: encode + present in one tick); mirrors
// present on their own serial queue, drop-if-busy (`presentLater`), so an occluded window's
// `nextDrawable` stall never reaches the loop or another surface, and at most one present per mirror
// is ever queued. Retained by the runtime only while attached (+ transiently by an in-flight present).
// `@unchecked Sendable`: the layer's drawable APIs are thread-safe and `drawableSize` has one writer
// (the view, on main); everything else is atomic or immutable.
import Metal
import QuartzCore
import Synchronization

final class SZRenderSurface: @unchecked Sendable {
    let layer: CAMetalLayer
    private let queue = DispatchQueue(label: "SZRenderSurface.present", qos: .userInteractive)
    /// Set from enqueue until the present completes (or early-outs); pushes are dropped while set.
    private let inFlight = Atomic<Bool>(false)
    /// Completed presents (test hook).
    let presentCount = Atomic<Int>(0)

    init(layer: CAMetalLayer) {
        self.layer = layer
    }

    /// The driver's present: synchronous on the loop thread (no lock held). `nextDrawable` can't
    /// wait on a visible window — ≤ 2 frames in flight against 3 drawables.
    func presentNow(_ endpoint: (any MTLTexture)?, via runtime: SZRuntime) {
        if runtime.presentEndpoint(endpoint, into: layer, onCompleted: nil) {
            presentCount.add(1, ordering: .relaxed)
        }
    }

    /// A mirror's present: enqueue one, drop while the previous is in flight. Never blocks the caller.
    /// The endpoint is a pool texture reused in place, so a late present still shows the newest frame.
    func presentLater(_ endpoint: (any MTLTexture)?, via runtime: SZRuntime) {
        guard inFlight.compareExchange(expected: false, desired: true,
                                       ordering: .acquiringAndReleasing).exchanged else { return }
        nonisolated(unsafe) let endpoint = endpoint   // MTLTexture isn't Sendable; single consumer
        queue.async { [self] in
            let committed = runtime.presentEndpoint(endpoint, into: layer) { [self] in
                presentCount.add(1, ordering: .relaxed)
                inFlight.store(false, ordering: .releasing)
            }
            if !committed { inFlight.store(false, ordering: .releasing) }
        }
    }
}
