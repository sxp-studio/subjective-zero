// SPDX-License-Identifier: AGPL-3.0-only
// The SZCore model round-trips to/from project.json + node-contract.json. Two levels:
//  - in-memory: encode → decode → value-stable (covers the typed ids, SZPortValue tags, the
//    `default` key, optional omission);
//  - on-disk: SZProjectIO.save → load through the `.subz` per-node-folder layout, contracts split out
//    and folded back. This is the canonical persistence path the sample project rides on.
import Foundation
import Testing
@testable import SZCore

private func sampleProject() -> SZProject {
    let cameraID = SZNodeID()
    let grayID = SZNodeID()

    let camera = SZNode(
        id: cameraID,
        kind: .generated,
        title: "MacBook Camera",
        sfSymbol: "camera",
        contract: SZNodeContract(
            title: "MacBook Camera",
            sfSymbol: "camera",
            summary: "Live Mac camera feed as a texture.",
            inputs: [
                SZPort(name: "mirror", type: .bool, ui: SZPortUI(kind: .toggle), def: .bool(true)),
                SZPort(name: "camera", type: .enumeration, ui: SZPortUI(kind: .dropdown), def: .enumeration("default"))
            ],
            outputs: [SZPort(name: "texture", type: .texture, display: true)],
            permissions: [.camera]
        ),
        position: SZPoint(x: 120, y: 200)
    )

    let grayscale = SZNode(
        id: grayID,
        kind: .generated,
        title: "Make Grayscale",
        sfSymbol: "circle.lefthalf.filled",
        contract: SZNodeContract(
            title: "Make Grayscale",
            sfSymbol: "circle.lefthalf.filled",
            summary: "Converts an input texture to luminance grayscale.",
            inputs: [
                SZPort(name: "input", type: .texture),
                SZPort(name: "amount", type: .float,
                       ui: SZPortUI(kind: .slider, min: 0, max: 1, step: 0.01), def: .float(1.0))
            ],
            outputs: [SZPort(name: "output", type: .texture, display: true)]
        ),
        position: SZPoint(x: 380, y: 200),
        // Pin the card-body field through both round-trip levels (in-memory + the .subz split —
        // body lives in project.json with the node, NOT in the split-out contract).
        body: SZNodeBody(mode: .preview, previewPort: "output")
    )

    let connection = SZConnection(
        from: SZPortRef(node: cameraID, port: "texture"),
        to: SZPortRef(node: grayID, port: "input"),
        kind: .data
    )

    return SZProject(
        name: "Grayscale Camera",
        author: "SXP Studio",
        graph: SZGraph(
            nodes: [camera, grayscale],
            connections: [connection],
            renderEndpoint: SZPortRef(node: grayID, port: "output")
        )
    )
}

@Test func projectRoundTripsInMemory() throws {
    let project = sampleProject()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(project)
    let decoded = try JSONDecoder().decode(SZProject.self, from: data)
    #expect(decoded == project)
    // Re-encoding the decoded value is byte-stable.
    #expect(try encoder.encode(decoded) == data)
}

@Test func appStateRoundTrips() throws {
    let app = SZAppState(windowSize: SZSize(width: 1600, height: 1000), theme: .dark, openProjectPath: "/x.subz",
                         livePreviews: false)
    let data = try JSONEncoder().encode(app)
    #expect(try JSONDecoder().decode(SZAppState.self, from: data) == app)
}

@Test func portValueTagsRoundTrip() throws {
    let values: [SZPortValue] = [
        .float(0.5), .float2([1, 2]), .float4([1, 2, 3, 4]), .float3x3(Array(repeating: 0, count: 9)),
        .colorRGBA([0.1, 0.2, 0.3, 1]), .bool(false), .enumeration("hd"), .string("/path"), .event
    ]
    for value in values {
        let data = try JSONEncoder().encode(value)
        #expect(try JSONDecoder().decode(SZPortValue.self, from: data) == value)
    }
}

@Test func enumOptionEncodesAsAPositionalPair() throws {
    // SZEnumOption encodes as ["label","value"] (flat pair, no named fields) and round-trips.
    let option = SZEnumOption(label: "FaceTime HD Camera", value: "FAC3T1ME-A1B2")
    let data = try JSONEncoder().encode(option)
    #expect(String(data: data, encoding: .utf8) == "[\"FaceTime HD Camera\",\"FAC3T1ME-A1B2\"]")
    #expect(try JSONDecoder().decode(SZEnumOption.self, from: data) == option)
    // The value-only convenience makes label == value.
    #expect(SZEnumOption(value: "add") == SZEnumOption(label: "add", value: "add"))
}

