// SPDX-License-Identifier: AGPL-3.0-only
// Custom-card mounts: one compiled `Card.swift` module + one live instance per `.custom`-bodied
// node, a source watcher per mount (edit → recompile → remount, the Node.swift motion), the two
// inbound channels every card sees (the scoped node snapshot, pushed write-on-change; display
// telemetry at ~30 Hz), and the outbound verbs routed to the host's ONE input write
// (`setInputDefault(persist:)`). Keep-last-good: a red recompile leaves the previous build mounted
// and rides its first error line as a warning; only a card that never mounted shows the failed chip.
//
// Event-driven like the previews it sits beside: `graphDidChange` (called from the same store hook
// that refreshes the preview stream) reconciles mounts and re-pushes snapshots; a ticker runs ONLY
// while an instance is live, for telemetry and the render-aspect follow. Each mount publishes
// through an observable box (`SZCardMount`) the card region reads directly.
import AppKit
import Foundation
import SwiftUI
import SZAI
import SZCore
import SZRuntime
import SZUI

@MainActor
final class SZCardHostController: SZCustomCardProvider {
    private unowned let host: SZHost
    private let workspace = FileManager.default.temporaryDirectory.appending(path: "SZCards-\(UUID().uuidString)")

    private static let sizeSettle: Duration = .milliseconds(300)
    /// How long a retired module lingers so SwiftUI can drop its view first (the probe's swap
    /// ordering — destroy view references, then retire — stretched over real frames).
    private static let moduleLinger: Duration = .milliseconds(500)

    @MainActor
    private final class Mount {
        let node: SZNodeID
        let box = SZCardMount()
        var instance: SZCardInstance?
        var module: SZCardModule?
        var compiling = false
        var pendingRecompile = false
        var lastSnapshot: Data?
        var sizeSettle: Task<Void, Never>?
        var watcher: SZSourceWatcher?
        init(node: SZNodeID) { self.node = node }
    }

    private var mounts: [SZNodeID: Mount] = [:]
    /// Which nodes have a `Card.swift` on disk — refreshed on graph change so the file button and
    /// context menu don't stat the disk per render.
    private var cardSources: Set<SZNodeID> = []
    private var ticker: Task<Void, Never>?
    private var lastRenderAspect: CGFloat = 0

    init(host: SZHost) { self.host = host }

    // MARK: - SZCustomCardProvider

    func mount(for node: SZNodeID) -> SZCardMount? { mounts[node]?.box }
    func hasCardSource(for node: SZNodeID) -> Bool { cardSources.contains(node) }

    func setCardShown(node: SZNodeID, _ on: Bool) {
        do { try host.applyNodeBody(node: node, mode: on ? .custom : .none) }
        catch { host.status = "\(error)" }
    }

