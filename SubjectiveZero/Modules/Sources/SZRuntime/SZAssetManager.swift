// SPDX-License-Identifier: AGPL-3.0-only
// Owns the app's single Metal device + command queue and allocates GPU resources (RUNTIME.md:
// "All MTLBuffer/MTLTexture allocation goes through the runtime's asset manager").
//
// Ownership doctrine (settled): the runtime owns *by id* only what must cross an **edge**, a **frame**,
// or the **display** — declared node outputs, the render endpoint, and persistent/feedback textures.
// **Node-private scratch stays node-side** (allocated straight from the device); the runtime doesn't
// track it. That keeps this object small.
//
// The pool is a **by-id texture pool** — one texture per
// "<nodeID>:<port>" key, reallocated only when the viewport size changes. The scheduler writes a node's
// declared outputs into these and binds a downstream node's inputs to the same id. Textures are `.shared`
// (so capture reads them back directly on Apple Silicon) with `[.renderTarget, .shaderRead, .shaderWrite]`
// usage so a node may clear them (render pass), sample them, or compute-write them.
//
// Not yet here (earned, not scheduled): recycled/aliased transient pooling, an explicit persistent-vs-
// transient split, `persistentTexture(id:)` survival across reload, and buffers — they land when a
// feedback node (or memory pressure) forces them.
import Metal

final class SZAssetManager {
    let device: any MTLDevice
    let commandQueue: any MTLCommandQueue
    private var pool: [String: any MTLTexture] = [:]

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.commandQueue = queue
    }

    /// The pooled texture for `id`, (re)allocated only when its size/format changes. Same id ⇒ same
    /// texture, so a downstream node reading an upstream output id gets the texture the upstream wrote.
    func texture(
        id: String,
        width: Int,
        height: Int,
        pixelFormat: MTLPixelFormat = .bgra8Unorm
    ) -> any MTLTexture {
        let w = max(1, width), h = max(1, height)
        if let existing = pool[id], existing.width == w, existing.height == h, existing.pixelFormat == pixelFormat {
            return existing
        }
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat, width: w, height: h, mipmapped: false
        )
        desc.usage = [.renderTarget, .shaderRead, .shaderWrite]
        desc.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: desc) else {
            preconditionFailure("SZAssetManager: failed to allocate \(w)×\(h) texture for \(id)")
        }
        pool[id] = texture
        return texture
    }

    /// Drop all pooled textures (e.g. when loading a different graph).
    func reset() {
        pool.removeAll()
    }
}
