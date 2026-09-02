// SPDX-License-Identifier: AGPL-3.0-only
import Testing
import Foundation
import CoreGraphics
import Metal
@testable import SZRuntime
@testable import SZCore

/// The music-reactive node suite — `system-audio.macos` (capture), `audio-onset` (events),
/// `impulse-envelope` (shaping) and `cube` (the first depth-buffered render pass). Same harness as
/// SZAudioSuiteNodeTests: the real library `Node.swift` files are copied into a temp project and the
/// runtime compiles, loads and renders them headlessly. Without Screen Recording access (CI),
/// `system-audio.macos` emits its synthetic sine fallback, keeping every branch deterministic.

private var libraryRoot: URL {
    URL(filePath: #filePath)
        .deletingLastPathComponent()   // SZRuntimeTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // Modules
        .deletingLastPathComponent()   // SubjectiveZero (umbrella root)
        .appending(path: "NodeLibrary")
}

private func libraryContract(_ id: String) throws -> SZNodeContract {
    try JSONDecoder().decode(
        SZNodeContract.self,
        from: Data(contentsOf: libraryRoot.appending(path: id).appending(path: "node-contract.json")))
}

private func copyLibrarySource(_ id: String, to url: URL) throws {
    try FileManager.default.copyItem(at: libraryRoot.appending(path: id).appending(path: "Node.swift"), to: url)
}

/// The cube is demo-only — it lives in the audio-cube fixture project, not the library.
private var cubeSampleDir: URL {
    libraryRoot.deletingLastPathComponent()
        .appending(path: "Modules/Tests/Fixtures/Projects/audio-cube.subz/nodes/ffffffff-ffff-4fff-8fff-ffffffffffff")
}

private func cubeContract() throws -> SZNodeContract {
    try JSONDecoder().decode(
        SZNodeContract.self, from: Data(contentsOf: cubeSampleDir.appending(path: "node-contract.json")))
}

private func maxChannel(_ frame: SZImageBytes) -> Int {
    var m = 0
    for y in 0..<frame.height {
        for x in 0..<frame.width {
            if let p = frame.pixel(x: x, y: y) { m = max(m, Int(p.r), Int(p.g), Int(p.b)) }
        }
    }
    return m
}

/// Save `project` into a temp `.subz`, run `writeSources` to place each node's Node.swift, load, and
/// hand the loaded runtime to `body` (the temp dir outlives the closure so repeated captures work).
@MainActor
private func withLoadedProject(
    runtime: SZRuntime, project: SZProject,
    writeSources: (URL) throws -> Void, body: () throws -> Void
) throws {
    let dir = FileManager.default.temporaryDirectory
        .appending(path: "SZMusicSuite-\(UUID().uuidString)").appending(path: "music.subz")
    defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
    try SZProjectIO.save(project, to: dir)
    try writeSources(dir)
    try runtime.loadProject(at: dir)
    try body()
}

// MARK: contract shapes (no GPU, runs everywhere)

@Test func musicSuiteContractsDecodeWithExpectedShape() throws {
    let systemAudio = try libraryContract("system-audio.macos")
    #expect(systemAudio.requiredPermissions == [.screenRecording])
    #expect(systemAudio.outputs.map(\.name) == ["samples"])
    #expect(systemAudio.outputs.first?.type == .floatArray)
    #expect(systemAudio.inputs.first { $0.name == "source" }?.type == .enumeration)

    let onset = try libraryContract("audio-onset")
    #expect(onset.inputs.first?.type == .floatArray)
    #expect(onset.inputs.contains { $0.name == "sampleRate" && $0.type == .float })
    #expect(onset.outputs.map(\.name) == ["kick", "snare", "hats", "onset", "flux"])
    #expect(onset.outputs.allSatisfy { $0.type == .float })

    let impulse = try libraryContract("impulse-envelope")
    #expect(impulse.inputs.map(\.name) == ["trigger", "attack", "decay", "amount"])
    #expect(impulse.outputs.map(\.name) == ["value"])
    #expect(impulse.outputs.first?.type == .float)

    let cube = try cubeContract()
    #expect(cube.outputs.first?.type == .texture)
    #expect(cube.outputs.first?.display == true)

    // the old-chain fixes: the mic reports its real rate, the bands accept one.
    let mic = try libraryContract("microphone.macos")
    #expect(mic.outputs.contains { $0.name == "sampleRate" && $0.type == .float })
    let bands = try libraryContract("audio-bands")
    #expect(bands.inputs.contains { $0.name == "sampleRate" && $0.type == .float })
}

// MARK: system-audio capture chain

/// The real `system-audio.macos` node compiles, loads (SCK lifecycle and all) and drives the fft→bands
/// chain through an inline visualizer — the mirror of the mic suite's chain test.
@MainActor
@Test(.enabled(if: SZGPU.isAvailable)) func systemAudioChainCompilesLoadsAndRenders() throws {
    let runtime = try requireRuntime(renderSize: (width: 128, height: 64))
    let bandNames = ["hz32", "hz64", "hz128", "hz256", "hz512", "hz1k", "hz2k", "hz4k", "hz8k", "hz16k"]

    let source = SZNodeID(), fft = SZNodeID(), bands = SZNodeID(), viz = SZNodeID()
    var connections: [SZConnection] = [
        SZConnection(from: SZPortRef(node: source, port: "samples"),
                     to: SZPortRef(node: fft, port: "samples"), kind: .data),
        SZConnection(from: SZPortRef(node: fft, port: "magnitudes"),
                     to: SZPortRef(node: bands, port: "magnitudes"), kind: .data),
    ]
    for name in bandNames {
        connections.append(SZConnection(from: SZPortRef(node: bands, port: name),
                                        to: SZPortRef(node: viz, port: name), kind: .data))
    }
    let vizContract = SZNodeContract(
        title: "Viz", sfSymbol: "waveform", summary: "",
        inputs: bandNames.map { SZPort(name: $0, type: .float) },
        outputs: [SZPort(name: "output", type: .texture, display: true)])
    let project = SZProject(
        name: "system-audio-chain",
        graph: SZGraph(
            nodes: [
                SZNode(id: source, kind: .generated, title: "System Audio", sfSymbol: "speaker.wave.3",
                       contract: try libraryContract("system-audio.macos"), position: SZPoint(x: 0, y: 0)),
                SZNode(id: fft, kind: .generated, title: "Audio FFT", sfSymbol: "waveform.path.ecg",
                       contract: try libraryContract("audio-fft"), position: SZPoint(x: 1, y: 0)),
                SZNode(id: bands, kind: .generated, title: "Frequency Bands", sfSymbol: "chart.bar.xaxis",
                       contract: try libraryContract("audio-bands"), position: SZPoint(x: 2, y: 0)),
                SZNode(id: viz, kind: .generated, title: "Viz", sfSymbol: "waveform",
                       contract: vizContract, position: SZPoint(x: 3, y: 0)),
            ],
            connections: connections,
            renderEndpoint: SZPortRef(node: viz, port: "output")))

    let inlineViz = """
    import Metal
    final class Node: SZNode {
        func update(_ ctx: SZFrameContext) {
            guard let out = ctx.outputTexture("output") else { return }
            var v: Float = 0
            for name in ["hz32","hz64","hz128","hz256","hz512","hz1k","hz2k","hz4k","hz8k","hz16k"] {
                v = max(v, ctx.inputFloat(name) ?? 0)
            }
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = out
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].clearColor = MTLClearColor(red: Double(v), green: Double(v), blue: Double(v), alpha: 1)
            pass.colorAttachments[0].storeAction = .store
            ctx.commandBuffer.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
        }
    }
    enum SZNodeMain { static func make() -> SZNode { Node() } }
    """

    try withLoadedProject(runtime: runtime, project: project, writeSources: { dir in
        try copyLibrarySource("system-audio.macos", to: SZProjectIO.nodeSourceURL(projectURL: dir, nodeID: source))
        try copyLibrarySource("audio-fft", to: SZProjectIO.nodeSourceURL(projectURL: dir, nodeID: fft))
        try copyLibrarySource("audio-bands", to: SZProjectIO.nodeSourceURL(projectURL: dir, nodeID: bands))
        try inlineViz.write(to: SZProjectIO.nodeSourceURL(projectURL: dir, nodeID: viz),
                            atomically: true, encoding: .utf8)
    }) {
        let frame = try #require(runtime.captureFrame())
        #expect(frame.width == 128 && frame.height == 64)
        if !CGPreflightScreenCaptureAccess() {
            // Synthetic fallback active → the bands are driven → a lit band brightens the frame.
            #expect(maxChannel(frame) > 60,
                    "expected a lit band from the synthetic fallback; brightest was \(maxChannel(frame))")
        }
        // With access granted a silent desktop renders ~black — no honest brightness assertion there.
    }
}

