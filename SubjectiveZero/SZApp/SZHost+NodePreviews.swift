// SPDX-License-Identifier: AGPL-3.0-only
// Live node previews — the host half. Owns the Graph ▸ Live Previews pref (the global gate), the
// per-node preview toggle op (the card's photo icon + `ui_set_node_body`), and the ~15 Hz capture
// loop: build the want-list from the graph, GPU-downscale + read back off-main
// (`SZRuntime.captureNodeOutputs`), then write each node's `SZNodePreviewFrame` box on the main
// actor — Observation invalidates only the thumb leaves, never the Equatable-gated cards.
import CoreGraphics
import Foundation
import SZCore
import SZRuntime
import SZUI

extension SZHost {
    /// Thumb budget per tick — bounds capture bandwidth on a huge auto-previewing graph. Graph order;
    /// no viewport culling yet (the camera is panel-local @State — publish a visible set upward if
    /// this cap ever bites).
    nonisolated static let previewMaxThumbs = 24
    /// Long-edge pixels of a captured thumb — plenty for a 200pt card region.
    nonisolated static let previewMaxDimension = 160

    /// Graph ▸ Live Previews — the global gate over per-card preview bodies. Order matters: the
    /// geometry gate flips first, then the observable pref re-renders the cards (their `==` compares
    /// it), so every card reflows exactly once with both in agreement.
    func setLivePreviews(_ on: Bool) {
        SZNodeLayout.previewsEnabled = on
        livePreviews = on
        if !on { previewFrames.clearImages() }
        refreshPreviewDriver()
        persistAppState()
    }

    /// THE apply path for a card body — shared by the photo toggle and `ui_set_node_body`, so both
    /// ride one choreography: store write → drop the node's stale thumb (a retargeted preview must
    /// never keep showing the old port's frame) → persist → driver refresh.
    @discardableResult
    func setNodeBody(node id: SZNodeID, body: SZNodeBody?) -> Bool {
        guard store.setNodeBody(id: id, body: body) else { return false }
        previewFrames.frame(for: id).image = nil
        persistProject()
        refreshPreviewDriver()
        return true
    }

    /// Toggle a texture output as the card's live preview — the node card's photo icon. Clicking the
    /// port the card effectively previews (including via the nil-body auto-preview fallback) turns
    /// the preview off (explicit `.none`); clicking any other texture output points the preview at
    /// it. Graph state, persisted with the project like `position`. Returns the applied body.
    ///
    /// A `.custom` body is refused (returned unchanged): the card renders compact so the user can't
    /// see what the click would destroy — the authored custom-card ref. Replacing it stays an
    /// explicit act (`ui_set_node_body`).
    @discardableResult
    func toggleNodePreview(node id: SZNodeID, port: String) -> SZNodeBody? {
        guard let node = store.project?.graph.node(id: id) else { return nil }
        guard node.body?.mode != .custom else { return node.body }
        let body = node.effectivePreviewPort == port
            ? SZNodeBody(mode: .none)
            : SZNodeBody(mode: .preview, previewPort: port)
        guard setNodeBody(node: id, body: body) else { return nil }
        return body
    }

    /// Start or stop the capture loop to match host state. The loop itself re-reads the graph every
    /// tick (graph edits need no refresh); this only needs calling when the RUN CONDITION changes —
    /// gate flips, project load — so a quiet editor holds zero timers when nothing previews.
    func refreshPreviewDriver() {
        guard livePreviews, runtime != nil, store.project != nil else {
            previewDriverTask?.cancel()
            previewDriverTask = nil
            return
        }
        guard previewDriverTask == nil else { return }
        previewDriverTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let delay = await self.previewDriverTick()
                try? await Task.sleep(for: delay)
            }
        }
    }

    /// One capture pass: want-list from the live graph, batch capture + CGImage conversion OFF the
    /// main actor (`waitUntilCompleted` readback must never block UI), then box writes back on it.
    /// Returns the next tick's delay — ~15 Hz while thumbs stream, a lazy idle poll while none do.
    private func previewDriverTick() async -> Duration {
        guard livePreviews, let runtime, let graph = store.project?.graph else { return .milliseconds(250) }
        // Deleted nodes must not pin their last frame forever — the tick is the one periodic place
        // that sees the live graph, so it owns the pruning (project switch prunes separately).
        previewFrames.prune(keeping: Set(graph.nodes.map(\.id)))
        var wanted: [(node: SZNodeID, port: String)] = []
        for node in graph.nodes {
            guard let port = node.effectivePreviewPort else { continue }
            wanted.append((node.id, port))
            if wanted.count == Self.previewMaxThumbs { break }
        }
        guard !wanted.isEmpty else { return .milliseconds(250) }
        // A paused timeline holds the pool frozen: once every wanted thumb has a frame, re-capturing
        // is pure GPU burn for pixel-identical results. A thumb enabled WHILE paused still fills
        // (its box is empty, so this guard falls through to one capture).
        if runtime.isPaused, wanted.allSatisfy({ previewFrames.frame(for: $0.node).image != nil }) {
            return .milliseconds(250)
        }
        let requests = wanted
        let images = await Task.detached(priority: .utility) {
            runtime.captureNodeOutputs(requests, maxDimension: Self.previewMaxDimension)
                .map { $0?.cgImage() }
        }.value
        // Re-validate after the await: the project may have switched, the gate flipped, or the task
        // been cancelled while the capture ran — writing then would resurrect pruned boxes with
        // frames from the wrong world.
        guard !Task.isCancelled, livePreviews, let current = store.project?.graph else {
            return .milliseconds(250)
        }
        let live = Set(current.nodes.map(\.id))
        for (want, image) in zip(wanted, images) where live.contains(want.node) {
            guard let image else { continue }   // never-written port: keep the placeholder, don't blank a stale thumb
            previewFrames.frame(for: want.node).image = image
        }
        return .milliseconds(66)
    }
}
