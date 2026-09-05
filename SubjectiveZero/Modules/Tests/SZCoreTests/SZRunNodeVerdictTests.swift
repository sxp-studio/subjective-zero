// SPDX-License-Identifier: AGPL-3.0-only
// `SZRunNodeVerdict.classify` — the run-end decision table, row by row, plus the phase × promoted sweep:
// success is promote evidence + derived state, only the node's OWN agent can report a problem that
// outranks a build, and only a silent, unpromoted node gets the generic failure.
import Testing
@testable import SZCore

@Suite struct SZRunNodeVerdictTests {
    private typealias V = SZRunNodeVerdict
    private static let allPhases: [SZNodeAgentPhase] = [.idle, .queued, .planning, .coding, .ok, .needsInput, .reloading, .error]
    private static let quietPhases: [SZNodeAgentPhase] = allPhases.filter { $0 != .error && $0 != .needsInput }
    private static let reportedPhases: [SZNodeAgentPhase] = [.error, .needsInput]
    private static let surface: Set<SZNodeContract.PortSignature> =
        [.init(direction: .input, name: "input", type: .texture)]
    private static let contract = SZNodeContract(
        title: "N", sfSymbol: "circle", summary: "",
        inputs: [SZPort(name: "input", type: .texture)], outputs: [])

    /// A built node in each of the derived states: clean, or dirty for one of the three reasons.
    private static func node(_ reason: SZRebuildReason?) -> SZNode {
        SZNode(kind: .generated, title: "Built", prompt: "p", contract: contract, position: SZPoint(x: 0, y: 0),
               buildStamp: SZBuildStamp(portSurface: reason == .contractChanged ? [] : surface,
                                        prompt: reason == .intentChanged ? "older" : "p"),
               sourceMismatch: reason == .sourceMismatch)
    }
    /// A never-built node: dirty with no rebuild reason (`kind == .prompt`).
    private static func draft() -> SZNode { SZNode(kind: .prompt, title: "Draft", prompt: "p", position: SZPoint(x: 0, y: 0)) }

    /// The state an AGENT left behind (`agent_report_status`) vs the one the HOST wrote on its behalf.
    private static func reported(_ phase: SZNodeAgentPhase) -> SZNodeAgentState {
        SZNodeAgentState(phase: phase, message: "m", reportedByAgent: true)
    }
    private static func hostWritten(_ phase: SZNodeAgentPhase) -> SZNodeAgentState {
        SZNodeAgentState(phase: phase, message: "m", reportedByAgent: false)
    }

    // MARK: The derived states

    @Test func promotedAndCleanIsImplementedUnlessTheAgentReported() {
        for phase in Self.quietPhases {
            #expect(V.classify(node: Self.node(nil), promoted: true, state: Self.reported(phase)) == .implemented)
        }
        // A promote wipes a stale report, so an AGENT report still standing on a clean node is its
        // verdict on its OWN build ("it compiles, but it renders black") — it outranks the clean stamp.
        for phase in Self.reportedPhases {
            #expect(V.classify(node: Self.node(nil), promoted: true, state: Self.reported(phase)) == .failedAsReported)
        }
    }

    /// Clean now = nothing left to do, even without a promote (an edit that was reverted heals by
    /// construction) — unless the agent said otherwise.
    @Test func cleanWithoutPromoteIsImplementedUnlessTheAgentReported() {
        for phase in Self.quietPhases {
            #expect(V.classify(node: Self.node(nil), promoted: false, state: Self.reported(phase)) == .implemented)
        }
        for phase in Self.reportedPhases {
            #expect(V.classify(node: Self.node(nil), promoted: false, state: Self.reported(phase)) == .failedAsReported)
        }
    }