    func openCardSource(node: SZNodeID) {
        guard let url = cardSource(node), FileManager.default.fileExists(atPath: url.path) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Start a card by hand: the docs' worked example lands beside Node.swift, the body flips to
    /// custom (the mount's watcher compiles it), and the file opens for editing. The flip runs first
    /// so a fenced node gets no orphan file; an existing card is never overwritten.
    func createCard(node id: SZNodeID) {
        guard let url = cardSource(id) else { return }
        do {
            if !FileManager.default.fileExists(atPath: url.path) {
                if let denial = host.fenceDenial(nodes: [id], origin: .user) { host.status = denial; return }
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try SZAgentDocs.cardStarterSource.write(to: url, atomically: true, encoding: .utf8)
                cardSources.insert(id)
            }
            try host.applyNodeBody(node: id, mode: .custom)
        } catch {
            host.status = "couldn't create Card.swift: \(error)"
            return
        }
        NSWorkspace.shared.open(url)
    }

    // MARK: - host entry points

    /// The MCP/debug read: what a node's mount looks like right now.
    func debugDescription(for node: SZNodeID) -> [String: Any] {
        var out: [String: Any] = ["hasSource": hasCardSource(for: node)]
        switch mounts[node]?.box.state {
        case .none: out["state"] = "unmounted"
        case .loading: out["state"] = "loading"
        case .ready(let warning):
            out["state"] = "ready"
            if let warning { out["warning"] = warning }
        case .failed(let message):
            out["state"] = "failed"
            out["error"] = message
        }
        if let rect = mounts[node]?.box.backdrop {
            out["backdrop"] = ["x": rect.minX, "y": rect.minY, "width": rect.width, "height": rect.height]
        }
        out["bindingSource"] = host.store.project?.graph.node(id: node)?.contract?.isBindingSource == true
        return out
    }

    /// The store hook (SZHost+NodePreviews' watch-set refresh calls this): mounts follow the graph
    /// and every mounted card gets its snapshot re-pushed (write-on-change inside).
    func graphDidChange() {
        let nodes = host.store.project?.graph.nodes ?? []
        cardSources = Set(nodes.compactMap { node in
            cardSource(node.id).flatMap { FileManager.default.fileExists(atPath: $0.path) ? node.id : nil }
        })
        let wanted = Set(nodes.filter { $0.effectiveBodyMode == .custom }.map(\.id))
        for id in mounts.keys where !wanted.contains(id) { unmount(id) }
        for id in wanted where mounts[id] == nil { mount(node: id) }
        followRenderAspect()
        for mount in mounts.values { pushSnapshot(mount) }
        syncTicker()
    }

    /// Project switch: drop every mount and stop its watcher (a dead project's folder must not
    /// keep being polled).
    func unmountAll() {
        for id in Array(mounts.keys) { unmount(id) }
        cardSources = []
        syncTicker()
    }

    /// The card half of `agent_compile_node`: compile-check a staged Card.swift off-main.
    nonisolated func compileCheck(source: URL) -> SZBuildResult {
        SZCardModule.compileCheck(source: source, workspace: workspace)
    }

    private func cardSource(_ id: SZNodeID) -> URL? {
        host.loadedProjectURL.map { SZProjectIO.cardSourceURL(projectURL: $0, nodeID: id) }
    }

    // MARK: - mount lifecycle

    private func mount(node id: SZNodeID) {
        let mount = Mount(node: id)
        mounts[id] = mount
        guard let source = cardSource(id) else { return }
        // Watch first, so a Card.swift written after the body flipped (an agent's promote, a hand
        // save) mounts the moment it lands — the watcher fires on absent → present too.
        let watcher = SZSourceWatcher(watching: source)
        watcher.start { [weak self] in self?.recompile(node: id) }
        mount.watcher = watcher
        if FileManager.default.fileExists(atPath: source.path) {
            recompile(node: id)
        } else {
            mount.box.state = .failed(message: "no Card.swift in this node's folder")
        }
    }

    private func unmount(_ id: SZNodeID) {
        guard let mount = mounts.removeValue(forKey: id) else { return }
        mount.watcher?.stop()
        mount.sizeSettle?.cancel()
        mount.box.content = nil
        if let module = mount.module { retire(module) }
        mount.instance = nil
        mount.module = nil
    }

    /// Give SwiftUI real frames to drop the retiring view before its module (and instances) die.
    private func retire(_ module: SZCardModule) {
        Task { @MainActor in
            try? await Task.sleep(for: Self.moduleLinger)
            module.unload()
        }
    }

    // MARK: - compile / hot reload

    /// Compile the node's Card.swift and swap the result in. A recompile requested while one is in
    /// flight coalesces into ONE more build after it (latest source wins). Green → fresh instance
    /// replaces the old one (spinner only when nothing was mounted before); red → keep the mounted
    /// build and surface the first error line as a warning (or the failed chip if none is mounted).
    private func recompile(node id: SZNodeID) {
        guard let mount = mounts[id], let source = cardSource(id) else { return }
        if mount.compiling {
            mount.pendingRecompile = true
            return
        }
        guard FileManager.default.fileExists(atPath: source.path) else {
            mount.box.state = .failed(message: "no Card.swift in this node's folder")
            return
        }
        cardSources.insert(id)
        mount.compiling = true
        if mount.instance == nil { mount.box.state = .loading }
        Task { @MainActor [weak self] in
            defer {
                mount.compiling = false
                if mount.pendingRecompile {
                    mount.pendingRecompile = false
                    self?.recompile(node: id)
                }
            }
            do {
                let module = try await SZCardModule.build(source: source, artifact: id.uuidString,
                                                          workspace: self?.workspace ?? FileManager.default.temporaryDirectory)
                // The mount may have gone (body flipped, node deleted) while swiftc ran.
                guard let self, self.mounts[id] === mount else {
                    module.unload()
                    return
                }
                self.attach(module, to: mount)
            } catch {
                guard let self, self.mounts[id] === mount else { return }
                self.recordFailure(mount, String(describing: error))
            }
        }
    }

    private func attach(_ module: SZCardModule, to mount: Mount) {
        guard let instance = module.createInstance(verbs: verbs(for: mount.node)) else {
            recordFailure(mount, "card refused to instantiate (ABI mismatch?)")
            module.unload()
            return
        }
        let previous = mount.module
        mount.instance = instance
        mount.module = module
        // The card's root view VALUE, lifted out of the dylib's hosting view — mounted as first-class
        // SwiftUI content so the camera's scaleEffect re-renders it crisp at every zoom (an embedded
        // NSView would raster-scale). NSHostingView<AnyView> is a system-framework generic: its
        // metadata is shared with the dylib, so this cast is exact.
        let view = instance.viewPointer().flatMap { Unmanaged<AnyObject>.fromOpaque($0).takeUnretainedValue() as? NSView }
        mount.box.content = (view as? NSHostingView<AnyView>)?.rootView
        if let previous { retire(previous) }
        mount.lastSnapshot = nil   // fresh instance starts from an empty state box
        pushSnapshot(mount)
        mount.box.state = .ready(warning: nil)
        host.recordBuildErrors(nil)
        syncTicker()
    }

    private func recordFailure(_ mount: Mount, _ log: String) {
        host.recordBuildErrors(log)
        // The chip has room for `line:col: message`, not the path (it is the node's own Card.swift;
        // the full log rides `debug_get_build_errors`).
        let line = SZHost.firstErrorLine(in: log)
            .replacingOccurrences(of: #"^.*?/Card\.swift:"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: " error: ", with: " ")
        if mount.instance != nil {
            mount.box.state = .ready(warning: line)   // keep last good
        } else {
            mount.box.state = .failed(message: line)
        }
    }

    // MARK: - outbound verbs

    private func verbs(for node: SZNodeID) -> SZCardVerbs {
        SZCardVerbs(
            live: { [weak self] port, values in self?.cardWrite(node: node, port: port, values: values, persist: false) },
            commit: { [weak self] port, values in self?.cardWrite(node: node, port: port, values: values, persist: true) },
            size: { [weak self] height in self?.noteMeasuredHeight(node: node, height: height) },
            call: { [weak self] tool, args in self?.cardCall(node: node, tool: tool, argsJSON: args) })
    }

    /// The verbs a card may name through `state.call` — the binding-learn vocabulary, nothing else.
    private static let bindingVerbs: Set<String> = ["learn_arm", "learn_cancel", "learn_commit", "remove_binding"]

    /// A card invokes a verb ON ITS OWN NODE only (the closure captured the node — the card never
    /// names one), only from the allowlist, and only when the node IS a binding source. Commits and
    /// removals go through the host's fenced binding funnel like the MCP tools; failures land in the
    /// status line rather than propagating — the card reads outcomes back from telemetry/state.
    private func cardCall(node id: SZNodeID, tool: String, argsJSON: String) {
        guard Self.bindingVerbs.contains(tool),
              host.store.project?.graph.node(id: id)?.contract?.isBindingSource == true,
              let args = (try? JSONSerialization.jsonObject(with: Data(argsJSON.utf8))) as? [String: Any] else { return }
        do {
            switch tool {
            case "learn_arm": try host.armBindingLearn(source: id)
            case "learn_cancel": host.cancelBindingLearn(source: id)
            case "learn_commit":
                guard let learn = host.bindingLearn, learn.node == id, let candidate = learn.candidate else { return }
                _ = try host.commitBinding(source: id, target: nil, key: candidate.key,
                                           label: args["label"] as? String, origin: .user)
            case "remove_binding":
                guard let port = args["port"] as? String else { return }
                try host.removeBinding(source: id, port: port, origin: .user)
            default: break
            }
        } catch {
            host.status = "\(error)"
        }
    }

    /// The card writes ITS node's inputs, by port name, through the host's one funnel — the same
    /// call the slider makes (`persist: false` per tick, `true` on release).
    private func cardWrite(node id: SZNodeID, port: String, values: [Float], persist: Bool) {
        guard let contractPort = host.store.project?.graph.node(id: id)?.contract?.inputs.first(where: { $0.name == port }),
              let value = SZPortValue(type: contractPort.type, doubles: values.map(Double.init)) else { return }
        host.setInputDefault(node: id, port: port, value: value, persist: persist)
    }

    // MARK: - sizing

    /// Measured intrinsic height → grid rows, committed after a settle (300 ms debounce, ceil(px/24)
    /// clamped 2…24 inside `applyNodeBody`), skipped when pinned or unchanged. A backdrop card's
    /// region follows the image instead (`followRenderAspect`).
    private func noteMeasuredHeight(node id: SZNodeID, height: Double) {
        guard let mount = mounts[id] else { return }
        mount.sizeSettle?.cancel()
        mount.sizeSettle = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.sizeSettle)
            guard !Task.isCancelled, let self, self.mounts[id] != nil,
                  let node = self.host.store.project?.graph.node(id: id),
                  node.effectivePreviewPort == nil else { return }
            self.commitRows(Int(ceil(height / SZNodeLayout.gridPitch)), for: node)
        }
    }

