// SPDX-License-Identifier: AGPL-3.0-only
// The bundled agent packs' host policy: materialize the SZAI-bundled pack tree into
// Application Support — the packs root every consumer (runs, the Plan panel, the debug
// tools) then reads — arm hot reload over the compiled steps, and resolve the Director's
// run-graph variant (env > persisted > pack default).
//
// Materialized rather than read in place: bundled resources live inside the app bundle,
// which is read-only in an installed, signed .app, so the writable copy is the one the user
// edits and it survives relaunches. One copy per app (see `packInstallKey`), so two builds
// can never drag one copy back and forth. Ours-or-theirs is decided by content, not mtime:
// the manifest records a hash of every byte we wrote, so a copy still holding those bytes
// is ours and follows the bundle either way (an update, a downgrade), while a copy the user
// changed is theirs and stays. Prompts need no watcher — SZBriefRenderer reads them per
// render. Step sources do: a step is compiled code, and the runtime swaps modules on green.
import AppKit
import CryptoKit
import Foundation
import SZAI
import SZCore
import SZRuntime
import SZUI
import UniformTypeIdentifiers

extension SZHost {
    /// `SZAppSupport.directory`: the base the materialized packs and their manifests hang off.
    nonisolated static var supportRoot: URL { SZAppSupport.directory }

    /// Which app a materialized pack belongs to. A shipped build always answers `app`: the copy,
    /// and the user's edits in it, then stay put when the app is moved, renamed, or run from a disk
    /// image (which hands a quarantined app a fresh path every launch). A dev build answers eight
    /// hex of its bundle path instead, so every worktree build — and the app xcodebuild launches to
    /// host SZAppTests — has its own copy and none can write another's.
    ///
    /// `dev` is an argument rather than an `#if` inside, so both answers are testable from either
    /// configuration: the shipped path must not be the one nobody's tests ever take.
    nonisolated static func packInstallKey(forAppAt bundle: URL, dev: Bool) -> String {
        guard dev else { return "app" }
        // Symlinks resolved first: /var and /private/var are the same app, and must not key apart.
        let path = bundle.resolvingSymlinksInPath().standardizedFileURL.path
        return String(contentHash(Data(path.utf8)).prefix(8))
    }

    nonisolated static var packInstallKey: String {
        #if DEBUG
        packInstallKey(forAppAt: Bundle.main.bundleURL, dev: true)
        #else
        packInstallKey(forAppAt: Bundle.main.bundleURL, dev: false)
        #endif
    }

    /// Whether `SZ_AGENT_PACKS` names the packs root instead (see `graphAgentPacksRoot`). Takes the
    /// environment rather than reading it, so a test states one instead of mutating the process's.
    nonisolated static func packsRootIsOverridden(
        in environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        !(environment["SZ_AGENT_PACKS"] ?? "").isEmpty
    }

    /// `~/Library/Application Support/SubjectiveZero/agents/<install>` — where this app's bundled
    /// packs materialize, and the packs root the host uses unless `SZ_AGENT_PACKS` overrides
    /// (see `graphAgentPacksRoot`).
    nonisolated static var materializedAgentPacksRoot: URL {
        supportRoot.appending(path: "agents/\(packInstallKey)")
    }

    /// Sync every bundled pack into the materialized root (see `syncAgentPack`), then arm
    /// the step watchers. Called once at `start`, before anything reads packs.
    func materializeAgentPacks() {
        // An override root is the user's own tree: read it, never write it.
        guard !Self.packsRootIsOverridden() else {
            armAgentPackStepWatchers()
            return
        }
        guard let bundled = SZAgentPackLoader.bundledRoot else {
            print("[SZHost] no bundled agent packs to materialize")
            return
        }
        let fm = FileManager.default
        let root = Self.materializedAgentPacksRoot
        // Which folder is this build's: a dev build's key is a hash, and an author editing
        // prompts cannot otherwise tell two builds' copies apart.
        print("[SZHost] agent packs root: \(root.path)")
        Self.reportPreKeyPacks(beside: root)
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
    /// Per shipped file, ours-or-theirs by content: a copy whose bytes still hash to what we
    /// last wrote is ours and is refreshed whenever the bundle's bytes differ, newer or older,
    /// so a downgrade cannot leave a pack half of each; a copy that no longer matches was
    /// edited by the user and stays, its recorded hash kept so it stays theirs until it once
    /// more reads as ours. A file we have no hash for (a manifest from before hashes were
    /// recorded, or a user file the bundle now also ships) falls back to mtime — bundle newer
    /// refreshes, else keep — and is recorded only once we have written it, so a guess never
    /// claims their bytes as ours.
    ///
    /// Then prune what a previous materialization wrote and this bundle no longer ships — a
    /// renamed graph or brief would otherwise stay load-visible forever (a variant the
    /// pack never meant, a brief nothing renders). Only that: a file the bundle never wrote
    /// is the user's — the authoring tutorial has them add a graph and a step folder inside
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

    /// What else is sitting beside this build's copy. Nothing is ever deleted: an edit may be in
    /// any of them, so they are reported once and left alone.
    nonisolated private static func reportPreKeyPacks(beside root: URL) {
        let fm = FileManager.default
        let parent = root.deletingLastPathComponent()
        let entries = ((try? fm.contentsOfDirectory(atPath: parent.path)) ?? []).sorted()
        // An agent folder holds an agent.json; a key folder holds agent folders. So a copy from
        // before packs were keyed by app is the one sitting directly under `agents/`.
        let preKey = entries.filter { fm.fileExists(atPath: parent.appending(path: "\($0)/agent.json").path) }
        if !preKey.isEmpty {
            print("[SZHost] agent packs: a pre-key copy is still here (\(preKey.joined(separator: ", ")))"
                + " — nothing reads it; an edit in it is yours to move or delete")
        }
        let others = entries.filter { !preKey.contains($0) && $0 != root.lastPathComponent }
        if !others.isEmpty {
            print("[SZHost] agent packs: \(others.count) other cop\(others.count == 1 ? "y" : "ies") here from"
                + " other builds — never deleted for you, since an edit may be in one")
        }
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
        case .sentPrompt(let turnID, let template):
            // A capture ages out past the caps; the authored brief is then the honest
            // fallback, not an error.
            guard heldPrompt(for: turnID) != nil else {
                status = "This turn's prompt is no longer kept. Only the last"
                    + " \(SZHost.debugTurnCaptureCap) turns are. Showing the brief template instead."
                openPackSource(agent: agent, source: .brief(path: template))
                return
            }
            viewTurnPrompt(turnID)
            return
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
    /// wrote — so a sync can tell our copies from the user's own additions and edits. A
    /// manifest from before hashes were recorded (a bare path list) reads with empty
    /// hashes: known to be ours once, content unknown, so those files take the mtime rule.
    /// Absent (first run) reads as empty — the conservative direction: nothing of theirs
    /// is ever taken on a guess. Keyed by the same install as the packs it describes, and beside
    /// the packs root rather than inside it: the root is enumerated as a pack library, and host
    /// bookkeeping filed there would read as an agent that will not load.
    static func materializedManifestURL(for agent: String) -> URL {
        supportRoot.appending(path: "agent-pack-manifests/\(packInstallKey)/\(agent).json")
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
