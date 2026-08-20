// SPDX-License-Identifier: AGPL-3.0-only
// The routing MCP tools' validation and read paths on a bare host. State is assigned
// directly and every mutation case exercised is a refusal or a no-op — the persisting
// mutators write the real app-state.json and belong to the live QA pass.
import Foundation
import SZAI
import SZCore
import Testing
@testable import SubjectiveZero

@MainActor
struct SZMCPRoutingToolTests {

    /// A bridge over a host whose routing state is exactly what the test says — nothing
    /// inherited from this machine's real app-state.json. The host rides along because the
    /// bridge holds it `unowned`; the tuple is what keeps it alive for the test's scope.
    private func bare(profiles: [SZRoutingProfile] = [],
                      active: String? = nil) -> (host: SZHost, bridge: SZHostBridge) {
        let host = SZHost()
        host.routingProfiles = profiles
        host.activeRoutingProfileName = active
        host.disabledProviderIDs = []
        host.narratedRoutingNotes = []
        return (host, SZHostBridge(host: host))
    }

    private var fastFleet: SZRoutingProfile {
        SZRoutingProfile(
            name: "fast-fleet",
            agents: ["director": .init(all: SZRouteEnvelope(providerID: "claude")),
                     "coding": .init(all: SZRouteEnvelope(providerID: "codex"))])
    }

    private func json(_ result: SZMCPToolResult) throws -> [String: Any] {
        guard case .text(let text) = result else {
            throw SZMCPError.message("expected a text result")
        }
        return try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    // MARK: - ui_set_routing_profile

    @Test func anUnknownProfileNameListsTheSavedOnes() {
        let pair = bare(profiles: [fastFleet])
        #expect {
            _ = try pair.bridge.callTool(name: "ui_set_routing_profile", arguments: ["profile": "nope"])
        } throws: { error in
            "\(error)".contains("\"nope\"") && "\(error)".contains("fast-fleet")
        }
    }

    @Test func anUnknownNameWithNothingSavedSaysNone() {
        let pair = bare()
        #expect {
            _ = try pair.bridge.callTool(name: "ui_set_routing_profile", arguments: ["profile": "nope"])
        } throws: { error in
            "\(error)".contains("(none)")
        }
    }

    @Test func emptyAndOmittedBothMeanOff() throws {
        // Off on an already-off host is the mutator's no-op lane — nothing persists.
        let pair = bare(profiles: [fastFleet], active: nil)
        for arguments in [[:], ["profile": ""]] as [[String: Any]] {
            let echo = try json(try pair.bridge.callTool(name: "ui_set_routing_profile",
                                                    arguments: arguments))
            #expect(echo["active_profile"] is NSNull)
        }
    }

    @Test func reactivatingTheActiveProfileEchoesIt() throws {
        // Same-name activation is the mutator's other no-op lane; the echo is the applied truth.
        let pair = bare(profiles: [fastFleet], active: "fast-fleet")
        let echo = try json(try pair.bridge.callTool(name: "ui_set_routing_profile",
                                                arguments: ["profile": "fast-fleet"]))
        #expect(echo["active_profile"] as? String == "fast-fleet")
    }

    // MARK: - ui_routing_profiles

    @Test func theProfileListReportsSavedAndActive() throws {
        let other = SZRoutingProfile(name: "thrifty")
        let pair = bare(profiles: [fastFleet, other], active: "thrifty")
        let state = try json(try pair.bridge.callTool(name: "ui_routing_profiles", arguments: [:]))
        #expect(state["profiles"] as? [String] == ["fast-fleet", "thrifty"])
        #expect(state["active_profile"] as? String == "thrifty")
    }

    @Test func aStaleActiveNameReadsAsOff() throws {
        // The stored-raw rule: a persisted name whose profile is gone degrades to Off.
        let pair = bare(profiles: [fastFleet], active: "gone")
        let state = try json(try pair.bridge.callTool(name: "ui_routing_profiles", arguments: [:]))
        #expect(state["active_profile"] is NSNull)
    }

    // MARK: - debug_set_routing (refusal branches only — a valid upsert persists)

    @Test func debugSetRoutingNeedsAnArgument() {
        let pair = bare()
        #expect {
            _ = try pair.bridge.callTool(name: "debug_set_routing", arguments: [:])
        } throws: { error in
            "\(error)".contains("needs")
        }
    }

    @Test func debugSetRoutingRejectsAnUndecodableProfile() {
        // `name` missing — the decode refuses before anything is upserted or persisted.
        let pair = bare()
        #expect {
            _ = try pair.bridge.callTool(name: "debug_set_routing",
                                    arguments: ["profile": ["queries": ["providerID": "claude"]]])
        } throws: { error in
            "\(error)".contains("does not decode")
        }
    }

    @Test func debugSetRoutingRejectsAnUnknownActiveName() {
        let pair = bare(profiles: [fastFleet])
        #expect {
            _ = try pair.bridge.callTool(name: "debug_set_routing", arguments: ["active": "nope"])
        } throws: { error in
            "\(error)".contains("\"nope\"") && "\(error)".contains("fast-fleet")
        }
    }

    // MARK: - debug_routing_state (read-only by contract)

    @Test func routingStateDumpsTheResolvedTableAndGrades() throws {
        let pair = bare(profiles: [fastFleet], active: "fast-fleet")
        let node = SZNodeID()
        pair.host.recordNodeGrade(node, "heavy")
        let state = try json(try pair.bridge.callTool(name: "debug_routing_state", arguments: [:]))
        #expect(state["active_profile"] as? String == "fast-fleet")
        #expect(state["profiles"] as? [String] == ["fast-fleet"])
        #expect((state["node_grades"] as? [String: String])?[node.uuidString] == "heavy")
        let resolved = try #require(state["resolved"] as? [String: Any])
        #expect(resolved["fallback"] is String)
        #expect((resolved["agents"] as? [String: String])?.keys.contains("director") == true)
    }

    @Test func routingStateWithNoProfileIsTheFallbackAlone() throws {
        let pair = bare()
        let state = try json(try pair.bridge.callTool(name: "debug_routing_state", arguments: [:]))
        let resolved = try #require(state["resolved"] as? [String: Any])
        #expect(resolved["fallback"] is String)
        #expect(resolved["agents"] == nil)   // routing off: one choice for every call
    }

    @Test func routingStateNeverConsumesTheNarrationMemory() throws {
        // A broken route produces a fallback sentence; the debug read must report it WITHOUT
        // eating it — the user's next delivery is still owed the narration.
        var profile = fastFleet
        profile.agents["coding"] = .init(all: SZRouteEnvelope(providerID: "no-such-cli"))
        let pair = bare(profiles: [profile], active: "fast-fleet")
        let state = try json(try pair.bridge.callTool(name: "debug_routing_state", arguments: [:]))
        let notes = try #require((state["resolved"] as? [String: Any])?["notes"] as? [String])
        #expect(notes.count == 1 && notes[0].contains("no-such-cli"))
        #expect(pair.host.narratedRoutingNotes.isEmpty)   // restored
        // The real resolution path still narrates it fresh.
        #expect(try pair.host.makeRouter(providerID: "claude").notes.count == 1)
    }
}
