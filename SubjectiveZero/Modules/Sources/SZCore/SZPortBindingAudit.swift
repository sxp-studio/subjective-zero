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

    // The runtime `ctx` accessors (SZRuntime/SZNode.swift), grouped by the port direction they name. The
    // port name is always the first string-literal argument. `floatArray` I/O rides `inputFloatArray` /
    // `setOutputFloats`.
    private static let inputAccessors  = ["inputTexture", "inputFloatArray", "inputFloats", "inputFloat", "inputString"]
    private static let outputAccessors = ["outputTexture", "setOutputFloats", "setOutputFloat"]

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

        var warnings: [String] = []
        for name in declaredInputs.subtracting(referencedInputs).sorted() {
            warnings.append("input \"\(name)\" is declared in node-contract.json but never read in Node.swift (dead control?).")
        }
        for name in declaredOutputs.subtracting(referencedOutputs).sorted() {
            warnings.append("output \"\(name)\" is declared in node-contract.json but never written in Node.swift.")
        }

        return Result(errors: errors, warnings: warnings)
    }

    /// Classify a built node's source against its contract, for `SZNode.rebuildReason`.
    ///
    /// ONLY `errors` (the code names a port the contract lacks) may be inferred from the files. The mirror
    /// case — a contract port the code never names — cannot: this is a string-literal scan, so a node that
    /// builds a port name at runtime trips it. `NodeLibrary/audio-bands` calls `ctx.setOutputFloat(kBandNames[b], …)`
    /// and would look permanently dirty. That case is knowable only at the moment the contract is edited, which
    /// is why `SZStore.editPorts` records `.contractChanged` there and nothing re-derives it later.
    ///
    /// Returns nil when the source satisfies the contract as far as a static scan can tell.
    public static func rebuildReason(contract: SZNodeContract, source: String) -> SZRebuildReason? {
        audit(contract: contract, source: source).errors.isEmpty ? nil : .sourceMismatch
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
