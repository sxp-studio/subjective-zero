// SPDX-License-Identifier: AGPL-3.0-only
// Settings ▸ Experimental ▸ Jev: the key lives in a test-only Keychain item, the switch needs
// a key, and the switch persists in app-state.
import Foundation
import Testing
import SZCore
@testable import SubjectiveZero

@MainActor
@Suite(.serialized)
struct SZHostExperimentalTests {

    @Test func theTestProcessNeverTouchesTheRealKey() {
        #expect(SZKeychain.jev.service.hasSuffix(".tests"))
    }

    @Test func keychainRoundTrip() {
        let item = SZKeychain(service: "studio.sxp.SubjectiveZero.tests.roundtrip", account: "api-key")
        defer { item.delete() }
        #expect(item.write("jv_live_first"))
        #expect(item.write("jv_live_second"))   // an update, not a duplicate
        #expect(item.read() == "jv_live_second")
        item.delete()
        #expect(item.read() == nil)
    }

    @Test func theSwitchNeedsAKeyAndPersists() {
        defer { SZKeychain.jev.delete() }
        let host = SZHost()
        host.removeJevKey()
        host.setJevEnabled(true)
        #expect(!host.jevEnabled)            // no key, stays off
        #expect(host.queryDecider == nil)

        #expect(SZKeychain.jev.write("jv_live_abcd1234"))
        host.jevKeyHint = SZHost.maskedKey("jv_live_abcd1234")
        host.setJevEnabled(true)
        #expect(host.jevEnabled)
        #expect(host.queryDecider != nil)
        #expect(SZAppStateIO.load()?.jevEnabled == true)

        host.removeJevKey()
        #expect(!host.jevEnabled)
        #expect(host.jevKeyHint == nil)
        #expect(SZAppStateIO.load()?.jevEnabled == nil)
    }

    @Test func theMaskShowsOnlyTheTail() {
        #expect(SZHost.maskedKey("jv_live_abcdef9876") == "jv_live_…9876")
    }
}
