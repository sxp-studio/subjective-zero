// SPDX-License-Identifier: AGPL-3.0-only
// The SZFactGen generator's core: parses the sentinel-marked spec region of SZFacts.swift
// (rigid grammar, plain string ops — no swift-syntax) and renders the one build-time
// artifact: SZStepKitGenerated.swift, the verbatim spec region + conveniences the step kit
// splices into every step build, so a step compiles against the very source the app
// compiled and both sides of the ABI decode the same wire shape. Pure functions of the
// input text — same input bytes, same output bytes, no timestamps — so the build stays
// deterministic and the tests can prove it. The tool target is a thin CLI over this
// library; the test target imports it directly.
import Foundation

/// One field as the spec declares it. `owner` names the struct the field lives in
/// ("SZFacts", "SZRun", …) — diagnostics only; there is no catalog any more.
public struct SZFactField: Equatable, Sendable {
    public var name: String
    public var swiftType: String
    public var owner: String
    public var doc: String

    public init(name: String, swiftType: String, owner: String, doc: String) {
        self.name = name
        self.swiftType = swiftType
        self.owner = owner
        self.doc = doc
    }
}

/// Everything the parser extracts from one spec file.
public struct SZFactSpec: Equatable, Sendable {
    /// The verbatim spec region, sentinel lines included, no trailing newline.
    public var regionText: String
    /// The text BELOW the end sentinel — the spec's derived-convenience extensions
    /// (`hasWorkLeft`, …), verbatim minus any `import` lines, so the step kit can embed
    /// them and share the exact spellings the app compiles. Ungoverned by the grammar:
    /// it is ordinary Swift, compile-checked on both sides.
    public var tailText: String
    public var fields: [SZFactField]
    /// The effect enum's plain cases, spec order; empty when the spec declares none.
    public var effectCases: [String]
}

/// A grammar violation. Every case carries the 1-based line number in the WHOLE file, so
/// the tool can print `path:line: error: …` and the build fails loudly at the right spot.
public enum SZFactGenFailure: Error, Equatable, CustomStringConvertible {
    case missingSentinel(String)
    /// A begin/end sentinel line appears AGAIN after the region closed. The classic cause is
    /// an end sentinel accidentally landing inside the intended region: the region would
    /// silently truncate at the stray line and everything below it — spec structs included —
    /// would drift into the ungoverned tail, embedded in the step kit but ungoverned. A
    /// spec carries exactly one begin/end pair, loudly.
    case straySentinel(line: Int, sentinel: String)
    case unclassifiableLine(line: Int, text: String)
    case docOutsideStruct(line: Int)
    case danglingDoc(line: Int)
    case varWithoutDoc(line: Int, name: String)
    case doubledDoc(line: Int)
    case unsupportedType(line: Int, type: String)
    case malformedVar(line: Int, text: String)
    case malformedCase(line: Int, text: String)
    case unterminatedDeclaration(name: String)
    case emptyEffectEnum(line: Int)
    case duplicateDeclaration(line: Int, name: String)
    /// The region never declares the root document — the wire shape a step receives.
    case missingRoot
    /// A struct-typed field names a struct the region does not declare.
    case unknownStructType(line: Int, type: String)

    public var line: Int? {
        switch self {
        case .missingSentinel, .unterminatedDeclaration, .missingRoot: return nil
        case .straySentinel(let line, _): return line
        case .unclassifiableLine(let line, _), .docOutsideStruct(let line),
             .danglingDoc(let line), .varWithoutDoc(let line, _), .doubledDoc(let line),
             .unsupportedType(let line, _), .malformedVar(let line, _),
             .malformedCase(let line, _), .emptyEffectEnum(let line),
             .duplicateDeclaration(let line, _), .unknownStructType(let line, _):
            return line
        }
    }

