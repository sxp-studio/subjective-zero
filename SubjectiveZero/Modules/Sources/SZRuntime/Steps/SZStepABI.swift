// SPDX-License-Identifier: AGPL-3.0-only
// The frozen DECISION-STEP ABI, v5 — the async step tier over the kind-free wire. A step is
// a standalone `Step.swift` compiled and hot-reloaded exactly like a node's `Node.swift`;
// what crosses the `dlopen` boundary is C-ABI, and the ergonomic kit (`SZStep`, `ctx.ask`)
// is compiled INTO each step from the host-owned `SZStepKit.source`.
//
// The async shape (since v4), and why:
// - Evaluation is ASYNC: `SZStepEvaluate` starts the step's body in a Task and returns a
//   cancel token; the result arrives through a completion callback that fires EXACTLY ONCE
//   (ok / cancelled / failed). A step may `await` — which is what admits `askModel`.
// - Facts arrive EAGERLY: one JSON document in the request, decoded once by the
//   kit. The snapshot is pinned at evaluate-start; that is the determinism contract (a step
//   that awaits and then reads a fact sees the world as it was when evaluation began).
// - ONE outbound capability: the `ask` function pointer, through which the kit's `askModel`
//   requests a stateless model completion from the host. The host answers every accepted
//   call exactly once — on success, failure, or cancellation — so the kit never needs its
//   own cancellation plumbing for an in-flight ask.
// - Payloads are push-style: the producer owns the buffer, the consumer copies inside the
//   callback frame. The v3 grow-and-retry pull survives only in `SZStepDeclare`, which is
//   synchronous and load-time-only.
import Foundation

/// dylib → host, once per evaluation: `(completionCtx, status, payloadUTF8, payloadLen)`.
/// status 0 = ok (payload is the outcome string — or, when the step requested effects, the
/// `{"effects": […], "outcome": "…"}` JSON envelope; an additive payload convention, not an
/// ABI change: the loader relays the string either way and the host adapter splits it),
/// 1 = cancelled (payload empty),
/// 2 = failed (payload is a human-readable reason). The payload pointer is owned by the
/// dylib and valid only inside the callback frame — the host copies. May fire on any thread,
/// possibly before `SZStepEvaluate` returns.
typealias SZStepCompletionFn = @convention(c) (UnsafeMutableRawPointer?, Int32, UnsafePointer<CChar>?, Int32) -> Void

/// host → dylib, once per accepted ask: `(replyCtx, status, payloadUTF8, payloadLen)`.
/// status 0 = ok (payload is the raw model reply text), 1 = cancelled, 2 = failed (payload
/// is a reason). The host owns the payload; the dylib copies inside the callback frame.
typealias SZStepAskReplyFn = @convention(c) (UnsafeMutableRawPointer?, Int32, UnsafePointer<CChar>?, Int32) -> Void

/// dylib → host: start one stateless model completion.
/// `(hostContext, requestJSONUTF8, requestLen, replyFn, replyCtx) -> callID`. 0 = rejected
/// and `replyFn` will never be called; nonzero = accepted, and the host guarantees `replyFn`
/// fires EXACTLY ONCE, from any thread. The request is `SZAskRequest` as JSON.
typealias SZStepAskFn = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?, Int32, SZStepAskReplyFn?, UnsafeMutableRawPointer?) -> UInt64

enum SZStepABI {
    /// Bumped on a breaking ABI change. The loader rejects a mismatch.
    /// v5: the kind-free wire — the facts document is the ONE `SZFacts` shape (a message is
    /// words; structure is world state), the declaration payload is `{outcomes}` (no facts
    /// kind), and the teardown symbol is gone (steps are stateless). The C function
    /// shapes are unchanged from v4 — the bump
    /// forces every cached dylib to recompile against the new kit.
    /// (v4: async evaluation + eager facts snapshot + the single `ask` capability.)
    static let version: Int32 = 5

    static let apiVersionSymbol = "SZStepAPIVersion"
    static let declareSymbol = "SZStepDeclare"
    static let evaluateSymbol = "SZStepEvaluate"
    static let cancelSymbol = "SZStepCancel"

    typealias APIVersionFn = @convention(c) () -> Int32
    /// `(out, capacity) -> fullLength`: the step's declaration JSON, grow-and-retry.
    /// 0 = the step declares nothing.
    typealias DeclareFn = @convention(c) (UnsafeMutablePointer<CChar>?, Int32) -> Int32
    /// Starts one evaluation: `(SZStepEvalRequestRaw*, completion, completionCtx) -> token`.
    /// Returns a nonzero dylib-minted token and guarantees `completion` fires exactly once
    /// (possibly before this returns). Returns 0 = the evaluation could not start (nil
    /// request, no completion, or the facts document was rejected); `completion` is then
    /// never called. The request struct and everything it points to are valid ONLY for the
    /// duration of this call — the kit copies before returning.
    typealias EvaluateFn = @convention(c) (UnsafeRawPointer?, SZStepCompletionFn?, UnsafeMutableRawPointer?) -> UInt64
    /// Cancel one in-flight evaluation by token. Idempotent; an unknown or already-settled
    /// token is a no-op. The evaluation still settles through its completion (cancelled).
    typealias CancelFn = @convention(c) (UInt64) -> Void
}

/// The request struct crossing at evaluate-start. **Its layout must byte-match the copy
/// inside `SZStepKit.source`** — both are compiled by the same `swiftc`, so identical field
/// order/types ⇒ identical layout (pinned by the layout-probe test).
struct SZStepEvalRequestRaw {
    var apiVersion: Int32 = SZStepABI.version
    /// The facts document, UTF-8 JSON. Copied by the kit during the call.
    var factsJSON: UnsafePointer<CChar>?
    var factsLen: Int32 = 0
    /// Opaque host-side evaluation identity, passed back verbatim on every ask. (Host-side
    /// it is a registry ID, never a live pointer — a stray ask after settle must be
    /// rejectable, not a memory hazard.)
    var hostContext: UnsafeMutableRawPointer?
    /// The one outbound capability. nil ⇒ `askModel` throws `.modelUnavailable`.
    var askFn: SZStepAskFn?
}
