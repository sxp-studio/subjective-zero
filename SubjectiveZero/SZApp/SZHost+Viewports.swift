// SPDX-License-Identifier: AGPL-3.0-only
// Viewport surfaces + the render-drive chokepoint. A viewport view reports attached / resized /
// detached; the host attaches its layer to the runtime, feeds the driver registry, and pushes ONE
// decision to the runtime — who drives (renderSize + synchronous present) and what paces the loop:
//   a driving viewport   → its view's display link
//   no viewport, thumbs  → the main window's display link, capped ~30 Hz
//   nothing to see       → nil (idle)
// That is the whole "should the renderer run" condition, in one place, on the main thread.
import AppKit
import Foundation
import QuartzCore
import SZCore
import SZRuntime
import SZUI

/// A viewport surface in a window. Identity is the layer; the view is weak (it emits `.detached`
/// itself on dealloc).
struct SZViewportSurface {
    let id: SZPanelID
    let layer: CAMetalLayer
    weak var view: SZViewportView?
}

/// The render-drive decision (and `applyRenderDrive`'s idempotence key).
enum SZRenderDrive: Equatable {
    case viewport(ObjectIdentifier)   // this layer drives; its view's link paces
    case thumbnails                   // no viewport; the main window's link paces for the thumbs
    case idle
}

extension SZHost {
    /// Vended to `SZViewportPanel` per instance (SZApp.panelContent).
    func viewportEvents(for id: SZPanelID) -> @MainActor (SZViewportView.Event) -> Void {
        { [weak self] event in self?.handleViewportEvent(id, event) }
    }

    private func handleViewportEvent(_ id: SZPanelID, _ event: SZViewportView.Event) {
        switch event {
        case .attached(let view):
            // The container mounts only once the runtime exists — a nil here is a startup-order bug.
            guard let runtime else { assertionFailure("viewport attached before the runtime"); return }
            viewportSurfaces.append(SZViewportSurface(id: id, layer: view.metalLayer, view: view))
            runtime.attach(view.metalLayer)
            viewportDriver.reportArea(id.instance, Self.pixelArea(view.metalLayer.drawableSize))
            syncViewportDriver()
        case .resized(let size):
            viewportDriver.reportArea(id.instance, Self.pixelArea(size))
            applyRenderDrive()
        case .detached(let layer):
            guard let index = viewportSurfaces.firstIndex(where: { $0.layer === layer }) else { return }
            viewportSurfaces.remove(at: index)
            runtime?.detach(layer)
            syncViewportDriver()
        }
    }

    /// The push: registry driver + thumb demand + window state → runtime driver + pacing link.
    /// Idempotent on the decision. Called on every edge that can change it: surface events, window
    /// visibility (`syncViewportDriver`), watch-set pushes (`refreshPreviewStream`).
    func applyRenderDrive() {
        guard let runtime else { return }
        // `last`: during a pop-out/dock transition two surfaces share an instance for one turn.
        let surface = viewportDriver.driver.flatMap { instance in
            viewportSurfaces.last { $0.id.instance == instance }
        }
        let mainWindow = popoutManager.mainWindow
        let drive: SZRenderDrive
        if let surface {
            drive = .viewport(ObjectIdentifier(surface.layer))
        } else if !lastPushedWatchKeys.isEmpty, mainWindow != nil {
            drive = .thumbnails
        } else {
            drive = .idle
        }
        guard drive != appliedRenderDrive else { return }
        appliedRenderDrive = drive
        runtime.setDriver(surface?.layer)
        let driverView = surface?.view
        runtime.setPacing { target, selector in
            switch drive {
            case .viewport:
                // Fires at the driver display's rate, follows the view across displays, suspends
                // with an occluded/miniaturized window.
                return driverView?.displayLink(target: target, selector: selector)
            case .thumbnails:
                // Thumbs publish at ~15 Hz; don't render the graph at 120 Hz for them.
                let link = mainWindow?.displayLink(target: target, selector: selector)
                link?.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
                return link
            case .idle:
                return nil
            }
        }
    }

    static func pixelArea(_ size: CGSize) -> Int {
        Int(size.width) * Int(size.height)
    }
}