    /// Backdrop cards size their region to the aspect-fit image (`SZNodeLayout.backdropRows`) —
    /// through the same commit as auto-size, so rows stay graph truth. Re-run when the render
    /// aspect moves (a viewport reshape) and on every graph change (a fresh mount).
    private func followRenderAspect() {
        guard let size = host.runtime?.renderSize, size.width > 0, size.height > 0 else { return }
        let aspect = CGFloat(size.width) / CGFloat(size.height)
        let moved = abs(aspect - lastRenderAspect) > 0.001
        lastRenderAspect = aspect
        for mount in mounts.values {
            guard let node = host.store.project?.graph.node(id: mount.node), node.effectivePreviewPort != nil else { continue }
            let rows = SZNodeLayout.backdropRows(of: node, renderAspect: aspect)
            if moved || rows != SZNodeLayout.customRows(of: node) { commitRows(rows, for: node) }
        }
    }

    private func commitRows(_ rows: Int, for node: SZNode) {
        guard node.body?.custom?.pinned != true, rows != SZNodeLayout.customRows(of: node) else { return }
        try? host.applyNodeBody(node: node.id, mode: .custom, rows: rows)
    }

    // MARK: - inbound channels

    /// The scoped node projection, write-on-change: identity, ports (with defaults + ui hints), which
    /// inputs are wired, the render size, the committed region footprint, and where the backdrop thumb
    /// sits — everything a card needs to draw itself and map gestures. The backdrop rect is also
    /// published on the mount box (the card region draws the thumb there).
    private func pushSnapshot(_ mount: Mount) {
        guard let node = host.store.project?.graph.node(id: mount.node) else { return }
        let bodySize = CGSize(width: SZNodeLayout.width(of: node), height: SZNodeLayout.customInset(of: node))
        let render = host.runtime.map { CGSize(width: $0.renderSize.width, height: $0.renderSize.height) } ?? .zero
        let backdrop = (host.livePreviews && node.effectivePreviewPort != nil)
            ? SZNodeLayout.customBackdropRect(body: bodySize, render: render) : nil
        if mount.box.backdrop != backdrop { mount.box.backdrop = backdrop }
        guard let instance = mount.instance else { return }

        var payload: [String: Any] = ["id": node.id.uuidString, "title": node.title]
        payload["inputs"] = (node.contract?.inputs ?? []).map { port -> [String: Any] in
            var entry: [String: Any] = ["name": port.name, "type": port.type.rawValue]
            if let def = port.def, let json = SZHostBridge.jsonValue(def) { entry["default"] = json }
            if let ui = port.ui {
                var control: [String: Any] = ["kind": ui.kind.rawValue]
                if let min = ui.min { control["min"] = min }
                if let max = ui.max { control["max"] = max }
                if let step = ui.step { control["step"] = step }
                entry["ui"] = control
            }
            if let options = port.options { entry["options"] = options.map { [$0.label, $0.value] } }
            return entry
        }
        payload["outputs"] = (node.contract?.outputs ?? []).map { port -> [String: Any] in
            var entry: [String: Any] = ["name": port.name, "type": port.type.rawValue]
            if let display = port.display { entry["display"] = display }
            return entry
        }
        payload["connectedInputs"] = (host.store.project?.graph.connections ?? [])
            .filter { $0.kind == .data && $0.to.node == node.id }
            .map(\.to.port).sorted()
        if render.width > 0, render.height > 0 {
            payload["render"] = ["width": render.width, "height": render.height]
        }
        payload["body"] = ["width": bodySize.width, "height": bodySize.height]
        if let backdrop {
            payload["backdrop"] = ["x": backdrop.minX, "y": backdrop.minY,
                                   "width": backdrop.width, "height": backdrop.height]
        }
        guard let json = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              json != mount.lastSnapshot else { return }
        mount.lastSnapshot = json
        instance.push(channel: "state", json: json)
    }

