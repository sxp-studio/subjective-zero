// SPDX-License-Identifier: AGPL-3.0-only
// Live node previews — the host half. Owns the Graph ▸ Live Previews pref, the
// per-node preview toggle op (the card's photo icon + `ui_set_node_body`), and the WATCH SET the
// runtime's zero-copy preview stream captures: effective-preview nodes ∩ the editor's visible set,
// capped. Event-driven end to end — graph edits arrive via Observation on the store, camera moves
// via the panel's visible-set callback, frames via the runtime's completion callback. No polling
// loop, no CPU pixels: the runtime publishes IOSurfaces that go straight into the cards' frame
// boxes (and from there to CALayer.contents). With no viewport showing, the watch set is what keeps
// the render loop paced (SZHost+Viewports.applyRenderDrive).
import Foundation
import SZCore
import SZRuntime
import SZUI

extension SZHost {
    /// Thumb budget — bounds capture bandwidth; applies to VISIBLE nodes once the editor reports.
    nonisolated static let previewMaxThumbs = 24
    /// Long-edge pixels of a thumb target — 2x a ~160pt preview region, crisp on Retina.
    nonisolated static let previewMaxDimension = 320

    /// Graph ▸ Live Previews — the gate over per-card preview bodies. One write: the panel threads
    /// this value into every layout call and the cards compare it, so a flip reflows each card once.
    func setLivePreviews(_ on: Bool) {
        livePreviews = on
        if !on { previewFrames.clear() }
        refreshPreviewStream()
        persistAppState()
    }

    /// THE apply path for a card body — shared by the photo toggle and `ui_set_node_body`, so both
    /// ride one choreography: store write → drop the node's stale thumb (a retargeted preview must
    /// never keep showing the old port's frame) → persist → watch-set refresh.
    @discardableResult
    func setNodeBody(node id: SZNodeID, body: SZNodeBody?, origin: SZMutationOrigin = .user) -> Bool {
        if let denial = fenceDenial(nodes: [id], origin: origin) {
            status = denial
            return false
        }
        let previous = store.project?.graph.node(id: id)?.body
        guard store.setNodeBody(id: id, body: body) else { return false }
        // What the card SHOWS is a decision; its GEOMETRY is not. Auto-size settles and the backdrop's
        // aspect follow re-apply `.custom` with fresh rows all session long (SZCardHostController), so
        // journaling every row commit would fill the Director's delta with "USER set card body".
        if body?.mode != previous?.mode || body?.previewPort != previous?.previewPort {
            noteMutation("set card body", ["\(mutationTitle(id)): \(body?.mode.rawValue ?? "auto")"], origin: origin)
        }
        previewFrames.frame(for: id).surface = nil
        persistProject()
        refreshPreviewStream()
        return true
    }

    /// Toggle a texture output as the card's live preview — the node card's photo icon. Clicking the
    /// port the card effectively previews (including via the nil-body auto-preview fallback) turns
    /// the preview off (explicit `.none`); clicking any other texture output points the preview at
    /// it. Graph state, persisted with the project like `position`. Returns the applied body.
    ///
    /// A `.custom` body is refused (returned unchanged): the photo glyph is hidden while a card fills
    /// the slot, and swapping the card away stays an explicit act (context menu, `ui_set_node_body`).
    /// Resolves through `applyNodeBody` — the one body-edit path.
    @discardableResult
    func toggleNodePreview(node id: SZNodeID, port: String) -> SZNodeBody? {
        guard let node = store.project?.graph.node(id: id) else { return nil }
        guard node.body?.mode != .custom else { return node.body }
        return try? applyNodeBody(node: id, mode: node.effectivePreviewPort == port ? .none : .preview, port: port)
    }

    /// Fold or unfold a card's port rows — the chevron pill and the context menu's Hide/Show Plugs.
    /// The card keeps its TOP edge: the collapse always removes a whole number of grid cells, so
    /// moving the centre by half of that leaves all four edges on grid for any row count. The move
    /// lands before the body write, so the pair persists once.
    @discardableResult
    func toggleNodePlugs(node id: SZNodeID) -> SZNodeBody? {
        guard let node = store.project?.graph.node(id: id),
              SZNodeLayout.canFoldPlugs(node, previewsEnabled: livePreviews) else { return nil }
        let folding = SZNodeLayout.showsPlugs(of: node, previewsEnabled: livePreviews)
        let shift = SZNodeLayout.foldDelta(of: node, previewsEnabled: livePreviews) / 2
        if shift != 0 {
            // Folding shrinks the card, so the CENTRE rises by half the loss to leave the top edge put.
            _ = store.moveNode(id: id, to: SZPoint(x: node.position.x,
                                                   y: node.position.y + (folding ? -shift : shift)))
        }
        return try? applyNodeBody(node: id, mode: node.effectiveBodyMode, port: node.effectivePreviewPort,
                                  plugs: !folding)
    }

