// SPDX-License-Identifier: AGPL-3.0-only
// The app half of web thumbnails. The page posts one BGRA atlas per tick (`SZWebSchemeHandler` hands
// the body here on the main thread) and, whenever its watched set changes, a layout message naming
// the tile each "<node>:<port>" key occupies. Off the main thread, every tile is row-copied into the
// back surface of that key's double-buffered IOSurface pair and the fronts are published as
// `SZNodePreviewSurface`s: the same frames the Metal stream publishes, so the cards never learn
// which renderer drew them. A body that arrives while the previous one still waits is dropped; the
// next tick brings a fresh atlas anyway.
import Foundation
import IOSurface
import SZCore
import Synchronization

final class SZWebPreviewSink: @unchecked Sendable {
    /// One key's place in the atlas: `y` is the tile's first row in the bytes as they arrive, and the
    /// page draws so that those rows run top-down.
    private struct Tile {
        let key: String
        let node: SZNodeID
        let port: String
        let x: Int, y: Int, width: Int, height: Int
    }

    private struct Layout {
        let id: Int
        let width: Int, height: Int
        let tiles: [Tile]
    }

    /// Two surfaces per key: the compositor may still read `front`, so the copy lands in the other.
    private final class Pair {
        let surfaces: (IOSurface, IOSurface)
        let width: Int, height: Int
        var front = 0

        init?(width: Int, height: Int) {
            guard let a = SZNodePreviewSurface.makeSurface(width: width, height: height),
                  let b = SZNodePreviewSurface.makeSurface(width: width, height: height) else { return nil }
            surfaces = (a, b)
            self.width = width
            self.height = height
        }

        func surface(at index: Int) -> IOSurface { index == 0 ? surfaces.0 : surfaces.1 }
    }

    private let queue = DispatchQueue(label: "studio.sxp.subz.web-previews")
    /// A body handed to the queue and not yet copied.
    private let pending = Atomic<Bool>(false)
    private let callback = Mutex<(@Sendable ([SZNodePreviewSurface]) -> Void)?>(nil)
    // Queue-confined from here on.
    private var layout: Layout?
    private var pairs: [String: Pair] = [:]

    /// The publish sink; fires on the sink's queue.
    var onFrames: (@Sendable ([SZNodePreviewSurface]) -> Void)? {
        get { callback.withLock { $0 } }
        set { callback.withLock { $0 = newValue } }
    }

    /// The page's `previewLayout` message: `layout` id, atlas `width`/`height`, parallel `keys` and
    /// `cells` ({x, y, w, h}). Pairs for keys no longer watched are dropped.
    func setLayout(from message: [String: Any]) {
        guard let id = message["layout"] as? Int, let width = message["width"] as? Int,
              let height = message["height"] as? Int, let keys = message["keys"] as? [String],
              let cells = message["cells"] as? [[String: Any]], keys.count == cells.count else { return }
        var tiles: [Tile] = []
        for (key, cell) in zip(keys, cells) {
            guard let colon = key.firstIndex(of: ":"), let node = UUID(uuidString: String(key[..<colon])),
                  let x = cell["x"] as? Int, let y = cell["y"] as? Int,
                  let w = cell["w"] as? Int, let h = cell["h"] as? Int, w > 0, h > 0,
                  x >= 0, y >= 0, x + w <= width, y + h <= height else { continue }
            tiles.append(Tile(key: key, node: node, port: String(key[key.index(after: colon)...]),
                              x: x, y: y, width: w, height: h))
        }
        let next = Layout(id: id, width: width, height: height, tiles: tiles)
        queue.async { [self] in
            layout = next
            let live = Set(tiles.map(\.key))
            pairs = pairs.filter { live.contains($0.key) }
        }
    }

    /// One posted atlas (`subz://app/previews?layout=N&seq=M`). Cheap on the caller's thread: a flag and
    /// a dispatch.
    func receive(_ body: Data, url: URL) {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let layoutID = items.first(where: { $0.name == "layout" })?.value.flatMap(Int.init) else { return }
        guard pending.compareExchange(expected: false, desired: true, ordering: .acquiringAndReleasing).exchanged
        else { return }
        queue.async { [self] in
            pending.store(false, ordering: .releasing)
            copy(body, layoutID: layoutID)
        }
    }

    private func copy(_ body: Data, layoutID: Int) {
        guard let layout, layout.id == layoutID, body.count == layout.width * layout.height * 4 else { return }
        var frames: [SZNodePreviewSurface] = []
        body.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            for tile in layout.tiles {
                guard let pair = pair(for: tile) else { continue }
                let back = 1 - pair.front
                let surface = pair.surface(at: back)
                guard surface.lock(options: [], seed: nil) == KERN_SUCCESS else { continue }
                let rowBytes = tile.width * 4
                for row in 0..<tile.height {
                    let src = base + ((tile.y + row) * layout.width + tile.x) * 4
                    memcpy(surface.baseAddress + row * surface.bytesPerRow, src, rowBytes)
                }
                surface.unlock(options: [], seed: nil)
                pair.front = back
                frames.append(SZNodePreviewSurface(node: tile.node, port: tile.port, surface: surface))
            }
        }
        guard !frames.isEmpty, let publish = onFrames else { return }
        publish(frames)
    }

    /// The key's pair, made (or remade after a size change) on demand.
    private func pair(for tile: Tile) -> Pair? {
        if let pair = pairs[tile.key], pair.width == tile.width, pair.height == tile.height { return pair }
        guard let pair = Pair(width: tile.width, height: tile.height) else { return nil }
        pairs[tile.key] = pair
        return pair
    }
}
