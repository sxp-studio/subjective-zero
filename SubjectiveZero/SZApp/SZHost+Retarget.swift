// SPDX-License-Identifier: AGPL-3.0-only
// Switching the open project's target platform in place: every node's built-for-target flag is re-read
// from disk, library twins are copied in without an agent, and a conversion run covers the rest. A node
// keeps one source per platform side by side, so switching back needs nothing once both exist.
import Foundation
import SZCore

/// One conversion in flight or just finished: which nodes it touched and how. The Target Platform pane
/// derives its report from this plus each node's platform flag and status line.
struct SZConversionState: Equatable {
    let target: SZProjectTarget
    /// Nodes whose library twin was copied at the switch: ready without an agent.
    var copied: Set<SZNodeID>
    /// Nodes handed to the conversion run.
    var queued: Set<SZNodeID>
    /// Nodes whose library says they can never run here, with the reason. Reported, never queued:
    /// an agent asked to write a file that cannot exist would burn a turn and fail.
    var unsupported: [SZNodeID: String] = [:]
    /// The run's task, once minted; nil when nothing needed a run.
    var taskID: UUID?
}

extension SZHost {
    /// Re-read every built node's platforms from disk and point it at the active target.
    func refreshTargetBuilds() {
        guard let projectURL = loadedProjectURL, store.project != nil else { return }
        store.mutate { project in
            for i in project.graph.nodes.indices where project.graph.nodes[i].kind == .generated {
                let built = SZProjectIO.builtTargets(projectURL: projectURL, nodeID: project.graph.nodes[i].id)
                project.graph.nodes[i].builtTargets = built
                project.graph.nodes[i].builtForTarget = built.contains(project.target)
                project.graph.nodes[i].activeTarget = project.target
            }
        }
    }

    /// Per platform: how many built nodes have a source for it that still matches their contract and
    /// prompt. The pane's row status.
    func builtNodeCount(for target: SZProjectTarget) -> Int {
        (store.project?.graph.nodes ?? []).filter { $0.kind == .generated && $0.hasCurrentBuild(for: target) }.count
    }

