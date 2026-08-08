// SPDX-License-Identifier: AGPL-3.0-only
// One decoded agent pack — the in-memory shape of an agent FOLDER: `agent.json` (identity +
// seat) beside `graphs/*.json`, `prompts/*.md.mustache`, and `steps/<name>/Step.swift`. Pure
// data: everything here was read off disk by `SZAgentPackLoader`, which also owns every
// judgment about it (validation lives there, not here).
import Foundation
import SZCore

public struct SZAgentPack: Sendable, Equatable {
    /// The pack's id — by rule identical to its folder name (the loader refuses a mismatch).
    public var id: String
    /// The seat this pack claims, if any. Seat arithmetic (exactly one holder per seat over
    /// the loaded set) is the loader's, at the library level.
    public var seat: SZAgentSeat?
    /// The pack's graphs, sorted by name.
    public var graphs: [SZAgentGraph]
    /// Prompt inventory: pack-relative paths (`prompts/<file>.md.mustache`), sorted — the
    /// namespace a turn node's `brief` must resolve in.
    public var prompts: [String]
    /// Step-folder inventory: every directory under `steps/`, sorted by name.
    public var steps: [StepFolder]

    /// One `steps/<name>/` directory. A folder without a `Step.swift` is inventory, not a
    /// step — a graph node naming it is a defect the loader reports.
    public struct StepFolder: Sendable, Equatable {
        public var name: String
        /// Whether `steps/<name>/Step.swift` exists.
        public var hasSource: Bool
        public init(name: String, hasSource: Bool) {
            self.name = name
            self.hasSource = hasSource
        }
    }

    public init(id: String, seat: SZAgentSeat? = nil, graphs: [SZAgentGraph] = [],
                prompts: [String] = [], steps: [StepFolder] = []) {
        self.id = id
        self.seat = seat
        self.graphs = graphs
        self.prompts = prompts
        self.steps = steps
    }

    public func step(named name: String) -> StepFolder? {
        steps.first { $0.name == name }
    }

    public func graph(handling kind: SZMessageKind) -> SZAgentGraph? {
        graphs.first { $0.kind == kind }
    }
}