    public var description: String {
        switch self {
        case .missingSentinel(let sentinel):
            return "SZFactGen: spec sentinel '\(sentinel)' not found"
        case .straySentinel(_, let sentinel):
            return "SZFactGen: '\(sentinel)' appears again after the region closed — the region "
                + "ends at the FIRST end sentinel, so everything between the two silently left "
                + "the spec; a file carries exactly one begin/end pair"
        case .unclassifiableLine(_, let text):
            return "SZFactGen: cannot classify this line inside the spec region: '\(text)'"
        case .docOutsideStruct:
            return "SZFactGen: doc lines are only legal immediately before a var inside a spec struct"
        case .danglingDoc:
            return "SZFactGen: doc line is not followed by a `public var` line"
        case .varWithoutDoc(_, let name):
            return "SZFactGen: var '\(name)' needs exactly one `///` doc line directly above it "
                + "— the doc NAMES THE CONSUMER; a fact nothing reads is deleted, not kept warm"
        case .doubledDoc:
            return "SZFactGen: a var takes exactly ONE doc line; fold these into one"
        case .unsupportedType(_, let type):
            return "SZFactGen: type '\(type)' is outside the rigid grammar (Int, Int?, Bool, "
                + "String, String?, [String], UUID?, [UUID], [String: String], or an optional "
                + "of a struct declared in this region)"
        case .malformedVar(_, let text):
            return "SZFactGen: malformed var line: '\(text)' (expected `public var name: Type`)"
        case .malformedCase(_, let text):
            return "SZFactGen: malformed case line: '\(text)' (expected `case name` with no raw value or payload)"
        case .unterminatedDeclaration(let name):
            return "SZFactGen: '\(name)' never closes before the end sentinel"
        case .emptyEffectEnum:
            return "SZFactGen: SZEffect has no cases — omit the enum instead"
        case .duplicateDeclaration(_, let name):
            return "SZFactGen: '\(name)' is declared twice in the spec region"
        case .missingRoot:
            return "SZFactGen: the region declares no `SZFacts` struct — the wire document a step receives"
        case .unknownStructType(_, let type):
            return "SZFactGen: '\(type)' names a struct this region does not declare"
        }
    }
}

public enum SZFactGen {
    public static let beginSentinel = "// SZFactGen:begin"
    public static let endSentinel = "// SZFactGen:end"
    /// The root document — the wire shape a step evaluation receives.
    public static let rootStruct = "SZFacts"
    /// The one effect enum's exact name.
    public static let effectEnum = "SZEffect"

    /// The closed set of PLAIN field types the grammar accepts. A struct declared in the
    /// region may additionally appear as an optional (`SZRun?`), validated after parse.
    public static let allowedTypes: Set<String> = [
        "Int", "Int?", "Bool", "String", "String?", "[String]", "UUID?", "[UUID]",
        "[String: String]"
    ]

    // MARK: - Parsing