    /// Switch the open project to `target`: flip and persist the target, remount the backend, copy library
    /// twins, and start a conversion run over every built node still missing a source. A no-op on the
    /// active target. Refused while a run owns the project.
    func setProjectTarget(_ target: SZProjectTarget) async {
        guard let projectURL = loadedProjectURL, let project = store.project, project.target != target else { return }
        guard !isBusyForProjectSwitch, !agentsOwnProject else {
            status = "busy: stop the run before switching platforms"
            return
        }
        // The pane's Mac row keeps its Switch off without the tools; this covers every other caller.
        guard target != .native || !toolchainMissing else {
            status = "switching to this Mac needs Apple's developer tools"
            presentTargetPlatformSettings()
            return
        }
        openingProject = project.name
        defer { openingProject = nil }
        // 1. The project is the other platform's from here: flip, pin, flag every node against disk.
        store.mutate { project in
            project.target = target
            if target == .web, project.web == nil { project.web = SZProjectWeb() }
        }
        refreshTargetBuilds()
        // 2. Library twins need no agent: copy the other platform's file beside the existing one.
        var copied: Set<SZNodeID> = []
        let fm = FileManager.default
        for node in conversionPlan(for: target).copied {
            guard let twin = libraryTwin(of: node, for: target) else { continue }
            let live = SZProjectIO.nodeSourceURL(projectURL: projectURL, nodeID: node.id, target: target)
            do {
                try fm.createDirectory(at: live.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.removeItem(at: live)
                try fm.copyItem(at: twin.file, to: live)
                copied.insert(node.id)
                // the twin implements what the source platform's build did: same stamp. The file
                // just written IS the library's own, so the copy is untouched on this platform too.
                let hash = (try? Data(contentsOf: live)).map(Self.contentHash)
                store.mutate { project in
                    guard let i = project.graph.nodes.firstIndex(where: { $0.id == node.id }) else { return }
                    project.graph.nodes[i].buildStamps[target] = project.graph.nodes[i].buildStamps[twin.from]
                    if let hash, project.graph.nodes[i].copiedHash != nil {
                        project.graph.nodes[i].copiedHash = hash
                        project.graph.nodes[i].copiedTarget = target
                    }
                }
            } catch {
                print("[SZHost] library twin copy failed for \(node.title): \(error)")
            }
        }
        refreshTargetBuilds()
        if let project = store.project {
            do { try SZProjectIO.save(project, to: projectURL) } catch { presentProjectError("Couldn't save the project", error) }
        }
        // 3. Render with the new platform's backend; a rolling take ends with the renderer it taps.
        finalizeActiveTakeBlocking()
        await remountBackend(at: projectURL)
        rewatchNodeSources()
        classifyRebuildsAfterLoad()
        refreshLibraryItems()   // the panel offers what the new platform can run
        // 4. Everything still missing or behind its contract goes to a conversion run.
        // A node whose library declares this platform a wall is reported, not queued.
        let walls = unsupportedNodes(for: target)
        let queued = Set((store.project?.graph.nodes ?? [])
            .filter { $0.kind == .generated && !$0.hasCurrentBuild(for: target) && walls[$0.id] == nil }
            .map(\.id))
        var state = SZConversionState(target: target, copied: copied, queued: queued,
                                      unsupported: walls, taskID: nil)
        if !queued.isEmpty {
            let platform = target == .web ? "the browser" : "this Mac"
            state.taskID = mintRun(
                instruction: "Convert this project for \(platform): every node in this run needs its "
                    + "\(target.sourceFileName) written, or brought up to its contract where the file is behind it. "
                    + "Keep every contract and wire as they are.",
                title: "Convert for \(platform)", nodes: queued, intent: .convert)
        }
        conversion = state
        status = "now runs \(target.displayName.lowercased())"
    }

    /// The nodes a switch to `target` would touch (no file for it, or a file behind the contract): those
    /// with a pristine library twin are copied, the rest go to the conversion run.
    func conversionPlan(for target: SZProjectTarget) -> (copied: [SZNode], queued: [SZNode]) {
        var copied: [SZNode] = []
        var queued: [SZNode] = []
        let walls = unsupportedNodes(for: target)
        for node in store.project?.graph.nodes ?? [] where node.kind == .generated && !node.hasCurrentBuild(for: target) {
            guard walls[node.id] == nil else { continue }
            if libraryTwin(of: node, for: target) != nil { copied.append(node) } else { queued.append(node) }
        }
        return (copied, queued)
    }

    /// Placed nodes whose library node declares `target` a wall, each with the reason to show. Read
    /// from the library's contract, not the project's copy: the wall is a fact about the node, and a
    /// project carries only a copy of its source.
    func unsupportedNodes(for target: SZProjectTarget) -> [SZNodeID: String] {
        var walls: [SZNodeID: String] = [:]
        for node in store.project?.graph.nodes ?? [] where !node.hasCurrentBuild(for: target) {
            guard let ref = node.libraryRef,
                  case .library(let source, let id) = ref,
                  let entry = libraryEntries.first(where: { $0.source == source && $0.entry.id == id }),
                  let reason = entry.portability(for: target).wall else { continue }
            walls[node.id] = reason
        }
        return walls
    }

    /// The library's `target` source for a node placed from the library, and the built platform whose
    /// source still is the library's own (so the twin implements the same thing). An edited node keeps
    /// its edits: it goes to the agent with them instead.
    private func libraryTwin(of node: SZNode, for target: SZProjectTarget) -> (file: URL, from: SZProjectTarget)? {
        guard let ref = node.libraryRef, let projectURL = loadedProjectURL,
              let folder = libraryFolder(ref) else { return nil }
        let fm = FileManager.default
        let twin = folder.appending(path: target.sourceFileName)
        guard fm.fileExists(atPath: twin.path) else { return nil }
        let pristine = node.builtTargets.first { built in
            let shipped = folder.appending(path: built.sourceFileName)
            let live = SZProjectIO.nodeSourceURL(projectURL: projectURL, nodeID: node.id, target: built)
            return !node.isStale(for: built) && fm.fileExists(atPath: shipped.path)
                && fm.contentsEqual(atPath: shipped.path, andPath: live.path)
        }
        return pristine.map { (twin, $0) }
    }

    /// Bring up the new platform's renderer on the open project: the same prepare, commit and mount as
    /// opening it (SZHost+Backend).
    func remountBackend(at url: URL) async {
        guard let runtime, let project = store.project else { return }
        do {
            let prepared = try await prepareBackend(for: project, at: url, runtime: runtime)
            try runtime.commit(prepared.native)
            mountBackend(prepared)
            if let page = prepared.page {
                do { try page.loadProject(project, at: url) } catch { print("[SZHost] web project load failed: \(error)") }
            }
        } catch {
            presentProjectError("Couldn't switch the platform", error)
        }
        previewFrames.clear()
        refreshPreviewStream()
        applyRenderDrive()
    }

    /// Stop the conversion run, leaving converted nodes converted.
    func stopConversion() {
        guard let taskID = conversion?.taskID else { return }
        if let run = activeRuns[taskID] { cancelRun(run) } else { withdrawTask(taskID) }
    }
}

extension SZHost {
    /// Placing a library node this project's platform has no source for: the other platform's copy
    /// is already in the node's folder, so this is the same conversion a target switch runs, over
    /// one node. Whatever it writes is kept as a port when the node next builds
    /// (`keepLibraryPortIfNew`), so nobody has to do it again.
    func startPortRun(_ id: SZNodeID, title: String, from source: SZProjectTarget) {
        nodeAgentState[id] = SZNodeAgentState(phase: .reloading)
        let platform = projectTarget == .web ? "the browser" : "this Mac"
        _ = mintRun(
            instruction: "Write \(title)'s \(projectTarget.sourceFileName) for \(platform), from the "
                + "\(source.sourceFileName) already in its folder. Keep its contract and its ports as they are.",
            title: "Port \(title) to \(platform)", nodes: [id], intent: .convert)
        status = "Porting \(title) to \(platform)"
    }
}
