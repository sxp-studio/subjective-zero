// SPDX-License-Identifier: AGPL-3.0-only
// Shared scaffolding for the library and save suites: a scratch folder, a node lookup, and the two
// checks on strings (a 64-hex hash, a uuid prefix that a person should never see).
import Foundation
import Testing
import SZCore
@testable import SubjectiveZero

@MainActor
enum SZLibraryTestSupport {
    static func scratchDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "sz-library-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A host that starts with only the library the app ships with.
    ///
    /// The prefs AND the default My Library folder both live in one temp home shared by the whole
    /// test process, so a suite that adds a library or saves a node is otherwise visible to every
    /// suite after it. Pointing My Library at a folder that does not exist is what makes "no library
    /// of your own yet" true per test rather than per process.
    static func withDefaultLibraries(_ host: SZHost) -> SZHost {
        host.addedLibraries = []
        host.myLibraryPath = FileManager.default.temporaryDirectory
            .appending(path: "sz-mine-\(UUID().uuidString)").path
        return host
    }

    static func node(_ host: SZHost, _ id: SZNodeID) throws -> SZNode {
        try #require(host.store.project?.graph.node(id: id))
    }

    static func isHex64(_ s: String?) -> Bool {
        guard let s, s.count == 64 else { return false }
        return s.allSatisfy { $0.isHexDigit }
    }

    static func containsUUIDPrefix(_ status: String) -> Bool {
        status.range(of: "[0-9a-fA-F]{8}", options: .regularExpression) != nil
    }
}
