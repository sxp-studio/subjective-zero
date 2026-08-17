// SPDX-License-Identifier: AGPL-3.0-only
// `SZRunNodeVerdict.classify` — the run-end decision table, row by row, plus the phase × promoted sweep:
// success is promote evidence + derived state, an agent's own report always wins, and only a silent,
// unpromoted node gets the generic failure.
import Testing
@testable import SZCore

@Suite struct SZRunNodeVerdictTests {
    private typealias V = SZRunNodeVerdict
    private static let allPhases: [SZNodeAgentPhase] = [.idle, .queued, .planning, .coding, .ok, .needsInput, .reloading, .error]
    private static let quietPhases: [SZNodeAgentPhase] = allPhases.filter { $0 != .error && $0 != .needsInput }
    private static let reportedPhases: [SZNodeAgentPhase] = [.error, .needsInput]

    // MARK: Rows

    @Test func promotedAndCleanIsImplementedUnlessTheAgentReported() {
        for phase in Self.quietPhases {
            #expect(V.classify(promoted: true, stillDirty: false, derivedReason: nil, phase: phase) == .implemented)
        }
        // A promote wipes a stale report, so one left standing on a clean node is the agent's verdict on
        // its OWN build ("compiled, but it renders black") — it outranks the clean stamp.
        for phase in Self.reportedPhases {
            #expect(V.classify(promoted: true, stillDirty: false, derivedReason: nil, phase: phase) == .failedAsReported)
        }
    }

    /// Clean now = nothing left to do, even without a promote (an edit that was reverted heals by construction) —
    /// unless the agent said otherwise.
    @Test func cleanWithoutPromoteIsImplementedUnlessTheAgentReported() {
        for phase in Self.quietPhases {
            #expect(V.classify(promoted: false, stillDirty: false, derivedReason: nil, phase: phase) == .implemented)
        }
        for phase in Self.reportedPhases {
            #expect(V.classify(promoted: false, stillDirty: false, derivedReason: nil, phase: phase) == .failedAsReported)
        }
    }

    @Test func promotedThenRebriefedIsImplementedUnlessTheAgentReported() {
        for phase in Self.quietPhases {
            #expect(V.classify(promoted: true, stillDirty: true, derivedReason: .intentChanged, phase: phase)
                    == .implementedButRebriefed)
        }
        for phase in Self.reportedPhases {
            #expect(V.classify(promoted: true, stillDirty: true, derivedReason: .intentChanged, phase: phase)
                    == .failedAsReported)
        }
    }

    @Test func promotedThenContractMovedIsImplementedUnlessTheAgentReported() {
        for phase in Self.quietPhases {
            #expect(V.classify(promoted: true, stillDirty: true, derivedReason: .contractChanged, phase: phase)
                    == .implementedButContractMoved)
        }
        for phase in Self.reportedPhases {
            #expect(V.classify(promoted: true, stillDirty: true, derivedReason: .contractChanged, phase: phase)
                    == .failedAsReported)
        }
    }

    /// The audit fault is a real defect in what was promoted: failed, whatever the agent said.
    @Test func promotedWithAuditErrorsFails() {
        for phase in Self.allPhases {
            #expect(V.classify(promoted: true, stillDirty: true, derivedReason: .sourceMismatch, phase: phase)
                    == .failedSourceMismatch)
        }
    }

    @Test func aReportedProblemWinsWhenNotPromoted() {
        for phase in Self.reportedPhases {
            for reason in [nil, SZRebuildReason.intentChanged, .contractChanged, .sourceMismatch] {
                #expect(V.classify(promoted: false, stillDirty: true, derivedReason: reason, phase: phase)
                        == .failedAsReported)
            }
        }
    }

    @Test func silentUnpromotedDirtyNodeFailsGenerically() {
        for phase in Self.quietPhases {
            // A `.prompt` node (no reason) and a stale built one (any stamp reason) alike.
            for reason in [nil, SZRebuildReason.intentChanged, .contractChanged, .sourceMismatch] {
                #expect(V.classify(promoted: false, stillDirty: true, derivedReason: reason, phase: phase)
                        == .failedSilently)
            }
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
