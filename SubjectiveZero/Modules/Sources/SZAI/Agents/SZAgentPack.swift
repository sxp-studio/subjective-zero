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
    /// The default VARIANT per kind (`agent.json`'s `defaults`): where several graphs handle
    /// one kind, this names the one a plain delivery opens. A single-graph kind needs no
    /// entry (the graph is its own default); the loader enforces that a multi-variant kind
    /// names exactly one of its graphs here.
    public var defaults: [SZMessageKind: String]
    /// The pack's graphs, sorted by name.
    public var graphs: [SZAgentGraph]
    /// Prompt inventory: pack-relative paths (`prompts/<file>.md.mustache`), sorted — the
    /// namespace a turn node's `brief` must resolve in.
    public var prompts: [String]
    /// Each prompt's template text, keyed by its pack-relative path — read alongside the
    /// inventory so validation can scan a brief's `{{tokens}}` without a second disk pass.
    public var promptSources: [String: String]
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

    public init(id: String, seat: SZAgentSeat? = nil, defaults: [SZMessageKind: String] = [:],
                graphs: [SZAgentGraph] = [],
                prompts: [String] = [], promptSources: [String: String] = [:],
                steps: [StepFolder] = []) {
        self.id = id
        self.seat = seat
        self.defaults = defaults
        self.graphs = graphs
        self.prompts = prompts
        self.promptSources = promptSources
        self.steps = steps
    }

    public func step(named name: String) -> StepFolder? {
        steps.first { $0.name == name }
    }

    /// Every graph handling `kind` — the kind's VARIANTS, in the pack's name order.
    public func variants(handling kind: SZMessageKind) -> [SZAgentGraph] {
        graphs.filter { $0.kind == kind }
    }

    /// The kind's DEFAULT graph: the one `defaults` names when it names one, else the kind's
    /// sole handler (a validated pack has a `defaults` entry wherever more than one exists).
    public func graph(handling kind: SZMessageKind) -> SZAgentGraph? {
        let variants = variants(handling: kind)
        if let named = defaults[kind], let match = variants.first(where: { $0.name == named }) {
            return match
        }
        return variants.first
    }

    /// A specific variant of `kind`, by graph name. nil = no such variant.
    public func graph(handling kind: SZMessageKind, variant name: String) -> SZAgentGraph? {
        variants(handling: kind).first { $0.name == name }
    }
}
