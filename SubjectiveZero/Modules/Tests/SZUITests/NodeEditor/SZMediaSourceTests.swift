// SPDX-License-Identifier: AGPL-3.0-only
// The media-file classifier + card placement shared by the canvas drop handler and `ui_add_source_node`.
// Both paths call these, so a change here moves the human and the agent together — which is the point of
// having lifted them out of the SwiftUI drop handler, where nothing could reach them.
import Foundation
import Testing
@testable import SZCore
@testable import SZUI

private func url(_ name: String) -> URL { URL(fileURLWithPath: "/tmp/\(name)") }

// MARK: - classification

@Test func imagesResolveToTheImageFileNode() {
    for name in ["a.png", "a.jpg", "a.jpeg", "a.heic", "a.gif", "a.tiff", "a.webp"] {
        #expect(SZMediaSource.libraryID(for: url(name)) == "image-file", "\(name)")
    }
}

@Test func moviesResolveToTheVideoFileNode() {
    for name in ["a.mov", "a.mp4", "a.m4v"] {
        #expect(SZMediaSource.libraryID(for: url(name)) == "video-file", "\(name)")
    }
}

@Test func nonMediaAndExtensionlessFilesResolveToNothing() {
    for name in ["a.txt", "a.subz", "README", "a.qqq"] {
        #expect(SZMediaSource.libraryID(for: url(name)) == nil, "\(name)")
    }
}

@Test func audioIsIgnoredEvenThoughItIsAudiovisualContent() {
    // `public.audio` conforms to `.audiovisualContent`, so audio used to fall through to `video-file` —
    // a node with no video track, holding the viewport. There is no library node that reads audio.
    for name in ["a.wav", "a.mp3", "a.aiff", "a.m4a"] {
        #expect(SZMediaSource.libraryID(for: url(name)) == nil, "\(name)")
    }
}

@Test func classificationIsCaseInsensitiveLikeTheFinder() {
    #expect(SZMediaSource.libraryID(for: url("A.PNG")) == "image-file")
    #expect(SZMediaSource.libraryID(for: url("A.MOV")) == "video-file")
}

// MARK: - placement

@Test func specsStaggerSuccessiveCardsDownRight() {
    let specs = SZMediaSource.specs(for: [url("a.png"), url("b.mov"), url("c.jpg")],
                                    origin: SZPoint(x: 100, y: 200))
    #expect(specs.map(\.libraryID) == ["image-file", "video-file", "image-file"])
    #expect(specs.map(\.position.x) == [100, 132, 164])
    #expect(specs.map(\.position.y) == [200, 232, 264])
    #expect(specs.map(\.path) == ["/tmp/a.png", "/tmp/b.mov", "/tmp/c.jpg"])
}

@Test func aSkippedNonMediaFileLeavesNoGapInTheStagger() {
    // The offset counts cards CREATED, not urls seen — dragging a mixed folder must not scatter the
    // surviving cards across the gaps where the .txt files were.
    let specs = SZMediaSource.specs(for: [url("a.png"), url("notes.txt"), url("b.mov")],
                                    origin: SZPoint(x: 0, y: 0))
    #expect(specs.count == 2)
    #expect(specs.map(\.position.x) == [0, 32])
}

@Test func specsForNoMediaIsEmptySoTheDragBouncesBack() {
    #expect(SZMediaSource.specs(for: [url("a.txt")], origin: SZPoint(x: 0, y: 0)).isEmpty)
    #expect(SZMediaSource.specs(for: [], origin: SZPoint(x: 0, y: 0)).isEmpty)
}
