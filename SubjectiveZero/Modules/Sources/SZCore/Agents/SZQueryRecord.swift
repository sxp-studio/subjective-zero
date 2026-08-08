// SPDX-License-Identifier: AGPL-3.0-only
// One journaled step query — every `askModel` exchange the query service runs leaves exactly
// one of these behind (attempt 0 and each repair retry separately), so a run's decisions are
// auditable after the fact without persisting whole prompts: the hash identifies the prompt
// bytes, the reply is the model's raw text.
import Foundation

/// One served step query, as the query service journals it.
public struct SZQueryRecord: Sendable, Equatable {
    /// The step whose evaluation asked.
    public var step: String
    /// The ask's 0-based attempt (0 = first ask, 1+ = repair retries).
    public var attempt: Int
    /// The template NAME the step asked for, as it asked (pack-relative resolution is the
    /// service's).
    public var template: String
    /// A stable digest of the rendered prompt bytes — identity without the payload.
    public var promptHash: String
    /// The raw reply text handed back to the step.
    public var reply: String

    public init(step: String, attempt: Int, template: String, promptHash: String, reply: String) {
        self.step = step
        self.attempt = attempt
        self.template = template
        self.promptHash = promptHash
        self.reply = reply
    }
}
