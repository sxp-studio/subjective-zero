// SPDX-License-Identifier: AGPL-3.0-only
// Graph-menu intents (Tidy Graph, Center View, Zoom to Fit) plus the one-shot reveal that slides
// agent-added cards into view. Tidy is a pure node-position edit committed through the shared
// SZStore.moveNodes path (the layout math lives in SZUI's SZGraphLayout, which SZCore can't reach —
// so the host, not the store, drives it). The camera commands can't run here at all: the editor's
// zoom/offset is panel-local @State, so the host just raises a one-shot `cameraCommand` the panel
// observes and applies (see SZNodeEditorPanel.applyCameraCommand).
import Foundation
import SZCore
import SZUI

extension SZHost {
    /// Graph ▸ Tidy Graph (and `ui_tidy_graph`) — reflow every node into clean left-to-right dependency
    /// layers, committed as one `moveNodes` transaction (one re-render / one persist). Pure position
    /// change: no runtime reload needed, so it persists like a node drag (`persistProject`, not
    /// `…AndReload`). Returns the applied `[node: center]` (empty on no-op / no project / no nodes) so
    /// the MCP handler can echo the truth to the agent.
    @discardableResult
    func tidyGraph() -> [SZNodeID: SZPoint] {
        guard let graph = store.project?.graph, !graph.nodes.isEmpty else { return [:] }
        let tidied = SZGraphLayout.tidied(nodes: graph.nodes, connections: graph.connections,
                                          anchor: graph.renderEndpoint?.node,
                                          previewsEnabled: livePreviews)
        guard !tidied.isEmpty else { return [:] }
        store.moveNodes(tidied.map { (id: $0.key, to: $0.value) })
        persistProject()
        return tidied
    }

    /// Graph ▸ Center View — recenter the node-editor camera on the graph (zoom unchanged).
    func centerView() { cameraCommand = SZCameraCommand(action: .center) }

    /// Graph ▸ Zoom to Fit — frame the whole graph in the node editor (zoom + offset).
    func zoomToFit() { cameraCommand = SZCameraCommand(action: .fit) }

    /// An agent added nodes: raise one `.reveal` per burst. The Director adds one node per tool call
    /// over a few seconds; the 80ms debounce folds adds that arrive together. Whether the camera
    /// moves is the panel's call (SZCanvasReveal).
    func revealAgentAddedNodes(_ ids: Set<SZNodeID>) {
        pendingReveal.formUnion(ids)
        revealDebounce?.cancel()
        revealDebounce = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled, let self else { return }
            cameraCommand = SZCameraCommand(action: .reveal(nodes: pendingReveal, askedAt: lastUserAskAt))
            pendingReveal = []
        }
    }
}
