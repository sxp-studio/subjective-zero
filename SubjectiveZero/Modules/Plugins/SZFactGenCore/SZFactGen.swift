// SPDX-License-Identifier: AGPL-3.0-only
// The SZFactGen generator's core: parses the sentinel-marked spec region of SZFacts.swift
// (rigid grammar, plain string ops — no swift-syntax) and renders the two build-time
// artifacts. Pure functions of the input text — same input bytes, same output bytes, no
// timestamps — so the build stays deterministic and the tests can prove it. The tool
// target is a thin CLI over this library; the test target imports it directly.
import Foundation

/// One fact field as the spec declares it. `kind` names the facts struct the field lives
/// in ("build" for `SZBuildFacts`); `lazy` mirrors the trailing `// lazy` marker.
public struct SZFactField: Equatable, Sendable {
    public var name: String
    public var swiftType: String
    public var kind: String
    public var doc: String
    public var lazy: Bool

    public init(name: String, swiftType: String, kind: String, doc: String, lazy: Bool) {
        self.name = name
        self.swiftType = swiftType
        self.kind = kind
        self.doc = doc
        self.lazy = lazy
    }
}

/// One effect enum as the spec declares it: the kind it belongs to and its plain cases.
public struct SZEffectSet: Equatable, Sendable {
    public var kind: String
    public var cases: [String]

    public init(kind: String, cases: [String]) {
        self.kind = kind
        self.cases = cases
    }
}

/// Everything the parser extracts from one spec file.
public struct SZFactSpec: Equatable, Sendable {
    /// The verbatim spec region, sentinel lines included, no trailing newline.
    public var regionText: String
    /// The text BELOW the end sentinel — the spec's derived-convenience extensions
    /// (`hasWorkLeft`, …), verbatim minus any `import` lines, so the step SDK can embed
    /// them and share the exact spellings the app compiles. Ungoverned by the grammar:
    /// it is ordinary Swift, compile-checked on both sides.
    public var tailText: String
    public var fields: [SZFactField]
    public var effects: [SZEffectSet]
}

/// A grammar violation. Every case carries the 1-based line number in the WHOLE file, so
/// the tool can print `path:line: error: …` and the build fails loudly at the right spot.
public enum SZFactGenFailure: Error, Equatable, CustomStringConvertible {
    case missingSentinel(String)
    case unclassifiableLine(line: Int, text: String)
    case docOutsideStruct(line: Int)
    case danglingDoc(line: Int)
    case varWithoutDoc(line: Int, name: String)
    case doubledDoc(line: Int)
    case unsupportedType(line: Int, type: String)
    case malformedVar(line: Int, text: String)
    case malformedCase(line: Int, text: String)
    case unterminatedDeclaration(name: String)
    case emptyEffectEnum(line: Int, name: String)
    case effectWithoutFacts(line: Int, name: String)
    case duplicateDeclaration(line: Int, name: String)

    public var line: Int? {
        switch self {
        case .missingSentinel, .unterminatedDeclaration: return nil
        case .unclassifiableLine(let line, _), .docOutsideStruct(let line),
             .danglingDoc(let line), .varWithoutDoc(let line, _), .doubledDoc(let line),
             .unsupportedType(let line, _), .malformedVar(let line, _),
             .malformedCase(let line, _), .emptyEffectEnum(let line, _),
             .effectWithoutFacts(let line, _), .duplicateDeclaration(let line, _):
            return line
        }
    }

    public var description: String {
        switch self {
        case .missingSentinel(let sentinel):
            return "SZFactGen: spec sentinel '\(sentinel)' not found"
        case .unclassifiableLine(_, let text):
            return "SZFactGen: cannot classify this line inside the spec region: '\(text)'"
        case .docOutsideStruct:
            return "SZFactGen: doc lines are only legal immediately before a var inside a facts struct"
        case .danglingDoc:
            return "SZFactGen: doc line is not followed by a `public var` line"
        case .varWithoutDoc(_, let name):
            return "SZFactGen: var '\(name)' needs exactly one `///` doc line directly above it"
        case .doubledDoc:
            return "SZFactGen: a var takes exactly ONE doc line; fold these into one"
        case .unsupportedType(_, let type):
            return "SZFactGen: type '\(type)' is outside the rigid grammar (Int, Bool, String, String?, [String], [String: String])"
        case .malformedVar(_, let text):
            return "SZFactGen: malformed var line: '\(text)' (expected `public var name: Type` with an optional trailing `// lazy`)"
        case .malformedCase(_, let text):
            return "SZFactGen: malformed case line: '\(text)' (expected `case name` with no raw value or payload)"
        case .unterminatedDeclaration(let name):
            return "SZFactGen: '\(name)' never closes before the end sentinel"
        case .emptyEffectEnum(_, let name):
            return "SZFactGen: effect enum '\(name)' has no cases — omit the enum instead"
        case .effectWithoutFacts(_, let name):
            return "SZFactGen: effect enum '\(name)' has no matching facts struct"
        case .duplicateDeclaration(_, let name):
            return "SZFactGen: '\(name)' is declared twice in the spec region"
        }
    }
}

