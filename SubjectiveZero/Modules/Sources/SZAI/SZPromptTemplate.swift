// SPDX-License-Identifier: AGPL-3.0-only
// Tiny {{TOKEN}} substituter for agent prompts — a deliberate non-dependency: our prompts only need
// flat token replacement, so a 3-line function beats pulling in a templating lib.
import Foundation

enum SZPromptTemplate {
    /// Replace every `{{key}}` in `template` with its value. Unlisted tokens are left as-is.
    static func render(_ template: String, _ values: [String: String]) -> String {
        var out = template
        for (key, value) in values {
            out = out.replacingOccurrences(of: "{{\(key)}}", with: value)
        }
        return out
    }

    /// Every `{{token}}` mentioned in `template`, deduplicated, in order of first mention.
    /// The dialect is flat — no sections, no inline includes — so whatever sits between the
    /// braces IS the token name `render` would substitute; the pack gate scans briefs with
    /// this so it judges exactly the spellings `render` acts on. Nesting braces and newlines
    /// never appear in a token (`defused` output cannot match: `{ {` breaks the opener).
    static func tokens(in template: String) -> [String] {
        var found: [String] = []
        var seen: Set<String> = []
        var rest = Substring(template)
        while let open = rest.range(of: "{{") {
            rest = rest[open.upperBound...]
            guard let close = rest.range(of: "}}") else { break }
            let name = rest[..<close.lowerBound]
            rest = rest[close.upperBound...]
            guard !name.isEmpty, !name.contains(where: { "{}".contains($0) || $0.isNewline }),
                  seen.insert(String(name)).inserted else { continue }
            found.append(String(name))
        }
        return found
    }

    /// Defuse `{{` in a NON-LITERAL value (user prose, fetched docs, assembled indexes) before it
    /// enters `render`: the loop above walks an unordered dictionary, so a live token inside a
    /// substituted value would be expanded — or left literal — depending on the process's hash
    /// seed, rendering two different prompts on two runs. Template-authored values skip this;
    /// everything else goes through it.
    static func defused(_ value: String) -> String {
        value.replacingOccurrences(of: "{{", with: "{ {")
    }
}
