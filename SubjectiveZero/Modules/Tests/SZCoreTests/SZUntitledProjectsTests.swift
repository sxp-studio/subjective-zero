// SPDX-License-Identifier: AGPL-3.0-only
// SZUntitledProjects — the "untitled iff inside its directory" definition (path logic only; the
// directory-creating helper is exercised live through the app's File ▸ New).
import Foundation
import Testing
@testable import SZCore

@Test func untitledDirectoryContainsItsProjects() {
    let inside = SZUntitledProjects.projectsDirectory.appending(path: "\(UUID().uuidString)/Untitled.subz")
    #expect(SZUntitledProjects.contains(inside))
}

@Test func untitledDirectoryDoesNotContainOutsidePaths() {
    #expect(!SZUntitledProjects.contains(URL(filePath: "/tmp/Test.subz")))
    // A sibling directory sharing the "Projects" prefix must not match (prefix is path-segment-aware).
    let sibling = SZUntitledProjects.projectsDirectory.deletingLastPathComponent()
        .appending(path: "ProjectsBackup/Test.subz")
    #expect(!SZUntitledProjects.contains(sibling))
    // The untitled projects' directory itself is not a project inside it.
    #expect(!SZUntitledProjects.contains(SZUntitledProjects.projectsDirectory))
}
