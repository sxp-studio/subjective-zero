// SPDX-License-Identifier: AGPL-3.0-only
// The app-hosted test process must never read or write the user's real Application Support
// folder: every SZHost() in this bundle persists preferences as a side effect.
import Foundation
import Testing
import SZCore
@testable import SubjectiveZero

@Test func theHostedTestProcessRunsOnATempHome() {
    #expect(SZAppSupport.directory.path.hasPrefix(FileManager.default.temporaryDirectory.path))
    #expect(SZAppStateIO.defaultURL.path.hasPrefix(SZAppSupport.directory.path))
    #expect(SZHost.supportRoot.path == SZAppSupport.directory.path)
}
