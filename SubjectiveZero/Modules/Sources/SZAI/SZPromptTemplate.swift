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
}
