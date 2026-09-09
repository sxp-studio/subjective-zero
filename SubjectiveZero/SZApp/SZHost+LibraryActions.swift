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
        // Porting needs an agent. The row's button is already inert without one, but Return and
        // double-click reach here too, so the refusal lives on the one path all three share.
        if needsAPort(ref), defaultProviderID == nil {
            status = "\(libraryTitle(ref)) doesn't run \(projectTarget.placeName) yet, and no agent is set up to port it"
            presentProviderSetup()
            return
        }
        do {
            try placeLibraryItem(ref, position: position, deferBuild: true)
        } catch {
            status = "Couldn't add \(libraryTitle(ref)): \(error.localizedDescription)"
        }
    }

    /// Whether placing this would have to write a source the library has none of for this platform.
    private func needsAPort(_ ref: SZLibraryRef) -> Bool {
        guard case .library(let source, let id) = ref,
              let entry = libraryEntries.first(where: { $0.source == source && $0.entry.id == id })
        else { return false }
        return entry.portability(for: projectTarget) == .portable
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
        // Next turn, not this one: when the panel was closed it is created by this same update, and
        // a view does not see a change that happened before it existed.
        Task { @MainActor in libraryFocusRequest += 1 }
    }

    /// The panel's section header: shut an open section or open a shut one, remembered with the prefs.
    func toggleLibrarySection(_ id: String) {
        if libraryCollapsedGroups.contains(id) {
            libraryCollapsedGroups.remove(id)
        } else {
            libraryCollapsedGroups.insert(id)
        }
        persistAppState()
    }

    /// The panel's grouping menu: sections become what a node does, or which library it came from.
    /// Shut sections are keyed by section id, so each axis remembers its own independently.
    func setLibraryGrouping(_ grouping: SZLibraryGrouping) {
        guard grouping != libraryGrouping else { return }
        libraryGrouping = grouping
        persistAppState()
    }

    /// What a node is and where it came from, for the top of its right-click menu. One line, in the
    /// order a person asks it: what it does, then whose it was, then whether it has drifted.
    ///
    /// A placed node otherwise shows a title and its ports and nothing else, which leaves no way to
    /// tell a library copy from a node an agent wrote — the distinction the whole copies-not-links
    /// design rests on.
    func nodeProvenance(_ id: SZNodeID) -> String? {
        guard let node = store.project?.graph.node(id: id) else { return nil }
        var parts: [String] = []
        if let summary = node.contract?.summary, !summary.isEmpty {
            parts.append(summary.split(separator: ".").first.map { "\($0)." } ?? summary)
        }
        switch lineage(of: id)?.origin {
        case .library(let ref):
            if case .library(let source, let entry) = ref {
                parts.append("From \(libraryName(source)): \(libraryTitle(source: source, id: entry))")
            }
        case .node(_, let title):
            parts.append("Copy of \(title)")
        case nil:
            if node.kind == .generated, node.prompt?.isEmpty == false { parts.append("Written for this project") }
        }
        if lineage(of: id)?.changed == true { parts.append("changed since") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
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

    /// The description strip was dragged. A panel preference, so it rides with the prefs.
    func setLibraryDetailHeight(_ height: CGFloat) {
        guard abs(libraryDetailHeight - Double(height)) > 0.5 else { return }
        libraryDetailHeight = Double(height)
        persistAppState()
    }

    // MARK: adding and updating libraries

    /// Settings ▸ Library ▸ Add Library: the folder picker, returning the path it chose.
    func chooseLibraryFolder() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose a folder of nodes"
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    /// The Add Library sheet's Add. A path is a folder, anything else is read as a link. Returns nil
    /// when it worked, else the sentence the sheet shows.
    func addLibrary(_ entry: String) async -> String? {
        do {
            if entry.hasPrefix("/") || entry.hasPrefix("~") {
                let path = (entry as NSString).expandingTildeInPath
                try addLibraryFolder(at: URL(filePath: path))
            } else {
                try await addLibraryLink(entry)
            }
            addLibraryPresented = false
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Settings ▸ Library ▸ Check for Updates: the sentence for the row, whether there is anything to
    /// move to, and the offer kept for Update. A check that failed says so and arms nothing.
    func checkForLibraryUpdate(key: String) async -> (note: String, hasUpdate: Bool) {
        do {
            let update = try await libraryUpdate(key: key)
            guard update.offered else {
                discardStagedUpdate(key: key)
                pendingLibraryUpdates[key] = nil
                return (update.note, false)
            }
            discardStagedUpdate(key: key)
            pendingLibraryUpdates[key] = update
            return (update.note, true)
        } catch {
            discardStagedUpdate(key: key)
            pendingLibraryUpdates[key] = nil
            return (error.localizedDescription, false)
        }
    }

    /// Settings ▸ Library ▸ Update: apply what the check found.
    func applyLibraryUpdate(key: String) async -> String {
        guard let update = pendingLibraryUpdates[key] else { return "Check for updates first" }
        do {
            try await applyLibraryUpdate(key: key, to: update)
            pendingLibraryUpdates[key] = nil
            return "Updated: \(update.summary)"
        } catch {
            discardStagedUpdate(key: key)
            pendingLibraryUpdates[key] = nil
            return error.localizedDescription
        }
    }

    /// Show an added folder library in the Finder.
    func revealLibrary(_ library: SZAddedLibrary) {
        NSWorkspace.shared.activateFileViewerSelecting([addedLibraryURL(library)])
    }

    /// Open Settings on the Library section.
    func presentLibrarySettings() {
        setupSection = .library
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