    /// Parse a whole SZFacts.swift source. Throws `SZFactGenFailure` on the first line the
    /// rigid grammar cannot account for.
    public static func parse(_ source: String) throws -> SZFactSpec {
        // Split keeping no separators; line numbers are 1-based over the whole file.
        let lines = source.components(separatedBy: "\n")
        guard let begin = lines.firstIndex(where: { $0.trimmed == beginSentinel }) else {
            throw SZFactGenFailure.missingSentinel(beginSentinel)
        }
        guard let end = lines[(begin + 1)...].firstIndex(where: { $0.trimmed == endSentinel }) else {
            throw SZFactGenFailure.missingSentinel(endSentinel)
        }
        // No sentinel may appear again below the region. An exact end-sentinel line INSIDE
        // the intended region would otherwise truncate it silently — the real end sentinel
        // reads as a duplicate down here, which is the loud symptom of that mistake.
        for index in (end + 1)..<lines.count {
            let trimmed = lines[index].trimmed
            if trimmed == endSentinel || trimmed == beginSentinel {
                throw SZFactGenFailure.straySentinel(line: index + 1, sentinel: trimmed)
            }
        }
        let regionText = lines[begin...end].joined(separator: "\n")
        var tailLines = Array(lines[(end + 1)...])
        tailLines.removeAll { $0.trimmed.hasPrefix("import ") }
        while tailLines.first?.trimmed.isEmpty == true { tailLines.removeFirst() }
        while tailLines.last?.trimmed.isEmpty == true { tailLines.removeLast() }
        let tailText = tailLines.joined(separator: "\n")

        enum Scope {
            case top
            case structBody(name: String)
            /// Inside a struct's `public init` — opaque to the grammar (the compiler
            /// governs it on both sides). `opened` flips at the body's `{` (a wrapped
            /// signature reaches it late); `depth` counts braces until the block closes.
            case initBlock(structName: String, opened: Bool, depth: Int)
            case enumBody
        }
        var scope = Scope.top
        var pendingDoc: (line: Int, text: String)? = nil
        var fields: [SZFactField] = []
        var effectCases: [String] = []
        var sawEffectEnum = false
        var structNames: [String] = []
        var seenNames: Set<String> = []
        /// Struct-typed fields, validated once every declaration is known (a group may be
        /// declared below its first use — file order is prose order, not dependency order).
        var structTypedUses: [(line: Int, type: String)] = []

        for index in (begin + 1)..<end {
            let number = index + 1                      // 1-based, whole file
            let text = lines[index].trimmed
            if text.isEmpty {
                if let doc = pendingDoc { throw SZFactGenFailure.danglingDoc(line: doc.line) }
                continue
            }
            switch scope {
            case .top:
                if text.hasPrefix("///") { throw SZFactGenFailure.docOutsideStruct(line: number) }
                if let name = structOpen(text) {
                    guard seenNames.insert(name).inserted else {
                        throw SZFactGenFailure.duplicateDeclaration(line: number, name: name)
                    }
                    structNames.append(name)
                    scope = .structBody(name: name)
                } else if text == "public enum \(effectEnum): String, Codable, Sendable {" {
                    guard seenNames.insert(effectEnum).inserted else {
                        throw SZFactGenFailure.duplicateDeclaration(line: number, name: effectEnum)
                    }
                    sawEffectEnum = true
                    scope = .enumBody
                } else {
                    throw SZFactGenFailure.unclassifiableLine(line: number, text: text)
                }
            case .structBody(let owner):
                if text == "}" {
                    if let doc = pendingDoc { throw SZFactGenFailure.danglingDoc(line: doc.line) }
                    scope = .top
                } else if text.hasPrefix("///") {
                    if pendingDoc != nil { throw SZFactGenFailure.doubledDoc(line: number) }
                    guard text.hasPrefix("/// "), text.count > 4 else {
                        throw SZFactGenFailure.unclassifiableLine(line: number, text: text)
                    }
                    pendingDoc = (number, String(text.dropFirst(4)))
                } else if text.hasPrefix("public var ") {
                    let (name, type) = try varLine(text, line: number)
                    guard let doc = pendingDoc else {
                        throw SZFactGenFailure.varWithoutDoc(line: number, name: name)
                    }
                    pendingDoc = nil
                    if !allowedTypes.contains(type) {
                        structTypedUses.append((number, type))
                    }
                    fields.append(SZFactField(name: name, swiftType: type, owner: owner, doc: doc.text))
                } else if text.hasPrefix("public init(") {
                    if let doc = pendingDoc { throw SZFactGenFailure.danglingDoc(line: doc.line) }
                    // Opaque to the grammar: the block is ordinary Swift the compiler
                    // checks on both sides. Brace counting only — string literals with
                    // braces do not belong in a spec init body.
                    let opened = text.contains("{")
                    let depth = braceDelta(of: text)
                    scope = opened && depth <= 0
                        ? .structBody(name: owner)   // one-line init
                        : .initBlock(structName: owner, opened: opened, depth: depth)
                } else {
                    throw SZFactGenFailure.unclassifiableLine(line: number, text: text)
                }
            case .initBlock(let structName, let opened, let depth):
                let nowOpened = opened || text.contains("{")
                let newDepth = depth + braceDelta(of: text)
                scope = nowOpened && newDepth <= 0
                    ? .structBody(name: structName)
                    : .initBlock(structName: structName, opened: nowOpened, depth: newDepth)
            case .enumBody:
                if text == "}" {
                    guard !effectCases.isEmpty else {
                        throw SZFactGenFailure.emptyEffectEnum(line: number)
                    }
                    scope = .top
                } else if text.hasPrefix("case ") {
                    let caseName = String(text.dropFirst("case ".count))
                    guard isIdentifier(caseName) else {
                        throw SZFactGenFailure.malformedCase(line: number, text: text)
                    }
                    effectCases.append(caseName)
                } else {
                    throw SZFactGenFailure.unclassifiableLine(line: number, text: text)
                }
            }
        }
        switch scope {
        case .top: break
        case .structBody(let name), .initBlock(let name, _, _):
            throw SZFactGenFailure.unterminatedDeclaration(name: name)
        case .enumBody: throw SZFactGenFailure.unterminatedDeclaration(name: effectEnum)
        }
        _ = sawEffectEnum   // a spec without effects is legal; the enum is simply absent

        guard structNames.contains(rootStruct) else { throw SZFactGenFailure.missingRoot }
        // A struct-typed field must be an OPTIONAL of a declared struct — the typed-group
        // pattern: outside its moment (no run, no assignment) the group is nil, never zeroed.
        let declared = Set(structNames)
        for use in structTypedUses {
            guard use.type.hasSuffix("?"), declared.contains(String(use.type.dropLast())) else {
                throw SZFactGenFailure.unknownStructType(line: use.line, type: use.type)
            }
        }
        return SZFactSpec(regionText: regionText, tailText: tailText,
                          fields: fields, effectCases: effectCases)
    }

