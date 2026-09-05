// SPDX-License-Identifier: AGPL-3.0-only
// The web backend: one WKWebView running the project's page (WebRuntime/), fed over WebKit's script
// messages, served in-process by SZWebSchemeHandler. It owns the page, not the tile: the viewport panel
// re-parents the webview, so panel moves never reload it. Speaks SZRenderBackend for the graph
// lifecycle, the compile gate and the capture; the last two await the page.
//
// Wire protocol, both ways JSON: the app posts `{op: ...}` through `window.__szDispatch` (queued until
// the page says `ready`); the page posts `{channel: ready | errors | loadError | check | previewLayout}`
// back. Thumbnail atlases come the other way as a POST to `subz://app/previews` (SZWebPreviewSink).
import AppKit
import AVFoundation
import Foundation
import SZCore
import WebKit

@MainActor
@Observable
final class SZWebRuntime: NSObject {
    /// Where the page is, in words the tile can show.
    enum Phase: Equatable {
        case downloading(String)
        case failed(String)
        case loading
        case ready

        var status: String? {
            switch self {
            case .downloading(let version): "Downloading three.js \(version)…"
            case .failed(let message): message
            case .loading: "Loading the web viewport"
            case .ready: nil
            }
        }
    }

    let projectURL: URL
    let threeVersion: String
    private(set) var phase: Phase = .loading
    private(set) var webView: WKWebView?
    private(set) var isPaused = false

    private let proxy = SZWeakScriptMessageProxy()
    private var handshaken = false
    /// Set when the page died with a graph loaded: the next handshake reloads the project.
    private var reloadOnReady = false
    private var queue: [[String: Any]] = []
    /// Per node: the source's change mark last sent, and the `?v=` the page imported it under.
    private var sent: [SZNodeID: String] = [:]
    private var versions: [SZNodeID: Int] = [:]
    private var checkCounter = 0
    private var checks: [String: CheckedContinuation<SZBuildResult, Never>] = [:]
    private var checkTimeouts: [String: Task<Void, Never>] = [:]
    /// Live input overrides waiting for the next flush; only the latest value per port reaches the page.
    private var pendingFloats: [SZNodeID: [String: [Float]]] = [:]
    private var pendingStrings: [SZNodeID: [String: String]] = [:]
    private var inputFlushScheduled = false
    private var errorCallback: (@Sendable ([SZNodeID: String]) -> Void)?
    /// The watched thumbnails, kept so a page that died and came back gets them again.
    private var watchedPreviews: [(node: SZNodeID, port: String)] = []
    private var previewMaxDimension = 0
    /// Turns the page's posted atlases into published surfaces (fed by the scheme handler).
    private let previewSink = SZWebPreviewSink()

    init(projectURL: URL, threeVersion: String) {
        self.projectURL = projectURL
        self.threeVersion = threeVersion
        super.init()
    }

