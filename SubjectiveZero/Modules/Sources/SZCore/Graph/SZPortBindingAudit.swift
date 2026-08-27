// SPDX-License-Identifier: AGPL-3.0-only
// A static cross-check that a node's `Node.swift` and its `node-contract.json` agree on port names: the
// contract declares the ports; the code must read/write exactly those. Catches the class of bug a
// schema-shape check misses — a declared control the code never reads (a dead knob — the "#knobs" bug), or
// a port the code reads/writes that was never declared (a typo / missing declaration).
//
// A pure text heuristic (no compilation): it scans the string-literal port name passed to each `ctx`
// accessor, so a name built by interpolation is invisible. Because a false "undeclared" would wrongly block
// a good node, only the unambiguous *referenced-but-undeclared* case is a hard error; a *declared-but-unused*
// port is a warning.
import Foundation

public enum SZPortBindingAudit {
    public struct Result: Equatable, Sendable {
        public var errors: [String]
        public var warnings: [String]
        public init(errors: [String], warnings: [String]) { self.errors = errors; self.warnings = warnings }
    }

    // The runtime `ctx` accessors (SZRuntime/Nodes/SZNodeKit.swift), grouped by the port direction they name. The
    // port name is always the first string-literal argument. `floatArray` I/O rides `inputFloatArray` /
    // `setOutputFloats`.
    private static let inputAccessors  = ["inputTexture", "inputFloatArray", "inputFloats", "inputFloat", "inputBool", "inputString"]
    private static let outputAccessors = ["outputTexture", "setOutputFloats", "setOutputFloat", "setOutputString"]

    /// Which runtime WIRE an accessor uses. `SZNodeKit` gives a node three per direction — the scalar
    /// value channel, the texture channel and the string channel — and every numeric accessor shares one
    /// of them (`inputFloat` is `inputFloats(port)?.first`, `inputBool` reads the same floats, and
    /// `inputFloatArray` differs only in how much it reads). So the accessor names the port's CHANNEL,
    /// never its exact type: a `bool` read with `inputFloat` is fine, a `texture` read with it is not.
    private enum Channel: String {
        case value, texture, string

        /// The channel a declared port is carried on, or nil for `event` — declared for the UI and never
        /// delivered to the node, so no accessor can legitimately name one.
        static func of(_ type: SZPortType) -> Channel? {
            switch type {
            case .float, .float2, .float3, .float4, .float3x3, .float4x4,
                 .colorRGB, .colorRGBA, .bool, .floatArray: return .value
            case .texture: return .texture
            case .enumeration, .string: return .string
            case .event: return nil
            }
        }

        /// How the message names what the code did, and what it should have called instead.
        var reading: String {
            switch self {
            case .value: return "a number"
            case .texture: return "a texture"
            case .string: return "a string"
            }
        }
        func accessor(_ direction: Direction) -> String {
            switch (self, direction) {
            case (.value, .input): return "ctx.inputFloat / ctx.inputFloats"
            case (.texture, .input): return "ctx.inputTexture"
            case (.string, .input): return "ctx.inputString"
            case (.value, .output): return "ctx.setOutputFloat / ctx.setOutputFloats"
            case (.texture, .output): return "ctx.outputTexture"
            case (.string, .output): return "ctx.setOutputString"
            }
        }
    }

    private enum Direction: String { case input, output }

    /// The accessors grouped by the channel they read or write — the type-side half of the audit.
    private static let accessorChannels: [Direction: [(Channel, [String])]] = [
        .input: [(.value, ["inputFloatArray", "inputFloats", "inputFloat", "inputBool"]),
                 (.texture, ["inputTexture"]),
                 (.string, ["inputString"])],
        .output: [(.value, ["setOutputFloats", "setOutputFloat"]),
                  (.texture, ["outputTexture"]),
                  (.string, ["setOutputString"])],
    ]

    /// Types that run on their OWN clock — they keep going when `update()` stops being called, so a graph
    /// that looks paused would still be playing audio or holding the mic. Constructing one without
    /// implementing `setPaused` is the "#knobs" bug's cousin: the control (Pause) is dead. A `ctx`
    /// accessor can't catch this, because the leak is in what the node OWNS, not what it reads.
    private static let liveResourceTypes = ["AVPlayer", "AVCaptureSession", "AVAudioEngine"]