    // MARK: - Rendering

    /// The `SZStepKitGenerated.swift` source that compiles into SZRuntime: the verbatim
    /// spec region (sentinels included) as one string constant, ready for the step kit to
    /// splice into the source it hands every step build.
    public static func factsSectionSource(from source: String) throws -> String {
        let spec = try parse(source)
        let pounds = rawStringPounds(for: spec.regionText)
        let tailPounds = rawStringPounds(for: spec.tailText)
        return """
        // Generated by the SZFactGen build-tool plugin from SZFacts.swift. DO NOT EDIT.

        /// The verbatim spec region of SZFacts.swift (sentinel lines included). The step kit
        /// embeds this so a step compiles against the very source the host compiled, and the
        /// two sides decode the same wire shape.
        enum SZStepKitGenerated {
            static let factsSection: String = \(pounds)\"\"\"
        \(spec.regionText)
        \"\"\"\(pounds)

            /// The spec's derived-convenience extensions (below the end sentinel, minus
            /// imports), embedded so `hasWorkLeft`-style spellings are one source on both
            /// sides of the ABI.
            static let conveniences: String = \(tailPounds)\"\"\"
        \(spec.tailText)
        \"\"\"\(tailPounds)
        }

        """
    }

    /// The smallest `#` run that keeps a raw string literal safe around `text`: one more
    /// `#` than any run the text could confuse with the delimiter or an escape lead.
    static func rawStringPounds(for text: String) -> String {
        var count = 1
        while text.contains("\"\"\"" + String(repeating: "#", count: count))
            || text.contains("\\" + String(repeating: "#", count: count)) {
            count += 1
        }
        return String(repeating: "#", count: count)
    }

    // MARK: - Line-level helpers

    /// Matches `public struct SZ<Name>: Codable, Sendable {` and yields the type name.
    /// Pure prefix/suffix string ops.
    static func structOpen(_ text: String) -> String? {
        let prefix = "public struct SZ"
        let tail = ": Codable, Sendable {"
        guard text.hasPrefix(prefix), text.hasSuffix(tail) else { return nil }
        let name = String(text.dropFirst(prefix.count).dropLast(tail.count))
        guard isIdentifier(name), let first = name.first, first.isUppercase else { return nil }
        return "SZ\(name)"
    }

    /// Parses `public var name: Type`.
    static func varLine(_ text: String, line: Int) throws -> (name: String, type: String) {
        let body = String(text.dropFirst("public var ".count))
        guard let colon = body.range(of: ": ") else {
            throw SZFactGenFailure.malformedVar(line: line, text: text)
        }
        let name = String(body[..<colon.lowerBound])
        let type = String(body[colon.upperBound...])
        guard isIdentifier(name) else {
            throw SZFactGenFailure.malformedVar(line: line, text: text)
        }
        guard allowedTypes.contains(type)
            || (type.hasSuffix("?") && structOpenName(type)) else {
            throw SZFactGenFailure.unsupportedType(line: line, type: type)
        }
        return (name, type)
    }

    /// Whether `type` LOOKS like an optional spec-struct reference (`SZRun?`) — the
    /// declared-name check runs after parse, once every declaration is known.
    private static func structOpenName(_ type: String) -> Bool {
        let base = String(type.dropLast())
        return base.hasPrefix("SZ") && isIdentifier(base)
    }

    /// `{` count minus `}` count on one line — the init-block tracker's whole arithmetic.
    static func braceDelta(of text: String) -> Int {
        text.count(where: { $0 == "{" }) - text.count(where: { $0 == "}" })
    }

    static func isIdentifier(_ text: String) -> Bool {
        guard let first = text.first, first.isLetter || first == "_" else { return false }
        return text.dropFirst().allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespaces) }
}