    @Test func promotedThenRebriefedIsImplementedUnlessTheAgentReported() {
        for phase in Self.quietPhases {
            #expect(V.classify(node: Self.node(.intentChanged), promoted: true, state: Self.reported(phase))
                    == .implementedButRebriefed)
        }
        for phase in Self.reportedPhases {
            #expect(V.classify(node: Self.node(.intentChanged), promoted: true, state: Self.reported(phase))
                    == .failedAsReported)
        }
    }

    @Test func promotedThenContractMovedIsImplementedUnlessTheAgentReported() {
        for phase in Self.quietPhases {
            #expect(V.classify(node: Self.node(.contractChanged), promoted: true, state: Self.reported(phase))
                    == .implementedButContractMoved)
        }
        for phase in Self.reportedPhases {
            #expect(V.classify(node: Self.node(.contractChanged), promoted: true, state: Self.reported(phase))
                    == .failedAsReported)
        }
    }

    /// The audit fault is a real defect in what was promoted: failed, whatever anyone said.
    @Test func promotedWithAuditErrorsFails() {
        for phase in Self.allPhases {
            #expect(V.classify(node: Self.node(.sourceMismatch), promoted: true, state: Self.reported(phase))
                    == .failedSourceMismatch)
            #expect(V.classify(node: Self.node(.sourceMismatch), promoted: true, state: Self.hostWritten(phase))
                    == .failedSourceMismatch)
        }
    }

    /// A node promotes green, then its shader fails at first frame: the fault fails the build. The
    /// caller passes a fault only for a build this run made (`everPromoted`), so `promoted` here is
    /// the per-dispatch flag and does not gate it.
    @Test func aPromotedNodeReportingARuntimeFaultFails() {
        for phase in Self.quietPhases {
            #expect(V.classify(node: Self.node(nil), promoted: true, state: Self.reported(phase),
                               runtimeFault: "half is a reserved type") == .failedRuntimeFault)
            #expect(V.classify(node: Self.node(nil), promoted: false, state: Self.reported(phase),
                               runtimeFault: "half is a reserved type") == .failedRuntimeFault)
            #expect(V.classify(node: Self.node(nil), promoted: false, state: Self.reported(phase),
                               runtimeFault: nil) == .implemented)
        }
        #expect(V.classify(node: Self.node(nil), promoted: true, state: nil, runtimeFault: "x") == .failedRuntimeFault)
        #expect(!V.failedRuntimeFault.isImplemented)
        // The agent's own report and the audit still outrank it: their words are more specific.
        #expect(V.classify(node: Self.node(nil), promoted: true, state: Self.reported(.error), runtimeFault: "x")
                == .failedAsReported)
        #expect(V.classify(node: Self.node(.sourceMismatch), promoted: true, state: nil, runtimeFault: "x")
                == .failedSourceMismatch)
    }

    @Test func aReportedProblemWinsWhenNotPromoted() {
        for phase in Self.reportedPhases {
            #expect(V.classify(node: Self.draft(), promoted: false, state: Self.reported(phase)) == .failedAsReported)
            for reason in [SZRebuildReason.intentChanged, .contractChanged, .sourceMismatch] {
                #expect(V.classify(node: Self.node(reason), promoted: false, state: Self.reported(phase))
                        == .failedAsReported)
            }
        }
    }

    @Test func silentUnpromotedDirtyNodeFailsGenerically() {
        for phase in Self.quietPhases {
            // A `.prompt` node (no reason) and a stale built one (any stamp reason) alike.
            #expect(V.classify(node: Self.draft(), promoted: false, state: Self.reported(phase)) == .failedSilently)
            for reason in [SZRebuildReason.intentChanged, .contractChanged, .sourceMismatch] {
                #expect(V.classify(node: Self.node(reason), promoted: false, state: Self.reported(phase))
                        == .failedSilently)
            }
        }
        // No state at all is the same story.
        #expect(V.classify(node: Self.draft(), promoted: false, state: nil) == .failedSilently)
    }

    // MARK: Who wrote the phase

    /// The incident this table exists for: a node promotes green at minute 3, its agent keeps polishing,
    /// the turn's budget runs out, and the HOST writes the timeout onto the node. The build is still
    /// there — a run must not report it failed.
    @Test func aHostWrittenFailureNeverOverrulesAGreenBuild() {
        for phase in Self.reportedPhases {
            #expect(V.classify(node: Self.node(nil), promoted: true, state: Self.hostWritten(phase)) == .implemented)
            #expect(V.classify(node: Self.node(nil), promoted: false, state: Self.hostWritten(phase)) == .implemented)
            // Built, then moved: the promote still stands, and the node is narrated as needing a pass.
            #expect(V.classify(node: Self.node(.intentChanged), promoted: true, state: Self.hostWritten(phase))
                    == .implementedButRebriefed)
            #expect(V.classify(node: Self.node(.contractChanged), promoted: true, state: Self.hostWritten(phase))
                    == .implementedButContractMoved)
        }
    }

    /// On a node with nothing built, the same host line is a failure — the run just has better words
    /// for it than "never compiled".
    @Test func aHostWrittenFailureOnADirtyUnpromotedNodeStillFails() {
        for phase in Self.reportedPhases {
            #expect(V.classify(node: Self.draft(), promoted: false, state: Self.hostWritten(phase)) == .failedSilently)
            #expect(V.classify(node: Self.node(.intentChanged), promoted: false, state: Self.hostWritten(phase))
                    == .failedSilently)
        }
    }

    /// Authorship only matters for the two report phases: an agent's `.ok` is not a verdict either way.
    @Test func authorshipOnlyMattersForAReportedProblem() {
        for phase in Self.quietPhases {
            #expect(V.classify(node: Self.draft(), promoted: false, state: Self.reported(phase))
                    == V.classify(node: Self.draft(), promoted: false, state: Self.hostWritten(phase)))
            #expect(V.classify(node: Self.node(nil), promoted: true, state: Self.reported(phase))
                    == V.classify(node: Self.node(nil), promoted: true, state: Self.hostWritten(phase)))
        }
    }

    // MARK: Summary counting

    @Test func implementedVerdictsCountAsImplemented() {
        #expect(V.implemented.isImplemented)
        #expect(V.implementedButRebriefed.isImplemented)
        #expect(V.implementedButContractMoved.isImplemented)
        #expect(!V.failedSourceMismatch.isImplemented)
        #expect(!V.failedAsReported.isImplemented)
        #expect(!V.failedSilently.isImplemented)
    }
}
