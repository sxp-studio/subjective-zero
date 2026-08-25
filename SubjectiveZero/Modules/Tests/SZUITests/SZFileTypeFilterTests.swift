// SPDX-License-Identifier: AGPL-3.0-only
// The open panel's filter, driven directly. `NSOpenPanel` consults these two delegate methods; they
// are plain functions over a URL, so the RULES are testable even though the modal panel is not.
//
// What they have to get right, and why it isn't `allowedContentTypes`:
// `UTType(filenameExtension: "mlpackage")` is nil on a Mac where nothing registered that type, so a
// content-type filter silently drops exactly the kinds worth declaring. These match the extension,
// which needs no type to exist anywhere.
import Foundation
import Testing
@testable import SZUI

private let sender = NSNull()

private func scratch() -> URL {
    let dir = FileManager.default.temporaryDirectory.appending(path: "sz-filter-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func file(_ dir: URL, _ name: String) -> URL {
    let url = dir.appending(path: name)
    FileManager.default.createFile(atPath: url.path, contents: Data("x".utf8))
    return url
}

/// `validate` throws to refuse; flatten that to a Bool so no call sits inside a macro expansion
/// (the delegate is an NSObject, and `#expect { }` would send it across isolation).
@MainActor
private func validates(_ filter: SZFileTypeFilter, _ url: URL) -> Bool {
    do { try filter.panel(sender, validate: url); return true } catch { return false }
}

@MainActor
private func reason(_ filter: SZFileTypeFilter, _ url: URL) -> NSError? {
    do { try filter.panel(sender, validate: url); return nil } catch { return error as NSError }
}

private func folder(_ dir: URL, _ name: String) -> URL {
    let url = dir.appending(path: name)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@MainActor
@Test func aPortThatDeclaresNothingAcceptsAnything() {
    let dir = scratch(); defer { try? FileManager.default.removeItem(at: dir) }
    let filter = SZFileTypeFilter(extensions: [])
    let url = file(dir, "whatever.xyz")
    let enabled = filter.panel(sender, shouldEnable: url)
    let accepted = validates(filter, url)
    #expect(enabled)
    #expect(accepted)
}

@MainActor
@Test func aDeclaredExtensionIsEnabledAndAnUndeclaredOneIsNot() {
    let dir = scratch(); defer { try? FileManager.default.removeItem(at: dir) }
    let filter = SZFileTypeFilter(extensions: ["mlpackage", "mlmodelc"])
    #expect(filter.panel(sender, shouldEnable: file(dir, "Depth.mlmodelc")))
    #expect(!filter.panel(sender, shouldEnable: file(dir, "Depth.mlmodel")))
}

/// Case is not part of the answer: a file off a camera or a Windows share arrives shouting.
@MainActor
@Test func theMatchIgnoresCase() {
    let dir = scratch(); defer { try? FileManager.default.removeItem(at: dir) }
    let filter = SZFileTypeFilter(extensions: ["mov"])
    #expect(filter.panel(sender, shouldEnable: file(dir, "IMG_2479.MOV")))
}

/// THE case this exists for: a folder macOS may or may not know is a package. Matching the extension
/// means it is selectable whether or not anything on this Mac registered the type.
@MainActor
@Test func aFolderShapedFileIsSelectableWhenItsExtensionIsDeclared() {
    let dir = scratch(); defer { try? FileManager.default.removeItem(at: dir) }
    let filter = SZFileTypeFilter(extensions: ["mlpackage"])
    let package = folder(dir, "Depth.mlpackage")
    let enabled = filter.panel(sender, shouldEnable: package)
    let accepted = validates(filter, package)
    #expect(enabled)
    #expect(accepted)
}

/// …while ordinary folders stay enabled for a different reason: you have to be able to walk INTO
/// them to reach the file. Enabled to navigate, refused on confirm.
@MainActor
@Test func aPlainFolderStaysWalkableButCannotBeChosen() {
    let dir = scratch(); defer { try? FileManager.default.removeItem(at: dir) }
    let filter = SZFileTypeFilter(extensions: ["mlpackage"])
    let plain = folder(dir, "Models")
    let enabled = filter.panel(sender, shouldEnable: plain)
    let accepted = validates(filter, plain)
    #expect(enabled, "a folder must stay navigable")
    #expect(!accepted, "but choosing it must be refused")
}

/// `shouldEnable` greys the browser out, but it is not the only way to choose: a typed path, a drag
/// into the panel, and Choose-on-the-current-folder all bypass it. `validate` is the backstop.
@MainActor
@Test func validateRefusesAWrongKindWithAReadableReason() {
    let dir = scratch(); defer { try? FileManager.default.removeItem(at: dir) }
    let filter = SZFileTypeFilter(extensions: ["mlpackage", "mlmodelc"])
    guard let ns = reason(filter, file(dir, "Depth.mlmodel")) else {
        Issue.record("a wrong-kind file must be refused")
        return
    }
    let said = ns.userInfo[NSLocalizedDescriptionKey] as? String
    let suggested = ns.userInfo[NSLocalizedRecoverySuggestionErrorKey] as? String
    #expect(said?.contains("Depth.mlmodel") == true)
    #expect(suggested == "Choose a .mlpackage or .mlmodelc file.")
}

@MainActor
@Test func validateAcceptsADeclaredExtension() {
    let dir = scratch(); defer { try? FileManager.default.removeItem(at: dir) }
    let filter = SZFileTypeFilter(extensions: ["mlpackage"])
    let accepted = validates(filter, file(dir, "Depth.mlpackage"))
    #expect(accepted)
}
