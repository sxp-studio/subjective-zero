// SPDX-License-Identifier: AGPL-3.0-only
// Mention substrate — canonical markup round-trip + degrade paths, agent-facing expansion
// (manifest resolution, @all enumeration, deleted-node tombstone), and the routing policy table
// (SZChatRouting.resolveRecipient — the seam these tests pin down so a policy swap is deliberate).
import Foundation
import Testing
@testable import SZCore

private let blurID = SZNodeID(uuidString: "11111111-1111-1111-1111-111111111111")!
private let skyID = SZNodeID(uuidString: "22222222-2222-2222-2222-222222222222")!

// MARK: - Markup

@Test func markupRoundTripsMixedSegments() {
    let segments: [SZMessageSegment] = [
        .mention(.node(blurID), display: "Blur"),
        .text(" soften the falloff, match "),
        .mention(.node(skyID), display: "Sky"),
        .text("'s tones"),
    ]
    let encoded = SZMentionMarkup.encode(segments)
    #expect(encoded == "@[Blur](node:\(blurID.uuidString)) soften the falloff, match @[Sky](node:\(skyID.uuidString))'s tones")
    #expect(SZMentionMarkup.parse(encoded) == segments)
}

@Test func markupRoundTripsProjectAndAll() {
    let segments: [SZMessageSegment] = [
        .mention(.project, display: "project"),
        .text(" implement the pending nodes, then tell "),
        .mention(.all, display: "all"),
    ]
    // Pin the WIRE FORMAT, not just the round trip: `parse(encode(x)) == x` holds even if both sides
    // drift to a new spelling in lockstep, silently orphaning every transcript already on disk.
    let encoded = SZMentionMarkup.encode(segments)
    #expect(encoded == "@[project](project) implement the pending nodes, then tell @[all](all)")
    #expect(SZMentionMarkup.parse(encoded) == segments)
}

@Test func malformedMarkupDegradesToLiteralText() {
    // Unknown target, bad uuid, unterminated token, bare "@[" — all kept as literal text.
    for raw in [
        "@[Blur](banana) x",
        "@[Blur](node:not-a-uuid) x",
        "@[Blur](node:",
        "hello @[ world",
        "email me @[here",
    ] {
        #expect(SZMentionMarkup.parse(raw) == [.text(raw)], "expected literal degrade for \(raw)")
    }
}

@Test func displaySanitizationCannotBreakMarkup() {
    let hostile = "Blur](node:33333333-3333-3333-3333-333333333333)\nboom"
    let encoded = SZMentionMarkup.encode([.mention(.node(blurID), display: hostile)])
    let parsed = SZMentionMarkup.parse(encoded)
    guard case .mention(.node(let id), _)? = parsed.first, parsed.count == 1 else {
        Issue.record("hostile display split the token: \(parsed)")
        return
    }
    #expect(id == blurID)
}

@Test func plainTextStripsMarkup() {
    let text = "@[Blur](node:\(blurID.uuidString)) and @[project](project) walk into a bar"
    #expect(SZMentionMarkup.plainText(text) == "@Blur and @project walk into a bar")
}

@Test func adjacentTextRunsMerge() {
    // A failed token between two text runs must not fragment the segments.
    let parsed = SZMentionMarkup.parse("a @[x](nope) b")
    #expect(parsed == [.text("a @[x](nope) b")])
}

// MARK: - Leading mention

@Test func leadingMentionSkipsWhitespaceOnly() {
    let text = "  \n @[Blur](node:\(blurID.uuidString)) do the thing"
    #expect(SZMentionMarkup.leadingMention(in: text) == .node(blurID))
}

@Test func midTextMentionIsNotLeading() {
    let text = "please fix @[Blur](node:\(blurID.uuidString))"
    #expect(SZMentionMarkup.leadingMention(in: text) == nil)
}

// MARK: - Routing policy table

@Test func routingLeadingNodeMentionGoesDirect() {
    let text = "@[Blur](node:\(blurID.uuidString)) soften it"
    #expect(SZChatRouting.resolveRecipient(message: text, activeScope: .director) == .node(blurID))
}

@Test func routingProjectAndAllGoToDirector() {
    for key in ["project", "all"] {
        let text = "@[\(key)](\(key)) do something"
        #expect(SZChatRouting.resolveRecipient(message: text, activeScope: .node(blurID)) == .director)
    }
}

@Test func routingNoLeadingMentionFallsBackToActiveTab() {
    #expect(SZChatRouting.resolveRecipient(message: "make it pop", activeScope: .node(blurID)) == .node(blurID))
    #expect(SZChatRouting.resolveRecipient(message: "make it pop", activeScope: .director) == .director)
    // References mid-text never route.
    let reference = "match @[Sky](node:\(skyID.uuidString))'s tones"
    #expect(SZChatRouting.resolveRecipient(message: reference, activeScope: .node(blurID)) == .node(blurID))
}

@Test func routingMultiMentionLeadingWins() {
    // "@Blur match @Sky" → Blur (Sky is a reference); never duplicated to both.
    let text = "@[Blur](node:\(blurID.uuidString)) match @[Sky](node:\(skyID.uuidString))"
    #expect(SZChatRouting.resolveRecipient(message: text, activeScope: .director) == .node(blurID))
}

// MARK: - Expansion

private let liveNodes: [(id: SZNodeID, title: String)] = [(blurID, "Blur Pass"), (skyID, "Sky")]

@Test func expansionInlinesDisplayAndResolvesCurrentTitle() {
    // Display frozen as "Blur" (what the user said); manifest resolves the CURRENT title.
    let text = "@[Blur](node:\(blurID.uuidString)) soften it"
    let expanded = SZMentionExpansion.agentText(text, nodes: liveNodes)
    #expect(expanded.hasPrefix("@Blur soften it"))
    #expect(expanded.contains("Mentioned in this message:"))
    #expect(expanded.contains("- @Blur → node \(blurID.uuidString) (current title \"Blur Pass\")"))
}

@Test func expansionAllEnumeratesSnapshot() {
    let expanded = SZMentionExpansion.agentText("@[all](all) re-check your inputs", nodes: liveNodes)
    #expect(expanded.contains("every node in the graph: \(blurID.uuidString) (\"Blur Pass\"), \(skyID.uuidString) (\"Sky\")"))
}

@Test func expansionAllOnEmptyGraph() {
    let expanded = SZMentionExpansion.agentText("@[all](all) hello", nodes: [])
    #expect(expanded.contains("(the graph has no nodes)"))
}

@Test func expansionDeletedNodeGetsTombstone() {
    let text = "@[Old](node:\(blurID.uuidString)) status?"
    let expanded = SZMentionExpansion.agentText(text, nodes: [(skyID, "Sky")])
    #expect(expanded.contains("- @Old → node \(blurID.uuidString) (no longer in the graph)"))
}

@Test func expansionWithoutMentionsIsUntouched() {
    #expect(SZMentionExpansion.agentText("plain message", nodes: liveNodes) == "plain message")
}

@Test func expansionDeduplicatesRepeatedMentions() {
    let text = "@[Blur](node:\(blurID.uuidString)) and again @[Blur](node:\(blurID.uuidString))"
    let expanded = SZMentionExpansion.agentText(text, nodes: liveNodes)
    let lines = expanded.components(separatedBy: "\n").filter { $0.hasPrefix("- @Blur") }
    #expect(lines.count == 1)
}
