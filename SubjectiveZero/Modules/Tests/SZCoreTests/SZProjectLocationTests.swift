// SPDX-License-Identifier: AGPL-3.0-only
// THE RULE (SZProjectLocation): two URLs name the same project when their canonical PATHS match.
// The cases below are the everyday ones, not exotica — an open panel hands the app a directory URL
// for a `.subz` while a remembered path string hands it a file-flavored one, and comparing those as
// URLs made the app decide it was looking at a second project (then fail on its own instance lock).
import Foundation
import Testing
@testable import SZCore

@Test func theSameBundleWithAndWithoutTheDirectoryFlagIsOneProject() {
    let panel = URL(fileURLWithPath: "/Users/c/Patches/Depth.subz", isDirectory: true)   // `…/Depth.subz/`
    let remembered = URL(filePath: "/Users/c/Patches/Depth.subz")
    #expect(panel != remembered, "the URLs really are unequal — that is the whole trap")
    #expect(SZProjectLocation.isSame(panel, remembered))
    #expect(SZProjectLocation.canonicalPath(panel) == "/Users/c/Patches/Depth.subz")
}

@Test func aRelativeStepIsStandardizedAway() {
    #expect(SZProjectLocation.isSame(URL(filePath: "/Users/c/Patches/../Patches/Depth.subz"),
                                     URL(filePath: "/Users/c/Patches/Depth.subz")))
}

@Test func twoDifferentProjectsStayDifferent() {
    #expect(!SZProjectLocation.isSame(URL(filePath: "/Users/c/Patches/Depth.subz"),
                                      URL(filePath: "/Users/c/Patches/Depth 2.subz")))
    // A name that merely shares the other's prefix is not the same project either.
    #expect(!SZProjectLocation.isSame(URL(filePath: "/Users/c/Patches/Depth.subz"),
                                      URL(filePath: "/Users/c/Patches/DepthOld.subz")))
}

/// The symlink case the old comparison already covered, kept: `/tmp` is a link to `/private/tmp`,
/// so a project reached through either path is one project (and one instance lock).
@Test func aSymlinkedPathResolvesToTheSameProject() throws {
    let name = "sz-location-\(UUID().uuidString)"
    let viaTmp = URL(filePath: "/tmp/\(name)/Depth.subz")
    let viaPrivate = URL(filePath: "/private/tmp/\(name)/Depth.subz")
    try FileManager.default.createDirectory(at: viaPrivate, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: viaPrivate.deletingLastPathComponent()) }

    #expect(SZProjectLocation.isSame(viaTmp, viaPrivate))
}

/// A case-insensitive volume (the macOS default) reads one bundle under two spellings, and the
/// strings alone cannot tell. Asked of a project that exists, the volume answers.
@Test func oneBundleUnderTwoSpellingsIsOneProject() throws {
    let dir = URL(filePath: "/tmp/sz-location-\(UUID().uuidString)")
    let bundle = dir.appending(path: "Depth.subz")
    try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let lowercased = dir.appending(path: "depth.subz")
    try #require(FileManager.default.fileExists(atPath: lowercased.path),
                 "this volume is case-sensitive, where the two really are different projects")

    #expect(SZProjectLocation.isSame(bundle, lowercased))
    #expect(!SZProjectLocation.isSame(bundle, dir.appending(path: "Other.subz")))
}

/// The fallback only ever adds identity, never removes it: a destination that does not exist yet
/// (every Save As target) still compares by path.
@Test func aDestinationThatDoesNotExistYetStillCompares() {
    let dest = URL(filePath: "/tmp/sz-location-none/New.subz")
    #expect(SZProjectLocation.isSame(dest, URL(fileURLWithPath: dest.path, isDirectory: true)))
    #expect(!SZProjectLocation.isSame(dest, URL(filePath: "/tmp/sz-location-none/Other.subz")))
}
