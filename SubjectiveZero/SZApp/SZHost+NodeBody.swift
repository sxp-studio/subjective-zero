// SPDX-License-Identifier: AGPL-3.0-only
// The one body-edit path for a node card: `applyNodeBody` turns a mode + optional datum into a
// validated `SZNodeBody` and lands it through `setNodeBody` (the previews' store-write →
// stale-thumb-drop → persist → watch-set-refresh choreography). Every caller — the MCP tool, the
// context-menu toggle, the card host's auto-size, the failed chip's "Hide Custom Card", promote's
// first-card flip, library instantiate — resolves through it, so preview and custom bodies can
// never disagree about what a valid body is.
import Foundation
import SZCore
import SZUI

extension SZHost {
    struct NodeBodyError: Error, CustomStringConvertible {
        let description: String
    }

    /// Custom-card mounts (compile/load lifecycle, per-node instances, card channels —
    /// SZCardHostController). Created on first access.
    var cardHost: SZCardHostController {
        if let cardHostStorage { return cardHostStorage }
        let controller = SZCardHostController(host: self)
        cardHostStorage = controller
        return controller
    }

    /// Whether `node`'s folder holds a `Card.swift` right now.
    func nodeHasCardSource(_ id: SZNodeID) -> Bool {
        guard let projectURL = loadedProjectURL else { return false }
        return FileManager.default.fileExists(atPath: SZProjectIO.cardSourceURL(projectURL: projectURL, nodeID: id).path)
    }

    /// Resolve and apply a body edit. Rules:
    /// - `.none`: compact card.
    /// - `.preview`: `port` must be a texture output; omitted, the shared default rule picks one
    ///   (`preferredTextureOutput` — the SAME pick the card's auto-preview shows). No texture
    ///   output → rejected, so the persisted body is always renderable.
    /// - `.custom`: the node's folder must hold a `Card.swift` (the mount reads it; whether it
    ///   compiles is the mount's business — geometry never depends on a build). Re-applying custom
    ///   carries the committed `cols`/`rows`/`pinned` forward unless overridden (auto-size can't
    ///   strip a pin; a pin can't drop the footprint); nothing is seeded — an unset footprint reads
    ///   the contract's `card` hints in the layout, so a later hint change reaches existing cards.
    ///   Flipping rows↔custom never touches the file on disk.
    /// `plugs` is orthogonal to all three and carried forward unless overridden, so the card host's
    /// auto-size re-apply can never unfold a card behind the user's back.
    /// Returns the applied body.
    @discardableResult
    func applyNodeBody(node id: SZNodeID, mode: SZNodeBodyMode, port: String? = nil,
                       cols: Int? = nil, rows: Int? = nil, pinned: Bool? = nil,
                       plugs: Bool? = nil, origin: SZMutationOrigin = .user) throws -> SZNodeBody {
        guard let node = store.project?.graph.node(id: id) else { throw NodeBodyError(description: "no node \(id)") }
        // Body is a generated-card affordance: a prompt card is a single field with no body region.
        guard node.kind == .generated else {
            throw NodeBodyError(description: "node \(id) is a prompt card — it has no body region")
        }
        var body: SZNodeBody
        switch mode {
        case .none:
            body = SZNodeBody(mode: .none)
        case .preview:
            let outputs = node.contract?.outputs ?? []
            if let port {
                guard outputs.contains(where: { $0.name == port && $0.type == .texture }) else {
                    throw NodeBodyError(description: "node \(id) has no texture output port '\(port)'")
                }
                body = SZNodeBody(mode: .preview, previewPort: port)
            } else if let port = outputs.preferredTextureOutput?.name {
                body = SZNodeBody(mode: .preview, previewPort: port)
            } else {
                throw NodeBodyError(description: "node \(id) has no texture output to preview")
            }
        case .custom:
            guard nodeHasCardSource(id) else {
                throw NodeBodyError(description: "node \(id) has no Card.swift — stage one with agent_write_node_staged { card }")
            }
            let previous = node.body?.mode == .custom ? node.body?.custom : nil
            body = SZNodeBody(mode: .custom, custom: SZCustomCardRef(
                cols: (cols ?? previous?.cols).map { max(6, min($0, 24)) },
                rows: (rows ?? previous?.rows).map { max(2, min($0, 24)) },
                pinned: pinned ?? previous?.pinned))
        }
        body.plugs = plugs ?? node.body?.plugs
        guard setNodeBody(node: id, body: body, origin: origin) else {
            throw NodeBodyError(description: status)
        }
        return body
    }
}
