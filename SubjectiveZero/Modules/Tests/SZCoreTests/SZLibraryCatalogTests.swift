// SPDX-License-Identifier: AGPL-3.0-only
// SZLibraryIndexEntry — the assembled Tier-1 catalog record. Identity + I/O + permissions are DERIVED from
// the contract (single source of truth); useWhen/avoidWhen/purpose/tags come from the curation entry. So a
// curation entry can't inject or override I/O — the historic `resolution` drift can't recur.
import Foundation
import Testing
@testable import SZCore

@Test func entryDerivesIOFromContract_notCuration() {
    let contract = SZNodeContract(
        title: "MacBook Camera", sfSymbol: "camera", summary: "Live camera feed.",
        inputs: [SZPort(name: "mirror", type: .bool),
                 SZPort(name: "aspectFit", type: .bool),
                 SZPort(name: "camera", type: .enumeration)],
        outputs: [SZPort(name: "texture", type: .texture)],
        permissions: [.camera])
    // Curation deliberately carries no io — and even if a stale field existed, the entry never reads io from it.
    let curation = SZLibraryCurationEntry(
        id: "camera.macos", tags: ["source", "camera"], purpose: "camera feed",
        useWhen: "need live camera", avoidWhen: "need a still", reuse: "copy-as-is", platform: "macos")

    let entry = SZLibraryIndexEntry(id: "camera.macos", contract: contract, curation: curation)

    #expect(entry.io.inputs.map(\.name) == ["mirror", "aspectFit", "camera"])   // no phantom "resolution"
    #expect(entry.io.outputs.map(\.name) == ["texture"])
    #expect(entry.io.inputs.map(\.type) == [.bool, .bool, .enumeration])
    #expect(entry.permissions == [.camera])
    #expect(entry.title == "MacBook Camera")            // from contract, not curation
    #expect(entry.useWhen == "need live camera")         // from curation
    #expect(entry.tags == ["source", "camera"])
}

@Test func entryWithoutCurationKeepsContractSubset() {
    let contract = SZNodeContract(
        title: "Audio FFT", sfSymbol: "waveform", summary: "spectrum",
        inputs: [SZPort(name: "samples", type: .floatArray)],
        outputs: [SZPort(name: "magnitudes", type: .floatArray)])

    let entry = SZLibraryIndexEntry(id: "audio-fft", contract: contract, curation: nil)

    #expect(entry.io.inputs.map(\.name) == ["samples"])
    #expect(entry.useWhen == nil)
    #expect(entry.tags == nil)
    #expect(entry.permissions == nil)
}

@Test func curationFileDecodesAndIndexesByID() throws {
    let json = """
    { "nodes": [
        { "id": "a", "useWhen": "ua", "tags": ["x"] },
        { "id": "b", "purpose": "pb", "io": { "inputs": [], "outputs": [] } }
    ] }
    """
    let file = try JSONDecoder().decode(SZLibraryCurationFile.self, from: Data(json.utf8))
    let byID = file.byID
    #expect(byID["a"]?.useWhen == "ua")
    #expect(byID["b"]?.purpose == "pb")   // the legacy "io" key on b is tolerated + ignored
    #expect(byID.count == 2)
}
