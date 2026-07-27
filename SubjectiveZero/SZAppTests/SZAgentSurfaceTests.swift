// SPDX-License-Identifier: AGPL-3.0-only
// The agent bus's tool-surface policy (SZHostBridge): which tools a spawned agent may see and call, and
// what the wire is allowed to carry. Every check reads the derived sets, so a future edit that
// reclassifies a tool — renames a `debug_*`, flips an `agentCallable`, leaks the policy key into a served
// definition — fails here rather than at an agent's first bad move. The derived name sets are
// environment-independent, so `SZ_AGENT_DEBUG_TOOLS=1` does not confuse them; the two tests that read a
// served `.agent` payload do depend on it (the setting legitimately adds `debug_*` to that list) and skip
// when it is set.
import Testing
@testable import SubjectiveZero

@MainActor private var callableNames: [String] { SZHostBridge.agentCallableToolNames }

// MARK: - the allowlist mirror

@Test @MainActor func theAgentAllowlistNeverIncludesADebugTool() {
    #expect(Set(callableNames).isDisjoint(with: SZHostBridge.debugToolNames))
}

@Test @MainActor func aToolIsNeverBothAgentCallableAndWithheld() {
    #expect(Set(callableNames).isDisjoint(with: SZHostBridge.agentWithheldToolNames))
}

@Test @MainActor func viewFrameIsAgentCallable() {
    // The bug this guards against: the Claude allowlist is a derived mirror, so dropping
    // `agent_view_frame` off the agent surface blinds every agent to its own render.
    #expect(callableNames.contains("agent_view_frame"))
}

@Test @MainActor func toolNamesAreUniqueAcrossTheAgentAndUIDefinitions() {
    #expect(callableNames.count == Set(callableNames).count)
}

@Test @MainActor func everyNameSetIsNonEmpty() {
    // A refactor that empties a definitions list would satisfy every disjointness check above in silence.
    #expect(!SZHostBridge.debugToolNames.isEmpty)
    #expect(!SZHostBridge.agentWithheldToolNames.isEmpty)
    #expect(!callableNames.isEmpty)
}

// MARK: - the served `tools/list` payload

@Test @MainActor func servedDefinitionsNeverCarryTheAgentCallablePolicyKey() {
    // `agentCallable` is host-side policy, not MCP wire schema.
    for surface in [SZHostBridge.Surface.full, .agent] {
        #expect(SZHostBridge.toolDefinitions(for: surface).allSatisfy { $0["agentCallable"] == nil })
    }
}

@Test @MainActor func everyServedDefinitionHasTheMCPWireShape() {
    // Written against the serialized shape a client actually receives: name, description, and an
    // object-typed inputSchema with a properties map.
    for def in SZHostBridge.toolDefinitions(for: .full) {
        let name = def["name"] as? String
        #expect(name?.isEmpty == false)
        #expect((def["description"] as? String)?.isEmpty == false, "\(name ?? "?") needs a description")
        let schema = def["inputSchema"] as? [String: Any]
        #expect(schema?["type"] as? String == "object", "\(name ?? "?") inputSchema must be an object")
        #expect(schema?["properties"] as? [String: Any] != nil, "\(name ?? "?") inputSchema needs properties")
    }
}

@Test @MainActor func everyDeclaredPropertyIsAJSONSchemaObject() {
    // A property is a schema object naming a JSON-Schema type — or, where a tool deliberately accepts
    // more than one (`ui_set_input_default.value`), a described untyped one. Never a bare value.
    let jsonTypes: Set<String> = ["string", "number", "integer", "boolean", "array", "object", "null"]
    for def in SZHostBridge.toolDefinitions(for: .full) {
        let name = def["name"] as? String ?? "?"
        let properties = (def["inputSchema"] as? [String: Any])?["properties"] as? [String: Any] ?? [:]
        for (key, property) in properties {
            guard let schema = property as? [String: Any] else {
                Issue.record("\(name).\(key) is not a schema object")
                continue
            }
            if let type = schema["type"] as? String {
                #expect(jsonTypes.contains(type), "\(name).\(key) declares unknown type \"\(type)\"")
                if type == "array" {
                    #expect(schema["items"] as? [String: Any] != nil, "\(name).\(key) is an array without items")
                }
            } else {
                #expect((schema["description"] as? String)?.isEmpty == false,
                        "\(name).\(key) declares no type, so it must describe what it accepts")
            }
        }
    }
}

// MARK: - what each surface serves

@Test @MainActor func theAgentSurfaceServesExactlyTheAgentCallableTools() {
    // Only meaningful when the surface is NOT holding the debug tools open for this process, so under
    // `SZ_AGENT_DEBUG_TOOLS=1` this skips rather than fails — the setting is legitimate, not a defect.
    guard !SZHostBridge.Surface.agent.exposesDebugTools else { return }
    let served = SZHostBridge.toolDefinitions(for: .agent).compactMap { $0["name"] as? String }
    #expect(served == callableNames)
}

@Test @MainActor func theFullSurfaceServesTheDebugToolsTheAgentSurfaceWithholds() {
    // Skipped, not failed, when `SZ_AGENT_DEBUG_TOOLS=1` opens the debug tools on the agent surface.
    guard !SZHostBridge.Surface.agent.exposesDebugTools else { return }
    let full = Set(SZHostBridge.toolDefinitions(for: .full).compactMap { $0["name"] as? String })
    let agent = Set(SZHostBridge.toolDefinitions(for: .agent).compactMap { $0["name"] as? String })
    #expect(SZHostBridge.debugToolNames.isSubset(of: full))
    #expect(SZHostBridge.agentWithheldToolNames.isSubset(of: full))
    #expect(full.subtracting(agent) == SZHostBridge.debugToolNames.union(SZHostBridge.agentWithheldToolNames))
}

@Test @MainActor func debugToolNamesAreDerivedFromTheDefinitionsNotAPrefix() {
    // The gate must not degrade into a naming convention: every name it holds comes from a debug definition.
    let defined = Set(SZHostBridge.debugToolDefinitions.compactMap { $0["name"] as? String })
    #expect(SZHostBridge.debugToolNames == defined)
}
