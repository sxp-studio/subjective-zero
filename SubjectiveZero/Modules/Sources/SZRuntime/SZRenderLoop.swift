// SPDX-License-Identifier: AGPL-3.0-only
// SZRenderLoop — the runtime's one render clock: a dedicated thread whose run loop hosts a single
// pacing CADisplayLink; each fire is one `SZRuntime.tick()`. The host decides WHEN it runs by handing
// over a link (or nil to idle) — no liveness heuristics here.
//
// The thread starts on first pacing and lives for the runtime (pacing edges only swap links); with no
// link it parks at zero CPU (a keep-alive port stops the run loop from returning early). Link
// add/invalidate always happen on the loop thread via a run-loop perform block. `state` guards the
// handoff vars only and is never held while ticking.
import Foundation
import QuartzCore
import Synchronization

final class SZRenderLoop: NSObject, @unchecked Sendable {
    private struct State {
        /// The loop thread's run loop — set once by the thread; nil until it's up and after `stop`.
        var runLoop: CFRunLoop?
        /// Blocks handed in before the run loop existed; the thread drains them once it's up.
        var pending: [@Sendable () -> Void] = []
        var started = false
        var stopped = false
    }

    private let state = Mutex<State>(State())
    private let tick: @Sendable () -> Void
    /// Loop-thread-only.
    private var link: CADisplayLink?

    init(tick: @escaping @Sendable () -> Void) {
        self.tick = tick
    }

    /// Install `link` as the pacer (dropping the previous one), or idle on nil. Any thread.
    func setPacing(_ link: CADisplayLink?) {
        nonisolated(unsafe) let link = link   // CADisplayLink isn't Sendable; single owner, handed once
        perform { [self] in
            self.link?.invalidate()
            self.link = link
            link?.add(to: .current, forMode: .default)
        }
    }

    /// The pacing link's target: one beat.
    @objc func fire(_ link: CADisplayLink) {
        tick()
    }

    /// End the thread (runtime deinit). Idempotent.
    func stop() {
        state.withLock { s in
            s.stopped = true
            if let runLoop = s.runLoop { CFRunLoopStop(runLoop) }
            s.runLoop = nil
        }
    }

    /// Run `body` on the loop thread (starts it on first use; queues until its run loop exists).
    private func perform(_ body: @escaping @Sendable () -> Void) {
        let runLoop: CFRunLoop? = state.withLock { s in
            guard !s.stopped else { return nil }
            if let runLoop = s.runLoop { return runLoop }
            s.pending.append(body)
            if !s.started {
                s.started = true
                startThread()
            }
            return nil
        }
        guard let runLoop else { return }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue, body)
        CFRunLoopWakeUp(runLoop)
    }

    private func startThread() {
        let thread = Thread { [self] in
            // Keep-alive source: without one, `run(mode:before:)` returns immediately.
            RunLoop.current.add(NSMachPort(), forMode: .default)
            let queued: [@Sendable () -> Void] = state.withLock { s in
                s.runLoop = CFRunLoopGetCurrent()
                defer { s.pending.removeAll() }
                return s.pending
            }
            for body in queued { body() }
            while !state.withLock({ $0.stopped }),
                  RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 1)) {}
            link?.invalidate()
            link = nil
        }
        thread.name = "SZRuntime.RenderLoop"
        thread.qualityOfService = .userInteractive
        thread.start()
    }
}
