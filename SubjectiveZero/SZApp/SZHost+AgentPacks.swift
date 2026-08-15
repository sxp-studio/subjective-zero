// SPDX-License-Identifier: AGPL-3.0-only
// The bundled agent packs' host policy: materialize the SZAI-bundled pack tree into
// Application Support — the packs root every consumer (runs, the Plan panel, the debug
// tools) then reads — arm hot reload over the compiled steps, and resolve the Director's
// run-graph VARIANT (env > persisted > pack default).
//
// MATERIALIZED rather than read in place: bundled resources live inside the app bundle,
// which is read-only in an installed, signed .app — so the WRITABLE copy is the one the
// user edits, and it survives relaunches. Ours-or-theirs is decided by CONTENT, not by
// mtime: the manifest beside the root records a hash of every byte we wrote, so a copy
// still holding those bytes is ours and follows the bundle in EITHER direction (an update,
// a downgrade, a stale debug build sharing this Application Support), while a copy the
// user changed is theirs and stays. Prompt templates need no watcher: SZBriefRenderer
// reads them from disk per render, so a saved edit reaches the very next turn. Step
// sources DO need one — a step is compiled code, and the step runtime swaps modules on
// green.
import AppKit
import CryptoKit
import Foundation
import SZAI
import SZCore
import SZRuntime
import SZUI
import UniformTypeIdentifiers

extension SZHost {
    /// `~/Library/Application Support/SubjectiveZero/agents` — where the bundled packs
    /// materialize, and the packs root the host uses unless `SZ_AGENT_PACKS` overrides
    /// (see `graphAgentPacksRoot`).
    nonisolated static var materializedAgentPacksRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "SubjectiveZero/agents")
    }

    /// Sync every bundled pack into the materialized root (see `syncAgentPack`), then arm
    /// the step watchers. Called once at `start`, before anything reads packs.
    func materializeAgentPacks() {
        guard let bundled = SZAgentPackLoader.bundledRoot else {
            print("[SZHost] no bundled agent packs to materialize")
            return
        }
        let fm = FileManager.default
        let root = Self.materializedAgentPacksRoot
        for agent in ((try? fm.contentsOfDirectory(atPath: bundled.path)) ?? []).sorted() {
            let bundledAgent = bundled.appending(path: agent)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: bundledAgent.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }
            do {
                let manifest = try Self.syncAgentPack(
                    from: bundledAgent, to: root.appending(path: agent),
                    previous: Self.materializedManifest(for: agent),
                    log: { print("[SZHost] agent packs: \(agent)/\($0)") })
                Self.writeMaterializedManifest(manifest, for: agent)
            } catch {
                print("[SZHost] agent pack \(agent): could not materialize — \(error)")
            }
        }
        agentGraphPlanCache = nil   // the plan library re-reads the materialized tree
        armAgentPackStepWatchers()
    }

    /// Bring one materialized agent folder in line with its bundled original, and return
    /// the manifest to record — path → hash of the bytes WE wrote there.
    ///
    /// Per shipped file, ours-or-theirs by content: a copy whose bytes still hash to what
    /// we last wrote is OURS and is refreshed whenever the bundle's bytes differ — newer or
    /// older, so two builds sharing this root can never leave a pack half of each; a copy
    /// that no longer matches was edited by the user and stays, its recorded hash kept so
    /// it stays theirs until it once more reads as ours. A file we have no hash for (a
    /// manifest from before hashes were recorded, or a user file the bundle now also
    /// ships) falls back to mtime — bundle newer refreshes, else keep — and is recorded only
    /// once we have written it, so a guess never claims their bytes as ours.
    ///
    /// Then PRUNE what a PREVIOUS materialization wrote and this bundle no longer ships — a
    /// renamed graph or brief would otherwise stay load-visible forever (a variant the
    /// pack never meant, a brief nothing renders). Only that: a file the bundle never wrote
    /// is the USER'S — the authoring tutorial has them add a graph and a step folder INSIDE
    /// the shipped director pack, and deleting those would take their work. Finally sweep
    /// the directories the removals emptied — an empty dir holds no user work, but reads
    /// as a step folder to every folder-scanning consumer.
    nonisolated static func syncAgentPack(from bundledAgent: URL, to dest: URL,
                                          previous: [String: String],
                                          log: (String) -> Void = { _ in }) throws -> [String: String] {
        let fm = FileManager.default
        func mtime(_ url: URL) -> Date? {
            (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        }
        var manifest: [String: String] = [:]
        let shipped = try relativeFilePaths(under: bundledAgent)
        for relative in shipped.sorted() {
            let from = bundledAgent.appending(path: relative)
            let to = dest.appending(path: relative)
            try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            let bundleBytes = try Data(contentsOf: from)
            let bundleHash = contentHash(bundleBytes)
            let existing = try? Data(contentsOf: to)
            let recorded = previous[relative]
            let refresh: Bool
            if let existing {
                if let recorded, !recorded.isEmpty {
                    let ours = contentHash(existing) == recorded
                    refresh = ours && existing != bundleBytes
                    if !ours { manifest[relative] = recorded; continue }
                } else {
                    refresh = (mtime(to) ?? .distantPast) < (mtime(from) ?? .distantPast)
                    if !refresh { continue }
                }
            } else {
                refresh = true
            }
            if refresh {
                try? fm.removeItem(at: to)
                try fm.copyItem(at: from, to: to)
                if existing != nil { log("refreshed \(relative)") }
            }
            manifest[relative] = bundleHash
        }
        let shippedSet = Set(shipped)
        for stale in Set(previous.keys).subtracting(shippedSet).sorted() {
            try? fm.removeItem(at: dest.appending(path: stale))
            log("removed \(stale) — the bundle no longer ships it")
        }
        if let walker = fm.enumerator(at: dest, includingPropertiesForKeys: [.isDirectoryKey]) {
            let dirs = walker.compactMap { $0 as? URL }
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            for dir in dirs.sorted(by: { $0.path.count > $1.path.count }) {
                if (try? fm.contentsOfDirectory(atPath: dir.path))?.isEmpty == true {
                    try? fm.removeItem(at: dir)
                }
            }
        }
        return manifest
    }

    nonisolated static func contentHash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Every regular file under `root`, as root-relative paths (no directories).
    nonisolated private static func relativeFilePaths(under root: URL) throws -> [String] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])
        else { return [] }
        var paths: [String] = []
        for case let url as URL in enumerator
        where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            let full = url.standardizedFileURL.path
            let base = root.standardizedFileURL.path + "/"
            guard full.hasPrefix(base) else { continue }
            paths.append(String(full.dropFirst(base.count)))
        }
        return paths
    }

    /// Watch every pack's `steps/<name>/Step.swift` in the LIVE packs root and recompile on
    /// save — the node hot-reload discipline (watch source → recompile → swap on green, keep
    /// old on red) applied to the one pack tier that is compiled code. The schedule shares
    /// the run adapter's key + build dirs (SZHostStepRunning), so an edit mid-session
    /// coalesces into the runtime's latest-source-wins compile and the next evaluation
    /// awaits it. A red compile surfaces at the next run's pack gate, with the compiler's
    /// own words.
    private func armAgentPackStepWatchers() {
        guard let root = Self.graphAgentPacksRoot() else { return }
        let fm = FileManager.default
        for agent in ((try? fm.contentsOfDirectory(atPath: root.path)) ?? []).sorted() {
            let stepsDir = root.appending(path: "\(agent)/steps")
            for step in ((try? fm.contentsOfDirectory(atPath: stepsDir.path)) ?? []).sorted() {
                let source = stepsDir.appending(path: "\(step)/Step.swift")
                guard fm.fileExists(atPath: source.path) else { continue }
                let watchKey = "\(agent)/\(step)"
                guard stepWatchers[watchKey] == nil else { continue }
                let key = SZStepKey(agent: agent, step: step)
                let watcher = SZSourceWatcher(watching: source)
                watcher.start { [weak self] in
                    print("[SZHost] step \(watchKey) source changed — recompiling")
                    let buildRoot = SZHostStepRunning.buildRoot(for: key)
                    self?.stepRuntime.scheduleLoad(
                        key: key, sourceURL: source,
                        buildDir: buildRoot.appending(path: "build"),
                        runtimeLoadsDir: buildRoot.appending(path: "runtime-loads"))
                }
                stepWatchers[watchKey] = watcher
            }
        }
    }

}

