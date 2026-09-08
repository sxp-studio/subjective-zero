// SPDX-License-Identifier: AGPL-3.0-only
// The Library panel's and the node menu's doors into the one copy path: place, add from the canvas
// menu, duplicate, apply to copies, save. Each turns a thrown error into a status line naming the node.
import AppKit
import Foundation
import SZCore
import SZUI

extension SZHost {
    /// A row dropped on the canvas, or Return in the panel with a click point remembered.
    func placeFromLibrary(_ ref: SZLibraryRef, at position: SZPoint) {
        libraryPlacementRequest = nil
        do {
            try placeLibraryItem(ref, position: position, deferBuild: true)
        } catch {
            status = "Couldn't add \(libraryTitle(ref)): \(error.localizedDescription)"
        }
    }

    /// Return or double-click in the panel: the remembered click point, else the visible canvas centre.
    func placeFromLibrary(_ ref: SZLibraryRef) {
        placeFromLibrary(ref, at: libraryPlacementRequest ?? canvasVisibleCenter ?? SZPoint(x: 0, y: 0))
    }

    /// The canvas menu's Add from Library: open the panel if needed, focus its search, and remember
    /// where the click was so the next placement lands there.
    func addFromLibrary(at position: SZPoint) {
        libraryPlacementRequest = position
        if !panelLayout.contains(.library) { showPanel(.library) }
        libraryFocusRequest += 1
    }

    /// The panel's section header: shut an open group or open a shut one, remembered with the prefs.
    func toggleLibraryGroup(_ group: SZLibraryGroup) {
        if libraryCollapsedGroups.contains(group) {
            libraryCollapsedGroups.remove(group)
        } else {
            libraryCollapsedGroups.insert(group)
        }
        persistAppState()
    }

    /// A built node can be duplicated; a prompt node has nothing to copy yet.
    func canDuplicate(_ id: SZNodeID?) -> Bool {
        guard let id, let node = store.project?.graph.node(id: id) else { return false }
        return node.kind == .generated && node.contract != nil
    }

    /// A second copy with its own values and lineage back to the original; beside it unless placed.
    @discardableResult
    func duplicateNode(_ id: SZNodeID, at position: SZPoint? = nil, origin: SZMutationOrigin = .user,
                       deferBuild: Bool = false) throws -> SZNodeID {
        guard let node = store.project?.graph.node(id: id) else { throw SZMCPError.message("no node \(id)") }
        let beside = SZPoint(x: node.position.x + SZNodeLayout.width + 24, y: node.position.y)
        return try placeLibraryItem(.projectNode(id), position: position ?? beside, origin: origin,
                                    deferBuild: deferBuild)
    }

    /// The node menu's and ⌘D's Duplicate.
    func duplicateNode(_ id: SZNodeID) {
        do {
            try duplicateNode(id, at: nil, deferBuild: true)
        } catch {
            status = "Couldn't duplicate \(mutationTitle(id)): \(error.localizedDescription)"
        }
    }

    /// How many copies of this node are still untouched since they were copied: the node menu's
    /// "Apply to N Copies" count; 0 hides the row.
    func applyToCopiesCount(_ id: SZNodeID) -> Int {
        lineage(of: id)?.copies.filter(\.inSync).count ?? 0
    }

    /// The node menu's Apply to Copies; the host method sets the status line itself.
    func applyToCopies(_ id: SZNodeID) {
        do {
            try applyNodeToCopies(source: id, to: nil, origin: .user)
        } catch {
            status = error.localizedDescription
        }
    }

    /// Open Settings on the Library section.
    func presentLibrarySettings() {
        requestedSetupSection = .library
        presentProviderSetup()
    }

    /// The Save to Library sheet's Save: a failure lands in the status line, the sheet closes either way.
    func saveToLibraryFromSheet(node id: SZNodeID, name: String, line: String) {
        do {
            try saveNodeToLibrary(node: id, name: name, line: line)
        } catch {
            status = "Couldn't save \(mutationTitle(id)): \(error.localizedDescription)"
        }
        saveToLibraryNode = nil
    }

    /// Settings ▸ Library ▸ Show in Finder.
    func revealMyLibrary() {
        NSWorkspace.shared.activateFileViewerSelecting([myLibraryURL])
    }

    /// Settings ▸ Library ▸ Move…: pick a folder; it becomes the library's new home.
    func moveMyLibraryViaPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose where \(SZLibrarySourceID.mine.displayName) should live"
        panel.prompt = "Move"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try moveMyLibrary(to: url)
        } catch {
            status = "Couldn't move \(SZLibrarySourceID.mine.displayName): \(error.localizedDescription)"
        }
    }

    private func libraryTitle(_ ref: SZLibraryRef) -> String {
        switch ref {
        case .library(let source, let id): libraryTitle(source: source, id: id)
        case .projectNode(let id): mutationTitle(id)
        }
    }
}
