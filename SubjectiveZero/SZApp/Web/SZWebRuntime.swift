// SPDX-License-Identifier: AGPL-3.0-only
// The web backend: one WKWebView running the project's page (WebRuntime/), fed over WebKit's script
// messages, served in-process by SZWebSchemeHandler. It owns the page, not the tile: the viewport panel
// re-parents the webview, so panel moves never reload it. Speaks SZRenderBackend for the graph
// lifecycle, the compile gate and the capture; the last two await the page.
//
// Wire protocol, both ways JSON: the app posts `{op: ...}` through `window.__szDispatch` (queued until
// the page says `ready`); the page posts `{channel: ready | errors | loadError | check | previewLayout |
// record}` back. Thumbnail atlases and a rolling take's frames come the other way as POSTs to
// `subz://app/previews` (SZWebPreviewSink) and `subz://app/record` (the recorder's CPU feed).
import AppKit
import AVFoundation
import Foundation
import Metal
import QuartzCore
import SZCore
import SZRuntime
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
    /// A take: the app's recorder, fed by the page's frames (sz-record.js). A class so the per-frame
    /// counters mutate in place: `take` itself changes only at start and stop, and observation
    /// (`renderSize`) never fires per frame.
    private final class Take {
        let token: Int
        let recorder: SZLiveVideoRecorder
        let settings: SZRecordSettings
        var output: (width: Int, height: Int) { (settings.width, settings.height) }
        var renderSize: (width: Int, height: Int) { settings.renderSize }
        /// Highest frame number seen from the current page; a reloaded page counts from 0 again.
        var lastSeq = -1
        var received = 0
        /// Frames the page dropped (its ring full): the current page's latest count, and the pages
        /// before a reload. Frames that landed behind a later one count as dropped too.
        var pageDropped = 0
        var pageDroppedBefore = 0
        var reordered = 0

        init(token: Int, recorder: SZLiveVideoRecorder, settings: SZRecordSettings) {
            self.token = token
            self.recorder = recorder
            self.settings = settings
        }

        /// The page came back: its frame numbers and drop count start over.
        func pageReloaded() {
            lastSeq = -1
            pageDroppedBefore += pageDropped
            pageDropped = 0
        }

        /// Drops to add to the recorder's: the page's own, from every page that served the take.
        func pageDrops(report: PageReport) -> Int {
            pageDroppedBefore + (report.received ? report.dropped : pageDropped) + reordered
        }
    }
    /// What the page reports when a take stops: frames sent and frames it dropped. `received` is false
    /// for the empty report a dead or silent page stands in for.
    private struct PageReport: Sendable {
        var sent = 0
        var dropped = 0
        var received = false
    }
    /// The rolling take; nil while none rolls (the seam's `isRecording`).
    private var take: Take?
    /// A stopped take whose last frames may still be in transit while its file finishes.
    private var finishing: Take?
    /// A take the page ended on its own (its graphics context went away), finished; the host's stop
    /// collects it.
    private var ended: (url: URL, frames: Int, dropped: Int, duration: Double)?
    private var takeCounter = 0
    private var stopReports: [Int: CheckedContinuation<PageReport, Never>] = [:]
    private var reportTimeouts: [Int: Task<Void, Never>] = [:]

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
        handler.onRecordBody = { [weak self] body, url in
            MainActor.assumeIsolated { self?.receiveRecordBody(body, url: url) }
        }
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
        // the host finalizes a take before any unmount path; this is the safety net
        if let take { self.take = nil; take.recorder.cancelAndDelete() }
        settleAllReports()
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
        // a rolling take's audio leg pauses with the clock (video pauses by not encoding)
        take?.recorder.setPaused(paused, now: CACurrentMediaTime())
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

// MARK: - Recording

extension SZWebRuntime {
    /// Whether a take is rolling.
    var isRecording: Bool { take != nil }

    /// The picture size a take is framed against: the take's own while rolling, else the page's
    /// canvas in pixels (the tile times its backing scale), the page's default before it is up.
    var renderSize: (width: Int, height: Int) {
        if let take { return take.renderSize }
        guard let webView, webView.bounds.width >= 1, webView.bounds.height >= 1 else { return (1280, 720) }
        let scale = webView.window?.backingScaleFactor ?? 2
        return (Int((webView.bounds.width * scale).rounded()), Int((webView.bounds.height * scale).rounded()))
    }

    /// Start a take: the recorder is built here, the page holds the render size and starts posting
    /// frames. Throws `.alreadyRecording`, `.nothingToRender` (no page yet), or `.writerFailed`.
    func startRecording(to url: URL, settings: SZRecordSettings) throws {
        guard take == nil else { throw SZRecordError.alreadyRecording }
        // the writer's pool wants a device for its Metal-compatible buffers; the page never touches it
        guard handshaken, let device = MTLCreateSystemDefaultDevice() else { throw SZRecordError.nothingToRender }
        let recorder = try SZLiveVideoRecorder(url: url, settings: settings, device: device)
        takeCounter += 1
        let started = Take(token: takeCounter, recorder: recorder, settings: settings)
        take = started
        ended = nil
        if isPaused { recorder.setPaused(true, now: CACurrentMediaTime()) }
        push(startRecordOp(for: started))
    }