extension SZHost {
    /// The panel's source affordance: resolve a card's authored file inside the ACTIVE
    /// packs root and open it in the user's editor. `.md.mustache` claims no default app,
    /// so unopenable files fall through to the plain-text editor, then TextEdit — never
    /// a shrug.
    func openPackSource(agent: String, source: SZAgentGraphFace.Source) {
        let root = SZHost.graphAgentPacksRoot() ?? Self.materializedAgentPacksRoot
        let url: URL
        switch source {
        case .step(let name):
            url = root.appending(path: "\(agent)/steps/\(name)/Step.swift")
        case .brief(let path):
            url = root.appending(path: "\(agent)/\(path)")
        case .dispatch:
            // The panel navigates dispatch links itself; nothing reaches the host.
            return
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            status = "no source at \(url.path)"
            return
        }
        if NSWorkspace.shared.urlForApplication(toOpen: url) != nil {
            NSWorkspace.shared.open(url)
            return
        }
        let editor = NSWorkspace.shared.urlForApplication(toOpen: UTType.plainText)
            ?? URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        NSWorkspace.shared.open([url], withApplicationAt: editor,
                                configuration: NSWorkspace.OpenConfiguration())
    }
}

extension SZHost {
    /// What the last materialization wrote for one agent — path → hash of the bytes we
    /// wrote — so a sync can tell OUR copies from the user's own additions and edits. A
    /// manifest from before hashes were recorded (a bare path list) reads with EMPTY
    /// hashes: known to be ours once, content unknown, so those files take the mtime rule.
    /// Absent (first run) reads as empty — the conservative direction: nothing of theirs
    /// is ever taken on a guess. Beside the packs root, never inside it: the root is
    /// enumerated as a pack library, and host bookkeeping filed there would read as an
    /// agent that will not load.
    static func materializedManifestURL(for agent: String) -> URL {
        materializedAgentPacksRoot.deletingLastPathComponent()
            .appending(path: "agent-pack-manifests/\(agent).json")
    }

    static func materializedManifest(for agent: String) -> [String: String] {
        materializedManifest(at: materializedManifestURL(for: agent))
    }

    nonisolated static func materializedManifest(at url: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        if let hashes = try? JSONDecoder().decode([String: String].self, from: data) { return hashes }
        guard let paths = try? JSONDecoder().decode([String].self, from: data) else { return [:] }
        return Dictionary(uniqueKeysWithValues: paths.map { ($0, "") })
    }

    static func writeMaterializedManifest(_ manifest: [String: String], for agent: String) {
        let url = materializedManifestURL(for: agent)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(manifest) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