public enum SZFactGen {
    public static let beginSentinel = "// SZFactGen:begin"
    public static let endSentinel = "// SZFactGen:end"

    /// The closed set of field types the grammar accepts.
    public static let allowedTypes: Set<String> = [
        "Int", "Bool", "String", "String?", "[String]", "[String: String]"
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
        let regionText = lines[begin...end].joined(separator: "\n")
        var tailLines = Array(lines[(end + 1)...])
        tailLines.removeAll { $0.trimmed.hasPrefix("import ") }
        while tailLines.first?.trimmed.isEmpty == true { tailLines.removeFirst() }
        while tailLines.last?.trimmed.isEmpty == true { tailLines.removeLast() }
        let tailText = tailLines.joined(separator: "\n")

        enum Scope {
            case top
            case structBody(kind: String, name: String)
            case enumBody(kind: String, name: String)
        }
        var scope = Scope.top
        var pendingDoc: (line: Int, text: String)? = nil
        var fields: [SZFactField] = []
        var effects: [SZEffectSet] = []
        var currentCases: [String] = []
        var seenNames: Set<String> = []

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
                if let (kind, name) = declarationOpen(text, keyword: "struct", suffix: "Facts", inheritance: "Codable, Sendable") {
                    guard seenNames.insert(name).inserted else {
                        throw SZFactGenFailure.duplicateDeclaration(line: number, name: name)
                    }
                    scope = .structBody(kind: kind, name: name)
                } else if let (kind, name) = declarationOpen(text, keyword: "enum", suffix: "Effect", inheritance: "String, Codable, Sendable") {
                    guard seenNames.insert(name).inserted else {
                        throw SZFactGenFailure.duplicateDeclaration(line: number, name: name)
                    }
                    scope = .enumBody(kind: kind, name: name)
                    currentCases = []
                } else {
                    throw SZFactGenFailure.unclassifiableLine(line: number, text: text)
                }
            case .structBody(let kind, _):
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
                    let (name, type, isLazy) = try varLine(text, line: number)
                    guard let doc = pendingDoc else {
                        throw SZFactGenFailure.varWithoutDoc(line: number, name: name)
                    }
                    pendingDoc = nil
                    fields.append(SZFactField(name: name, swiftType: type, kind: kind, doc: doc.text, lazy: isLazy))
                } else {
                    throw SZFactGenFailure.unclassifiableLine(line: number, text: text)
                }
            case .enumBody(let kind, let name):
                if text == "}" {
                    guard !currentCases.isEmpty else {
                        throw SZFactGenFailure.emptyEffectEnum(line: number, name: name)
                    }
                    effects.append(SZEffectSet(kind: kind, cases: currentCases))
                    scope = .top
                } else if text.hasPrefix("case ") {
                    let caseName = String(text.dropFirst("case ".count))
                    guard isIdentifier(caseName) else {
                        throw SZFactGenFailure.malformedCase(line: number, text: text)
                    }
                    currentCases.append(caseName)
                } else {
                    throw SZFactGenFailure.unclassifiableLine(line: number, text: text)
                }
            }
        }
        switch scope {
        case .top: break
        case .structBody(_, let name), .enumBody(_, let name):
            throw SZFactGenFailure.unterminatedDeclaration(name: name)
        }

        // A kind may have no effect enum; an effect enum without a facts struct is a typo.
        let factKinds = Set(fields.map(\.kind))
        for effect in effects where !factKinds.contains(effect.kind) {
            throw SZFactGenFailure.effectWithoutFacts(line: end + 1, name: "SZ\(effect.kind.capitalizedFirst)Effect")
        }
        return SZFactSpec(regionText: regionText, tailText: tailText, fields: fields, effects: effects)
    }

    // MARK: - Rendering

    /// The `SZFactCatalog.generated.swift` source that compiles into SZCore.
    public static func catalogSource(from source: String) throws -> String {
        let spec = try parse(source)
        var out = """
        // Generated by the SZFactGen build-tool plugin from SZFacts.swift. DO NOT EDIT.
        // One record per fact field in the spec region, in spec order.

        /// One fact field as the spec declares it: `kind` names the facts struct the field
        /// lives in ("build" for SZBuildFacts); `lazy` mirrors the `// lazy` marker.
        public struct SZFactRecord: Equatable, Sendable {
            public let name: String
            public let swiftType: String
            public let kind: String
            public let doc: String
            public let lazy: Bool

            public init(name: String, swiftType: String, kind: String, doc: String, lazy: Bool) {
                self.name = name
                self.swiftType = swiftType
                self.kind = kind
                self.doc = doc
                self.lazy = lazy
            }
        }

        public enum SZFactCatalog {
            public static let all: [SZFactRecord] = [

        """
        for field in spec.fields {
            out += "        SZFactRecord(name: \(literal(field.name)), swiftType: \(literal(field.swiftType)), kind: \(literal(field.kind)), doc: \(literal(field.doc)), lazy: \(field.lazy)),\n"
        }
        out += """
            ]
        }

        /// Effect case names per kind, in spec order — what the traversal engine validates a
        /// step's requested effects against. A kind with no effect enum is absent.
        public enum SZEffectCatalog {
            public static let byKind: [String: [String]] = [

        """
        for effect in spec.effects {
            out += "        \(literal(effect.kind)): [\(effect.cases.map(literal).joined(separator: ", "))],\n"
        }
        if spec.effects.isEmpty { out += "        :\n" }   // the empty-dictionary spelling
        out += """
            ]

            /// The effect set for one kind name; empty for a kind that declares none.
            public static func cases(kind: String) -> [String] {
                byKind[kind] ?? []
            }
        }

        """
        return out
    }

    /// The `SZStepSDKGenerated.swift` source that compiles into SZRuntime: the verbatim
    /// spec region (sentinels included) as one string constant, ready for the step SDK to
    /// splice into the source it hands every step build.
    public static func factsSectionSource(from source: String) throws -> String {
        let spec = try parse(source)
        let pounds = rawStringPounds(for: spec.regionText)
        let tailPounds = rawStringPounds(for: spec.tailText)
        return """
        // Generated by the SZFactGen build-tool plugin from SZFacts.swift. DO NOT EDIT.

        /// The verbatim spec region of SZFacts.swift (sentinel lines included). The step SDK
        /// embeds this so a step compiles against the very source the host compiled, and the
        /// two sides decode the same wire shape.
        enum SZStepSDKGenerated {
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

    /// Matches `public <keyword> SZ<Kind><suffix>: <inheritance> {` and yields the
    /// lowercased kind plus the full type name. Pure prefix/suffix string ops.
    static func declarationOpen(_ text: String, keyword: String, suffix: String, inheritance: String) -> (kind: String, name: String)? {
        let prefix = "public \(keyword) SZ"
        let tail = "\(suffix): \(inheritance) {"
        guard text.hasPrefix(prefix), text.hasSuffix(tail) else { return nil }
        let kind = String(text.dropFirst(prefix.count).dropLast(tail.count))
        guard isIdentifier(kind), let first = kind.first, first.isUppercase else { return nil }
        return (kind.lowercased(), "SZ\(kind)\(suffix)")
    }

    /// Parses `public var name: Type` with an optional trailing ` // lazy`.
    static func varLine(_ text: String, line: Int) throws -> (name: String, type: String, lazy: Bool) {
        var body = String(text.dropFirst("public var ".count))
        var isLazy = false
        if body.hasSuffix(" // lazy") {
            isLazy = true
            body = String(body.dropLast(" // lazy".count))
        }
        guard let colon = body.range(of: ": ") else {
            throw SZFactGenFailure.malformedVar(line: line, text: text)
        }
        let name = String(body[..<colon.lowerBound])
        let type = String(body[colon.upperBound...])
        guard isIdentifier(name) else {
            throw SZFactGenFailure.malformedVar(line: line, text: text)
        }
        guard allowedTypes.contains(type) else {
            throw SZFactGenFailure.unsupportedType(line: line, type: type)
        }
        return (name, type, isLazy)
    }

    static func isIdentifier(_ text: String) -> Bool {
        guard let first = text.first, first.isLetter || first == "_" else { return false }
        return text.dropFirst().allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    /// A deterministic Swift string literal for `text` (escapes backslash, quote, and the
    /// control characters the grammar could ever let through).
    static func literal(_ text: String) -> String {
        var out = "\""
        for ch in text.unicodeScalars {
            switch ch {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            default: out.unicodeScalars.append(ch)
            }
        }
        return out + "\""
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespaces) }
    var capitalizedFirst: String {
        guard let first else { return self }
        return String(first).uppercased() + dropFirst()
    }
}
