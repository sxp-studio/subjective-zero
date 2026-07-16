// SPDX-License-Identifier: AGPL-3.0-only
// The zero-copy node-preview stream's state: which (node, port) outputs are watched, and a
// double-buffered IOSurface target pair per watched port. The runtime encodes MPS downscales for
// the watched set onto the LIVE frame's command buffer (SZRuntime.encodePreviewPass) — no second
// buffer, no CPU wait, no readback — and the buffer's completion handler flips each pair's front
// and publishes the surfaces. The UI hands an IOSurface straight to `CALayer.contents`, so a thumb
// frame is GPU-composited end to end.
//
// Locking (the SZAssetManager convention): every `var` here is touched ONLY inside the engine lock.
// The completion handler — which runs on Metal's completion thread with no lock held — touches only
// the two atomics (`passInFlight`, each pair's `front`) and its captured payload.
import Foundation
import IOSurface
import Metal
import MetalPerformanceShaders
import Synchronization
import SZCore

/// One published thumb frame: the surface is the pair's freshly-completed buffer; CA composites it
/// directly. Alternating surfaces per pass is what makes `layer.contents` recomposite (identity
/// change), and what keeps the GPU's next write off the surface the compositor is reading.
public struct SZNodePreviewSurface: @unchecked Sendable {
    public let node: SZNodeID
    public let port: String
    public let surface: IOSurface
}

/// A watched port's double-buffered render target: two IOSurfaces, each wrapped by an
/// IOSurface-backed MTLTexture the MPS scaler writes into. `front` is the index the compositor may
/// be reading — the GPU always writes `1 - front`, and ONLY the completion handler flips it.
final class SZPreviewTargetPair: @unchecked Sendable {
    let surfaces: (IOSurface, IOSurface)
    let textures: (any MTLTexture, any MTLTexture)
    let width: Int, height: Int
    let front = Atomic<Int>(0)

    init?(device: any MTLDevice, width: Int, height: Int) {
        guard let s0 = Self.makeSurface(width: width, height: height),
              let s1 = Self.makeSurface(width: width, height: height),
              let t0 = Self.makeTexture(device: device, surface: s0, width: width, height: height),
              let t1 = Self.makeTexture(device: device, surface: s1, width: width, height: height)
        else { return nil }
        surfaces = (s0, s1)
        textures = (t0, t1)
        self.width = width
        self.height = height
    }

    func surface(at index: Int) -> IOSurface { index == 0 ? surfaces.0 : surfaces.1 }
    func texture(at index: Int) -> any MTLTexture { index == 0 ? textures.0 : textures.1 }

    /// A BGRA8 IOSurface sized for one thumb. Row bytes are alignment-rounded per IOSurface's own
    /// requirement (the Metal wrap below inherits the padding).
    private static func makeSurface(width: Int, height: Int) -> IOSurface? {
        let bytesPerRow = IOSurfaceAlignProperty(kIOSurfaceBytesPerRow as CFString, width * 4)
        return IOSurface(properties: [
            .width: width,
            .height: height,
            .bytesPerElement: 4,
            .bytesPerRow: bytesPerRow,
            .pixelFormat: UInt32(0x4247_5241),   // 'BGRA'
        ])
    }

    /// Wrap a surface as the MPS scale destination. `.shaderWrite` is what MPS requires of a
    /// destination; storage follows the device (IOSurface textures are `.shared` on unified-memory
    /// machines, `.managed` elsewhere).
    private static func makeTexture(device: any MTLDevice, surface: IOSurface,
                                    width: Int, height: Int) -> (any MTLTexture)? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        desc.usage = [.shaderWrite, .shaderRead]
        desc.storageMode = device.hasUnifiedMemory ? .shared : .managed
        return device.makeTexture(descriptor: desc, iosurface: surface, plane: 0)
    }
}

/// The stream's mutable state, hung off `EngineState` (a class so the completion handler can hold
/// it without copying engine state). See the file header for the locking contract.
final class SZPreviewStream: @unchecked Sendable {
    /// The watched (node, port) outputs, in host priority order.
    var watched: [(node: SZNodeID, port: String)] = []
    /// Long-edge pixels of a thumb target.
    var maxDimension = 320
    /// The host's publish sink. Fires on Metal's completion thread — see
    /// `SZRuntime.setPreviewFrameCallback` for the contract.
    var onFrames: (@Sendable ([SZNodePreviewSurface]) -> Void)?
    /// When the last pass was ATTEMPTED (not completed) — unwritten pools must not rescan at
    /// frame rate.
    var lastPass: TimeInterval = -.infinity
    /// Minimum seconds between passes (~15 Hz). Tests set 0 via `setPreviewThrottleForTests`.
    var minInterval: TimeInterval = 1.0 / 15
    /// The ONE reused scale kernel (allocating per pass was the old pipeline's lock-hold cost).
    var scaler: MPSImageBilinearScale?
    /// Target pairs keyed by `SZScheduler.textureID(node:port:)`.
    var pairs: [String: SZPreviewTargetPair] = [:]
    /// True from pass-encode until its completion handler ran; the next pass is SKIPPED while set,
    /// so at most one pass is ever in flight (this is what makes double buffering sufficient).
    let passInFlight = Atomic<Bool>(false)
}
