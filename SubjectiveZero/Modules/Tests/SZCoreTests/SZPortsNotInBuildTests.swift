// SPDX-License-Identifier: AGPL-3.0-only
// `SZNode.portsNotInBuild` — which declared ports the running build was never compiled against. The
// card draws these rows muted, so the answer must be exactly the `rebuildReason` comparison one level
// finer: same evidence (the build stamp), same healing (a promote re-stamps and the set empties).
import Foundation
import Testing
@testable import SZCore

@MainActor
struct SZPortsNotInBuildTests {

    private func contract(_ ports: [(String, SZPortType)]) -> SZNodeContract {
        SZNodeContract(title: "Plasma", sfSymbol: "waveform", summary: "",
                       inputs: ports.map { SZPort(name: $0.0, type: $0.1) })
    }

    private func node(kind: SZNodeKind = .generated,
                      declares: [(String, SZPortType)],
                      built: [(String, SZPortType)]?) -> SZNode {
        SZNode(kind: kind, title: "Plasma", contract: contract(declares),
               position: SZPoint(x: 0, y: 0),
               buildStamp: built.map { SZBuildStamp(portSurface: contract($0).portSurface, prompt: nil) })
    }

    @Test func aPortDeclaredSinceTheBuildIsNotInIt() {
        let n = node(declares: [("amount", .float), ("warp", .float)], built: [("amount", .float)])
        #expect(n.portsNotInBuild.map(\.name) == ["warp"])
        #expect(n.rebuildReason == .contractChanged)   // the two read the same evidence
    }

    @Test func aRestampedNodeHasNothingPending() {
        let n = node(declares: [("amount", .float)], built: [("amount", .float)])
        #expect(n.portsNotInBuild.isEmpty)
        #expect(n.rebuildReason == nil)
    }

    @Test func aRetypedPortIsNotInTheBuild() {
        // The signature is direction + name + type, so the code compiled against `float` does not
        // satisfy a port that is now a texture, even though the name never moved.
        let n = node(declares: [("src", .texture)], built: [("src", .float)])
        #expect(n.portsNotInBuild.map(\.name) == ["src"])
    }

    @Test func aBuildNothingStampedIsTrusted() {
        // "Trust the build": with no stamp there is nothing for the contract to be ahead of, and a
        // card must not mute every row on a node that predates the stamp.
        let n = node(declares: [("amount", .float)], built: nil)
        #expect(n.portsNotInBuild.isEmpty)
    }

    @Test func aDraftHasNoBuildToBeAheadOf() {
        let n = node(kind: .prompt, declares: [("amount", .float)], built: [])
        #expect(n.portsNotInBuild.isEmpty)
    }
}
