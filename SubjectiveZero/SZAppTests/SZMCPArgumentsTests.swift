// SPDX-License-Identifier: AGPL-3.0-only
// The argument seam every `ui_*`/`agent_*` handler reads through (SZHostBridge.swift): the typed
// accessors, and the null-stripping the dispatcher applies before any of them run. Arguments arrive off
// the wire via JSONSerialization, so the fixtures below are decoded from real JSON rather than hand-built
// — the NSNumber bridging these accessors exist for is the whole point. The tail pins the one JSON shape
// every tool answers in.
import Foundation
import SZCore
import Testing
@testable import SubjectiveZero

private func arguments(_ json: String) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
}

// MARK: - scalars

@Test func readsStringsAndRejectsOtherTypes() throws {
    let args = try arguments(#"{"prompt": "a blue ramp", "count": 3}"#)
    #expect(args.string("prompt") == "a blue ramp")
    #expect(args.string("count") == nil)
    #expect(args.string("missing") == nil)
}

@Test func readsDoublesFromEveryJSONNumberForm() throws {
    let args = try arguments(#"{"x": 12.5, "y": 40, "z": -1e2, "label": "12.5"}"#)
    #expect(args.double("x") == 12.5)
    #expect(args.double("y") == 40)      // an integer literal still reads as a Double
    #expect(args.double("z") == -100)
    #expect(args.double("label") == nil) // a numeric-looking string is not a number
    #expect(args.double("missing") == nil)
}

@Test func readsIntsAndTruncatesFractions() throws {
    let args = try arguments(#"{"pieces": 3, "fractional": 3.7, "negative": -3.7}"#)
    #expect(args.int("pieces") == 3)
    #expect(args.int("fractional") == 3)    // truncates toward zero, it does not round
    #expect(args.int("negative") == -3)
}

// MARK: - identifiers

@Test func readsUUIDsAndRejectsMalformedOnes() throws {
    let id = UUID()
    let args = try arguments(#"{"node": "\#(id.uuidString)", "bad": "not-a-uuid", "n": 7}"#)
    #expect(args.uuid("node") == id)
    #expect(args.uuid("bad") == nil)
    #expect(args.uuid("n") == nil)
    #expect(args.uuid("missing") == nil)
}

@Test func readsUUIDListsDroppingUnparseableEntries() throws {
    let first = UUID(), second = UUID()
    let args = try arguments(#"{"nodes": ["\#(first.uuidString)", "nope", 4, "\#(second.uuidString)"]}"#)
    #expect(args.uuidList("nodes") == [first, second])
}

@Test func aMissingOrWrongTypedListReadsAsEmpty() throws {
    // Handlers treat an absent list as "nothing named" — never as an error.
    let args = try arguments(#"{"nodes": "not-a-list"}"#)
    #expect(args.uuidList("nodes").isEmpty)
    #expect(args.uuidList("missing").isEmpty)
    #expect(args.stringList("nodes").isEmpty)
    #expect(args.stringList("missing").isEmpty)
}

@Test func readsStringListsDroppingNonStrings() throws {
    let args = try arguments(#"{"paths": ["/a.png", 2, "/b.mov", null]}"#)
    #expect(args.stringList("paths") == ["/a.png", "/b.mov"])
}

// MARK: - nested objects

@Test func readsNestedObjects() throws {
    let args = try arguments(#"{"inputs": {"remove": ["gain"]}, "node": "x"}"#)
    let inputs = try #require(args.object("inputs"))
    #expect(inputs.stringList("remove") == ["gain"])
    #expect(args.object("node") == nil)
    #expect(args.object("missing") == nil)
}

// MARK: - `null` reads as absent

@Test func nullValuedArgumentsAreDroppedAtEveryDepth() throws {
    // A client that materializes its declared-but-unused optional properties sends `null`; every handler
    // must see the same thing it sees for an argument that was never sent.
    let args = SZHostBridge.omittingNulls(
        try arguments(#"{"node": null, "port": "out", "contract": {"title": "T", "card": null}}"#))
    #expect(args["node"] == nil)
    #expect(args.string("port") == "out")
    #expect(args.object("contract")?["card"] == nil)
    #expect(args.object("contract")?["title"] as? String == "T")
}

@Test func aNullInsideAnArrayStandsAsAnElement() throws {
    // A list's shape is the caller's: dropping an element would silently change an arity the value
    // coercions are there to refuse.
    let args = SZHostBridge.omittingNulls(try arguments(#"{"value": [1, null, 3]}"#))
    #expect((args["value"] as? [Any])?.count == 3)
}

@Test @MainActor func anArgumentSentAsNullTakesTheArgumentLessPath() async throws {
    // `agent_view_frame { "node": null }` must behave exactly like `agent_view_frame {}` — read the
    // viewport's endpoint — not fail on "`node` must be a UUID".
    let host = SZHost()
    host.store.setProject(SZProject(name: "t", graph: SZGraph(nodes: [])))
    let bridge = SZHostBridge(host: host)
    await #expect {
        _ = try await bridge.call(name: "agent_view_frame", arguments: ["node": NSNull()])
    } throws: { error in
        "\(error)".contains("no frame rendered yet")     // the endpoint path, with nothing rendered yet
    }
}

// MARK: - the port shape `ui_edit_ports` reads

@Test @MainActor func aPortDefaultSentAsABareNumberIsRefusedInTheAppsOwnWords() throws {
    // The shape an agent guesses: `default: 0.5`, with the range beside it instead of inside `ui`.
    // The answer used to be the decoder's own — a Swift type name and a coding path — which is not
    // the vocabulary the caller wrote the JSON in.
    let host = SZHost()   // held: the bridge keeps it `unowned`
    let bridge = SZHostBridge(host: host)
    let args = try arguments("""
        {"node": "\(UUID().uuidString)",
         "inputs": {"upsert": [{"name": "mix", "type": "float", "default": 0.5, "min": 0, "max": 1}]}}
        """)
    #expect {
        _ = try bridge.callTool(name: "ui_edit_ports", arguments: args)
    } throws: { error in
        let said = "\(error)"
        return said.contains("ui_edit_ports")
            && said.contains("port `mix`")                                  // which port
            && said.contains("`default`")                                   // and which key
            && said.contains(#"{ "type": "float", "value": 0.5 }"#)         // and the shape it takes
            && said.contains("Nothing was changed.")
            && !said.contains("DecodingError") && !said.contains("Dictionary<String, Any>")
    }
}

@Test @MainActor func aPortControlSentAsAStringNamesTheKeyAndNotTheSwiftType() throws {
    // `"ui": "slider"` — the other guess. Same channel, named by the key the caller wrote.
    let host = SZHost()
    let bridge = SZHostBridge(host: host)
    let args = try arguments("""
        {"node": "\(UUID().uuidString)",
         "outputs": {"upsert": [{"name": "amount", "type": "float", "ui": "slider"}]}}
        """)
    #expect {
        _ = try bridge.callTool(name: "ui_edit_ports", arguments: args)
    } throws: { error in
        let said = "\(error)"
        return said.contains("port `amount` in `outputs.upsert`")
            && said.contains("`ui` is an object")
            && !said.contains("DecodingError")
    }
}

@Test @MainActor func anUpsertThatIsNotAListOfPortsSaysSoRatherThanDroppingIt() throws {
    // A non-list `upsert` used to read as "no ports sent" and come back as "needs at least one
    // upsert or remove", which sends the caller looking in the wrong place.
    let host = SZHost()
    let bridge = SZHostBridge(host: host)
    let args = try arguments(#"{"node": "\#(UUID().uuidString)", "inputs": {"upsert": "mix"}}"#)
    #expect {
        _ = try bridge.callTool(name: "ui_edit_ports", arguments: args)
    } throws: { error in
        "\(error)".contains("`inputs.upsert` is a list of port objects")
    }
}

@Test @MainActor func anEnumPortDeclaredAsPositionalPairsIsAccepted() throws {
    // `SZEnumOption` decodes an unkeyed pair, so the documented `[label, value]` form has to be the
    // one the tool takes.
    let id = SZNodeID()
    let node = SZNode(id: id, kind: .generated, title: "Effect",
                      contract: SZNodeContract(title: "Effect", sfSymbol: "s", summary: "",
                                               inputs: [], outputs: []),
                      position: SZPoint(x: 0, y: 0))
    let host = SZHost()
    host.store.setProject(SZProject(name: "t", graph: SZGraph(nodes: [node])))
    let bridge = SZHostBridge(host: host)
    let args = try arguments("""
        {"node": "\(id.uuidString)",
         "inputs": {"upsert": [{"name": "mode", "type": "enum",
                                "options": [["Warm", "warm"], ["Cool", "cool"]],
                                "default": {"type": "enum", "value": "warm"}}]}}
        """)
    _ = try bridge.callTool(name: "ui_edit_ports", arguments: args)
    let port = host.store.project?.graph.node(id: id)?.contract?.inputs.first
    #expect(port?.options == [SZEnumOption(label: "Warm", value: "warm"),
                              SZEnumOption(label: "Cool", value: "cool")])
    #expect(port?.def == .enumeration("warm"))
}

@Test @MainActor func enumOptionsSentAsObjectsAreAnsweredWithThePairForm() throws {
    // The wrong guess is the object form; answering with it again loops the caller through the same
    // refusal.
    let host = SZHost()
    let bridge = SZHostBridge(host: host)
    let args = try arguments("""
        {"node": "\(UUID().uuidString)",
         "inputs": {"upsert": [{"name": "mode", "type": "enum",
                                "options": [{"label": "Warm", "value": "warm"}]}]}}
        """)
    #expect {
        _ = try bridge.callTool(name: "ui_edit_ports", arguments: args)
    } throws: { error in
        let said = "\(error)"
        return said.contains("port `mode`")
            && said.contains("[label, value] string pairs")
            && said.contains(#"[["Warm", "warm"]"#)
            && !said.contains(#"{ "label", "value" }"#)
    }
}

@Test @MainActor func aTextureDefaultIsToldTheTypeCarriesNoDefault() throws {
    // The tagged object is the right shape here; the type is what has no by-value default, so the
    // "tag your default" answer would describe what the caller already sent.
    let host = SZHost()
    let bridge = SZHostBridge(host: host)
    let args = try arguments("""
        {"node": "\(UUID().uuidString)",
         "inputs": {"upsert": [{"name": "src", "type": "texture",
                                "default": {"type": "texture", "value": 0}}]}}
        """)
    #expect {
        _ = try bridge.callTool(name: "ui_edit_ports", arguments: args)
    } throws: { error in
        let said = "\(error)"
        return said.contains("takes no default")
            && !said.contains("naming the value's type")
    }
}

@Test @MainActor func theSchemaSaysEnumOptionsArePositionalPairs() throws {
    // The schema is what an agent copies the call from, so its item shape has to be one
    // `SZEnumOption` decodes: an object shape documented a call that always came back refused.
    let definition = SZHostBridge.toolDefinitions(for: .agent)
        .first { $0["name"] as? String == "ui_edit_ports" }
    let properties = (definition?["inputSchema"] as? [String: Any])?["properties"] as? [String: Any]
    let port = ((properties?["inputs"] as? [String: Any])?["properties"] as? [String: Any])
        .flatMap { ($0["upsert"] as? [String: Any])?["items"] as? [String: Any] }
    let options = try #require((port?["properties"] as? [String: Any])?["options"] as? [String: Any])
    let item = try #require(options["items"] as? [String: Any])
    #expect(item["type"] as? String == "array")
    #expect((item["items"] as? [String: Any])?["type"] as? String == "string")
    // and the example it shows is one the decoder takes
    #expect(try JSONDecoder().decode([SZEnumOption].self, from: Data(#"[["Warm", "warm"]]"#.utf8))
            == [SZEnumOption(label: "Warm", value: "warm")])
}

@Test @MainActor func theEditPortsSchemaSpellsOutThePortShape() {
    // The schema is the documentation an agent calls this tool from: it used to say `[Port]` and
    // define `Port` nowhere, so the two keys below were a guess.
    let definition = SZHostBridge.toolDefinitions(for: .agent)
        .first { $0["name"] as? String == "ui_edit_ports" }
    let properties = (definition?["inputSchema"] as? [String: Any])?["properties"] as? [String: Any]
    let port = ((properties?["inputs"] as? [String: Any])?["properties"] as? [String: Any])
        .flatMap { ($0["upsert"] as? [String: Any])?["items"] as? [String: Any] }
    let keys = port?["properties"] as? [String: Any]
    #expect(port?["required"] as? [String] == ["name", "type"])
    #expect(keys?["name"] != nil && keys?["type"] != nil && keys?["options"] != nil)
    // `default` is an object of {type, value}, not a bare value, and a slider's range is in `ui`.
    #expect((keys?["default"] as? [String: Any])?["type"] as? String == "object")
    let ui = keys?["ui"] as? [String: Any]
    #expect((ui?["properties"] as? [String: Any])?["min"] != nil)
    #expect(((ui?["properties"] as? [String: Any])?["kind"] as? [String: Any])?["enum"] as? [String]
            == SZPortUIKind.allCases.map(\.rawValue))
}

// MARK: - one JSON shape

@Test @MainActor func annotatedAndPlainPayloadsAreEncodedIdentically() throws {
    // `agent_read_graph`/`agent_read_node` re-encode a decoded payload to annotate it; that path and the
    // plain `Encodable` one must produce the same bytes, or one tool answers in a shape its neighbours
    // don't (slashes in a file path being the visible tell).
    let bridge = SZHostBridge(host: SZHost())
    let contract = SZNodeContract(title: "T", sfSymbol: "circle", summary: "a/b",
                                  inputs: [SZPort(name: "path", type: .string)], outputs: [])
    let encoded = bridge.encodeJSON(contract)
    let json = try #require(try JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [String: Any])
    #expect(bridge.encodeJSON(json, fallback: "") == encoded)
}