@Test func portWithStaticOptionsRoundTrips() throws {
    let port = SZPort(name: "blend", type: .enumeration, ui: SZPortUI(kind: .dropdown),
                      def: .enumeration("screen"),
                      options: [SZEnumOption(value: "add"), SZEnumOption(value: "screen"),
                                SZEnumOption(label: "Multiply", value: "multiply")])
    let data = try JSONEncoder().encode(port)
    #expect(try JSONDecoder().decode(SZPort.self, from: data) == port)
}

@Test func portValueStringAccessor() throws {
    #expect(SZPortValue.enumeration("high").string == "high")
    #expect(SZPortValue.string("/path").string == "/path")
    #expect(SZPortValue.float(1).string == nil)
    #expect(SZPortValue.bool(true).string == nil)
}

@Test func entitlementRawValuesRoundTrip() throws {
    // Each SZEntitlement encodes as its lowercase name and decodes back. A contract carrying a
    // `microphone` permission survives the JSON the runtime broker pre-grants from.
    #expect(try JSONDecoder().decode(SZEntitlement.self, from: Data("\"camera\"".utf8)) == .camera)
    #expect(try JSONDecoder().decode(SZEntitlement.self, from: Data("\"microphone\"".utf8)) == .microphone)
    #expect(String(decoding: try JSONEncoder().encode(SZEntitlement.microphone), as: UTF8.self) == "\"microphone\"")

    let contract = SZNodeContract(
        title: "Mic", sfSymbol: "mic", summary: "Built-in microphone.",
        inputs: [], outputs: [SZPort(name: "level", type: .float)], permissions: [.microphone])
    let decoded = try JSONDecoder().decode(SZNodeContract.self, from: try JSONEncoder().encode(contract))
    #expect(decoded.requiredPermissions == [.microphone])
}

@Test func floatArrayPortRoundTripsAndHasNoByValueDefault() throws {
    // The composable audio suite carries PCM samples / FFT magnitudes as a variable-length `floatArray`
    // port over the connected value channel. It round-trips as a contract port, and — like `texture` — is
    // connection-only: it has no by-value default.
    let contract = SZNodeContract(
        title: "FFT", sfSymbol: "waveform", summary: "Spectrum magnitudes.",
        inputs: [SZPort(name: "samples", type: .floatArray)],
        outputs: [SZPort(name: "magnitudes", type: .floatArray)])
    let decoded = try JSONDecoder().decode(SZNodeContract.self, from: try JSONEncoder().encode(contract))
    #expect(decoded == contract)
    #expect(decoded.outputs.first?.type == .floatArray)

    // A floatArray with a by-value default is rejected (mirrors the texture precedent).
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(SZPortValue.self, from: Data("{\"type\":\"floatArray\",\"value\":[1,2]}".utf8))
    }
}

@Test func projectRoundTripsThroughDisk() throws {
    let project = sampleProject()
    let dir = FileManager.default.temporaryDirectory
        .appending(path: "SZProjectIOTests-\(UUID().uuidString)")
        .appending(path: "Grayscale.subz")
    defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }

    try SZProjectIO.save(project, to: dir)

    // project.json exists and does NOT carry node contracts inline (they live in node folders).
    let projectJSON = try String(contentsOf: dir.appending(path: "project.json"), encoding: .utf8)
    #expect(!projectJSON.contains("\"summary\""))
    // Each node's contract was written to its folder.
    for node in project.graph.nodes {
        let contractFile = dir.appending(path: "nodes").appending(path: node.id.description)
            .appending(path: "node-contract.json")
        #expect(FileManager.default.fileExists(atPath: contractFile.path))
    }

    let loaded = try SZProjectIO.load(from: dir)
    #expect(loaded == project)
}

// MARK: - Load re-establishes the contract↔code invariant
//
// `SZStore.editPorts` can mark a node for rebuild because it sees the edit. A project on disk carries only the
// RESULT of that edit, so `load` re-derives what it can by auditing each built node's source against its
// contract. This is what catches drift that predates the fix, or a hand-edited file.

@MainActor
private func projectWithSource(contract: SZNodeContract, source: String,
                              rebuildReason: SZRebuildReason? = nil) throws -> (url: URL, id: SZNodeID) {
    let id = SZNodeID()
    var project = SZProject(name: "Drifted")
    project.graph = SZGraph(nodes: [
        SZNode(id: id, kind: .generated, title: contract.title, contract: contract,
               position: SZPoint(x: 0, y: 0), rebuildReason: rebuildReason)
    ])
    let dir = FileManager.default.temporaryDirectory
        .appending(path: "SZLoadAudit-\(UUID().uuidString)")
        .appending(path: "Drifted.subz")
    try SZProjectIO.save(project, to: dir)
    try source.write(to: SZProjectIO.nodeSourceURL(projectURL: dir, nodeID: id), atomically: true, encoding: .utf8)
    return (dir, id)
}

