// SPDX-License-Identifier: AGPL-3.0-only
// Media files → source-node specs. The rules for "which library node reads this file, and where does its
// card land" used to live inside the node editor's drop handler, reachable only by a human dragging onto
// the canvas. They are lifted here so the drop path (SZNodeEditorPanel) and the MCP path
// (`ui_add_source_node`) share ONE classifier and ONE placement rule rather than drifting apart —
// the same reuse discipline the rest of the `ui_*` surface follows.
//
// Pure: classification reads the file EXTENSION only (never disk), so a caller holding a path that may
// not exist must check existence itself. A dropped file always exists; an agent-supplied path may not.
import Foundation
import SZCore
import UniformTypeIdentifiers

public enum SZMediaSource {
    /// Successive source cards step down-right by this much, so a multi-file drop doesn't stack them.
    public static let stagger: Double = 32

    /// The library node that reads `url`, or nil if we have nothing that does. Images (anything Image I/O
    /// decodes, `UTType.image`) → `image-file`; movies (`UTType.movie` / `.audiovisualContent`) →
    /// `video-file`. Anything else (audio, text, folders) → nil = ignored.
    public static func libraryID(for url: URL) -> String? {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return nil }
        if type.conforms(to: .image) { return "image-file" }
        // Audio must be rejected BEFORE the movie test: `public.audio` conforms to `.audiovisualContent`,
        // so an .mp3 would otherwise land on `video-file`, which has no video track to draw and would
        // take the viewport with it. `.audiovisualContent` still catches video containers that aren't
        // `public.movie`, which is why it can't simply be dropped.
        if type.conforms(to: .audio) { return nil }
        if type.conforms(to: .movie) || type.conforms(to: .audiovisualContent) { return "video-file" }
        return nil
    }

    /// Classify each url and place its card, staggering successive ones down-right from `origin`.
    /// Non-media files are skipped, and skipping one does NOT leave a gap in the stagger — the offset
    /// counts nodes actually created, matching what a user sees when they drag a folder's worth of mixed
    /// files onto the canvas.
    public static func specs(for urls: [URL], origin: SZPoint)
    -> [(libraryID: String, path: String, position: SZPoint)] {
        var specs: [(libraryID: String, path: String, position: SZPoint)] = []
        for url in urls {
            guard let libraryID = libraryID(for: url) else { continue }
            let offset = Double(specs.count) * stagger
            specs.append((libraryID, url.path, SZPoint(x: origin.x + offset, y: origin.y + offset)))
        }
        return specs
    }
}
