// SPDX-License-Identifier: AGPL-3.0-only
// Jev, TypeSafe's hosted decision model (docs.typesafe.ai): a short state plus typed questions in,
// typed answers out, billed per input token. Experimental, turned on from Settings ▸
// Experimental. This file is everything Jev-specific: the wire shapes, the error statuses,
// and the decider that answers a pack's declared decisions.
import Foundation

public enum SZJevError: Error, Equatable, CustomStringConvertible {
    case keyRejected                    // 401
    case noBalance                      // 402
    case rateLimited                    // 429, or 529 overloaded
    case http(status: Int, body: String)
    case unreadable(String)
    /// The reply carried no answer for the question asked.
    case noAnswer(String)

    public var description: String {
        switch self {
        case .keyRejected: "Jev did not recognize the key"
        case .noBalance: "the Jev balance is empty"
        case .rateLimited: "Jev is busy or rate limiting this key"
        case .http(let status, let body): "Jev answered HTTP \(status): \(body.prefix(300))"
        case .unreadable(let detail): "unreadable Jev reply: \(detail)"
        case .noAnswer(let name): "Jev returned no answer for '\(name)'"
        }
    }
}

public struct SZJevClient: Sendable {
    public static let endpoint = URL(string: "https://api.typesafe.ai/v1/systemone")!
    public static let model = "jev-latest"

    public struct Answer: Decodable, Sendable, Equatable {
        public var choice: String?
        public var score: Double?
        public var noul: Double?
        public var confidence: Double?
    }

    public struct Reply: Sendable, Equatable {
        public var answers: [String: Answer]
        public var inputTokens: Int?
        public var latency: TimeInterval
    }

    public var key: String
    public var session: URLSession
    public var timeout: TimeInterval

    public init(key: String, session: URLSession = .shared, timeout: TimeInterval = 10) {
        self.key = key
        self.session = session
        self.timeout = timeout
    }

    /// One Jev question on the wire.
    public struct Question: Encodable, Sendable, Equatable {
        public enum Kind: String, Encodable, Sendable { case choice, score, noul }
        public enum Criteria: Encodable, Sendable, Equatable {
            case options([String: String])
            case levels([String])

            public func encode(to encoder: Encoder) throws {
                var container = encoder.singleValueContainer()
                switch self {
                case .options(let map): try container.encode(map)
                case .levels(let list): try container.encode(list)
                }
            }
        }

        public var type: Kind
        public var instructions: String
        public var criteria: Criteria?

        public init(type: Kind, instructions: String, criteria: Criteria? = nil) {
            self.type = type
            self.instructions = instructions
            self.criteria = criteria
        }

        /// A declared decision in Jev's terms: choices become a `choice`, levels a `score`.
        public init(_ decision: SZDeclaredDecision) {
            if let levels = decision.levels {
                self.init(type: .score, instructions: decision.instructions, criteria: .levels(levels))
            } else {
                self.init(type: .choice, instructions: decision.instructions,
                          criteria: .options(decision.choices ?? [:]))
            }
        }
    }

    /// One `decide` call over name → question.
    public func decide(state: String, questions: [String: Question]) async throws -> Reply {
        var request = URLRequest(url: Self.endpoint, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        request.httpBody = try encoder.encode(Body(state: state, model: Self.model, questions: questions))

        let start = Date()
        let (data, response) = try await session.data(for: request)
        let latency = Date().timeIntervalSince(start)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200..<300: break
        case 401: throw SZJevError.keyRejected
        case 402: throw SZJevError.noBalance
        case 429, 529: throw SZJevError.rateLimited
        default: throw SZJevError.http(status: status, body: String(decoding: data, as: UTF8.self))
        }
        do {
            let decoded = try JSONDecoder().decode(Wire.self, from: data)
            return Reply(answers: decoded.answers, inputTokens: decoded.usage?.input_tokens, latency: latency)
        } catch {
            throw SZJevError.unreadable(String(describing: error))
        }
    }

    /// The Settings key check: Jev has no key or balance endpoint, so this is one tiny real
    /// call (a few input tokens).
    public func verify() async throws {
        _ = try await decide(state: "SubZ settings key check.",
                             questions: ["ok": Question(type: .noul, instructions: "Is this a key check?")])
    }

    /// A decider over this client: answers a declared decision with one call.
    public func decider() -> SZQueryDecider {
        { decision, state in
            let reply = try await decide(state: state, questions: [decision.key: Question(decision)])
            guard let answer = reply.answers[decision.key] else { throw SZJevError.noAnswer(decision.key) }
            return SZDecisionAnswer(value: try Self.value(of: answer, for: decision),
                                    confidence: answer.confidence, deciderID: "jev",
                                    inputTokens: reply.inputTokens, latency: reply.latency)
        }
    }

    /// The declared answer name: a choice as given, a score rounded to its level.
    static func value(of answer: Answer, for decision: SZDeclaredDecision) throws -> String {
        if let levels = decision.levels {
            guard let score = answer.score, !levels.isEmpty else { throw SZJevError.noAnswer(decision.key) }
            let index = min(max(Int(score.rounded()), 0), levels.count - 1)
            return levels[index]
        }
        guard let choice = answer.choice, decision.choices?[choice] != nil else {
            throw SZJevError.noAnswer(decision.key)
        }
        return choice
    }

    private struct Body: Encodable {
        var state: String
        var model: String
        var questions: [String: Question]
    }

    private struct Wire: Decodable {
        struct Usage: Decodable { var input_tokens: Int? }
        var answers: [String: Answer]
        var usage: Usage?
    }
}
