// SPDX-License-Identifier: AGPL-3.0-only
// SZTimeline — the runtime's virtual playback clock. It sits between the wall/media clock and the
// per-frame node context, producing the `(frameIndex, timeSeconds)` each encode reads. Making it a
// value type owned by `EngineState` means pause/reset are just field mutations under the engine
// `Mutex` — no new locking, no threading hazard (see SZRuntime's class header).
//
// SEPARATION OF CONCERNS: freezing the *visible output* on pause is the RUNTIME's job — while paused
// it stops advancing the schedule and re-presents the current endpoint (SZRuntime.drawLive). This clock
// only owns *time*: it's a pausable, resettable elapsed clock. Ticking it while paused returns the
// frozen frame (a paused clock doesn't advance), and on resume the paused span is excluded so time is
// continuous — that's what makes Play pick up exactly where Pause left off.
//
// Ported from the proto's `SDRendererTimeline`, with one change: pause freezes the FRAME INDEX too, so
// `frameIndex` and `time` stay coherent across a pause.
//
// Why a LOCAL elapsed clock (`timeSeconds = now - baseTime`) rather than raw media time: absolute
// `CACurrentMediaTime()` grows large enough that Double precision collapses per-frame deltas toward
// zero. Rebasing to a local zero keeps time precise for the life of a run.
import Foundation

/// The per-frame timing the runtime hands each node.
struct SZFrameTiming: Equatable, Sendable {
    var frameIndex: UInt64
    var timeSeconds: Double
}

/// The runtime's pausable/resettable clock. `now` is always the caller's `CACurrentMediaTime()` —
/// the timeline never reads a clock itself, so it stays a pure value type (trivially testable).
struct SZTimeline: Sendable {
    /// Media-time origin of the current run; `timeSeconds` is measured from here. `nil` until the
    /// first frame (or after a reset) rebases it to `now`.
    private var baseTime: Double?
    /// `timeSeconds` returned on the previous running frame — the value we freeze at on pause and
    /// resume from after it (so pausing never nudges the clock).
    private var lastTime: Double = 0
    private var frameIndex: UInt64 = 0
    private var isPaused = false
    /// The frame the caller last saw while paused — returned unchanged every paused frame so the
    /// image is byte-identical.
    private var frozen: SZFrameTiming?
    /// The next `nextFrame` rebases to a fresh zero. Defaults true so a reset issued (or the very
    /// first frame drawn) before any frame still starts cleanly at 0.
    private var pendingReset = true

    /// Whether the clock is currently paused (mirrored to the host's observable HUD state).
    var paused: Bool { isPaused }

    /// Freeze/unfreeze the clock. On pause we snapshot the current frame so every subsequent paused
    /// frame returns it verbatim. On unpause we shift `baseTime` forward by the paused wall-time so
    /// elapsed excludes the pause and animation resumes exactly where it froze (no jump).
    mutating func setPaused(_ paused: Bool, now: Double) {
        guard paused != isPaused else { return }
        isPaused = paused
        if paused {
            // Freeze on the LAST frame we actually issued (`frameIndex` is the next-to-issue counter,
            // `lastTime` the elapsed we last returned) — so pausing produces zero visible jump. Before
            // any frame is drawn, `frameIndex`/`lastTime` are both 0.
            frozen = SZFrameTiming(frameIndex: frameIndex == 0 ? 0 : frameIndex - 1,
                                   timeSeconds: lastTime)
        } else {
            // Resume from the frozen elapsed: rebase so `now - baseTime == frozenElapsed`.
            if let frozen, !pendingReset {
                baseTime = now - frozen.timeSeconds
                lastTime = frozen.timeSeconds
            }
            frozen = nil
        }
    }

    /// Request a rewind-to-start. Lazily applied on the next `nextFrame` so it's safe to call from any
    /// thread state (and coalesces multiple resets into one). Leaves `isPaused` untouched: a reset
    /// while paused rebases the frozen frame to 0 and stays frozen there.
    mutating func reset() {
        pendingReset = true
    }

    /// Advance one frame and return its timing. Caller passes `CACurrentMediaTime()`.
    mutating func nextFrame(now: Double) -> SZFrameTiming {
        if pendingReset {
            baseTime = now
            frameIndex = 0
            lastTime = 0
            pendingReset = false
            // A reset that lands while paused re-freezes at the fresh zero.
            frozen = isPaused ? SZFrameTiming(frameIndex: 0, timeSeconds: 0) : nil
        }

        if isPaused, let frozen {
            return frozen
        }

        if baseTime == nil { baseTime = now }
        let elapsed = max(0, now - (baseTime ?? now))
        lastTime = elapsed
        let timing = SZFrameTiming(frameIndex: frameIndex, timeSeconds: elapsed)
        frameIndex &+= 1
        return timing
    }
}
