// SPDX-License-Identifier: AGPL-3.0-only
// The streaming-transcript coalescer: per-lane order is preserved, chunk bursts collapse to few
// flushes, a trailing flush paints a burst-then-silence, and `finish()` is a hard boundary — the
// full text is delivered synchronously and nothing can land after it (the host awaits the stream
// consumer task, which calls `finish()` before returning, so turn-end readers see complete text).
import Foundation
import Testing
@testable import SZAI

@MainActor
struct SZChatStreamCoalescerTests {
    /// Two sink lanes recorded as one interleaved log, so cross-lane ordering is assertable too.
    private final class Sink {
        var events: [(lane: String, text: String)] = []
        var reply: String { events.filter { $0.lane == "reply" }.map(\.text).joined() }
        var thinking: String { events.filter { $0.lane == "thinking" }.map(\.text).joined() }
    }

    private func makeCoalescer(
        flushInterval: Duration, trailingDelay: Duration = .seconds(60)
    ) -> (SZChatStreamCoalescer, Sink) {
        let sink = Sink()
        let coalescer = SZChatStreamCoalescer(
            flushInterval: flushInterval, trailingDelay: trailingDelay,
            onReply: { sink.events.append(("reply", $0)) },
            onThinking: { sink.events.append(("thinking", $0)) })
        return (coalescer, sink)
    }

    @Test func interleavedLanesPreservePerLaneOrder() {
        let (coalescer, sink) = makeCoalescer(flushInterval: .zero)
        coalescer.addReply("a")
        coalescer.addThinking("1")
        coalescer.addReply("b")
        coalescer.addThinking("2")
        coalescer.finish()
        #expect(sink.reply == "ab")
        #expect(sink.thinking == "12")
    }

    @Test func burstCoalescesToOneFlushPerLaneOnFinish() {
        let (coalescer, sink) = makeCoalescer(flushInterval: .seconds(60))
        // Backdated first-flush paints the opening chunk immediately…
        coalescer.addReply("first ")
        #expect(sink.reply == "first ")
        // …then the burst sits buffered until the final flush.
        for i in 0..<50 { coalescer.addReply("r\(i) ") }
        for i in 0..<50 { coalescer.addThinking("t\(i) ") }
        let flushesMidBurst = sink.events.count
        coalescer.finish()
        #expect(flushesMidBurst == 1)                     // only the opening flush
        #expect(sink.events.count == 3)                   // + one reply flush + one thinking flush
        #expect(sink.reply == "first " + (0..<50).map { "r\($0) " }.joined())
        #expect(sink.thinking == (0..<50).map { "t\($0) " }.joined())
    }

    @Test func trailingFlushPaintsBurstThenSilence() async throws {
        let (coalescer, sink) = makeCoalescer(flushInterval: .seconds(60), trailingDelay: .milliseconds(20))
        coalescer.addReply("opening")           // immediate (backdated first flush)
        coalescer.addReply(" tail")             // buffered; trailing flush armed
        #expect(sink.reply == "opening")
        try await Task.sleep(for: .milliseconds(200))
        #expect(sink.reply == "opening tail")   // painted by the trailing flush, no finish() needed
    }

    @Test func nothingLandsAfterFinish() async throws {
        let (coalescer, sink) = makeCoalescer(flushInterval: .seconds(60), trailingDelay: .milliseconds(10))
        coalescer.addReply("kept")
        coalescer.finish()
        coalescer.addReply(" dropped")
        try await Task.sleep(for: .milliseconds(100))    // any stray trailing task would fire in here
        #expect(sink.reply == "kept")
    }
}
