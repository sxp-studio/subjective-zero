// cube — the "Cube" library node (NODE_LIBRARY.md). A GPU source: renders a spinning, lit 3D cube on
// black into the output texture — the library's first real render pass WITH a depth buffer. Built for
// beat-driven visuals: wire impulse-envelope values into `punch` (scale pop) and `flash` (brightness
// pop), layer it over a gradient with blend's screen mode. `reuse: copy-as-is`.
//
// Geometry lives in the shader as constants (8 corners, 36 indices, 6 face normals) indexed by
// vertex_id — no vertex buffer. Rotation angles derive purely from ctx.time (rewind-safe); lighting is
// flat facets + cheap lambert computed per vertex. The depth texture is node-private scratch (the
// gaussian-blur pattern), rebuilt lazily when the output size changes.
import Metal
import simd

private let kShader = """
#include <metal_stdlib>
using namespace metal;

struct U { float4x4 mvp; float4x4 model; float4 color; };

constant float3 corners[8] = {
    float3(-1,-1,-1), float3( 1,-1,-1), float3( 1, 1,-1), float3(-1, 1,-1),
    float3(-1,-1, 1), float3( 1,-1, 1), float3( 1, 1, 1), float3(-1, 1, 1)
};
// two ccw triangles per face: front +z, back -z, right +x, left -x, top +y, bottom -y
constant ushort idx[36] = {
    4,5,6, 4,6,7,  1,0,3, 1,3,2,  5,1,2, 5,2,6,
    0,4,7, 0,7,3,  3,7,6, 3,6,2,  0,1,5, 0,5,4
};
constant float3 normals[6] = {
    float3(0,0,1), float3(0,0,-1), float3(1,0,0), float3(-1,0,0), float3(0,1,0), float3(0,-1,0)
};

struct VOut { float4 position [[position]]; float4 color; };

vertex VOut cube_vertex(uint vid [[vertex_id]], constant U &u [[buffer(0)]]) {
    float3 p = corners[idx[vid]];
    float3 n = normalize((u.model * float4(normals[vid / 6], 0)).xyz);
    float lit = 0.35 + 0.65 * max(0.0, (float)dot(n, normalize(float3(0.4, 0.7, 0.6))));
    VOut out;
    out.position = u.mvp * float4(p, 1);
    out.color = float4(u.color.rgb * lit, 1);
    return out;
}

fragment float4 cube_fragment(VOut in [[stage_in]]) { return in.color; }
"""

private struct Uniforms {
    var mvp: simd_float4x4
    var model: simd_float4x4
    var color: SIMD4<Float>
}

final class Node: SZNode {
    private var pipeline: MTLRenderPipelineState?
    private var depthState: MTLDepthStencilState?
    private var depthTexture: MTLTexture?
    private var setupError: String?

    func setup(_ ctx: SZSetupContext) {
        do {
            let library = try ctx.device.makeLibrary(source: kShader, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "cube_vertex")
            descriptor.fragmentFunction = library.makeFunction(name: "cube_fragment")
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            descriptor.depthAttachmentPixelFormat = .depth32Float
            pipeline = try ctx.device.makeRenderPipelineState(descriptor: descriptor)

            let depth = MTLDepthStencilDescriptor()
            depth.depthCompareFunction = .less
            depth.isDepthWriteEnabled = true
            depthState = ctx.device.makeDepthStencilState(descriptor: depth)
        } catch {
            setupError = "Cube could not build its render pipeline: \(error.localizedDescription)"
        }
    }

    func update(_ ctx: SZFrameContext) {
        if let setupError { ctx.reportError(setupError) }
        guard let out = ctx.outputTexture("output"), let pipeline, let depthState else { return }

        // node-private depth scratch, rebuilt when the render size changes (hot-reload drops it too).
        if depthTexture == nil || depthTexture?.width != out.width || depthTexture?.height != out.height {
            let d = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .depth32Float, width: out.width, height: out.height, mipmapped: false)
            d.usage = [.renderTarget]
            d.storageMode = .private
            depthTexture = ctx.device.makeTexture(descriptor: d)
        }
        guard let depthTexture else { return }

