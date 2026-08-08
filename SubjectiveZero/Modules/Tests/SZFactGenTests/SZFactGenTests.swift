// SPDX-License-Identifier: AGPL-3.0-only
// Proof for the SZFactGen spike: the generated catalog in SZCore matches the spec field
// for field, the generated facts section in SZRuntime is byte-verbatim spec text, the
// generator is deterministic, and the rigid grammar fails loudly on every line shape it
// must reject.
import Foundation
import Testing
@testable import SZCore
@testable import SZRuntime
@testable import SZFactGenCore

/// The one spec, read from the tree the tests were compiled from.
private func specSource() throws -> String {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // SZFactGenTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // Modules
        .appending(path: "Sources/SZCore/AgentFacts/SZFacts.swift")
    return try String(contentsOf: url, encoding: .utf8)
}

// MARK: - The catalog vs. the spec

@Test func catalogMatchesTheSpecFieldForField() throws {
    let spec = try SZFactGen.parse(try specSource())
    #expect(SZFactCatalog.all.count == spec.fields.count)
    for (record, field) in zip(SZFactCatalog.all, spec.fields) {
        #expect(record.name == field.name)
        #expect(record.swiftType == field.swiftType)
        #expect(record.kind == field.kind)
        #expect(record.doc == field.doc)
        #expect(record.lazy == field.lazy)
    }
}

@Test func catalogHasTheApprovedShape() throws {
    let all = SZFactCatalog.all
    #expect(all.count == 21)
    #expect(all.filter { $0.kind == "build" }.count == 10)
    #expect(all.filter { $0.kind == "chat" }.count == 4)
    #expect(all.filter { $0.kind == "item" }.count == 4)
    #expect(all.filter { $0.kind == "request" }.count == 3)

    // graphJSON is the one heavy field; the // lazy marker must surface in its record.
    let lazyRecords = all.filter(\.lazy)
    #expect(lazyRecords.map(\.name) == ["graphJSON"])
    #expect(lazyRecords.first?.swiftType == "String")
    #expect(lazyRecords.first?.kind == "build")

    // Spot checks across kinds, including the optional spelling.
    func record(_ name: String, _ kind: String) -> SZFactRecord? {
        all.first { $0.name == name && $0.kind == kind }
    }
    #expect(record("workLeft", "build")?.swiftType == "Int")
    #expect(record("workSet", "build")?.swiftType == "[String]")
    #expect(record("nodeStatuses", "build")?.swiftType == "[String: String]")
    #expect(record("nodeSeed", "chat")?.swiftType == "String?")
    #expect(record("resumeSession", "item")?.swiftType == "String?")
    #expect(record("nodes", "request")?.swiftType == "[String]")
    // Every record carries a doc — the grammar makes doc-less vars unrepresentable.
    #expect(all.allSatisfy { !$0.doc.isEmpty })
}

@Test func effectsParseAndTolerateAKindWithoutAnEnum() throws {
    let spec = try SZFactGen.parse(try specSource())
    let byKind = Dictionary(uniqueKeysWithValues: spec.effects.map { ($0.kind, $0.cases) })
    #expect(byKind["build"] == ["captureStatuses"])
    #expect(byKind["chat"] == ["requestBuild"])
    #expect(byKind["request"] == ["split", "merge"])
    #expect(byKind["item"] == nil)   // item has facts but no effect enum — legal
}

// MARK: - The runtime constant vs. the spec

@Test func runtimeFactsSectionIsVerbatimSpecRegion() throws {
    let source = try specSource()
    let spec = try SZFactGen.parse(source)
    // The generated constant compiled into SZRuntime is the spec region byte for byte.
    #expect(SZStepSDKGenerated.factsSection == spec.regionText)
    #expect(SZStepSDKGenerated.factsSection.hasPrefix(SZFactGen.beginSentinel))
    #expect(SZStepSDKGenerated.factsSection.hasSuffix(SZFactGen.endSentinel))
    #expect(SZStepSDKGenerated.factsSection.contains("public struct SZBuildFacts: Codable, Sendable {"))
    // The region alone must be enough for a step to decode the wire shape — the derived
    // conveniences stay below the end sentinel and out of the SDK.
    #expect(!SZStepSDKGenerated.factsSection.contains("hasWorkLeft"))
}

// MARK: - Determinism

@Test func generationIsDeterministic() throws {
    let source = try specSource()
    #expect(try SZFactGen.catalogSource(from: source) == SZFactGen.catalogSource(from: source))
    #expect(try SZFactGen.factsSectionSource(from: source) == SZFactGen.factsSectionSource(from: source))
    // And stable across independently re-read bytes, not just repeated calls.
    let again = try specSource()
    #expect(try SZFactGen.catalogSource(from: source) == SZFactGen.catalogSource(from: again))
}

@Test func generatedSourcesCarryNoTimestamps() throws {
    let source = try specSource()
    let catalog = try SZFactGen.catalogSource(from: source)
    let section = try SZFactGen.factsSectionSource(from: source)
    for year in ["202", "Date", "date:"] {
        #expect(!catalog.contains(year))
        #expect(!section.contains(year))
    }
}

// MARK: - The rigid grammar fails loudly

private func spec(_ body: String) -> String {
    "// SZFactGen:begin\n\(body)\n// SZFactGen:end\n"
}

@Test func missingSentinelsAreErrors() {
    #expect(throws: SZFactGenFailure.missingSentinel("// SZFactGen:begin")) {
        try SZFactGen.parse("public struct SZBuildFacts: Codable, Sendable {\n}\n")
    }
    #expect(throws: SZFactGenFailure.missingSentinel("// SZFactGen:end")) {
        try SZFactGen.parse("// SZFactGen:begin\n")
    }
}