// MARK: onset -> envelope, deterministic

/// End-to-end proof of the EVENT stages on any machine: an inline source is silent long enough to warm
/// the onset statistics, then bursts a tone; the kick pulse must punch the envelope (bright frame) and
/// the envelope must decay afterwards. Every stage is the real library node.
@MainActor
@Test(.enabled(if: SZGPU.isAvailable)) func onsetPulsePunchesEnvelopeAndDecays() throws {
    let runtime = try requireRuntime(renderSize: (width: 64, height: 32))

    let source = SZNodeID(), fft = SZNodeID(), onset = SZNodeID(), impulse = SZNodeID(), viz = SZNodeID()
    let sourceContract = SZNodeContract(
        title: "Burst", sfSymbol: "waveform", summary: "",
        inputs: [], outputs: [SZPort(name: "samples", type: .floatArray)])
    let vizContract = SZNodeContract(
        title: "Viz", sfSymbol: "waveform", summary: "",
        inputs: [SZPort(name: "level", type: .float)],
        outputs: [SZPort(name: "output", type: .texture, display: true)])
    let project = SZProject(
        name: "onset-chain",
        graph: SZGraph(
            nodes: [
                SZNode(id: source, kind: .generated, title: "Burst", sfSymbol: "waveform",
                       contract: sourceContract, position: SZPoint(x: 0, y: 0)),
                SZNode(id: fft, kind: .generated, title: "Audio FFT", sfSymbol: "waveform.path.ecg",
                       contract: try libraryContract("audio-fft"), position: SZPoint(x: 1, y: 0)),
                SZNode(id: onset, kind: .generated, title: "Onset Detector", sfSymbol: "bolt.fill",
                       contract: try libraryContract("audio-onset"), position: SZPoint(x: 2, y: 0)),
                SZNode(id: impulse, kind: .generated, title: "Impulse", sfSymbol: "waveform.path",
                       contract: try libraryContract("impulse-envelope"), position: SZPoint(x: 3, y: 0)),
                SZNode(id: viz, kind: .generated, title: "Viz", sfSymbol: "waveform",
                       contract: vizContract, position: SZPoint(x: 4, y: 0)),
            ],
            connections: [
                SZConnection(from: SZPortRef(node: source, port: "samples"),
                             to: SZPortRef(node: fft, port: "samples"), kind: .data),
                SZConnection(from: SZPortRef(node: fft, port: "magnitudes"),
                             to: SZPortRef(node: onset, port: "magnitudes"), kind: .data),
                SZConnection(from: SZPortRef(node: onset, port: "kick"),
                             to: SZPortRef(node: impulse, port: "trigger"), kind: .data),
                SZConnection(from: SZPortRef(node: impulse, port: "value"),
                             to: SZPortRef(node: viz, port: "level"), kind: .data),
            ],
            renderEndpoint: SZPortRef(node: viz, port: "output")))

    // silent for its first 12 updates, then a steady 80 Hz kick-band tone: exactly one flux jump.
    let burstSource = """
    import Foundation
    final class Node: SZNode {
        private var frames = 0
        func update(_ ctx: SZFrameContext) {
            var out = [Float](repeating: 0, count: 2048)
            if frames >= 12 {
                for i in 0..<2048 { out[i] = 0.8 * sinf(2 * .pi * 80 * Float(i) / 48000) }
            }
            frames += 1
            ctx.setOutputFloats("samples", out)
        }
    }
    enum SZNodeMain { static func make() -> SZNode { Node() } }
    """
    let levelViz = """
    import Metal
    final class Node: SZNode {
        func update(_ ctx: SZFrameContext) {
            guard let out = ctx.outputTexture("output") else { return }
            let v = Double(ctx.inputFloat("level") ?? 0)
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = out
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].clearColor = MTLClearColor(red: v, green: v, blue: v, alpha: 1)
            pass.colorAttachments[0].storeAction = .store
            ctx.commandBuffer.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
        }
    }
    enum SZNodeMain { static func make() -> SZNode { Node() } }
    """

    try withLoadedProject(runtime: runtime, project: project, writeSources: { dir in
        try burstSource.write(to: SZProjectIO.nodeSourceURL(projectURL: dir, nodeID: source),
                              atomically: true, encoding: .utf8)
        try copyLibrarySource("audio-fft", to: SZProjectIO.nodeSourceURL(projectURL: dir, nodeID: fft))
        try copyLibrarySource("audio-onset", to: SZProjectIO.nodeSourceURL(projectURL: dir, nodeID: onset))
        try copyLibrarySource("impulse-envelope", to: SZProjectIO.nodeSourceURL(projectURL: dir, nodeID: impulse))
        try levelViz.write(to: SZProjectIO.nodeSourceURL(projectURL: dir, nodeID: viz),
                           atomically: true, encoding: .utf8)
    }) {
        // silence phase: 12 frames spaced ~30 ms so the onset warm-up window (0.25 s) genuinely passes.
        for _ in 0..<12 {
            let frame = try #require(runtime.captureFrame())
            #expect(maxChannel(frame) < 20, "envelope moved during silence: \(maxChannel(frame))")
            usleep(30_000)
        }
        // burst phase: the single flux jump must fire the kick and punch the envelope near 1.
        var peak = 0
        for _ in 0..<6 {
            let frame = try #require(runtime.captureFrame())
            peak = max(peak, maxChannel(frame))
            usleep(30_000)
        }
        #expect(peak > 180, "expected the kick pulse to punch the envelope; peak was \(peak)")
        // decay phase: nodes only tick inside captureFrame and the envelope clamps dt to 0.1 s, so a
        // single long sleep contributes one clamped step — pump frames to genuinely apply ~0.5 s.
        for _ in 0..<5 {
            _ = runtime.captureFrame()
            usleep(100_000)
        }
        let settled = try #require(runtime.captureFrame())
        #expect(maxChannel(settled) < peak / 2,
                "expected the envelope to decay; settled at \(maxChannel(settled)) after peak \(peak)")
    }
}

