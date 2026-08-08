// SPDX-License-Identifier: AGPL-3.0-only
// The bundled agent packs' host policy: materialize the SZAI-bundled pack tree into
// Application Support — the packs root every consumer (runs, the Plan panel, the debug
// tools) then reads — arm hot reload over the compiled steps, and resolve the Director's
// run-graph VARIANT (env > persisted > pack default).
//
// MATERIALIZED rather than read in place: bundled resources live inside the app bundle,
// which is read-only in an installed, signed .app — so the WRITABLE copy is the one the
// user edits, and it survives relaunches. A file refreshes when the bundle ships a NEWER
// copy (an app update); a user edit, being newer than the bundle's mtime, wins until then.
// Prompt templates need no watcher: SZBriefRenderer reads them from disk per render, so a
// saved edit reaches the very next turn. Step sources DO need one — a step is compiled
// code, and the step runtime swaps modules on green.
import AppKit
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

    /// Copy the bundled pack tree into the materialized root — per-file mtime freshness
    /// (bundle newer → refresh; user edit newer → keep; `copyItem` preserves the bundle's
    /// mtime, so an unchanged copy is never re-taken), then prune what the bundle no longer
    /// ships and arm the step watchers. Called once at `start`, before anything reads packs.
    func materializeAgentPacks() {
        guard let bundled = SZAgentPackLoader.bundledRoot else {
            print("[SZHost] no bundled agent packs to materialize")
            return
        }
        let fm = FileManager.default
        let root = Self.materializedAgentPacksRoot
        func mtime(_ url: URL) -> Date? {
            (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        }
        for agent in ((try? fm.contentsOfDirectory(atPath: bundled.path)) ?? []).sorted() {
            let bundledAgent = bundled.appending(path: agent)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: bundledAgent.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }
            do {
                let shipped = try Self.relativeFilePaths(under: bundledAgent)
                let dest = root.appending(path: agent)
                for relative in shipped.sorted() {
                    let from = bundledAgent.appending(path: relative)
                    let to = dest.appending(path: relative)
                    try fm.createDirectory(at: to.deletingLastPathComponent(),
                                           withIntermediateDirectories: true)
                    let bundleDate = mtime(from) ?? .distantPast
                    if mtime(to).map({ $0 < bundleDate }) ?? true {
                        try? fm.removeItem(at: to)
                        try fm.copyItem(at: from, to: to)
                    }
                }
                // PRUNE what a PREVIOUS materialization wrote and this bundle no longer
                // ships — a renamed graph or brief would otherwise stay load-visible forever
                // (a variant the pack never meant, a brief nothing renders).
                //
                // Only that. A file the bundle never wrote is the USER'S — the authoring
                // tutorial has them add a graph and a step folder INSIDE the shipped
                // director pack, and deleting those at next launch would take their work
                // and, if `agent.json` still named the variant, refuse every Build after.
                // The manifest of what we wrote lives beside the copy for exactly this.
                let shippedSet = Set(shipped)
                let previous = Self.materializedManifest(for: agent)
                for stale in previous.subtracting(shippedSet).sorted() {
                    try? fm.removeItem(at: dest.appending(path: stale))
                    print("[SZHost] agent packs: removed \(agent)/\(stale) — the bundle no longer ships it")
                }
                Self.writeMaterializedManifest(shippedSet, for: agent)
            } catch {
                print("[SZHost] agent pack \(agent): could not materialize — \(error)")
            }
        }
        agentGraphPlanCache = nil   // the plan library re-reads the materialized tree
        armAgentPackStepWatchers()
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

    // MARK: - Run-graph variants

    /// The director pack, loaded from the live packs root — the variant helpers' one source.
    /// Cheap (a handful of small files); called from the debug tools and run start only.
    private func loadedDirectorPack() -> SZAgentPack? {
        guard let root = Self.graphAgentPacksRoot() else { return nil }
        let loaded = SZAgentPackLoader.load(root: root)
        guard let id = loaded.seats.director else { return nil }
        return loaded.packs.first { $0.id == id }
    }

    /// The director pack's build-kind variant names — `debug_set_orchestrator`'s valid set.
    func directorBuildVariantNames() -> [String] {
        loadedDirectorPack()?.variants(handling: .build).map(\.name) ?? []
    }

    /// The variant the NEXT run drives build with, by name: env > persisted > pack default,
    /// resolved against the loaded variants (an unknown choice reads as the default). Silent —
    /// `resolvedRunGraphVariant` is the run path's narrating twin. nil = no pack library.
    func activeRunGraphVariant() -> String? {
        guard let pack = loadedDirectorPack() else { return nil }
        let names = pack.variants(handling: .build).map(\.name)
        if let requested = requestedRunGraphVariant(), names.contains(requested) {
            return requested
        }
        return pack.graph(handling: .build)?.name
    }

    /// The user's stated choice before validation: `SZ_RUN_GRAPH` outranks the persisted one.
    private func requestedRunGraphVariant() -> String? {
        if let env = ProcessInfo.processInfo.environment["SZ_RUN_GRAPH"], !env.isEmpty {
            return env
        }
        return runGraphVariant
    }

    /// The run path's resolution: the validated choice, or nil for the pack default — with
    /// ONE status line when the choice names no loaded variant (a stale persisted name, a
    /// typoed env), so the fallback never happens silently.
    func resolvedRunGraphVariant() -> String? {
        guard let requested = requestedRunGraphVariant() else { return nil }
        guard directorBuildVariantNames().contains(requested) else {
            status = "run-graph variant '\(requested)' is unknown — using the pack default"
            return nil
        }
        return requested
    }

    /// Persist the run-graph variant choice (`debug_set_orchestrator` writes through here) —
    /// same app-state.json home as the other host prefs.
    func setRunGraphVariant(_ name: String?) {
        runGraphVariant = name
        persistAppState()
        agentGraphPlanCache = nil   // the sidebar's active badge follows the choice, now
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
    /// What the last materialization wrote for one agent, so a prune can tell OUR stale
    /// copies from the user's own additions. Absent (first run, or an older build) reads as
    /// empty — the conservative direction: nothing of theirs is ever taken on a guess.
    static func materializedManifest(for agent: String) -> Set<String> {
        let url = materializedAgentPacksRoot.appending(path: ".materialized/\(agent).json")
        guard let data = try? Data(contentsOf: url),
              let paths = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(paths)
    }

    static func writeMaterializedManifest(_ paths: Set<String>, for agent: String) {
        let url = materializedAgentPacksRoot.appending(path: ".materialized/\(agent).json")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(paths.sorted()) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