    // MARK: - Watch-set maintenance (event-driven)

    /// The editor's visible-node report (SZNodeEditorPanel → SZApp closure). `nil` until the first
    /// report — no culling then, so headless/MCP sessions (no editor panel mounted) still stream.
    func setVisiblePreviewNodes(_ nodes: Set<SZNodeID>) {
        visiblePreviewNodes = nodes
        refreshPreviewStream()
    }

    /// Project-switch teardown — the ONE unwatch home (clearPerProjectState calls it): cancel any
    /// pending refresh, forget the old project's visible-set report (the panel re-reports for the
    /// new graph), and unwatch everything. A late in-flight publish is dropped by
    /// `applyPreviewFrames`' re-validation; this just stops encoding for a dead graph.
    func resetPreviewStreamForProjectSwitch() {
        previewWatchDebounce?.cancel()
        previewWatchDebounce = nil
        visiblePreviewNodes = nil
        lastPushedWatchKeys = []
        runtime?.setWatchedPreviews([], maxDimension: Self.previewMaxDimension)
        applyRenderDrive()
    }

    /// Recompute the watched set NOW and push it to the runtime iff it changed. Cheap (one graph
    /// scan + ordered-key compare), so every mutation chokepoint just calls it. The watch set is also
    /// the thumbs' demand on the render loop (each push re-applies the render drive), and it empties
    /// when the main window — the node editor's only home — can't show pixels.
    func refreshPreviewStream() {
        cardHostStorage?.graphDidChange()   // custom cards ride the same graph hook (SZCardHostController)
        guard let runtime else { return }
        // a renderer without thumbnails leaves the Metal loop nothing to run for
        guard livePreviews, capabilities.streamsPreviews, popoutManager.mainWindowIsDisplayable,
              let graph = store.project?.graph else {
            if lastPushedWatchKeys != [] {
                lastPushedWatchKeys = []
                runtime.setWatchedPreviews([], maxDimension: Self.previewMaxDimension)
                applyRenderDrive()
            }
            return
        }
        previewFrames.prune(keeping: Set(graph.nodes.map(\.id)))
        var wanted: [(node: SZNodeID, port: String)] = []
        for node in graph.nodes {
            guard let port = node.effectivePreviewPort else { continue }
            if let visible = visiblePreviewNodes, !visible.contains(node.id) { continue }
            wanted.append((node.id, port))
            if wanted.count == Self.previewMaxThumbs { break }
        }
        let keys = wanted.map { "\($0.node.uuidString):\($0.port)" }
        guard keys != lastPushedWatchKeys else { return }
        lastPushedWatchKeys = keys
        runtime.setWatchedPreviews(wanted, maxDimension: Self.previewMaxDimension)
        applyRenderDrive()
    }

    /// Observe the store for graph edits (every `mutate` reassigns `project`, so this fires on any
    /// edit — including drags, which the 100ms debounce + set-compare absorb) and re-arm. The one
    /// event source `refreshPreviewStream`'s explicit call sites can't cover: agent-driven edits
    /// that add/remove/retarget texture nodes mid-run.
    func armPreviewGraphObservation() {
        withObservationTracking {
            _ = store.project?.graph
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.schedulePreviewWatchRefresh()
                self.armPreviewGraphObservation()
            }
        }
    }

    private func schedulePreviewWatchRefresh() {
        previewWatchDebounce?.cancel()
        previewWatchDebounce = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            self?.refreshPreviewStream()
        }
    }

    // MARK: - Frame delivery

    /// Install the runtime→host publish path (called once from `start()`). The runtime callback
    /// fires on Metal's completion thread — hop to the main actor and apply.
    func installPreviewFrameSink(_ runtime: SZRuntime) {
        runtime.setPreviewFrameCallback { [weak self] frames in
            Task { @MainActor [weak self] in
                self?.applyPreviewFrames(frames)
            }
        }
    }

    /// Write published surfaces into the cards' frame boxes — re-validating each against the LIVE
    /// graph first: a publish races project switches, deletes, and retargets (the pass was encoded
    /// against an older world), and a stale write would resurrect pruned boxes.
    private func applyPreviewFrames(_ frames: [SZNodePreviewSurface]) {
        // a pass encoded before a switch to a renderer without thumbnails lands after the clear
        guard livePreviews, capabilities.streamsPreviews, let graph = store.project?.graph else { return }
        for frame in frames {
            guard let node = graph.node(id: frame.node),
                  node.effectivePreviewPort == frame.port else { continue }
            previewFrames.frame(for: frame.node).surface = frame.surface
        }
    }
}