@Test func unclassifiableLinesAreErrors() {
    let bad = spec("""
    public struct SZBuildFacts: Codable, Sendable {
        /// Fine.
        public var workLeft: Int
        let sneaky = 1
    }
    """)
    #expect(throws: SZFactGenFailure.unclassifiableLine(line: 5, text: "let sneaky = 1")) {
        try SZFactGen.parse(bad)
    }
}

@Test func varWithoutDocIsAnError() {
    let bad = spec("""
    public struct SZBuildFacts: Codable, Sendable {
        public var workLeft: Int
    }
    """)
    #expect(throws: SZFactGenFailure.varWithoutDoc(line: 3, name: "workLeft")) {
        try SZFactGen.parse(bad)
    }
}

@Test func doubledDocIsAnError() {
    let bad = spec("""
    public struct SZBuildFacts: Codable, Sendable {
        /// One.
        /// Two.
        public var workLeft: Int
    }
    """)
    #expect(throws: SZFactGenFailure.doubledDoc(line: 4)) { try SZFactGen.parse(bad) }
}

@Test func danglingDocIsAnError() {
    let bad = spec("""
    public struct SZBuildFacts: Codable, Sendable {
        /// Documents nothing.
    }
    """)
    #expect(throws: SZFactGenFailure.danglingDoc(line: 3)) { try SZFactGen.parse(bad) }
}

@Test func typeOutsideTheWhitelistIsAnError() {
    let bad = spec("""
    public struct SZBuildFacts: Codable, Sendable {
        /// Sneaky.
        public var when: Date
    }
    """)
    #expect(throws: SZFactGenFailure.unsupportedType(line: 4, type: "Date")) {
        try SZFactGen.parse(bad)
    }
}

@Test func onlyOptionalStringIsAllowed() {
    let bad = spec("""
    public struct SZChatFacts: Codable, Sendable {
        /// Sneaky.
        public var count: Int?
    }
    """)
    #expect(throws: SZFactGenFailure.unsupportedType(line: 4, type: "Int?")) {
        try SZFactGen.parse(bad)
    }
}

@Test func effectEnumRulesHold() {
    // A raw-valued case breaks the plain-case grammar.
    let rawValue = spec("""
    public struct SZBuildFacts: Codable, Sendable {
        /// Fine.
        public var workLeft: Int
    }

    public enum SZBuildEffect: String, Codable, Sendable {
        case captureStatuses = "capture"
    }
    """)
    #expect(throws: SZFactGenFailure.malformedCase(line: 8, text: "case captureStatuses = \"capture\"")) {
        try SZFactGen.parse(rawValue)
    }
    // An empty effect enum must be omitted, not declared.
    let empty = spec("""
    public struct SZBuildFacts: Codable, Sendable {
        /// Fine.
        public var workLeft: Int
    }

    public enum SZBuildEffect: String, Codable, Sendable {
    }
    """)
    #expect(throws: SZFactGenFailure.emptyEffectEnum(line: 8, name: "SZBuildEffect")) {
        try SZFactGen.parse(empty)
    }
    // An effect enum whose kind has no facts struct is a typo, not tolerance.
    let orphan = spec("""
    public struct SZBuildFacts: Codable, Sendable {
        /// Fine.
        public var workLeft: Int
    }

    public enum SZCharEffect: String, Codable, Sendable {
        case requestBuild
    }
    """)
    #expect(throws: SZFactGenFailure.effectWithoutFacts(line: 10, name: "SZCharEffect")) {
        try SZFactGen.parse(orphan)
    }
}

@Test func unterminatedDeclarationIsAnError() {
    let bad = "// SZFactGen:begin\npublic struct SZBuildFacts: Codable, Sendable {\n// SZFactGen:end\n"
    #expect(throws: SZFactGenFailure.unterminatedDeclaration(name: "SZBuildFacts")) {
        try SZFactGen.parse(bad)
    }
}

@Test func docOutsideAStructIsAnError() {
    let bad = spec("""
    /// Free-floating prose belongs above the begin sentinel.
    public struct SZBuildFacts: Codable, Sendable {
        /// Fine.
        public var workLeft: Int
    }
    """)
    #expect(throws: SZFactGenFailure.docOutsideStruct(line: 2)) { try SZFactGen.parse(bad) }
}

// MARK: - The compiled side of the spec

@Test func derivedConveniencesReadTheFacts() throws {
    var facts = SZBuildFacts(
        workLeft: 2, workSet: ["a", "b"], nodeStatuses: ["a": "implementing"],
        buildErrors: [:], round: 1, roundCap: 3, briefed: true, projectLoaded: true,
        graphJSON: "{}", steers: []
    )
    #expect(facts.hasWorkLeft)
    #expect(!facts.fleetIsFailing)
    facts.workLeft = 0
    facts.nodeStatuses["a"] = "stuck"
    #expect(!facts.hasWorkLeft)
    #expect(facts.fleetIsFailing)
    facts.nodeStatuses["a"] = "done"
    facts.buildErrors["b"] = "error: missing symbol"
    #expect(facts.fleetIsFailing)
}

@Test func factsStructsRoundTripAsCodable() throws {
    let chat = SZChatFacts(sentMessage: "hi", resuming: false, draftedWork: true, nodeSeed: nil)
    let data = try JSONEncoder().encode(chat)
    let back = try JSONDecoder().decode(SZChatFacts.self, from: data)
    #expect(back.sentMessage == "hi")
    #expect(back.nodeSeed == nil)
}
