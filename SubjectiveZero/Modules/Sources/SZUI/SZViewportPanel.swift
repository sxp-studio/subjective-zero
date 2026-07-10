// SPDX-License-Identifier: AGPL-3.0-only
// ViewportPanel — the live render surface. The view shell lives in SZUI; **all GPU resources live in
// SZRuntime**: the host injects the SZRuntime-owned `device` and a per-frame render closure (backed by
// SZRuntime.drawLive(into:)). SZUI and SZRuntime never import each other — they meet on Apple framework
// types (MTLDevice, CAMetalLayer), wired by the host.
//
// Deliberately NOT an MTKView: we'd pause it, drop its delegate, and disable its drawable auto-sizing
// just to bypass its main-thread draw loop (editor interactions starved viewport frames by 20–700ms
// when rendering shared the main thread). A plain layer-backed NSView owning a CAMetalLayer and its
// own display-link render loop is smaller, has no turned-off machinery, and is the exact shape the
// planned out-of-process renderer needs on the UI side (same view, IOSurface contents instead).
import SwiftUI
import Metal
import QuartzCore
import Synchronization

/// The SwiftUI shim: hands the host-wired `device` + `renderFrame` to the view. No coordinator, no
/// dismantle hook — the view owns its whole lifecycle (it stops its render loop when it leaves the
/// window and restarts on re-attach).
public struct SZViewportPanel: NSViewRepresentable {
    private let device: (any MTLDevice)?
    private let renderFrame: ((CAMetalLayer) -> Void)?

    /// `device` and `renderFrame` come from the host (backed by SZRuntime). `renderFrame` is called
    /// on the view's render thread, once per display refresh.
    public init(device: (any MTLDevice)?, renderFrame: ((CAMetalLayer) -> Void)?) {
        self.device = device
        self.renderFrame = renderFrame
    }

    public func makeNSView(context: Context) -> SZViewportView {
        // Prints once per panel LIFETIME: at launch, and again on a legitimate close→reopen (the
        // layout container removes closed panels, so reopen makes a fresh view — its render loop restarts
        // itself). A print WITHOUT a close/reopen means the panel lost its SwiftUI identity to a
        // structural re-parent — the regression the flat panel-layout container exists to prevent.
        print("[SZViewportPanel] makeNSView (creating viewport view)")
        let view = SZViewportView()
        view.device = device
        view.renderFrame = renderFrame
        return view
    }

    public func updateNSView(_ view: SZViewportView, context: Context) {
        if view.device == nil { view.device = device }
        // The host wires `renderFrame` at launch (`.task`), possibly after the view exists.
        if view.renderFrame == nil { view.renderFrame = renderFrame }
    }
}

/// The whole viewport: a layer-backed NSView owning a `CAMetalLayer` and the display-link render
/// thread that drives `renderFrame(layer)` into it.
///
/// - **Geometry has ONE writer:** this view syncs `drawableSize` on the main thread wherever it can
///   change (layout, backing-scale moves, window attach). The render thread only reads it.
/// - **Lifecycle is window-bound:** the render loop starts when the view is in a window (a display link
///   created windowless binds to no display and never fires) and stops when it leaves — panel
///   close/reopen just works, and every attach gets a FRESH link + loop bound to the current state.
/// - **Teardown is race-free by ownership:** each render loop (the link's target) owns its `(layer,
///   closure)` pair immutably, weakly referencing the view only for the stop flag — an in-flight
///   frame finishes into a layer its own strong reference keeps alive, and a stale loop can never
///   observe a newer attach's state. The render thread parks in bounded (1s) run-loop slices:
///   `CFRunLoopStop` is only a best-effort wake, so the timeout is what guarantees exit. `stop()`
///   can block up to one drawable timeout if the thread is parked in `nextDrawable()` — accepted,
///   detach is rare and the bound is hard.
public final class SZViewportView: NSView {
    /// Set by the panel before/at attach; applied to the layer it backs.
    var device: (any MTLDevice)? {
        didSet { (layer as? CAMetalLayer)?.device = device }
    }

    /// The per-frame render, called on the render thread. Setting it while attached starts the render loop.
    var renderFrame: ((CAMetalLayer) -> Void)? {
        didSet { startRenderLoopIfReady() }
    }

    private var renderLoop: RenderLoop?

    override public var wantsUpdateLayer: Bool { true }
    override public func updateLayer() {}   // contents come from Metal presents, not Core Animation

    override public func makeBackingLayer() -> CALayer {
        let metalLayer = CAMetalLayer()
        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = false   // the runtime blits its offscreen endpoint into the drawable
        return metalLayer
    }

    public init() {
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    deinit {
        renderLoop?.stop()
    }

    // MARK: geometry — single writer of drawableSize, always on the main thread

    override public func layout() {
        super.layout()
        syncDrawableSize()
    }

    override public func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        syncDrawableSize()   // moved to a display with a different scale (1x ↔ 2x)
    }

    private func syncDrawableSize() {
        guard let metalLayer = layer as? CAMetalLayer, window != nil else { return }
        let size = convertToBacking(bounds.size)
        if size.width > 0, size.height > 0, metalLayer.drawableSize != size {
            metalLayer.drawableSize = size
        }
    }

    // MARK: render-loop lifecycle — window-bound

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            syncDrawableSize()
            startRenderLoopIfReady()
        } else {
            renderLoop?.stop()
            renderLoop = nil
        }
    }

    private func startRenderLoopIfReady() {
        guard renderLoop == nil, window != nil, let renderFrame,
              let metalLayer = layer as? CAMetalLayer else { return }
        let renderLoop = RenderLoop(layer: metalLayer, renderFrame: renderFrame)
        self.renderLoop = renderLoop
        // Created from the view (so the link tracks the view's display, including moves between
        // screens) — valid only while in a window, hence the window-bound lifecycle above.
        renderLoop.start(link: displayLink(target: renderLoop, selector: #selector(RenderLoop.tick(_:))))
    }

    /// One attach's render loop: the display link's target, owning that attach's `(layer, closure)`
    /// pair immutably. The link retains the loop object (not the view — no cycle); it runs its own
    /// thread whose run loop drives the link off-main.
    private final class RenderLoop: NSObject, @unchecked Sendable {
        private let layer: CAMetalLayer
        private let renderFrame: (CAMetalLayer) -> Void
        private let state = Mutex<(stopped: Bool, runLoop: CFRunLoop?)>((false, nil))
        private var link: CADisplayLink?

        init(layer: CAMetalLayer, renderFrame: @escaping (CAMetalLayer) -> Void) {
            self.layer = layer
            self.renderFrame = renderFrame
        }

        func start(link: CADisplayLink) {
            self.link = link
            nonisolated(unsafe) let loopLink = link
            let thread = Thread { [weak self] in
                self?.state.withLock { $0.runLoop = CFRunLoopGetCurrent() }
                loopLink.add(to: .current, forMode: .default)
                // Bounded park slices — the timeout, not CFRunLoopStop, guarantees cancellation lands.
                while !Thread.current.isCancelled,
                      RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 1)) {}
            }
            thread.name = "SZViewportView.RenderLoop"
            thread.qualityOfService = .userInteractive
            thread.start()
        }

        /// Fires on the render thread: one viewport frame.
        @objc func tick(_ link: CADisplayLink) {
            guard !state.withLock({ $0.stopped }) else { return }
            renderFrame(layer)
        }

        func stop() {
            link?.invalidate()
            link = nil
            state.withLock { state in
                state.stopped = true
                if let loop = state.runLoop { CFRunLoopStop(loop) }   // best-effort wake (see header)
                state.runLoop = nil
            }
        }
    }
}
