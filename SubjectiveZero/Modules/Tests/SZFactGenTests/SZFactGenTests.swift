// SPDX-License-Identifier: AGPL-3.0-only
// Proof for SZFactGen: the generated facts section in SZRuntime is byte-verbatim spec
// text, the generator is deterministic, and the rigid grammar fails loudly on every line
// shape it must reject.
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

// MARK: - The parsed spec has the approved shape

@Test func theSpecParsesToTheApprovedShape() throws {
    let spec = try SZFactGen.parse(try specSource())
    // The wire document and its typed groups, in file order.
    let owners = Dictionary(grouping: spec.fields, by: \.owner)
    #expect(Set(owners.keys) == ["SZFacts", "SZRun", "SZAssignment"])
    #expect(owners["SZFacts"]?.map(\.name) == ["message", "node", "resuming", "run", "assignment"])
    #expect(owners["SZRun"]?.map(\.name) == ["workSet", "round", "roundCap", "steers", "instruction"])
    #expect(owners["SZAssignment"]?.map(\.name) == ["attempt", "note"])
    // Typed-group references and the plain whitelist, spot-checked.
    func field(_ name: String, _ owner: String) -> SZFactField? {
        spec.fields.first { $0.name == name && $0.owner == owner }
    }
    #expect(field("run", "SZFacts")?.swiftType == "SZRun?")
    #expect(field("assignment", "SZFacts")?.swiftType == "SZAssignment?")
    #expect(field("node", "SZFacts")?.swiftType == "UUID?")
    #expect(field("workSet", "SZRun")?.swiftType == "[UUID]")
    #expect(field("note", "SZAssignment")?.swiftType == "String?")
    // Every field carries a doc — the grammar makes doc-less vars unrepresentable, which
    // is where the consumer rule lives.
    #expect(spec.fields.allSatisfy { !$0.doc.isEmpty })
    // The one effect with a live consumer.
    #expect(spec.effectCases == ["requestBuild"])
}

// MARK: - The runtime constant vs. the spec

@Test func runtimeFactsSectionIsVerbatimSpecRegion() throws {
    let source = try specSource()
    let spec = try SZFactGen.parse(source)
    // The generated constant compiled into SZRuntime is the spec region byte for byte.
    #expect(SZStepSDKGenerated.factsSection == spec.regionText)
    #expect(SZStepSDKGenerated.factsSection.hasPrefix(SZFactGen.beginSentinel))
    #expect(SZStepSDKGenerated.factsSection.hasSuffix(SZFactGen.endSentinel))
    #expect(SZStepSDKGenerated.factsSection.contains("public struct SZFacts: Codable, Sendable {"))
    // The conveniences live below the end sentinel and ride the SDK separately.
    #expect(!SZStepSDKGenerated.factsSection.contains("var hasWorkLeft"))
    #expect(SZStepSDKGenerated.conveniences.contains("hasWorkLeft"))
}

// MARK: - Determinism

@Test func generationIsDeterministic() throws {
    let source = try specSource()
    #expect(try SZFactGen.factsSectionSource(from: source) == SZFactGen.factsSectionSource(from: source))
    // And stable across independently re-read bytes, not just repeated calls.
    let again = try specSource()
    #expect(try SZFactGen.factsSectionSource(from: source) == SZFactGen.factsSectionSource(from: again))
}

@Test func generatedSourceCarriesNoTimestamps() throws {
    let section = try SZFactGen.factsSectionSource(from: try specSource())
    for marker in ["202", "Date(", "date:"] {
        #expect(!section.contains(marker))
    }
}

// MARK: - The rigid grammar fails loudly

private func spec(_ body: String) -> String {
    "// SZFactGen:begin\n\(body)\n// SZFactGen:end\n"
}

/// The smallest legal region — the root document with one field.
private let minimalRoot = """
public struct SZFacts: Codable, Sendable {
    /// Fine.
    public var message: String
}
"""

@Test func missingSentinelsAreErrors() {
    #expect(throws: SZFactGenFailure.missingSentinel("// SZFactGen:begin")) {
        try SZFactGen.parse("public struct SZFacts: Codable, Sendable {\n}\n")
    }
    #expect(throws: SZFactGenFailure.missingSentinel("// SZFactGen:end")) {
        try SZFactGen.parse("// SZFactGen:begin\n")
    }
}

@Test func aSentinelInsideTheRegionFailsLoudlyInsteadOfTruncating() {
    // A stray end sentinel would silently truncate the spec — the struct below it drifting
    // out of the SDK while still compiling everywhere. The duplicate must be loud.
    let truncated = """
    // SZFactGen:begin
    public struct SZFacts: Codable, Sendable {
        /// Fine.
        public var message: String
    }
    // SZFactGen:end
    public struct SZRun: Codable, Sendable {
        /// Silently lost without the stray-sentinel check.
        public var round: Int
    }
    // SZFactGen:end
    """
    #expect(throws: SZFactGenFailure.straySentinel(line: 11, sentinel: "// SZFactGen:end")) {
        try SZFactGen.parse(truncated)
    }

    let doubledBegin = spec(minimalRoot) + "// SZFactGen:begin\n"
    #expect(throws: SZFactGenFailure.straySentinel(line: 7, sentinel: "// SZFactGen:begin")) {
        try SZFactGen.parse(doubledBegin)
    }
}

@Test func unclassifiableLinesAreErrors() {
    let bad = spec("""
    public struct SZFacts: Codable, Sendable {
        /// Fine.
        public var message: String
        let sneaky = 1
    }
    """)
    #expect(throws: SZFactGenFailure.unclassifiableLine(line: 5, text: "let sneaky = 1")) {
        try SZFactGen.parse(bad)
    }
}

