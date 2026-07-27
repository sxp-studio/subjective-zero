// SPDX-License-Identifier: AGPL-3.0-only
// The typed accessors every `ui_*`/`agent_*` handler reads its arguments through (SZHostBridge.swift).
// Arguments arrive off the wire via JSONSerialization, so the fixtures below are decoded from real JSON
// rather than hand-built — the NSNumber bridging these accessors exist for is the whole point.
import Foundation
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