    private func startRecordOp(for take: Take) -> [String: Any] {
        let s = take.settings
        return ["op": "startRecord", "take": take.token,
                "width": s.width, "height": s.height, "fps": s.fps,
                "renderWidth": s.renderSize.width, "renderHeight": s.renderSize.height,
                "crop": ["x": s.crop.x, "y": s.crop.y, "w": s.crop.width, "h": s.crop.height]]
    }

    /// Attach the app-sound capture to the rolling take (see SZRuntime.startRecordingSound).
    func startRecordingSound() async throws {
        guard let take else { throw SZRecordError.notRecording }
        try await take.recorder.startAudioCapture()
    }

    /// Stop the take. The take leaves `take` before the first await (as the Metal runtime removes its
    /// tap first), so a wind-down hook finds nothing rolling; frames still in transit land through
    /// `finishing` until the page has reported what it sent, then the recorder finishes the file. A
    /// dead page reports nothing and the file keeps what arrived. A take the page ended itself is
    /// collected here.
    func stopRecording() async throws -> (url: URL, frames: Int, dropped: Int, duration: Double) {
        guard let take else { return try await endedResult() }
        self.take = nil
        finishing = take
        defer { finishing = nil }
        var report = PageReport()
        if handshaken {
            push(["op": "stopRecord"])
            report = await awaitReport(for: take.token)
            let deadline = CACurrentMediaTime() + 0.5
            while take.received < report.sent, CACurrentMediaTime() < deadline {
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        let result = try await take.recorder.stop()
        return (result.url, result.frames, result.dropped + take.pageDrops(report: report), result.duration)
    }

    /// Bounded synchronous stop, the quit path; frames still in transit are lost, the file plays.
    @discardableResult
    func stopRecordingBlocking(timeout: TimeInterval) -> URL? {
        guard let take else { return nil }
        self.take = nil
        if handshaken { push(["op": "stopRecord"]) }
        return take.recorder.stopBlocking(timeout: timeout)
    }

    /// Abandon the rolling take and delete its file. No-op when idle.
    func cancelRecording() {
        guard let take else { return }
        self.take = nil
        if handshaken { push(["op": "stopRecord"]) }
        take.recorder.cancelAndDelete()
    }

    /// One posted frame (`subz://app/record?take=&seq=&t=&dropped=`), on the main thread: a frame for
    /// another take is ignored; one that lands behind a later frame (readbacks settle on their own
    /// timers) would stamp a step late, so it counts as dropped; the rest go to the recorder's queue.
    private func receiveRecordBody(_ body: Data, url: URL) {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return }
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard let token = value("take").flatMap(Int.init),
              let current = [take, finishing].compactMap({ $0 }).first(where: { $0.token == token }),
              let seq = value("seq").flatMap(Int.init), let time = value("t").flatMap(Double.init) else { return }
        current.received += 1
        if let dropped = value("dropped").flatMap(Int.init) { current.pageDropped = dropped }
        guard seq > current.lastSeq else { current.reordered += 1; return }
        current.lastSeq = seq
        current.recorder.appendFrame(bgra: body, width: current.output.width, height: current.output.height,
                                     engineTime: time)
    }

    // MARK: The page's stop report

    /// The page's report for `token`, or an empty one after 3 s (a page that never answers).
    private func awaitReport(for token: Int) async -> PageReport {
        await withCheckedContinuation { continuation in
            stopReports[token] = continuation
            reportTimeouts[token] = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(3))
                self?.settleReport(token, PageReport())
            }
        }
    }

    private func settleReport(_ token: Int, _ report: PageReport) {
        reportTimeouts.removeValue(forKey: token)?.cancel()
        stopReports.removeValue(forKey: token)?.resume(returning: report)
    }

    /// The page is gone (unmount, process death): every pending stop proceeds without a report.
    private func settleAllReports() {
        for token in Array(stopReports.keys) { settleReport(token, PageReport()) }
    }

    /// The page ended the take on its own: finish the file with what it holds. The host still
    /// believes a take rolls; its stop collects the result through `endedResult`.
    private func endTake(_ take: Take) {
        self.take = nil
        finishing = take
        Task { @MainActor [weak self] in
            let result = try? await take.recorder.stop()
            guard let self else { return }
            finishing = nil
            ended = result.map { ($0.url, $0.frames, $0.dropped + take.pageDrops(report: PageReport()), $0.duration) }
        }
    }

    private func endedResult() async throws -> (url: URL, frames: Int, dropped: Int, duration: Double) {
        while finishing != nil { try? await Task.sleep(for: .milliseconds(20)) }
        guard let result = ended else { throw SZRecordError.notRecording }
        ended = nil
        return result
    }

    /// The page died and came back: the rolling take continues on the fresh page (its clock and frame
    /// numbers start over; the recorder takes the clock reset in stride).
    private func resumeTakeOnReloadedPage() {
        guard let take else { return }
        take.pageReloaded()
        push(startRecordOp(for: take))
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
                resumeTakeOnReloadedPage()
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
        case "record":
            guard let token = body["take"] as? Int else { return }
            if body["event"] as? String == "failed" {
                print("[SZWebRuntime] take \(token): \(body["message"] ?? "the page stopped recording")")
                if stopReports[token] == nil, let take, take.token == token { endTake(take) }
            }
            settleReport(token, PageReport(sent: body["sent"] as? Int ?? 0, dropped: body["dropped"] as? Int ?? 0,
                                           received: true))
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
        settleAllReports()   // a stop waiting on this page proceeds with what arrived
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