    public static func audit(contract: SZNodeContract, source: String) -> Result {
        // Scan CODE only, not comments: an agent leaving a breadcrumb like `// TODO: ctx.inputFloat("x")`
        // for an undeclared port must not hard-block an otherwise-correct node.
        let scan = strippingComments(source)
        let referencedInputs  = portNames(in: scan, accessors: inputAccessors)
        let referencedOutputs = portNames(in: scan, accessors: outputAccessors)
        let declaredInputs  = Set(contract.inputs.map(\.name))
        let declaredOutputs = Set(contract.outputs.map(\.name))

        var errors: [String] = []
        for name in referencedInputs.subtracting(declaredInputs).sorted() {
            errors.append("Node.swift reads input port \"\(name)\" but node-contract.json declares no such input.")
        }
        for name in referencedOutputs.subtracting(declaredOutputs).sorted() {
            errors.append("Node.swift writes output port \"\(name)\" but node-contract.json declares no such output.")
        }
        // A port on the WRONG CHANNEL is the same fault one level down, and the name check above waves it
        // straight through: the port IS declared, so nothing is missing — the code just reads a different
        // wire than the one the port is carried on, gets nil every frame, and falls back to its hardcoded
        // default while the card still reads Ready. Unambiguous, so it blocks like the undeclared case.
        errors += channelErrors(contract: contract, scan: scan)

        // Unlike the declared-but-unread case, this one is unambiguous enough to block: the type names
        // are constructed right there in the source, and the fix is a single line the node needs anyway.
        // `func setPaused(`, not just "pause" — nodes call `player.pause()` / `engine.pause()` on their
        // own objects all the time, and matching those would wave the leak straight through.
        if !scan.contains("func setPaused(") {
            for type in liveResourceTypes where scan.contains("\(type)(") {
                errors.append("""
                    Node.swift creates an \(type), which keeps running when the graph's clock stops \
                    (a paused graph would still play audio / hold the device). Stop it in \
                    `func setPaused(_ paused: Bool)` — see node-abi.
                    """)
            }
        }

        var warnings: [String] = []
        for name in declaredInputs.subtracting(referencedInputs).sorted() {
            warnings.append("input \"\(name)\" is declared in node-contract.json but never read in Node.swift (dead control?).")
        }
        for name in declaredOutputs.subtracting(referencedOutputs).sorted() {
            warnings.append("output \"\(name)\" is declared in node-contract.json but never written in Node.swift.")
        }

        return Result(errors: errors, warnings: warnings)
    }

    /// What a promote would put live, plus the audit of `source` against it. The gate every promote passes:
    /// an authored (staged) contract merges into the node (`mergingAuthored(_:intoNode:)`); without one the
    /// LIVE contract is the truth the source must agree with — so a source-only re-stage can never skip the
    /// port audit.
    public struct PromoteAudit: Equatable, Sendable {
        /// The contract the promote must WRITE: the authored one folded into the node. nil when the agent
        /// staged none — the node's live contract (and its identity) then stand untouched.
        public var contract: SZNodeContract?
        public var result: Result
        /// Boundary-merge notes (`SZBoundaryMergeResult.conflicts`), for the agent as warnings.
        public var mergeConflicts: [String]
    }

    /// The merge runs HERE and only here, so what the gate audits is what the promote lands.
    public static func auditForPromote(source: String, authored: SZNodeContract?, node: SZNode) -> PromoteAudit {
        var conflicts: [String] = []
        var merged: SZNodeContract?
        if let authored {
            let merge = SZNodeContract.mergingAuthored(authored, intoNode: node)
            merged = merge.contract
            conflicts = merge.conflicts
        }
        // Nothing to audit against only when the node has neither an authored nor a live contract.
        let audited = merged ?? node.contract
        let result = audited.map { audit(contract: $0, source: source) } ?? Result(errors: [], warnings: [])
        return PromoteAudit(contract: merged, result: result, mergeConflicts: conflicts)
    }

    /// Blank out `/* … */` and `// …` comments so the scan sees code only. A heuristic: a `//` or `/*`
    /// *inside* a string literal could over-strip, but that only risks a MISSED reference (a lost warning
    /// or an undetected mismatch) — never a false hard error, which is the failure mode we must avoid.
    private static func strippingComments(_ source: String) -> String {
        var s = source
        let passes: [(String, NSRegularExpression.Options)] = [
            (#"/\*.*?\*/"#, .dotMatchesLineSeparators),   // block comments (across lines)
            (#"//[^\n]*"#, []),                            // line comments (to end of line)
        ]
        for (pattern, options) in passes {
            guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { continue }
            s = re.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: "")
        }
        return s
    }

    /// Ports whose declared type is not on the channel the code's accessor uses. Only ports the contract
    /// actually declares: an undeclared name is already the harder error above, and reporting both would
    /// say the same thing twice.
    private static func channelErrors(contract: SZNodeContract, scan: String) -> [String] {
        var errors: [String] = []
        for direction in [Direction.input, .output] {
            let declared = direction == .input ? contract.inputs : contract.outputs
            for (channel, accessors) in accessorChannels[direction] ?? [] {
                for name in portNames(in: scan, accessors: accessors).sorted() {
                    guard let port = declared.first(where: { $0.name == name }) else { continue }
                    guard Channel.of(port.type) != channel else { continue }
                    let verb = direction == .input ? "reads" : "writes"
                    let fix = Channel.of(port.type).map { "Use \($0.accessor(direction))" }
                        ?? "An `event` port is never delivered to the node"
                    errors.append("""
                        Node.swift \(verb) \(direction.rawValue) port "\(name)" as \(channel.reading), but \
                        node-contract.json declares it \(port.type.rawValue) — a different channel, so that \
                        \(verb == "reads" ? "read" : "write") never reaches the port. \(fix), or declare the \
                        port on the type the code uses — see node-abi.
                        """)
                }
            }
        }
        return errors
    }

    /// Port names passed as the first string-literal argument to any of the given `ctx` accessors. The
    /// trailing `(` anchor lets an accessor match only its exact name (e.g. `inputFloat` won't match
    /// `inputFloats(` / `inputFloatArray(`).
    private static func portNames(in source: String, accessors: [String]) -> Set<String> {
        var names: Set<String> = []
        let ns = source as NSString
        for accessor in accessors {
            let pattern = #"\."# + NSRegularExpression.escapedPattern(for: accessor) + #"\s*\(\s*"([^"\\]+)""#
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            for m in re.matches(in: source, range: NSRange(location: 0, length: ns.length)) {
                names.insert(ns.substring(with: m.range(at: 1)))
            }
        }
        return names
    }
}
