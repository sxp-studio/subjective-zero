// SPDX-License-Identifier: AGPL-3.0-only
// The agent-facing copy wrapped around the node library's catalog. Prose lives in a bundled
// markdown-mustache (Resources/Prompts/library/), never inline in a Swift string: the host assembles the
// catalog, SZAI says what it means, and the wording stays reviewable next to the other prompts.
import Foundation

public enum SZAgentLibraryText {
    /// The `agent_library_index` payload: the framing prose with the host's assembled `categories` block
    /// substituted in.
    public static func index(categories: String) -> String {
        SZPrompts.libraryIndex(categories: categories)
    }
}
