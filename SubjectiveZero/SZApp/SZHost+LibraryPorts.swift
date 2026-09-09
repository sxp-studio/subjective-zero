// SPDX-License-Identifier: AGPL-3.0-only
// The ports overlay: where a node's source for a platform lands when it was written after the fact.
//
// The question this answers is where a port GOES so it never has to happen again. Not into the
// project, or the next project redoes it. Not into the node's own folder either: the built-in
// library lives in a read-only app bundle, and a library fetched from a link is replaced whole by
// its next update. So a port is a file beside the library rather than inside it, at
// `<AppSupport>/ports/<library key>/<node id>/Node.js`. It outlives the library's updates and the
// app's, and it goes when the library goes. A port is a contribution to the library, not a fix to
// one project.
import Foundation
import SZCore

extension SZHost {
    /// Where ports written on this Mac live. One folder per library key, mirroring the library.
    nonisolated static var libraryPortsURL: URL {
        SZAppSupport.directory.appending(path: "ports")
    }

    nonisolated static func libraryPortsURL(source: SZLibrarySourceID) -> URL {
        libraryPortsURL.appending(path: source.rawValue)
    }

    /// The overlay folder for one node, whether or not anything is in it.
    nonisolated static func libraryPortURL(source: SZLibrarySourceID, id: String) -> URL {
        libraryPortsURL(source: source).appending(path: id)
    }

    /// The platforms a node has a source for anywhere: its own folder, plus any port written here.
    /// One place, so the panel, the agents' index and placement can never disagree about it.
    nonisolated static func builtTargets(folder: URL, source: SZLibrarySourceID, id: String) -> Set<SZProjectTarget> {
        let fm = FileManager.default
        let overlay = libraryPortURL(source: source, id: id)
        return Set(SZProjectTarget.allCases.filter {
            fm.fileExists(atPath: folder.appending(path: $0.sourceFileName).path)
                || fm.fileExists(atPath: overlay.appending(path: $0.sourceFileName).path)
        })
    }

    /// Where to copy a node's source for `target` from: its own folder when it has one, else the
    /// port written here. Nil when neither exists.
    nonisolated static func librarySourceURL(folder: URL, source: SZLibrarySourceID, id: String,
                                             target: SZProjectTarget) -> URL? {
        let fm = FileManager.default
        let own = folder.appending(path: target.sourceFileName)
        if fm.fileExists(atPath: own.path) { return own }
        let ported = libraryPortURL(source: source, id: id).appending(path: target.sourceFileName)
        return fm.fileExists(atPath: ported.path) ? ported : nil
    }

    /// Keep a port for a library node. The overlay is created on the way.
    nonisolated static func writeLibraryPort(source: SZLibrarySourceID, id: String,
                                             target: SZProjectTarget, contents: String) throws {
        let folder = libraryPortURL(source: source, id: id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try contents.write(to: folder.appending(path: target.sourceFileName), atomically: true, encoding: .utf8)
    }

    /// Forget every port for a library, when the library itself is forgotten.
    nonisolated static func removeLibraryPorts(source: SZLibrarySourceID) {
        try? FileManager.default.removeItem(at: libraryPortsURL(source: source))
    }
}

extension SZHost {
    /// A node placed from a library just built for a platform its library has no source for: keep
    /// that file as the library's port, so the next project gets it without an agent.
    ///
    /// Called on every successful reload, and does nothing on all but the first: once the port is
    /// there, the library has a source for the platform and the condition below is false.
    func keepLibraryPortIfNew(_ id: SZNodeID, in projectURL: URL) {
        guard case .library(let source, let entryID)? = store.project?.graph.node(id: id)?.libraryRef,
              let entry = libraryEntries.first(where: { $0.source == source && $0.entry.id == entryID }),
              !entry.builtTargets.contains(projectTarget) else { return }
        let live = SZProjectIO.nodeSourceURL(projectURL: projectURL, nodeID: id, target: projectTarget)
        guard let contents = try? String(contentsOf: live, encoding: .utf8), !contents.isEmpty else { return }
        do {
            try Self.writeLibraryPort(source: source, id: entryID, target: projectTarget, contents: contents)
        } catch {
            print("[SZHost] couldn't keep the port for \(entryID): \(error)")
            return
        }
        refreshLibraryItems()   // the row stops being dimmed
        status = "\(libraryTitle(source: source, id: entryID)) now works \(projectTarget.placeName) too"
    }
}