// MARK: cube

/// The library's first depth-buffered render pass builds and draws: the cube covers the frame center
/// (lit color) while the corners stay black background.
@MainActor
@Test(.enabled(if: SZGPU.isAvailable)) func cubeRendersWithDepthOverBlackBackground() throws {
    let runtime = try requireRuntime(renderSize: (width: 128, height: 128))

    let cube = SZNodeID()
    let project = SZProject(
        name: "cube",
        graph: SZGraph(
            nodes: [SZNode(id: cube, kind: .generated, title: "Cube", sfSymbol: "cube.fill",
                           contract: try cubeContract(), position: SZPoint(x: 0, y: 0))],
            connections: [],
            renderEndpoint: SZPortRef(node: cube, port: "output")))

    try withLoadedProject(runtime: runtime, project: project, writeSources: { dir in
        try FileManager.default.copyItem(
            at: cubeSampleDir.appending(path: "Node.swift"),
            to: SZProjectIO.nodeSourceURL(projectURL: dir, nodeID: cube))
    }) {
        let frame = try #require(runtime.captureFrame())
        let center = try #require(frame.pixel(x: 64, y: 64))
        let corner = try #require(frame.pixel(x: 2, y: 2))
        let centerSum = Int(center.r) + Int(center.g) + Int(center.b)
        let cornerSum = Int(corner.r) + Int(corner.g) + Int(corner.b)
        #expect(centerSum > 60, "expected the lit cube at the frame center; got \(centerSum)")
        #expect(cornerSum < 20, "expected black background in the corner; got \(cornerSum)")
    }
}
