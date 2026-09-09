// Grid Warp — projection mapping onto a surface that isn't flat. The input is stretched over a 4×4
// net of control points (normalized output coordinates, y-down, (0,0) top-left … (1,1) bottom-right),
// row-major p00…p33; everything outside the mesh is black. Drag the points on the node's card
// (Card.swift) or set them by hand. corner-pin is the four-corner case of the same idea.
//
// MESH render template, not a sampled one: a quad has a closed-form inverse and a mesh does not, so
// this draws the surface as geometry instead of mapping each output pixel back. The vertex stage
// walks a 32×32 subdivision from `vertex_id` (no vertex buffer) and places each vertex with a
// clamped Catmull-Rom bicubic over the sixteen points, so the surface passes through every one of
// them and stays smooth across cell boundaries. The fragment stage samples the source at the
// vertex's regular (u, v).
@preconcurrency import Metal
import simd

final class Node: SZNode {
    /// Cells per side of the subdivision. 32 is smooth on a projector and 6144 vertices is nothing.
    private static let subdivisions = 32

    private var pipeline: MTLRenderPipelineState?

    func setup(_ ctx: SZSetupContext) {
        let source = """
        #include <metal_stdlib>
        using namespace metal;
        constant uint N = \(Self.subdivisions);
        struct VOut { float4 pos [[position]]; float2 uv; };

        // One uniform Catmull-Rom segment through b and c, with a and d as the neighbours.
        float2 cr_seg(float2 a, float2 b, float2 c, float2 d, float u) {
            return 0.5 * ((2.0 * b) + (-a + c) * u
                          + (2.0 * a - 5.0 * b + 4.0 * c - d) * u * u
                          + (-a + 3.0 * b - 3.0 * c + d) * u * u * u);
        }

        // The interpolating curve through all four points, t = 0 at p0 and 1 at p3. The ends are
        // clamped by reflecting a phantom neighbour, so the curve starts and ends where the points do.
        float2 cr4(float2 p0, float2 p1, float2 p2, float2 p3, float t) {
            float2 before = 2.0 * p0 - p1;
            float2 after = 2.0 * p3 - p2;
            float s = clamp(t, 0.0, 1.0) * 3.0;
            int i = int(min(floor(s), 2.0));
            float u = s - float(i);
            if (i == 0) return cr_seg(before, p0, p1, p2, u);
            if (i == 1) return cr_seg(p0, p1, p2, p3, u);
            return cr_seg(p1, p2, p3, after, u);
        }

        // The bicubic patch: interpolate along each row, then between the four results.
        float2 patch(constant float2 *p, float u, float v) {
            float2 r0 = cr4(p[0], p[1], p[2], p[3], u);
            float2 r1 = cr4(p[4], p[5], p[6], p[7], u);
            float2 r2 = cr4(p[8], p[9], p[10], p[11], u);
            float2 r3 = cr4(p[12], p[13], p[14], p[15], u);
            return cr4(r0, r1, r2, r3, v);
        }

        vertex VOut v_main(uint vid [[vertex_id]], constant float2 *points [[buffer(0)]]) {
            float2 corner[6] = { float2(0, 0), float2(1, 0), float2(0, 1),
                                 float2(1, 0), float2(1, 1), float2(0, 1) };
            uint cell = vid / 6u;
            float2 o = corner[vid % 6u];
            float u = (float(cell % N) + o.x) / float(N);
            float v = (float(cell / N) + o.y) / float(N);
            float2 p = patch(points, u, v);
            VOut out;
            out.pos = float4(p.x * 2.0 - 1.0, 1.0 - p.y * 2.0, 0.0, 1.0);
            out.uv = float2(u, v);
            return out;
        }

        fragment float4 f_main(VOut in [[stage_in]], texture2d<float> tex [[texture(0)]]) {
            constexpr sampler smp(filter::linear, address::clamp_to_edge);
            return tex.sample(smp, in.uv);
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

        let points = mesh(ctx)
        points.withUnsafeBytes { encoder.setVertexBytes($0.baseAddress!, length: $0.count, index: 0) }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0,
                               vertexCount: Self.subdivisions * Self.subdivisions * 6)
    }

    /// The sixteen points, row-major. Read one literal name at a time so the port audit can see them.
    private func mesh(_ ctx: SZFrameContext) -> [SIMD2<Float>] {
        [Self.point(ctx.inputFloats("p00"), 0, 0), Self.point(ctx.inputFloats("p01"), 0, 1),
         Self.point(ctx.inputFloats("p02"), 0, 2), Self.point(ctx.inputFloats("p03"), 0, 3),
         Self.point(ctx.inputFloats("p10"), 1, 0), Self.point(ctx.inputFloats("p11"), 1, 1),
         Self.point(ctx.inputFloats("p12"), 1, 2), Self.point(ctx.inputFloats("p13"), 1, 3),
         Self.point(ctx.inputFloats("p20"), 2, 0), Self.point(ctx.inputFloats("p21"), 2, 1),
         Self.point(ctx.inputFloats("p22"), 2, 2), Self.point(ctx.inputFloats("p23"), 2, 3),
         Self.point(ctx.inputFloats("p30"), 3, 0), Self.point(ctx.inputFloats("p31"), 3, 1),
         Self.point(ctx.inputFloats("p32"), 3, 2), Self.point(ctx.inputFloats("p33"), 3, 3)]
    }

    /// A control point, falling back to its place on the flat mesh when it is missing or not finite.
    private static func point(_ v: [Float]?, _ row: Int, _ column: Int) -> SIMD2<Float> {
        guard let v, v.count >= 2, v[0].isFinite, v[1].isFinite else {
            return SIMD2<Float>(Float(column) / 3, Float(row) / 3)
        }
        return SIMD2<Float>(v[0], v[1])
    }
}

enum SZNodeMain { static func make() -> SZNode { Node() } }
