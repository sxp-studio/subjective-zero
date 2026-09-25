// SPDX-License-Identifier: AGPL-3.0-only
// A declared decision: an ask that names its possible answers up front, in a
// `prompts/<template>.decision.json` beside the ask's template. With a decider attached, the query
// service answers such an ask from the declaration instead of a free-text completion, and
// falls back to the completion whenever the decider can't. Vendor-neutral: which service
// decides lives with the decider, never here.
import Foundation

public struct SZDeclaredDecision: Decodable, Sendable, Equatable {
    /// The reply's field name: the step decodes `{"<key>": "<answer>"}`.
    public var key: String
    /// The template that renders the facts the decision reads (message, work in hand).
    public var state: String
    public var instructions: String
    /// Pick one: answer → what it means. Exactly one of `choices` / `levels` is set.
    public var choices: [String: String]?
    /// Rate on an ordered scale, lowest first; the answer is the level's name.
    public var levels: [String]?

    public init(key: String, state: String, instructions: String,
                choices: [String: String]? = nil, levels: [String]? = nil) {
        self.key = key
        self.state = state
        self.instructions = instructions
        self.choices = choices
        self.levels = levels
    }

    /// The declaration path for an ask template stem.
    public static func path(for template: String) -> String {
        "prompts/\(template).decision.json"
    }
}

/// A decider's answer, with what it cost.
public struct SZDecisionAnswer: Sendable, Equatable {
    public var value: String
    public var confidence: Double?
    public var deciderID: String
    public var inputTokens: Int?
    public var latency: TimeInterval

    public init(value: String, confidence: Double? = nil, deciderID: String,
                inputTokens: Int? = nil, latency: TimeInterval) {
        self.value = value
        self.confidence = confidence
        self.deciderID = deciderID
        self.inputTokens = inputTokens
        self.latency = latency
    }
}

/// Answers a declared decision over its rendered state. Throwing hands the ask back to the
/// routed completion.
public typealias SZQueryDecider = @Sendable (_ decision: SZDeclaredDecision, _ state: String) async throws -> SZDecisionAnswer
