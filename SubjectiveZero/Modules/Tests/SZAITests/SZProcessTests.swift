// SPDX-License-Identifier: AGPL-3.0-only
// SZSystemProcessRunner substrate truths the app layer builds on:
//  - a signal death (killed/crashed CLI) is distinguishable from a plain non-zero exit
//    (`uncaughtSignal` — the mid-turn provider-death surface keys off it);
//  - stopping/timing out a run kills the CLI's whole descendant tree, not just the wrapper
//    (codex's Node wrapper spawns the vendor binary as a grandchild — killing only the direct
//    child would orphan the process actually talking to the model);
//  - live output is handed out as raw bytes, so a codepoint split across two pipe reads still
//    reaches the transcript intact.
// Real /bin/sh processes, no stubs: the substrate IS the thing under test.
import Foundation
import Synchronization
import Testing
import SZCore
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

    // The inactivity bound (coding agents ride it): SILENCE kills a turn, streaming keeps it alive,
    // and the wall clock stays as the hard cap for a CLI that streams forever.

    @Test func silenceKillsAtTheInactivityBoundNotTheWallClock() async throws {
        let started = ContinuousClock.now
        let result = try await runner.run("/bin/sh", ["-c", "sleep 30"], timeout: 25, inactivityTimeout: 1)
        #expect(result.timedOut)
        #expect(ContinuousClock.now - started < .seconds(10), "silent process outlived the inactivity bound")
    }

    @Test func streamingOutputKeepsATurnAliveAcrossTheInactivityWindow() async throws {
        // A chunk every 0.3s for ~3s — each one pushes the 1s silence deadline forward, so the run
        // must complete normally, well past the point a silent process would have died.
        let result = try await runner.run(
            "/bin/sh", ["-c", "for i in 1 2 3 4 5 6 7 8 9 10; do echo tick$i; sleep 0.3; done"],
            timeout: 30, inactivityTimeout: 1)
        #expect(!result.timedOut)
        #expect(result.exitCode == 0)
        #expect(result.output.contains("tick10"))   // it streamed to the end
    }

    @Test func theWallClockCapStillBoundsAForeverStreamingProcess() async throws {
        let started = ContinuousClock.now
        let result = try await runner.run(
            "/bin/sh", ["-c", "while true; do echo tick; sleep 0.2; done"],
            timeout: 1, inactivityTimeout: 10)
        #expect(result.timedOut)
        #expect(ContinuousClock.now - started < .seconds(10), "wall-clock cap did not fire")
    }

    /// The live-transcript path end to end — pipe chunks → `SZLineBuffer` → a provider's stream
    /// consumer — over a 4-byte codepoint the child writes in two halves, so it straddles a pipe-read
    /// boundary. `onOutput` must hand out the raw bytes: decoding each read on its own replaces both
    /// halves with U+FFFD permanently, and a mangled byte inside a JSONL line can cost the whole
    /// assistant message (the parse just fails). Only the live stream is affected — the accumulated
    /// `SZProcessResult.output` is decoded once, at the end — so nothing downstream of `parse()` shows it.
    @Test func aCodepointSplitAcrossPipeReadsSurvivesTheLiveStream() async throws {
        let chunks = Mutex<[Data]>([])
        // One claude stream-json line carrying "done 🎉", written as two printf calls 0.3s apart that
        // cut the emoji (f0 9f | 8e 89) down the middle — two reads, guaranteed.
        let head = ##"{"type":"assistant","message":{"content":[{"type":"text","text":"done \360\237"##
        let tail = ##"\216\211"}]}}\n"##
        let result = try await runner.run(
            "/bin/sh", ["-c", "/usr/bin/printf '\(head)'; sleep 0.3; /usr/bin/printf '\(tail)'"],
            onOutput: { chunk in chunks.withLock { $0.append(chunk) } })
        #expect(result.exitCode == 0)
        #expect(chunks.withLock { $0.count } >= 2, "the writes coalesced — nothing was split")

        // Exactly what SZHost's agent streaming does with the chunks.
        let lineBuffer = SZLineBuffer()
        let consumer = SZClaudeStreamConsumer()
        var events: [SZAgentStreamEvent] = []
        for chunk in chunks.withLock({ $0 }) {
            for line in lineBuffer.appendAndExtractLines(chunk) {
                events.append(contentsOf: consumer.consume(line))
            }
        }
        events.append(contentsOf: consumer.finish())
        #expect(events == [.reply("done 🎉")])
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
