// SPDX-License-Identifier: AGPL-3.0-only
import Testing
import Foundation
@testable import SZRuntime

/// Unit coverage for the runtime's virtual clock (`SZTimeline`). The timeline never reads a clock
/// itself — the caller feeds `now` — so every case here is deterministic. Adapted from the proto's
/// `SDRendererTimelineTests`, extended for frame-index freezing.

@Test func advancesTimeAndFrameIndexWhileRunning() {
    var t = SZTimeline()
    let a = t.nextFrame(now: 100)   // first frame rebases to 0
    #expect(a.frameIndex == 0)
    #expect(a.timeSeconds == 0)

    let b = t.nextFrame(now: 100.5)
    #expect(b.frameIndex == 1)
    #expect(abs(b.timeSeconds - 0.5) < 1e-9)

    let c = t.nextFrame(now: 101)
    #expect(c.frameIndex == 2)
    #expect(abs(c.timeSeconds - 1.0) < 1e-9)
}

@Test func pauseFreezesTimeAndFrameIndex() {
    var t = SZTimeline()
    _ = t.nextFrame(now: 100)
    let running = t.nextFrame(now: 100.5)   // frameIndex 1, time 0.5

    t.setPaused(true, now: 100.6)
    // Every paused frame returns the SAME snapshot regardless of how `now` advances.
    let p1 = t.nextFrame(now: 101)
    let p2 = t.nextFrame(now: 105)
    #expect(p1 == p2)
    #expect(p1.frameIndex == running.frameIndex)
    #expect(abs(p1.timeSeconds - running.timeSeconds) < 1e-9)
    #expect(t.paused)
}

@Test func unpauseResumesFromFrozenTimeExcludingPausedDuration() {
    var t = SZTimeline()
    _ = t.nextFrame(now: 100)
    _ = t.nextFrame(now: 101)               // time 1.0
    t.setPaused(true, now: 101)             // freeze at 1.0
    _ = t.nextFrame(now: 110)               // 9s of paused wall-time, still 1.0
    t.setPaused(false, now: 110)
    let resumed = t.nextFrame(now: 110.5)   // 0.5s after unpause
    // Elapsed continues from 1.0, NOT 10.5 — the 9 paused seconds are excluded.
    #expect(abs(resumed.timeSeconds - 1.5) < 1e-9)
}

@Test func resetBeforeFirstFrameStartsAtZero() {
    var t = SZTimeline()
    t.reset()
    let f = t.nextFrame(now: 500)   // large `now`, but a pending reset rebases here
    #expect(f.frameIndex == 0)
    #expect(f.timeSeconds == 0)
}

@Test func resetWhileRunningRestartsNextFrame() {
    var t = SZTimeline()
    _ = t.nextFrame(now: 100)
    _ = t.nextFrame(now: 103)       // frameIndex 1, time 3.0
    t.reset()
    let f = t.nextFrame(now: 104)
    #expect(f.frameIndex == 0)
    #expect(f.timeSeconds == 0)
    let g = t.nextFrame(now: 104.25)
    #expect(g.frameIndex == 1)
    #expect(abs(g.timeSeconds - 0.25) < 1e-9)
}

@Test func resetWhilePausedStaysFrozenAtZeroThenResumesFromZero() {
    var t = SZTimeline()
    _ = t.nextFrame(now: 100)
    _ = t.nextFrame(now: 102)       // time 2.0
    t.setPaused(true, now: 102)
    t.reset()
    // Frozen at the fresh zero while still paused.
    let p = t.nextFrame(now: 108)
    #expect(p.frameIndex == 0)
    #expect(p.timeSeconds == 0)
    // Unpause: time resumes from 0. The paused frame never advanced the frame counter, so the first
    // running frame after a reset is frame 0 (with time now advancing).
    t.setPaused(false, now: 108)
    let r = t.nextFrame(now: 108.5)
    #expect(abs(r.timeSeconds - 0.5) < 1e-9)
    #expect(r.frameIndex == 0)
    let r2 = t.nextFrame(now: 108.75)
    #expect(r2.frameIndex == 1)
}

@Test func timeNeverGoesNegativeAcrossAReset() {
    var t = SZTimeline()
    _ = t.nextFrame(now: 100)
    _ = t.nextFrame(now: 200)       // big jump forward
    t.reset()
    let f = t.nextFrame(now: 150)    // reset rebases to `now`; elapsed is 0, not -50
    #expect(f.timeSeconds == 0)
    #expect(f.frameIndex == 0)
}
