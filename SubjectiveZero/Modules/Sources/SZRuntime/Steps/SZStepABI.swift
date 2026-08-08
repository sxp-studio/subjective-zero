// SPDX-License-Identifier: AGPL-3.0-only
// The frozen DECISION-STEP ABI, v4 — the async evolution of the step tier. A step is a
// standalone `Step.swift` compiled and hot-reloaded exactly like a node's `Node.swift`; what
// crosses the `dlopen` boundary is C-ABI, and the ergonomic SDK (`SZStep`, `SZCondition`,
// `askModel`) is compiled INTO each step from the host-owned `SZStepSDK.source`.
//
// v4's shape, and why:
// - Evaluation is ASYNC: `SZStepEvaluate` starts the step's body in a Task and returns a
//   cancel token; the result arrives through a completion callback that fires EXACTLY ONCE
//   (ok / cancelled / failed). A step may `await` — which is what admits `askModel`.
// - Facts arrive EAGERLY: one kind-gated JSON document in the request, decoded once by the
//   SDK. The snapshot is pinned at evaluate-start; that is the determinism contract (a step
//   that awaits and then reads a fact sees the world as it was when evaluation began).
// - ONE outbound capability: the `ask` function pointer, through which the SDK's `askModel`
//   requests a stateless model completion from the host. The host answers every accepted
//   call exactly once — on success, failure, or cancellation — so the SDK never needs its
//   own cancellation plumbing for an in-flight ask.
// - Payloads are push-style: the producer owns the buffer, the consumer copies inside the
//   callback frame. The v3 grow-and-retry pull survives only in `SZStepDeclare`, which is
//   synchronous and load-time-only.
import Foundation

/// dylib → host, once per evaluation: `(completionCtx, status, payloadUTF8, payloadLen)`.
/// status 0 = ok (payload is the outcome string), 1 = cancelled (payload empty),
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
    /// v4: async evaluation (completion callback + cancel token), eager facts snapshot in
    /// the request, and the single `ask` outbound capability. (v3 was synchronous with a
    /// lazy per-fact resolver; its history lives on the archived mailbox-agents branch.)
    static let version: Int32 = 4

    static let apiVersionSymbol = "SZStepAPIVersion"
    static let declareSymbol = "SZStepDeclare"
    static let evaluateSymbol = "SZStepEvaluate"
    static let cancelSymbol = "SZStepCancel"
    static let teardownSymbol = "SZStepTeardown"

    typealias APIVersionFn = @convention(c) () -> Int32
    /// `(out, capacity) -> fullLength`: the step's declaration JSON, grow-and-retry.
    /// 0 = the step declares nothing.
    typealias DeclareFn = @convention(c) (UnsafeMutablePointer<CChar>?, Int32) -> Int32
    /// Starts one evaluation: `(SZStepEvalRequestRaw*, completion, completionCtx) -> token`.
    /// Returns a nonzero dylib-minted token and guarantees `completion` fires exactly once
    /// (possibly before this returns). Returns 0 = the evaluation could not start (nil
    /// request, no completion, or the facts document was rejected); `completion` is then
    /// never called. The request struct and everything it points to are valid ONLY for the
    /// duration of this call — the SDK copies before returning.
    typealias EvaluateFn = @convention(c) (UnsafeRawPointer?, SZStepCompletionFn?, UnsafeMutableRawPointer?) -> UInt64
    /// Cancel one in-flight evaluation by token. Idempotent; an unknown or already-settled
    /// token is a no-op. The evaluation still settles through its completion (cancelled).
    typealias CancelFn = @convention(c) (UInt64) -> Void
    /// Called once, after the host has drained every in-flight evaluation, before dlclose.
    typealias TeardownFn = @convention(c) () -> Void
}

/// The request struct crossing at evaluate-start. **Its layout must byte-match the copy
/// inside `SZStepSDK.source`** — both are compiled by the same `swiftc`, so identical field
/// order/types ⇒ identical layout (pinned by the layout-probe test).
struct SZStepEvalRequestRaw {
    var apiVersion: Int32 = SZStepABI.version
    /// The kind-gated facts document, UTF-8 JSON. Copied by the SDK during the call.
    var factsJSON: UnsafePointer<CChar>?
    var factsLen: Int32 = 0
    /// Opaque host-side evaluation state; retained by the host until the completion fires.
    var hostContext: UnsafeMutableRawPointer?
    /// The one outbound capability. nil ⇒ `askModel` throws `.modelUnavailable`.
    var askFn: SZStepAskFn?
}
