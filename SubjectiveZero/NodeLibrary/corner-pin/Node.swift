// Corner Pin — projection mapping. Warps the input onto the quadrilateral tl→tr→br→bl (normalized
// output coordinates, y-down, (0,0) top-left … (1,1) bottom-right); everything outside the quad is
// black. The four corners are the surface you're projecting onto — drag them on the node's card
// (Card.swift) or set them by hand.
//
// SAMPLED render template with an inverse homography: `update` solves the square→quad projective
// map on the CPU (Heckbert), inverts it, and the fragment shader maps each output pixel back into
// the source (0…1) space and samples there. Degenerate quads (three corners on a line, a corner
// dragged through the opposite edge) keep the last valid matrix instead of blowing up.
@preconcurrency import Metal
import simd

final class Node: SZNode {
    private var pipeline: MTLRenderPipelineState?
    private var inverse = matrix_identity_float3x3

    func setup(_ ctx: SZSetupContext) {
        let source = """
        #include <metal_stdlib>
        using namespace metal;
        struct VOut { float4 pos [[position]]; float2 uv; };
        vertex VOut v_main(uint vid [[vertex_id]]) {
            float2 p[3] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };
            VOut o;
            o.pos = float4(p[vid], 0, 1);
            o.uv = float2(o.pos.x * 0.5 + 0.5, 0.5 - o.pos.y * 0.5);
            return o;
        }
        fragment float4 f_main(VOut in [[stage_in]],
                               texture2d<float> tex      [[texture(0)]],
                               constant float3x3 &hinv   [[buffer(0)]]) {
            constexpr sampler smp(filter::linear, address::clamp_to_zero);
            float3 s = hinv * float3(in.uv, 1.0);
            if (s.z <= 0.0) return float4(0, 0, 0, 1);
            float2 src = s.xy / s.z;
            if (any(src < 0.0) || any(src > 1.0)) return float4(0, 0, 0, 1);
            return tex.sample(smp, src);
        }
        """
        guard let library = try? ctx.device.makeLibrary(source: source, options: nil) else { return }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "v_main")
        descriptor.fragmentFunction = library.makeFunction(name: "f_main")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipeline = try? ctx.device.makeRenderPipelineState(descriptor: descriptor)
    }

    func update(_ ctx: SZFrameContext) {
        guard let input = ctx.inputTexture("input"),
              let out = ctx.outputTexture("output"),
              let pipeline else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = out
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = ctx.commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        defer { encoder.endEncoding() }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(input, index: 0)

        if let h = Self.squareToQuad(
            tl: Self.corner(ctx.inputFloats("tl"), [0, 0]), tr: Self.corner(ctx.inputFloats("tr"), [1, 0]),
            br: Self.corner(ctx.inputFloats("br"), [1, 1]), bl: Self.corner(ctx.inputFloats("bl"), [0, 1])),
           let inv = Self.inverted(h) {
            inverse = inv
        }
        var hinv = inverse
        encoder.setFragmentBytes(&hinv, length: MemoryLayout<simd_float3x3>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }

    private static func corner(_ v: [Float]?, _ fallback: SIMD2<Float>) -> SIMD2<Float> {
        guard let v, v.count >= 2, v[0].isFinite, v[1].isFinite else { return fallback }
        return SIMD2<Float>(v[0], v[1])
    }

    /// The projective map taking the unit square (0,0)→tl, (1,0)→tr, (1,1)→br, (0,1)→bl. Column-major
    /// 3×3 acting on (u, v, 1) → (x·w, y·w, w). Nil when the quad is degenerate.
    static func squareToQuad(tl p0: SIMD2<Float>, tr p1: SIMD2<Float>,
                             br p2: SIMD2<Float>, bl p3: SIMD2<Float>) -> simd_float3x3? {
        let sx = p0.x - p1.x + p2.x - p3.x
        let sy = p0.y - p1.y + p2.y - p3.y
        var a, b, c, d, e, f, g, h: Float
        if abs(sx) < 1e-6 && abs(sy) < 1e-6 {
            // Parallelogram: an affine map.
            a = p1.x - p0.x; b = p2.x - p1.x; c = p0.x
            d = p1.y - p0.y; e = p2.y - p1.y; f = p0.y
            g = 0; h = 0
        } else {
            let dx1 = p1.x - p2.x, dx2 = p3.x - p2.x
            let dy1 = p1.y - p2.y, dy2 = p3.y - p2.y
            let den = dx1 * dy2 - dx2 * dy1
            guard abs(den) > 1e-8 else { return nil }
            g = (sx * dy2 - dx2 * sy) / den
            h = (dx1 * sy - sx * dy1) / den
            a = p1.x - p0.x + g * p1.x; b = p3.x - p0.x + h * p3.x; c = p0.x
            d = p1.y - p0.y + g * p1.y; e = p3.y - p0.y + h * p3.y; f = p0.y
        }
        return simd_float3x3(columns: (SIMD3(a, d, g), SIMD3(b, e, h), SIMD3(c, f, 1)))
    }

    /// The inverse map (output → source), nil for a singular or non-finite one — the caller keeps
    /// the last valid matrix so a corner dragged through a degenerate pose never renders garbage.
    static func inverted(_ m: simd_float3x3) -> simd_float3x3? {
        let det = simd_determinant(m)
        guard det.isFinite, abs(det) > 1e-9 else { return nil }
        let inv = m.inverse
        guard inv[0].x.isFinite, inv[1].y.isFinite, inv[2].z.isFinite else { return nil }
        return inv
    }
}

enum SZNodeMain { static func make() -> SZNode { Node() } }
