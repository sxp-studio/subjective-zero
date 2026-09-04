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
