// SPDX-License-Identifier: AGPL-3.0-only
// One agent turn's working trace, split into the steps it took.
//
// The host writes the trace as one string: reasoning as it arrives, a tool call as its own
// "→ name" line (SZHost+AgentStreaming). As a paragraph it is a wall; as steps it is a list of
// what the agent did. Pure, so the rule is testable without a view.
import Foundation

struct SZAgentActivityStep: Identifiable, Equatable {
    enum Kind: Equatable { case tool, thought }

    let id: Int
    let kind: Kind
    let text: String

    /// Split a trace into steps: each "→ name" line is a tool step, and the prose between them
    /// gathers into one thought step apiece. Blank runs collapse — the stream pads with newlines.
    static func steps(thinking: String) -> [SZAgentActivityStep] {
        var steps: [SZAgentActivityStep] = []
        var pending: [String] = []

        func flushThought() {
            let text = pending.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            pending.removeAll()
            guard !text.isEmpty else { return }
            steps.append(SZAgentActivityStep(id: steps.count, kind: .thought, text: text))
        }

        for line in thinking.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let name = trimmed.strippingToolArrow {
                flushThought()
                steps.append(SZAgentActivityStep(id: steps.count, kind: .tool, text: name))
            } else {
                pending.append(String(line))
            }
        }
        flushThought()
        return steps
    }
}

private extension String {
    /// The "→ name" a tool sighting is written as; nil for anything else.
    var strippingToolArrow: String? {
        guard hasPrefix("→") else { return nil }
        let name = dropFirst().trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }
}
