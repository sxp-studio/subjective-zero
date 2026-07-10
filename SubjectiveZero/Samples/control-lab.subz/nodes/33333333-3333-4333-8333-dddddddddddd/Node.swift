// Control Zoo — completes the control-lab playground with every VALUE widget Pattern Source doesn't
// exercise: a plain numeric field (`scale`), component fields (`offset` float2, `background` float3,
// `corners` float4), and the read-only chips (`fill` colorRGB, `ring` colorRGBA, `colorMatrix`
// float3x3, `gain` float4x4). All of them cross the v3 scalar channel (`inputFloats`), so editing any
// field visibly moves the render: a filled disc + ring offset over a corner-weighted background,
// finished through the color matrix and the gain diagonal. One texture output.
//
// It also exercises the one control the scalar widgets don't reach: `path`, a `filePicker` string on
// the v4 string channel (`inputString`). Its bytes hash to a stable 0..1 seed that rotates the output
// hue, so choosing a different file visibly repaints the palette (empty path → seed 0 → no rotation).
@preconcurrency import Metal
import simd

final class Node: SZNode {
    private var pipeline: MTLRenderPipelineState?

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
        // p[0] = offset.xy, scale, pathSeed       p[1] = background.rgb   p[2] = corners (tl tr bl br)
        // p[3] = fill.rgb                        p[4] = ring.rgba
        // p[5..7] = colorMatrix rows             p[8] = gain diagonal
        // Rotate `col`'s hue by `angle` radians about the (1,1,1) achromatic axis — angle 0 is identity.
        float3 hueRotate(float3 col, float angle) {
            const float3 k = float3(0.57735026);   // 1/sqrt(3), the neutral axis
            float c = cos(angle), s = sin(angle);
            return col * c + cross(k, col) * s + k * dot(k, col) * (1.0 - c);
        }
        fragment float4 f_main(VOut in [[stage_in]], constant float4 *p [[buffer(0)]]) {
            float2 uv = in.uv;
            float w = mix(mix(p[2].x, p[2].y, uv.x), mix(p[2].z, p[2].w, uv.x), uv.y);
            float3 col = p[1].rgb * (0.35 + 0.65 * w);
            float d = distance(uv, float2(0.5) + p[0].xy);
            float scale = max(p[0].z, 0.001);
            if (d < scale) { col = p[3].rgb; }
            float ringEdge = fabs(d - scale);
            if (ringEdge < 0.015) { col = mix(col, p[4].rgb, p[4].a); }
            col = float3(dot(p[5].xyz, col), dot(p[6].xyz, col), dot(p[7].xyz, col));
            col = hueRotate(col, p[0].w * 6.2831853);   // pathSeed 0..1 → full hue turn
            return float4(col, 1.0) * p[8];
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
        guard let out = ctx.outputTexture("texture"), let pipeline else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = out
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = ctx.commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        defer { encoder.endEncoding() }

        // Every input rides the v3 scalar channel — vectors/colors/matrices arrive as flat floats.
        let scale = ctx.inputFloat("scale") ?? 0.35
        let offset = vec(ctx.inputFloats("offset"), count: 2, or: [0.15, -0.1])
        let background = vec(ctx.inputFloats("background"), count: 3, or: [0.05, 0.07, 0.12])
        let corners = vec(ctx.inputFloats("corners"), count: 4, or: [1, 0.6, 0.8, 0.4])
        let fill = vec(ctx.inputFloats("fill"), count: 3, or: [0.2, 0.9, 0.6])
        let ring = vec(ctx.inputFloats("ring"), count: 4, or: [1, 0.3, 0.2, 0.85])
        let m3 = vec(ctx.inputFloats("colorMatrix"), count: 9, or: [1, 0, 0, 0, 1, 0, 0, 0, 1])
        let m4 = vec(ctx.inputFloats("gain"), count: 16,
                     or: [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1])
        // The filePicker `path` rides the v4 string channel, not the scalar one — hash it to a stable
        // 0..1 seed the shader turns into a hue rotation (empty path → 0 → the render's base palette).
        let pathSeed = Self.seed(from: ctx.inputString("path") ?? "")

        var params: [SIMD4<Float>] = [
            SIMD4(offset[0], offset[1], scale, pathSeed),
            SIMD4(background[0], background[1], background[2], 0),
            SIMD4(corners[0], corners[1], corners[2], corners[3]),
            SIMD4(fill[0], fill[1], fill[2], 0),
            SIMD4(ring[0], ring[1], ring[2], ring[3]),
            SIMD4(m3[0], m3[1], m3[2], 0),                     // colorMatrix rows (row-major)
            SIMD4(m3[3], m3[4], m3[5], 0),
            SIMD4(m3[6], m3[7], m3[8], 0),
            SIMD4(m4[0], m4[5], m4[10], m4[15]),               // gain diagonal
        ]
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&params, length: MemoryLayout<SIMD4<Float>>.stride * params.count, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }

    /// The port's floats padded/truncated to `count` (host may deliver fewer while a default is unset).
    private func vec(_ values: [Float]?, count: Int, or fallback: [Float]) -> [Float] {
        let v = values ?? fallback
        return (0..<count).map { $0 < v.count ? v[$0] : fallback[$0] }
    }

    /// A stable 0..1 seed from a path string via a deterministic djb2 hash — NOT `String.hashValue`,
    /// which is per-run randomized and would make the hue flicker between launches. Empty path → 0.
    private static func seed(from path: String) -> Float {
        if path.isEmpty { return 0 }
        var hash: UInt64 = 5381
        for byte in path.utf8 { hash = (hash &* 33) &+ UInt64(byte) }
        return Float(hash % 1000) / 1000
    }
}

enum SZNodeMain { static func make() -> SZNode { Node() } }