        let spin = ctx.inputFloat("spin") ?? 0.25
        let size = ctx.inputFloat("size") ?? 0.6
        let punch = max(0, ctx.inputFloat("punch") ?? 0)
        let flash = max(0, ctx.inputFloat("flash") ?? 0)
        let hue = ctx.inputFloat("hue") ?? 0.6

        // angles purely from the graph clock: rewinding time rewinds the cube, no dt bookkeeping.
        let t = Float(ctx.time)
        let yaw = 2 * Float.pi * spin * t
        let pitch = 0.45 + 0.3 * sinf(0.7 * t)
        let scale = size * (1 + punch)
        let model = Self.translation(z: -3) * Self.rotationY(yaw) * Self.rotationX(pitch) * Self.scale(scale)
        let aspect = Float(out.width) / Float(max(1, out.height))
        let mvp = Self.perspective(fovY: 0.9, aspect: aspect, near: 0.1, far: 10) * model

        var uniforms = Uniforms(mvp: mvp, model: model, color: SIMD4(Self.hsv(hue) * (1 + flash), 1))

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = out
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        pass.depthAttachment.texture = depthTexture
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.clearDepth = 1
        pass.depthAttachment.storeAction = .dontCare
        guard let encoder = ctx.commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        defer { encoder.endEncoding() }
        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(depthState)
        encoder.setFrontFacing(.counterClockwise)
        encoder.setCullMode(.back)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 36)
    }

    // MARK: matrices (column-major, metal clip space with depth 0..1)

    private static func perspective(fovY: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
        let ys = 1 / tanf(fovY * 0.5)
        let xs = ys / aspect
        let zs = far / (near - far)
        return simd_float4x4(columns: (
            SIMD4(xs, 0, 0, 0), SIMD4(0, ys, 0, 0), SIMD4(0, 0, zs, -1), SIMD4(0, 0, zs * near, 0)))
    }

    private static func rotationY(_ a: Float) -> simd_float4x4 {
        let c = cosf(a), s = sinf(a)
        return simd_float4x4(columns: (
            SIMD4(c, 0, -s, 0), SIMD4(0, 1, 0, 0), SIMD4(s, 0, c, 0), SIMD4(0, 0, 0, 1)))
    }

    private static func rotationX(_ a: Float) -> simd_float4x4 {
        let c = cosf(a), s = sinf(a)
        return simd_float4x4(columns: (
            SIMD4(1, 0, 0, 0), SIMD4(0, c, s, 0), SIMD4(0, -s, c, 0), SIMD4(0, 0, 0, 1)))
    }

    private static func translation(z: Float) -> simd_float4x4 {
        var m = matrix_identity_float4x4
        m.columns.3.z = z
        return m
    }

    private static func scale(_ s: Float) -> simd_float4x4 {
        simd_float4x4(diagonal: SIMD4(s, s, s, 1))
    }

    /// hue 0..1 -> rgb at fixed saturation 0.75 / value 1 (the classic hsv wedge walk).
    private static func hsv(_ hue: Float) -> SIMD3<Float> {
        guard hue.isFinite else { return SIMD3(1, 0.25, 0.25) }   // Int(NaN) traps; wired inputs arrive raw
        let h = (hue - floorf(hue)) * 6
        let f = h - floorf(h)
        let s: Float = 0.75
        let p: Float = 1 - s
        let q = 1 - s * f
        let u = 1 - s * (1 - f)
        switch Int(h) % 6 {
        case 0: return SIMD3(1, u, p)
        case 1: return SIMD3(q, 1, p)
        case 2: return SIMD3(p, 1, u)
        case 3: return SIMD3(p, q, 1)
        case 4: return SIMD3(u, p, 1)
        default: return SIMD3(1, p, q)
        }
    }
}

enum SZNodeMain { static func make() -> SZNode { Node() } }