@Test func varWithoutDocIsAnError() {
    let bad = spec("""
    public struct SZFacts: Codable, Sendable {
        public var message: String
    }
    """)
    #expect(throws: SZFactGenFailure.varWithoutDoc(line: 3, name: "message")) {
        try SZFactGen.parse(bad)
    }
}

@Test func doubledDocIsAnError() {
    let bad = spec("""
    public struct SZFacts: Codable, Sendable {
        /// One.
        /// Two.
        public var message: String
    }
    """)
    #expect(throws: SZFactGenFailure.doubledDoc(line: 4)) { try SZFactGen.parse(bad) }
}

@Test func danglingDocIsAnError() {
    let bad = spec("""
    public struct SZFacts: Codable, Sendable {
        /// Documents nothing.
    }
    """)
    #expect(throws: SZFactGenFailure.danglingDoc(line: 3)) { try SZFactGen.parse(bad) }
}

@Test func typeOutsideTheWhitelistIsAnError() {
    let bad = spec("""
    public struct SZFacts: Codable, Sendable {
        /// Sneaky.
        public var when: Date
    }
    """)
    #expect(throws: SZFactGenFailure.unsupportedType(line: 4, type: "Date")) {
        try SZFactGen.parse(bad)
    }
}

@Test func aStructTypedFieldMustNameADeclaredStructAndBeOptional() {
    // A reference to a struct the region never declares is a typo, not tolerance.
    let unknown = spec("""
    public struct SZFacts: Codable, Sendable {
        /// Sneaky.
        public var run: SZGhost?
    }
    """)
    #expect(throws: SZFactGenFailure.unknownStructType(line: 4, type: "SZGhost?")) {
        try SZFactGen.parse(unknown)
    }
    // A NON-optional group is refused: outside its moment the group is nil, never zeroed.
    let nonOptional = spec("""
    public struct SZFacts: Codable, Sendable {
        /// Sneaky.
        public var run: SZRun
    }

    public struct SZRun: Codable, Sendable {
        /// Fine.
        public var round: Int
    }
    """)
    #expect(throws: SZFactGenFailure.unsupportedType(line: 4, type: "SZRun")) {
        try SZFactGen.parse(nonOptional)
    }
}

@Test func initBlocksPassThroughUnparsed() throws {
    // A struct may declare public inits — opaque to the grammar, compiler-checked on both
    // sides; the fields around them still parse.
    let withInit = spec("""
    public struct SZFacts: Codable, Sendable {
        /// Fine.
        public var message: String

        public init(message: String,
                    extra: Int = 0) {
            self.message = message
        }

        /// Also fine.
        public var resuming: Bool
    }
    """)
    let parsed = try SZFactGen.parse(withInit)
    #expect(parsed.fields.map(\.name) == ["message", "resuming"])
}

@Test func theRootDocumentIsRequired() {
    let noRoot = spec("""
    public struct SZRun: Codable, Sendable {
        /// Fine.
        public var round: Int
    }
    """)
    #expect(throws: SZFactGenFailure.missingRoot) { try SZFactGen.parse(noRoot) }
}

@Test func effectEnumRulesHold() {
    // A raw-valued case breaks the plain-case grammar.
    let rawValue = spec(minimalRoot + """


    public enum SZEffect: String, Codable, Sendable {
        case requestBuild = "build"
    }
    """)
    #expect(throws: SZFactGenFailure.malformedCase(line: 8, text: "case requestBuild = \"build\"")) {
        try SZFactGen.parse(rawValue)
    }
    // An empty effect enum must be omitted, not declared.
    let empty = spec(minimalRoot + """


    public enum SZEffect: String, Codable, Sendable {
    }
    """)
    #expect(throws: SZFactGenFailure.emptyEffectEnum(line: 8)) {
        try SZFactGen.parse(empty)
    }
}

@Test func unterminatedDeclarationIsAnError() {
    let bad = "// SZFactGen:begin\npublic struct SZFacts: Codable, Sendable {\n// SZFactGen:end\n"
    #expect(throws: SZFactGenFailure.unterminatedDeclaration(name: "SZFacts")) {
        try SZFactGen.parse(bad)
    }
}

@Test func docOutsideAStructIsAnError() {
    let bad = spec("""
    /// Free-floating prose belongs above the begin sentinel.
    """ + "\n" + minimalRoot)
    #expect(throws: SZFactGenFailure.docOutsideStruct(line: 2)) { try SZFactGen.parse(bad) }
}

// MARK: - The compiled side of the spec

@Test func derivedConveniencesReadTheFacts() throws {
    var facts = SZFacts(message: "go",
                        run: SZRun(workSet: [UUID()], round: 1, roundCap: 2,
                                   steers: [], instruction: ""))
    #expect(facts.hasWorkLeft)
    facts.run?.workSet = []
    #expect(!facts.hasWorkLeft)
    facts.run = nil
    #expect(!facts.hasWorkLeft)
}

@Test func factsRoundTripAsCodable() throws {
    let node = UUID()
    let facts = SZFacts(message: "hi", node: node, resuming: true,
                        assignment: SZAssignment(attempt: 2, note: "use Rec.709"))
    let data = try JSONEncoder().encode(facts)
    let back = try JSONDecoder().decode(SZFacts.self, from: data)
    #expect(back.message == "hi")
    #expect(back.node == node)
    #expect(back.resuming)
    #expect(back.run == nil)
    #expect(back.assignment?.attempt == 2)
    #expect(back.assignment?.note == "use Rec.709")
}