    /// The bundled page files (`WebRuntime/`, a folder reference in Resources), with the source tree as
    /// the fallback for `swift test` and running from the checkout.
    nonisolated static var runtimeDirectory: URL {
        if let bundled = Bundle.main.resourceURL?.appending(path: "WebRuntime"),
           FileManager.default.fileExists(atPath: bundled.appending(path: "index.html").path) {
            return bundled
        }
        return URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "WebRuntime")
    }

    // MARK: - Mount / unmount

    /// Bring the page up: three.js first (a one-time download per version), then the webview. Never
    /// throws: a failure lands in `phase` for the tile to show, and `start()` again is the retry.
    func start() async {
        phase = .downloading(threeVersion)
        let library: URL
        do {
            library = try await SZWebLibraryStore.ensure(threeVersion)
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }
        if let webView {
            // a retry after a failed load or a dead page: the same view loads the page again
            if handshaken { phase = .ready } else { phase = .loading; webView.load(URLRequest(url: SZWebSchemeHandler.indexURL)) }
            return
        }
        phase = .loading
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.mediaTypesRequiringUserActionForPlayback = []   // a camera node plays its stream without a click
        let handler = SZWebSchemeHandler(runtimeDirectory: Self.runtimeDirectory, libraryDirectory: library,
                                         projectURL: projectURL, threeVersion: threeVersion)
        handler.onPreviewBody = { [previewSink] body, url in previewSink.receive(body, url: url) }
        config.setURLSchemeHandler(handler, forURLScheme: SZWebSchemeHandler.scheme)
        if let rules = try? await Self.sealRuleList() { config.userContentController.add(rules) }
        proxy.handler = self
        config.userContentController.add(proxy, name: "sz")
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = self
        view.uiDelegate = self
        view.setValue(false, forKey: "drawsBackground")
        #if DEBUG
        view.isInspectable = true
        #endif
        webView = view
        view.load(URLRequest(url: SZWebSchemeHandler.indexURL))
    }

    /// Tear down cleanly: WebKit retains the message-handler proxy, so remove it explicitly.
    func unmount() {
        proxy.handler = nil
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "sz")
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView?.removeFromSuperview()
        webView = nil
        handshaken = false
        for (_, continuation) in checks { continuation.resume(returning: .failed("the web viewport closed")) }
        checks.removeAll()
        for (_, timeout) in checkTimeouts { timeout.cancel() }
        checkTimeouts.removeAll()
    }

    /// Everything but the page's own scheme is blocked, so a node cannot reach the network or a file.
    private static func sealRuleList() async throws -> WKContentRuleList? {
        let identifier = "sz-web-project-seal"
        let store = WKContentRuleListStore.default()!
        if let cached = try? await store.contentRuleList(forIdentifier: identifier) { return cached }
        let rules = """
        [
          { "trigger": { "url-filter": ".*" }, "action": { "type": "block" } },
          { "trigger": { "url-filter": "^subz://app/.*" }, "action": { "type": "ignore-previous-rules" } }
        ]
        """
        return try await store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: rules)
    }

    // MARK: - The push

    private func push(_ payload: [String: Any]) {
        guard handshaken, let webView else { queue.append(payload); return }
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        webView.callAsyncJavaScript("window.__szDispatch(payload)",
                                    arguments: ["payload": String(decoding: data, as: UTF8.self)],
                                    in: nil, in: .page) { _ in }
    }

    private func flushQueue() {
        let pending = queue
        queue.removeAll()
        for payload in pending { push(payload) }
    }

    // MARK: - Graph payloads

    private func sourceURL(for id: SZNodeID, staged: Bool = false) -> String {
        let folder = staged ? ".staging/nodes" : "nodes"
        return "subz://app/project/\(folder)/\(id.uuidString)/Node.js?v=\(versions[id] ?? 0)"
    }

    /// A source file's change mark: size and modification time. A promote writes a new file, so the
    /// mark moves without the contents being read.
    nonisolated private static func stamp(of url: URL) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber,
              let modified = attributes[.modificationDate] as? Date else { return nil }
        return "\(size)-\(modified.timeIntervalSinceReferenceDate)"
    }

    nonisolated private static func json(_ contract: SZNodeContract?) -> Any {
        guard let contract, let data = try? SZProjectIO.contractData(contract),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return ["inputs": [], "outputs": []]
        }
        return object
    }

    /// The unconnected inputs' by-value seeds, split by channel the same way the Mac runtime splits
    /// them (`SZPortType.valueChannel`).
    nonisolated private static func seeds(_ contract: SZNodeContract?) -> (floats: [String: [Float]], strings: [String: String]) {
        var floats: [String: [Float]] = [:]
        var strings: [String: String] = [:]
        for port in contract?.inputs ?? [] {
            switch port.type.valueChannel {
            case .float: if let f = port.def?.floats { floats[port.name] = f }
            case .string: if let s = port.def?.string { strings[port.name] = s }
            case .none: break
            }
        }
        return (floats, strings)
    }

    nonisolated private static func ref(_ ref: SZPortRef) -> [String: Any] {
        ["node": ref.node.uuidString, "port": ref.port]
    }

    // MARK: - The gate and the capture

    /// The compile gate for a staged `Node.js`: a JavaScriptCore parse, then the page imports the module,
    /// constructs it, and runs setup and a few updates against scratch targets. Same `{ok, errors}`
    /// meaning as swiftc's check.
    func checkNodeSource(at stagedSource: URL, for node: SZNode) async -> SZBuildResult {
        guard let source = try? String(contentsOf: stagedSource, encoding: .utf8) else {
            return .failed("no staged source at \(stagedSource.path)")
        }
        if case .failed(let message) = SZWebNodeCheck.parse(source: source) { return .failed(message) }
        if !handshaken { await waitForPage() }
        guard handshaken else {
            return .failed("the web viewport is not up yet (\(phase.status ?? "loading")); try again in a moment")
        }
        checkCounter += 1
        versions[node.id, default: 0] += 1
        let token = "check-\(checkCounter)"
        let seeds = Self.seeds(node.contract)
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<SZBuildResult, Never>) in
            checks[token] = continuation
            push(["op": "check", "token": token, "sourceURL": sourceURL(for: node.id, staged: true),
                  "contract": Self.json(node.contract), "values": seeds.floats, "strings": seeds.strings])
            checkTimeouts[token] = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled else { return }
                self?.checks.removeValue(forKey: token)?.resume(returning: .failed("the web viewport did not answer the check in time"))
            }
        }
        checkTimeouts.removeValue(forKey: token)?.cancel()
        return result
    }

    /// Give the page a moment to handshake; returns early once it fails.
    private func waitForPage(seconds: Double = 15) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !handshaken, Date() < deadline {
            if case .failed = phase { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// A PNG of the page as shown, long edge at most `maxDimension`.
    func captureViewport(maxDimension: Int) async -> Data? {
        guard let webView, handshaken else { return nil }
        guard let image = try? await webView.takeSnapshot(configuration: nil) else { return nil }
        let size = image.size
        let scale = min(1, CGFloat(maxDimension) / max(size.width, size.height, 1))
        let target = NSSize(width: max(1, (size.width * scale).rounded()), height: max(1, (size.height * scale).rounded()))
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(target.width), pixelsHigh: Int(target.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: target), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}

// MARK: - The backend seam

extension SZWebRuntime: SZRenderBackend {
    var capabilities: SZBackendCapabilities { .web }

    func loadProject(_ project: SZProject, at url: URL) throws {
        var live: Set<SZNodeID> = []
        let payload = Self.loadPayload(project: project, projectURL: url) { [self] node in
            live.insert(node.id)
            let source = SZProjectIO.nodeSourceURL(projectURL: url, nodeID: node.id, target: .web)
            guard let stamp = Self.stamp(of: source), sent[node.id] != stamp else { return nil }
            versions[node.id, default: 0] += 1
            sent[node.id] = stamp
            return sourceURL(for: node.id)
        }
        sent = sent.filter { live.contains($0.key) }
        push(payload)
    }

    /// The `load` message: the renderable graph in topological order, every node's contract, the data
    /// edges, the endpoint, the unconnected inputs' seeds, and per node the URL to import its source
    /// from when `sourceURL` gives one (nil keeps the page's current instance). Shared with the export,
    /// which hands data: URLs instead of `subz://` ones.
    nonisolated static func loadPayload(project: SZProject, projectURL: URL,
                            sourceURL: (SZNode) -> String?) -> [String: Any] {
        let graph = project.graph.renderable
        let order = graph.topologicalOrder() ?? graph.nodes.map(\.id)
        var nodes: [[String: Any]] = []
        var floats: [String: Any] = [:]
        var strings: [String: Any] = [:]
        for node in graph.nodes {
            var entry: [String: Any] = ["id": node.id.uuidString, "contract": json(node.contract)]
            if let url = sourceURL(node) { entry["sourceURL"] = url }
            let seeds = seeds(node.contract)
            floats[node.id.uuidString] = seeds.floats
            strings[node.id.uuidString] = seeds.strings
            nodes.append(entry)
        }
        let connections: [[String: Any]] = graph.connections
            .filter { $0.kind == .data }
            .map { ["from": ref($0.from), "to": ref($0.to)] }
        var payload: [String: Any] = [
            "op": "load",
            "order": order.map(\.uuidString),
            "nodes": nodes, "connections": connections,
            "values": floats, "strings": strings,
        ]
        payload["endpoint"] = graph.renderEndpoint.map(ref) ?? NSNull()
        return payload
    }

    func reloadNode(id: SZNodeID, source: URL) throws {
        guard sent[id] != nil else { return }
        versions[id, default: 0] += 1
        sent[id] = Self.stamp(of: source)
        push(["op": "reload", "id": id.uuidString, "sourceURL": sourceURL(for: id)])
    }

    func isNodeLoaded(_ id: SZNodeID) -> Bool { sent[id] != nil }

    func setInputValue(node: SZNodeID, port: String, floats: [Float]) {
        pendingFloats[node, default: [:]][port] = floats
        scheduleInputFlush()
    }

    func setInputString(node: SZNodeID, port: String, string: String) {
        pendingStrings[node, default: [:]][port] = string
        scheduleInputFlush()
    }

    func clearInput(node: SZNodeID, port: String) {
        pendingFloats[node]?[port] = nil
        pendingStrings[node]?[port] = nil
        push(["op": "clearInput", "id": node.uuidString, "port": port])
    }

    /// A slider drag or a controller writes many values a second and the page reads once per frame, so
    /// one message per run-loop pass carries the latest of each.
    private func scheduleInputFlush() {
        guard !inputFlushScheduled else { return }
        inputFlushScheduled = true
        Task { @MainActor [weak self] in self?.flushInputs() }
    }

    private func flushInputs() {
        inputFlushScheduled = false
        guard !pendingFloats.isEmpty || !pendingStrings.isEmpty else { return }
        var floats: [String: Any] = [:]
        var strings: [String: Any] = [:]
        for (id, ports) in pendingFloats { floats[id.uuidString] = ports }
        for (id, ports) in pendingStrings { strings[id.uuidString] = ports }
        pendingFloats.removeAll()
        pendingStrings.removeAll()
        push(["op": "setInputs", "floats": floats, "strings": strings])
    }

    func setRenderEndpoint(_ ref: SZPortRef?) {
        push(["op": "setEndpoint", "endpoint": ref.map(Self.ref) ?? NSNull()])
    }

    func setPaused(_ paused: Bool) {
        isPaused = paused
        push(["op": "setPaused", "paused": paused])
    }

    func resetTimeline() {
        push(["op": "resetTimeline"])
    }

    func setNodeErrorCallback(_ callback: (@Sendable ([SZNodeID: String]) -> Void)?) {
        errorCallback = callback
    }

    func setWatchedPreviews(_ requests: [(node: SZNodeID, port: String)], maxDimension: Int) {
        watchedPreviews = requests
        previewMaxDimension = maxDimension
        pushWatchedPreviews()
    }

    private func pushWatchedPreviews() {
        push(["op": "setWatchedPreviews", "keys": watchedPreviews.map { "\($0.node.uuidString):\($0.port)" },
              "maxDimension": previewMaxDimension])
    }

    func setPreviewFrameCallback(_ callback: (@Sendable ([SZNodePreviewSurface]) -> Void)?) {
        previewSink.onFrames = callback
    }
}

// MARK: - The page's messages

extension SZWebRuntime: WKScriptMessageHandler {
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let channel = body["channel"] as? String else { return }
        switch channel {
        case "ready":
            handshaken = true
            phase = .ready
            if reloadOnReady {
                reloadOnReady = false
                queue.removeAll()
                if let project = try? SZProjectIO.load(from: projectURL) { try? loadProject(project, at: projectURL) }
                if !watchedPreviews.isEmpty { pushWatchedPreviews() }
            }
            flushQueue()
        case "errors":
            let raw = body["nodeErrors"] as? [String: String] ?? [:]
            var errors: [SZNodeID: String] = [:]
            for (key, value) in raw { if let id = UUID(uuidString: key) { errors[id] = value } }
            errorCallback?(errors)
        case "loadError":
            print("[SZWebRuntime] \(body["id"] ?? "?"): \(body["message"] ?? "")")
        case "previewLayout":
            previewSink.setLayout(from: body)
        case "check":
            guard let token = body["token"] as? String, let continuation = checks.removeValue(forKey: token) else { return }
            let ok = body["ok"] as? Bool ?? false
            continuation.resume(returning: ok ? .ok : .failed(body["errors"] as? String ?? "the node failed to load"))
        default:
            break
        }
    }
}

// MARK: - Navigation policy: the page loads once and goes nowhere

extension SZWebRuntime: WKNavigationDelegate, WKUIDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        let url = action.request.url
        if url == SZWebSchemeHandler.indexURL || url?.absoluteString == "about:blank" { return .allow }
        print("[SZWebRuntime] denied navigation to \(url?.absoluteString ?? "?")")
        return .cancel
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        nil
    }

    /// A node's getUserMedia: this Mac's own camera/microphone grant decides, asked once if it never
    /// was, so the page never shows a prompt of its own.
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void) {
        let media: [AVMediaType]
        switch type {
        case .camera: media = [.video]
        case .microphone: media = [.audio]
        case .cameraAndMicrophone: media = [.video, .audio]
        @unknown default: decisionHandler(.deny); return
        }
        Task { @MainActor in
            for kind in media where !(await AVCaptureDevice.requestAccess(for: kind)) {
                decisionHandler(.deny)
                return
            }
            decisionHandler(.grant)
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        phase = .failed("The web viewport could not load its page. \(error.localizedDescription)")
    }

    /// The page process died (out of memory, a GPU fault): forget what it held and load it again.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        handshaken = false
        sent.removeAll()
        reloadOnReady = true
        for (_, continuation) in checks { continuation.resume(returning: .failed("the web viewport stopped; try again")) }
        checks.removeAll()
        phase = .loading
        webView.load(URLRequest(url: SZWebSchemeHandler.indexURL))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        phase = .failed("The web viewport could not load its page. \(error.localizedDescription)")
    }
}

/// WKUserContentController retains its script-message handler; this proxy is what WebKit retains, and
/// it holds the runtime weakly so unmount decides the real lifetime.
final class SZWeakScriptMessageProxy: NSObject, WKScriptMessageHandler {
    weak var handler: (any WKScriptMessageHandler)?

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        handler?.userContentController(controller, didReceive: message)
    }
}
