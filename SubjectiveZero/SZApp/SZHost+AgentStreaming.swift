// SPDX-License-Identifier: AGPL-3.0-only
// One shared path for streaming an agent turn's output into a chat transcript. Both interactive
// chat (`SZHost.sendChat`) and a run's per-node coding agents (`SZProceduralDirectorStrategy`) funnel
// through this, so run output lands in the node/Director tabs exactly the way chat replies already do.
//
// The pipeline is order-preserving: provider stdout arrives off-main per chunk → an AsyncStream →
// line-buffered → the provider's own stream consumer (claude stream-json vs codex jsonl) → classified
// `SZAgentStreamEvent`s → appended to the scope's transcript message on the MainActor. The provider owns
// the parsing; the host stays provider-agnostic (just routes the classified events).
import Foundation
import SZAI
import SZCore

extension SZHost {
    /// Run one agent turn and stream its classified output into `scope`'s transcript message
    /// `assistantID`. The caller owns opening that assistant message, session bookkeeping, and any
    /// working/in-flight flags; this method only wires the stream and runs the turn. Any `onOutput`
    /// already set on `request` is preserved (called in addition to the transcript routing).
    @MainActor
    @discardableResult
    func streamAgentTurn(
        provider: any SZProvider,
        request: SZAgentRunRequest,
        into scope: SZChatScope,
        message assistantID: UUID
    ) async throws -> SZAgentRunResult {
        // Provider output (off-main, per chunk) is funnelled through an AsyncStream and consumed serially
        // on the MainActor — line-buffered, parsed by the provider's consumer, appended to the transcript.
        let (chunks, chunksContinuation) = AsyncStream<String>.makeStream()
        let streamConsumer = provider.makeStreamConsumer()
        let route: @MainActor ([SZAgentStreamEvent]) -> Void = { [store] events in
            for event in events {
                switch event {
                case .reply(let text): store.appendChatText(text, to: assistantID, in: scope)
                case .thinking(let text): store.appendChatThinking(text + "\n", to: assistantID, in: scope)
                case .toolCall(let name): store.appendChatThinking("→ \(name)\n", to: assistantID, in: scope)
                case .usage(let usage): store.setChatUsage(usage, assistantID, in: scope)
                }
            }
        }
        let consumer = Task { @MainActor in
            let lineBuffer = SZLineBuffer()
            for await chunk in chunks {
                for line in lineBuffer.appendAndExtractLines(Data(chunk.utf8)) {
                    route(streamConsumer.consume(line))
                }
            }
            route(streamConsumer.finish())   // flush the finalized reply
        }

        // Feed the stream from the run's output, keeping any caller-supplied onOutput.
        var request = request
        let passthrough = request.onOutput
        request.onOutput = { chunk in
            passthrough?(chunk)
            chunksContinuation.yield(chunk)
        }

        do {
            let result = try await provider.run(request)
            chunksContinuation.finish()
            await consumer.value
            return result
        } catch {
            chunksContinuation.finish()
            await consumer.value
            throw error
        }
    }
}
