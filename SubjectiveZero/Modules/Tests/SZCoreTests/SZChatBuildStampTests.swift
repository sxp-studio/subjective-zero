// SPDX-License-Identifier: AGPL-3.0-only
// A message's build name and step survive the sidecar, and their absence decodes as nil.
import Foundation
import Testing
@testable import SZCore

@Test func buildNameAndStepRoundTripAndDefaultToNil() throws {
    let stamped = SZChatMessage(role: .assistant, text: "…", buildName: "Warm orange gradient",
                                buildStep: "Decompose")
    let data = try JSONEncoder().encode(stamped)
    let back = try JSONDecoder().decode(SZChatMessage.self, from: data)
    #expect(back.buildName == "Warm orange gradient")
    #expect(back.buildStep == "Decompose")

    let plain = try JSONDecoder().decode(SZChatMessage.self, from: Data(#"{"role":"assistant","text":"hi"}"#.utf8))
    #expect(plain.buildName == nil)
    #expect(plain.buildStep == nil)
    // Absent stamps are not written as null.
    let bare = String(decoding: try JSONEncoder().encode(SZChatMessage(role: .user, text: "x")), as: UTF8.self)
    #expect(!bare.contains("buildName"))
}