/// The reported bug, exactly: the Director re-sent the Kaleidoscope's contract with only `input` + a new
/// `audioDrive`, deleting `segments`/`spin`/`twist` — while `Node.swift` went on reading them. Nothing noticed,
/// so the node kept rendering a frozen, audio-deaf kaleidoscope. On load, the code names ports the contract does
/// not declare: an unambiguous error, and grounds to rebuild.
@MainActor
@Test func loadMarksRebuildWhenCodeReadsAPortTheContractDropped() throws {
    let (url, id) = try projectWithSource(
        contract: SZNodeContract(title: "Kaleidoscope", sfSymbol: "sparkles", summary: "",
                                 inputs: [SZPort(name: "input", type: .texture),
                                          SZPort(name: "audioDrive", type: .float)],
                                 outputs: [SZPort(name: "output", type: .texture)]),
        source: """
        final class Node: SZNode {
            func update(_ ctx: SZFrameContext) {
                let t = ctx.inputTexture("input")
                var segments = ctx.inputFloat("segments") ?? 6      // declared by no contract any more
                var spin = ctx.inputFloat("spin") ?? 0
                ctx.outputTexture("output")
            }
        }
        """)
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    let node = try SZProjectIO.load(from: url).graph.node(id: id)!
    // Classified by CONDITION: the code names ports that do not exist, so those reads resolve to nil every
    // frame. That is a fault, not an unfinished feature — the card goes red, not amber.
    #expect(node.rebuildReason == .sourceMismatch)
    #expect(node.kind == .generated)   // still has a build, still renders — it is not un-built
    #expect(node.needsImplementation)
}

/// The loop guard. `SZPortBindingAudit` is a string-literal scan, so a node that builds a port name at runtime —
/// `NodeLibrary/audio-bands` does exactly this — looks like it "never writes" its declared outputs. If a warning
/// marked a node for rebuild, audio-bands would be dirty on every single open and regenerate forever. Only
/// errors (code naming an UNDECLARED port) may raise the flag.
@MainActor
@Test func loadNeverMarksRebuildForADeclaredButUnwrittenPort() throws {
    let (url, id) = try projectWithSource(
        contract: SZNodeContract(title: "Audio Bands", sfSymbol: "waveform", summary: "",
                                 inputs: [SZPort(name: "magnitudes", type: .floatArray)],
                                 outputs: [SZPort(name: "bass", type: .float),
                                           SZPort(name: "treble", type: .float)]),
        source: """
        let kBandNames = ["bass", "treble"]
        final class Node: SZNode {
            func update(_ ctx: SZFrameContext) {
                let m = ctx.inputFloatArray("magnitudes") ?? []
                for b in 0..<2 { ctx.setOutputFloat(kBandNames[b], m.first ?? 0) }   // names built at runtime
            }
        }
        """)
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    #expect(try SZProjectIO.load(from: url).graph.node(id: id)!.rebuildReason == nil)
}

@MainActor
@Test func loadLeavesACleanNodeAlone() throws {
    let (url, id) = try projectWithSource(
        contract: SZNodeContract(title: "Passthrough", sfSymbol: "circle", summary: "",
                                 inputs: [SZPort(name: "input", type: .texture)],
                                 outputs: [SZPort(name: "output", type: .texture)]),
        source: """
        final class Node: SZNode {
            func update(_ ctx: SZFrameContext) {
                _ = ctx.inputTexture("input")
                ctx.outputTexture("output")
            }
        }
        """)
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    let node = try SZProjectIO.load(from: url).graph.node(id: id)!
    #expect(node.rebuildReason == nil)
    #expect(node.needsImplementation == false)
}

/// A `project.json` written before `needsRebuild` existed must decode, not throw.
@Test func nodeDecodesWithoutTheNeedsRebuildKey() throws {
    let json = """
    {"id":"\(UUID().uuidString)","kind":"generated","title":"Legacy","sfSymbol":"circle",
     "position":{"x":0,"y":0}}
    """
    let node = try JSONDecoder().decode(SZNode.self, from: Data(json.utf8))
    #expect(node.rebuildReason == nil)
    #expect(node.kind == .generated)
}
