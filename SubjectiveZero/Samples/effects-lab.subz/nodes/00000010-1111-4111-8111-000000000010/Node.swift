// Chromatic Aberration — splits the RGB channels radially from a center, faking lens color fringing.
// SAMPLED render template: a full-screen triangle samples the input with a linear sampler. Red samples
// outward, blue inward, green stays put — the offset grows with distance from `center` and `amount`.
@preconcurrency import Metal

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
        fragment float4 f_main(VOut in [[stage_in]],
                               texture2d<float> tex     [[texture(0)]],
                               constant float  &amount  [[buffer(0)]],
                               constant float2 &center  [[buffer(1)]]) {
            constexpr sampler smp(filter::linear, address::clamp_to_edge);
            float2 uv = in.uv;
            float2 dir = uv - center;
            float2 off = dir * amount;
            float r = tex.sample(smp, uv + off).r;
            float g = tex.sample(smp, uv).g;
            float b = tex.sample(smp, uv - off).b;
            return float4(r, g, b, tex.sample(smp, uv).a);
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

        var amount = ctx.inputFloat("amount") ?? 0.01
        let c = ctx.inputFloats("center") ?? [0.5, 0.5]
        var center = SIMD2<Float>(c.count > 0 ? c[0] : 0.5, c.count > 1 ? c[1] : 0.5)
        encoder.setFragmentBytes(&amount, length: MemoryLayout<Float>.size, index: 0)
        encoder.setFragmentBytes(&center, length: MemoryLayout<SIMD2<Float>>.size, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }
}

enum SZNodeMain { static func make() -> SZNode { Node() } }