    /// Display telemetry, card-scoped: the node's own float-family/floatArray output values under
    /// `outputs`, string/enum outputs under `strings`, and — for a binding source — the host's learn
    /// state under `learn` (pushed even when idle, so a card sees the disarm). Nodes with none of
    /// these get no pushes at all.
    private func pushTelemetry() {
        for mount in mounts.values {
            guard let instance = mount.instance,
                  let node = host.store.project?.graph.node(id: mount.node),
                  let runtime = host.runtime else { continue }
            var payload: [String: Any] = [:]
            var outputs: [String: Any] = [:]
            var strings: [String: String] = [:]
            for port in node.contract?.outputs ?? [] {
                switch port.type {
                case .texture, .event: continue
                case .string, .enumeration:
                    if let string = runtime.readOutputString(node: mount.node, port: port.name) { strings[port.name] = string }
                default:
                    guard let values = runtime.readOutputFloats(node: mount.node, port: port.name) else { continue }
                    // Node math can produce NaN/Inf; JSONSerialization raises for non-finite numbers.
                    outputs[port.name] = values.map { $0.isFinite ? Double($0) : 0 }
                }
            }
            if !outputs.isEmpty { payload["outputs"] = outputs }
            if !strings.isEmpty { payload["strings"] = strings }
            if node.contract?.isBindingSource == true {
                var learn: [String: Any] = ["armed": false, "seen": false]
                if let session = host.bindingLearn, session.node == mount.node {
                    learn["armed"] = true
                    if let candidate = session.candidate {
                        learn["seen"] = true
                        learn["key"] = candidate.key
                        learn["value01"] = candidate.value01
                    }
                }
                payload["learn"] = learn
            }
            guard !payload.isEmpty,
                  let json = try? JSONSerialization.data(withJSONObject: payload) else { continue }
            instance.push(channel: "telemetry", json: json)
        }
    }

    /// The ~30 Hz ticker — only while an instance is live: telemetry, and the render-aspect follow
    /// (the viewport's size isn't observable; it lands frame by frame).
    private func syncTicker() {
        let live = mounts.values.contains { $0.instance != nil }
        if live, ticker == nil {
            ticker = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(33))
                    guard let self else { return }
                    self.followRenderAspect()
                    self.pushTelemetry()
                }
            }
        } else if !live {
            ticker?.cancel()
            ticker = nil
        }
    }
}
