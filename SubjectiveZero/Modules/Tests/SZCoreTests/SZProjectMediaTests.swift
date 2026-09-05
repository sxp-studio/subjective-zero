// SPDX-License-Identifier: AGPL-3.0-only
// THE RULE (SZProjectMedia): a file port's value resolves against the project bundle unless it is
// already absolute. Both branches matter — the relative one is what makes a `.subz` portable, the
// absolute one is what keeps a project written before that still rendering.
import Foundation
import Testing
@testable import SZCore

private let bundle = URL(fileURLWithPath: "/Volumes/Work/Patches/Depth.subz")

@Test func anUnsetFilePortStaysUnset() {
    #expect(SZProjectMedia.resolve("", in: bundle) == "")
    #expect(!SZProjectMedia.needsImport("", in: bundle))
}

@Test func aBundleRelativeValueJoinsTheProject() {
    #expect(SZProjectMedia.resolve("media/ABC/IMG_2479.MOV", in: bundle)
            == "/Volumes/Work/Patches/Depth.subz/media/ABC/IMG_2479.MOV")
}

@Test func anAbsolutePathResolvesToItself() {
    #expect(SZProjectMedia.resolve("/Users/c/Downloads/IMG.MOV", in: bundle) == "/Users/c/Downloads/IMG.MOV")
}

@Test func aTildePathIsExpandedRatherThanJoinedToTheBundle() {
    let resolved = SZProjectMedia.resolve("~/Downloads/IMG.MOV", in: bundle)
    #expect(resolved.hasPrefix("/"))
    #expect(!resolved.contains("Depth.subz"))
    #expect(resolved.hasSuffix("/Downloads/IMG.MOV"))
}

@Test func aFileAlreadyInsideTheBundleIsRecognisedAndNeverReimported() {
    let inside = bundle.appending(path: "media/ABC/IMG.MOV")
    #expect(SZProjectMedia.relativePath(for: inside, in: bundle) == "media/ABC/IMG.MOV")
    #expect(!SZProjectMedia.needsImport(inside.path, in: bundle))
    // …and neither is the relative form it will actually be stored as.
    #expect(!SZProjectMedia.needsImport("media/ABC/IMG.MOV", in: bundle))
}

/// The chat owns `attachments/`; a node that shows one of its files gets its own copy in `media/`.
@Test func aChatAttachmentIsBroughtIntoMedia() {
    let inside = bundle.appending(path: "attachments/53723509/IMG_3171.jpg")
    #expect(SZProjectMedia.relativePath(for: inside, in: bundle) == "attachments/53723509/IMG_3171.jpg")
    #expect(SZProjectMedia.isAttachment("attachments/53723509/IMG_3171.jpg"))
    #expect(SZProjectMedia.needsImport(inside.path, in: bundle))
    #expect(SZProjectMedia.needsImport("attachments/53723509/IMG_3171.jpg", in: bundle))
    #expect(!SZProjectMedia.isAttachment("media/ABC/attachments.jpg"))
}

@Test func aFileOutsideTheBundleIsBroughtIn() {
    #expect(SZProjectMedia.relativePath(for: URL(fileURLWithPath: "/Users/c/Downloads/IMG.MOV"), in: bundle) == nil)
    #expect(SZProjectMedia.needsImport("/Users/c/Downloads/IMG.MOV", in: bundle))
}

/// A sibling directory that merely SHARES the bundle's name prefix is not inside it.
@Test func aPrefixNeighbourIsNotInsideTheBundle() {
    let neighbour = URL(fileURLWithPath: "/Volumes/Work/Patches/Depth.subz.bak/IMG.MOV")
    #expect(SZProjectMedia.relativePath(for: neighbour, in: bundle) == nil)
    #expect(SZProjectMedia.needsImport(neighbour.path, in: bundle))
}

@Test func aDestinationKeepsTheExactFilenameUnderItsOwnDirectory() {
    let (relative, url) = SZProjectMedia.destination(for: "IMG 2479.MOV", in: bundle)
    #expect(relative.hasPrefix("media/"))
    #expect(relative.hasSuffix("/IMG 2479.MOV"))
    #expect(url.path == bundle.appending(path: relative).path)
    // Two picks of the same filename never collide.
    #expect(SZProjectMedia.destination(for: "IMG 2479.MOV", in: bundle).relative != relative)
}

// MARK: - The graph projection

private func graph(port: SZPort) -> SZGraph {
    SZGraph(nodes: [SZNode(kind: .generated, title: "Video File",
                           contract: SZNodeContract(title: "Video File", sfSymbol: "film", summary: "", inputs: [port]),
                           position: SZPoint(x: 0, y: 0))])
}

private func firstDefault(_ g: SZGraph) -> SZPortValue? { g.nodes[0].contract?.inputs[0].def }

@Test func theProjectionResolvesOnlyFilePorts() {
    let file = SZPort(name: "path", type: .string, ui: SZPortUI(kind: .filePicker),
                      def: .string("media/ABC/IMG.MOV"))
    #expect(firstDefault(graph(port: file).resolvingFilePaths(in: bundle))
            == .string("/Volumes/Work/Patches/Depth.subz/media/ABC/IMG.MOV"))

    // A plain string port carrying the same text is NOT a path.
    let text = SZPort(name: "label", type: .string, ui: SZPortUI(kind: .field),
                      def: .string("media/ABC/IMG.MOV"))
    #expect(firstDefault(graph(port: text).resolvingFilePaths(in: bundle)) == .string("media/ABC/IMG.MOV"))
}

@Test func theProjectionLeavesTheModelItselfAlone() {
    let g = graph(port: SZPort(name: "path", type: .string, ui: SZPortUI(kind: .filePicker),
                               def: .string("media/ABC/IMG.MOV")))
    _ = g.resolvingFilePaths(in: bundle)
    #expect(firstDefault(g) == .string("media/ABC/IMG.MOV"))   // value semantics: the source is untouched
}

@Test func theProjectionSurvivesAFilePortWithNoValue() {
    let g = graph(port: SZPort(name: "path", type: .string, ui: SZPortUI(kind: .filePicker), def: .string("")))
    #expect(firstDefault(g.resolvingFilePaths(in: bundle)) == .string(""))
}
