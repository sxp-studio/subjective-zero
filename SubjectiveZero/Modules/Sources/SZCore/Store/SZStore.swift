// SPDX-License-Identifier: AGPL-3.0-only
// The single source of truth (docs/ARCHITECTURE.md#the-host-seam). UI binds to it, the runtime reads
// from it, the host loads projects into it.
//
// Holds the loaded `SZProject`. TODO: the command/transaction/undo engine (docs/BUILD_SPEC.md) is not
// here yet — edits mutate the loaded project in place; it lands when undo/checkpoints ship.
import Observation

@MainActor
@Observable
public final class SZStore {
    public private(set) var project: SZProject?

    /// Chat transcripts keyed by `SZChatScope.key` (a node uuid, "director", or "debug"). Persisted
    /// per scope as .subz sidecars (SZChatTranscriptIO — the host flushes on message completion /
    /// run end / save / quit and restores on project open; `.debug` stays ephemeral); NOT part of
    /// project.json. Mutated through the SZStore+Chat ops; observed by the chat panel and the MCP
    /// surface. `internal(set)` so those same-module ops can write it.
    public internal(set) var chat: [String: [SZChatMessage]] = [:]

    /// The host-installed fence tripwire (SZHost+Fence.swift): returns a reason when a fenced-class
    /// mutation on these nodes should have been refused upstream, nil when it may proceed. The
    /// store stays lock-blind — ops assert this is nil (debug only, never a throw) so a future
    /// caller that bypasses the host funnels is caught in development instead of silently
    /// mutating a held node. nil closure (tests, no host) = no check.
    @ObservationIgnored public var fenceBackstop: ((Set<SZNodeID>) -> String?)?

    /// Debug-assert a fenced-class mutation was pre-cleared. Call sites are the destructive/content
    /// ops in SZStore+GraphEdits; move/add are open by design and never call this.
    func assertFenceCleared(_ ids: Set<SZNodeID>) {
        assert(fenceBackstop?(ids) == nil,
               "unfenced store mutation: \(fenceBackstop?(ids) ?? "") — route through the host funnel")
    }

    public init() {}

    /// Replace the loaded project (e.g. after `SZProjectIO.load`).
    public func setProject(_ project: SZProject?) {
        self.project = project
    }

    /// Apply a targeted in-place edit to the loaded project (no-op if none loaded). The graph-edit
    /// path: `ui_*`/`agent_*` tools and promote mutate through here.
    @discardableResult
    public func mutate(_ transform: (inout SZProject) -> Void) -> Bool {
        guard var project else { return false }
        transform(&project)
        self.project = project
        return true
    }
}
