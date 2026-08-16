// SPDX-License-Identifier: AGPL-3.0-only
// ViewportPanel — the live render surface. This view owns a CAMetalLayer and reports its lifecycle to
// the host (`events`: attached / resized / detached); the host attaches the layer to SZRuntime's
// render loop, which pushes every frame into it. SZUI and SZRuntime never import each other — they
// meet on Apple types, wired by the host.
//
// Not an MTKView: its main-thread draw loop and drawable auto-sizing would only be turned off (editor
// interactions used to starve viewport frames by 20–700ms). This shape also fits the planned
// out-of-process renderer (same view, IOSurface contents).
import SwiftUI
import Metal
import QuartzCore

/// The SwiftUI shim: hands the host-wired `device` + `events` to the view. No coordinator, no dismantle
/// hook — the view reports its own attach/detach.
public struct SZViewportPanel: NSViewRepresentable {
    private let device: (any MTLDevice)?
    private let events: (@MainActor (SZViewportView.Event) -> Void)?

    /// `device` and `events` come from the host (backed by SZRuntime). Events fire on the main thread.
    public init(device: (any MTLDevice)?, events: (@MainActor (SZViewportView.Event) -> Void)?) {
        self.device = device
        self.events = events
    }

    public func makeNSView(context: Context) -> SZViewportView {
        // Prints once per panel lifetime (launch, close→reopen). A print WITHOUT a close/reopen means
        // the panel lost its SwiftUI identity to a structural re-parent — the regression the flat
        // panel-layout container exists to prevent.
        print("[SZViewportPanel] makeNSView (creating viewport view)")
        let view = SZViewportView()
        view.device = device
        view.events = events
        return view
    }

    public func updateNSView(_ view: SZViewportView, context: Context) {
        if view.device == nil { view.device = device }
        // Late wiring at launch: the setter replays `.attached` if already in a window.
        if view.events == nil { view.events = events }
    }
}

/// A layer-backed NSView owning the CAMetalLayer the render loop presents into.
/// - `drawableSize` has one writer: this view, on main (layout, backing scale, window attach); each
///   real change is reported.
/// - Lifecycle is window-bound: `.attached` on entering a window (size synced first), `.detached` on
///   leaving — and from `deinit`, since a pop-out close tears views down via window dealloc. The
///   detach payload is the layer, never the view.
public final class SZViewportView: NSView {
    /// The surface lifecycle, reported on the main thread.
    public enum Event {
        /// In a window, size synced: the surface can present.
        case attached(SZViewportView)
        /// `metalLayer.drawableSize` changed.
        case resized(CGSize)
        /// Left its window or deallocated; the layer is the surface identity.
        case detached(CAMetalLayer)
    }

    /// The backing layer, created up front so it is the view's identity for its whole life.
    /// `nonisolated(unsafe)` only so `deinit` can name it (immutable; drawable APIs are thread-safe).
    nonisolated(unsafe) public let metalLayer: CAMetalLayer = {
        let layer = CAMetalLayer()
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = false   // the runtime blits its offscreen endpoint into the drawable
        return layer
    }()

    var device: (any MTLDevice)? {
        didSet { metalLayer.device = device }
    }

    /// Host-wired; setting it while attached replays `.attached`.
    var events: (@MainActor (Event) -> Void)? {
        didSet { if attached { events?(.attached(self)) } }
    }

    private var attached = false

    override public var wantsUpdateLayer: Bool { true }
    override public func updateLayer() {}   // contents come from Metal presents, not Core Animation

    override public func makeBackingLayer() -> CALayer { metalLayer }

    public init() {
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    deinit {
        // Balance the attach on window dealloc (pop-out close). No `self` in the payload.
        guard attached, let events else { return }
        let layer = metalLayer
        if Thread.isMainThread {
            MainActor.assumeIsolated { events(.detached(layer)) }
        } else {
            DispatchQueue.main.async { events(.detached(layer)) }
        }
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
        guard window != nil else { return }
        let size = convertToBacking(bounds.size)
        if size.width > 0, size.height > 0, metalLayer.drawableSize != size {
            metalLayer.drawableSize = size
            if attached { events?(.resized(size)) }
        }
    }

    // MARK: surface lifecycle — window-bound

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            syncDrawableSize()   // size first, so `.attached` reads a real drawableSize
            guard !attached else { return }
            attached = true
            events?(.attached(self))
        } else if attached {
            attached = false
            events?(.detached(metalLayer))
        }
    }
}
