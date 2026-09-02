// impulse-envelope — the "Impulse" library node (NODE_LIBRARY.md). Pure math, no device and no GPU:
// it turns a trigger pulse (`trigger` >= 0.5, e.g. audio-onset's `kick`) into a one-shot attack/decay
// envelope on `value` — the shape that makes a visual parameter pop on a hit instead of wobbling with a
// level. `reuse: copy-as-is`.
//
// `attack` and `decay` are in seconds: dt is derived from ctx.time (there is no ABI delta-time), so the
// curve is display-refresh independent. Attack is linear from the current value (a retrigger mid-decay
// climbs, never snaps to 0); decay is exponential, ~5% left after `decay` seconds. A backward time step
// (HUD Reset Time) clears the envelope — the video-file rewind convention.
import Foundation

final class Node: SZNode {
    private var env: Float = 0
    private var attacking = false
    private var lastTime = 0.0

    func update(_ ctx: SZFrameContext) {
        // dt from the graph clock; backward step = reset. clamp so a stall can't produce a giant jump.
        if ctx.time < lastTime { env = 0; attacking = false }
        let dt = Float(min(max(ctx.time - lastTime, 0.001), 0.1))
        lastTime = ctx.time

        let attack = ctx.inputFloat("attack") ?? 0.01
        let decay = max(ctx.inputFloat("decay") ?? 0.35, 0.01)
        let amount = ctx.inputFloat("amount") ?? 1

        if (ctx.inputFloat("trigger") ?? 0) >= 0.5 { attacking = true }
        if attacking {
            env = attack <= 0.0005 ? 1 : min(1, env + dt / attack)
            if env >= 1 { attacking = false }
        } else {
            env *= exp(-3 * dt / decay)   // ~5% left after `decay` seconds
        }
        ctx.setOutputFloat("value", amount * env)
    }
}

enum SZNodeMain { static func make() -> SZNode { Node() } }
