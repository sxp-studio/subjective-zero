// SPDX-License-Identifier: AGPL-3.0-only
import Testing
import Foundation
import AVFoundation
import Metal
@testable import SZRuntime
@testable import SZCore

/// The composable audio node suite — `microphone.macos` → `audio-fft` → `audio-bands` — wired over the
/// `floatArray` + named-`float` value channels. These tests compile and load the real library `Node.swift`
/// files (the "copy-as-is" act, by hand) and render the chain headlessly through a tiny INLINE visualizer
/// (the library ships analysis primitives only; the visual output is authored per project). With no
/// authorized mic (CI), `microphone.macos` emits its synthetic sine fallback, so the pipeline drives a
/// visible spectrum without hardware.

private var audioLibraryRoot: URL {
    URL(filePath: #filePath)
        .deletingLastPathComponent()   // SZRuntimeTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // Modules
        .deletingLastPathComponent()   // SubjectiveZero (umbrella root)
        .appending(path: "NodeLibrary")
}

private func audioContract(_ id: String) throws -> SZNodeContract {
    try JSONDecoder().decode(
        SZNodeContract.self,
        from: Data(contentsOf: audioLibraryRoot.appending(path: id).appending(path: "node-contract.json")))
}

private let audioBandNames = ["hz32", "hz64", "hz128", "hz256", "hz512", "hz1k", "hz2k", "hz4k", "hz8k", "hz16k"]

/// Inline stand-in for a render endpoint: 10 named `float` inputs → a `texture` output cleared to
/// gray = the loudest band. A lit band ⇒ a bright frame, so `maxChannel` proves the analysis chain drove it.
private func inlineVisualizerContract() -> SZNodeContract {
    SZNodeContract(title: "Viz", sfSymbol: "waveform", summary: "",
                   inputs: audioBandNames.map { SZPort(name: $0, type: .float) },
                   outputs: [SZPort(name: "output", type: .texture, display: true)])
}

private let inlineVisualizerSource = """
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

private func maxChannel(_ frame: SZImageBytes) -> Int {
    var m = 0
    for y in 0..<frame.height {
        for x in 0..<frame.width {
            if let p = frame.pixel(x: x, y: y) { m = max(m, Int(p.r), Int(p.g), Int(p.b)) }
        }
    }
    return m
}

/// Wire `<source> → audio-fft → audio-bands → inline-viz`, save + copy sources, load, return a captured frame.
@MainActor
private func renderAudioChain(
    runtime: SZRuntime, sourceID: SZNodeID, sourceContract: SZNodeContract, sourceSetup: (URL) throws -> Void
) throws -> SZImageBytes {
    let fft = SZNodeID(), bands = SZNodeID(), viz = SZNodeID()
    var connections: [SZConnection] = [
        SZConnection(from: SZPortRef(node: sourceID, port: "samples"),
                     to: SZPortRef(node: fft, port: "samples"), kind: .data),
        SZConnection(from: SZPortRef(node: fft, port: "magnitudes"),
                     to: SZPortRef(node: bands, port: "magnitudes"), kind: .data),
    ]
    for name in audioBandNames {
        connections.append(SZConnection(from: SZPortRef(node: bands, port: name),
                                        to: SZPortRef(node: viz, port: name), kind: .data))
    }
    let project = SZProject(
        name: "audio-chain",
        graph: SZGraph(
            nodes: [
                SZNode(id: sourceID, kind: .generated, title: "Source", sfSymbol: "waveform",
                       contract: sourceContract, position: SZPoint(x: 0, y: 0)),
                SZNode(id: fft, kind: .generated, title: "Audio FFT", sfSymbol: "waveform.path.ecg",
                       contract: try audioContract("audio-fft"), position: SZPoint(x: 1, y: 0)),
                SZNode(id: bands, kind: .generated, title: "Frequency Bands", sfSymbol: "chart.bar.xaxis",
                       contract: try audioContract("audio-bands"), position: SZPoint(x: 2, y: 0)),
                SZNode(id: viz, kind: .generated, title: "Viz", sfSymbol: "waveform",
                       contract: inlineVisualizerContract(), position: SZPoint(x: 3, y: 0)),
            ],
            connections: connections,
            renderEndpoint: SZPortRef(node: viz, port: "output")))

    let dir = FileManager.default.temporaryDirectory
        .appending(path: "SZAudioChain-\(UUID().uuidString)").appending(path: "audio.subz")
    defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
    try SZProjectIO.save(project, to: dir)
    try sourceSetup(SZProjectIO.nodeSourceURL(projectURL: dir, nodeID: sourceID))
    for (id, libID) in [(fft, "audio-fft"), (bands, "audio-bands")] {
        try FileManager.default.copyItem(
            at: audioLibraryRoot.appending(path: libID).appending(path: "Node.swift"),
            to: SZProjectIO.nodeSourceURL(projectURL: dir, nodeID: id))
    }
    try inlineVisualizerSource.write(to: SZProjectIO.nodeSourceURL(projectURL: dir, nodeID: viz),
                                     atomically: true, encoding: .utf8)

    try runtime.loadProject(at: dir)
    return try #require(runtime.captureFrame())
}

@Test func audioSuiteContractsDecodeWithExpectedShape() throws {
    let mic = try audioContract("microphone.macos")
    #expect(mic.requiredPermissions == [.microphone])
    #expect(mic.outputs.first?.type == .floatArray)

    let fft = try audioContract("audio-fft")
    #expect(fft.inputs.first?.type == .floatArray)
    #expect(fft.outputs.first?.type == .floatArray)

    let bands = try audioContract("audio-bands")
    #expect(bands.inputs.first?.type == .floatArray)
    #expect(bands.outputs.count == 10)
    #expect(bands.outputs.allSatisfy { $0.type == .float })
}

@MainActor
@Test(.enabled(if: SZGPU.isAvailable)) func audioSuiteChainCompilesLoadsAndRenders() throws {
    let runtime = try requireRuntime(renderSize: (width: 128, height: 64))

    // The real microphone.macos node copied in as the source. Compiles all nodes + loads + runs setup/update
    // across the chain; a rendered frame proves the floatArray + named-float edges resolved without crashing.
    let mic = SZNodeID()
    let frame = try renderAudioChain(
        runtime: runtime, sourceID: mic, sourceContract: try audioContract("microphone.macos"),
        sourceSetup: { url in
            try FileManager.default.copyItem(
                at: audioLibraryRoot.appending(path: "microphone.macos/Node.swift"), to: url)
        })

    // Asserted on BOTH branches. This test's unique job is that the real `microphone.macos` node compiles
    // and the floatArray + named-float edges resolve — and a frame at the requested size is the evidence.
    // Previously the authorized branch (the one taken on any dev box that has granted mic access) had an
    // empty body and asserted nothing at all, so this test was vacuous exactly where it usually ran.
    #expect(frame.width == 128 && frame.height == 64)

    // With a real (silent) mic on one headless frame the output is ~black, so brightness says nothing —
    // there is no honest assertion to make on that branch beyond the frame above. The band MATH is proven
    // deterministically, on every machine, by audioAnalysisChainLightsBarsFromKnownSignal below.
    if AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
        // Synthetic fallback active → the bands are driven → a lit band brightens the frame.
        #expect(maxChannel(frame) > 60, "expected a lit band from the synthetic fallback; brightest was \(maxChannel(frame))")
    }
}

/// Deterministic end-to-end proof of the ANALYSIS stages independent of microphone auth: an inline source
/// emits a known sine mix feeding the real `audio-fft` → `audio-bands`. The loudest band must brighten the
/// frame — verifying the FFT/band math and the floatArray + named-float edges on any machine.
@MainActor
@Test(.enabled(if: SZGPU.isAvailable)) func audioAnalysisChainLightsBarsFromKnownSignal() throws {
    let runtime = try requireRuntime(renderSize: (width: 128, height: 64))

    let src = SZNodeID()
    let frame = try renderAudioChain(
        runtime: runtime, sourceID: src,
        sourceContract: SZNodeContract(title: "Tone", sfSymbol: "waveform", summary: "",
                                       inputs: [], outputs: [SZPort(name: "samples", type: .floatArray)]),
        sourceSetup: { url in
            try """
            import Foundation
            final class Node: SZNode {
                func update(_ ctx: SZFrameContext) {
                    let tones: [(Float, Float)] = [(80, 0.6), (220, 0.3), (880, 0.15)]
                    var out = [Float](repeating: 0, count: 2048)
                    for i in 0..<2048 {
                        let t = Float(i) / 48000
                        var s: Float = 0
                        for tone in tones { s += tone.1 * sinf(2 * .pi * tone.0 * t) }
                        out[i] = s
                    }
                    ctx.setOutputFloats("samples", out)
                }
            }
            enum SZNodeMain { static func make() -> SZNode { Node() } }
            """.write(to: url, atomically: true, encoding: .utf8)
        })

    #expect(maxChannel(frame) > 60, "expected a lit band from the known tone mix; brightest was \(maxChannel(frame))")
}
