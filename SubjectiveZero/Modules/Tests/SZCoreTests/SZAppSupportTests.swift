// SPDX-License-Identifier: AGPL-3.0-only
// The per-machine home resolver: an absolute override wins, a test runner never gets the user's
// real Application Support folder, and a plain launch does.
import Foundation
import Testing
@testable import SZCore

private let realHome = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appending(path: "SubjectiveZero", directoryHint: .isDirectory)
private let tempRoot = FileManager.default.temporaryDirectory.path

@Test func aPlainLaunchUsesTheRealApplicationSupportHome() {
    #expect(SZAppSupport.directory(env: [:]).path == realHome.path)
    #expect(SZAppSupport.directory(env: [:], arguments: ["/Applications/App.app/Contents/MacOS/App"]).path
            == realHome.path)
    // A user path that merely contains ".xctest" is not a test bundle.
    #expect(SZAppSupport.directory(env: [:], arguments: ["app", "--open", "/p/foo.xctest-fixtures/Demo.subz"]).path
            == realHome.path)
}

@Test func aTestRunnerGetsAFreshTempHomeOfItsOwn() {
    // Xcode's hosted runner: XCTest env vars. SwiftPM's: the .xctest bundle path as an argument.
    var homes = ["XCTestConfigurationFilePath", "XCTestBundlePath", "XCTestSessionIdentifier"]
        .map { SZAppSupport.directory(env: [$0: "x"]) }
    homes.append(SZAppSupport.directory(
        env: [:], arguments: ["helper", "--test-bundle-path", "/b/ModulesPackageTests.xctest/Contents/MacOS/x"]))
    for home in homes {
        #expect(home.path != realHome.path)
        #expect(home.path.hasPrefix(tempRoot))
    }
    // Fresh per resolution, so a recycled pid never inherits an older run's state.
    #expect(Set(homes.map(\.path)).count == homes.count)
}

@Test func anAbsoluteOverrideWinsEvenUnderATestRunner() {
    let home = SZAppSupport.directory(env: ["SZ_APP_SUPPORT_DIR": "/tmp/sz-home",
                                            "XCTestConfigurationFilePath": "x"])
    #expect(home.path == "/tmp/sz-home")
    // A relative or empty override is no override: a GUI launch's cwd is `/`.
    #expect(SZAppSupport.directory(env: ["SZ_APP_SUPPORT_DIR": "sz-home"]).path == realHome.path)
    #expect(SZAppSupport.directory(env: ["SZ_APP_SUPPORT_DIR": ""]).path == realHome.path)
}

@Test func thisTestProcessIsNotPointedAtTheUsersHome() {
    #expect(SZAppSupport.directory.path.hasPrefix(tempRoot))
    #expect(SZAppStateIO.defaultURL.path.hasPrefix(SZAppSupport.directory.path))
}
