// SPDX-License-Identifier: AGPL-3.0-only
// The app's per-machine home: `~/Library/Application Support/SubjectiveZero`. Every file that is
// not part of a `.subz` project lives under it.
//
// One resolver, so a test process can move the whole home. Under a test runner it is a fresh temp
// folder, removed at exit: SZAppTests drives a real SZHost whose mutators persist, and one such
// test once disabled Codex in the user's real app. `SZ_APP_SUPPORT_DIR` overrides for any other
// driver that wants its own home.
import Foundation

public enum SZAppSupport {
    /// The home, resolved once per process.
    public static let directory: URL = {
        let home = directory(env: ProcessInfo.processInfo.environment, arguments: CommandLine.arguments)
        if home.lastPathComponent.hasPrefix(testHomePrefix) { atexit(szRemoveTestHome) }
        return home
    }()

    static let testHomePrefix = "SubjectiveZero-tests-"

    /// Takes env and arguments so tests can pass their own: an absolute override wins, a test
    /// runner gets a temp home, anything else gets the real Application Support folder.
    static func directory(env: [String: String], arguments: [String] = []) -> URL {
        if let override = env["SZ_APP_SUPPORT_DIR"], override.hasPrefix("/") {
            return URL(filePath: override, directoryHint: .isDirectory)
        }
        if isTestRunner(env: env, arguments: arguments) {
            return FileManager.default.temporaryDirectory
                .appending(path: testHomePrefix + UUID().uuidString, directoryHint: .isDirectory)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "SubjectiveZero", directoryHint: .isDirectory)
    }

    /// Xcode sets the XCTest variables on the process hosting the tests (the app itself for
    /// SZAppTests). SwiftPM's `swift test` sets none; its helper gets the `.xctest` bundle path
    /// as an argument.
    static func isTestRunner(env: [String: String], arguments: [String]) -> Bool {
        env["XCTestConfigurationFilePath"] != nil
            || env["XCTestBundlePath"] != nil
            || env["XCTestSessionIdentifier"] != nil
            || arguments.contains { $0.split(separator: "/").contains { $0.hasSuffix(".xctest") } }
    }
}

/// The atexit hook: drop this process's temp home (C-callable, so a free function).
private func szRemoveTestHome() {
    try? FileManager.default.removeItem(at: SZAppSupport.directory)
}
