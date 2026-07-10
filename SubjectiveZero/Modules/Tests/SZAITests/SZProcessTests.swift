// SPDX-License-Identifier: AGPL-3.0-only
// SZSystemProcessRunner substrate truths the app layer builds on:
//  - a signal death (killed/crashed CLI) is distinguishable from a plain non-zero exit
//    (`uncaughtSignal` — the mid-turn provider-death surface keys off it);
//  - stopping/timing out a run kills the CLI's whole descendant tree, not just the wrapper
//    (codex's Node wrapper spawns the vendor binary as a grandchild — killing only the direct
//    child would orphan the process actually talking to the model).
// Real /bin/sh processes, no stubs: the substrate IS the thing under test.
import Foundation
import Testing
@testable import SZAI

struct SZProcessTests {
    private let runner = SZSystemProcessRunner()

    @Test func normalExitCarriesNoSignal() async throws {
        let result = try await runner.run("/bin/sh", ["-c", "exit 3"])
        #expect(result.exitCode == 3)
        #expect(result.uncaughtSignal == nil)
        #expect(!result.timedOut)
    }

    @Test func signalDeathIsCaptured() async throws {
        let result = try await runner.run("/bin/sh", ["-c", "kill -9 $$"])
        #expect(result.uncaughtSignal == SIGKILL)
        #expect(!result.timedOut)
    }

    @Test func timeoutKillsWholeProcessTree() async throws {
        // The shell prints its background child's pid, then waits; the 1s timeout SIGKILLs the
        // tree. If only the shell died, the `sleep` grandchild would survive as an orphan — AND
        // hold the merged pipe open, so `run` itself would block until the sleep ends. Hence the
        // elapsed bound: without it, the child-dead poll below passes spuriously once a
        // surviving orphan runs out its clock. The sleep must comfortably exceed the bound —
        // any shorter and the orphan exits naturally in time for that same spurious pass.
        let started = ContinuousClock.now
        let result = try await runner.run(
            "/bin/sh", ["-c", "sleep 60 & echo CHILD:$!; wait"], timeout: 1)
        #expect(result.timedOut)
        #expect(ContinuousClock.now - started < .seconds(30), "run blocked on an orphan's pipe")
        let childPID = try #require(
            result.output.split(separator: "\n")
                .first(where: { $0.hasPrefix("CHILD:") })
                .flatMap { Int32($0.dropFirst("CHILD:".count)) })
        // SIGKILL delivery is asynchronous — poll briefly before declaring a leak.
        var alive = true
        for _ in 0..<50 where alive {
            alive = kill(childPID, 0) == 0
            if alive { try await Task.sleep(for: .milliseconds(20)) }
        }
        if alive { kill(childPID, SIGKILL) }   // don't leak the sleeper out of a failing test
        #expect(!alive, "descendant \(childPID) survived the tree kill")
    }

    @Test func normalExitDoesNotBlockOnAnOrphanHoldingThePipe() async throws {
        // The shell backgrounds a long sleeper that INHERITS the merged pipe, prints its pid, then exits
        // immediately (no `wait`). The sleeper is not a live child at any kill snapshot, so nothing kills
        // it and the pipe's write end stays open long past the shell's exit. `run` must still return
        // promptly (the bounded drain) with the output already buffered, rather than blocking until the
        // orphan finally exits — the regression guard for the wedged-run hang (isRunning stuck true).
        let started = ContinuousClock.now
        let result = try await runner.run("/bin/sh", ["-c", "sleep 20 & echo PID:$!"])
        let elapsed = ContinuousClock.now - started
        #expect(!result.timedOut)
        #expect(elapsed < .seconds(10), "run blocked on an orphan holding the pipe open (\(elapsed))")
        // Don't leak the sleeper past the test.
        if let pid = result.output.split(separator: "\n")
            .first(where: { $0.hasPrefix("PID:") })
            .flatMap({ Int32($0.dropFirst("PID:".count)) }) {
            kill(pid, SIGKILL)
        }
    }
}
