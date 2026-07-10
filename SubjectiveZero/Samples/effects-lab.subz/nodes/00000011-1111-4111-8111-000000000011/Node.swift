// Edge Detect — a 3×3 Sobel on luminance; edges are colored, flat regions take the background color.
// SAMPLED render template: a full-screen triangle samples nine neighbors with a linear sampler (taps
// offset by `thickness * texelSize`), computes the gradient magnitude, and thresholds it via smoothstep.
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
                               texture2d<float> tex        [[texture(0)]],
                               constant float2 &texelSize  [[buffer(0)]],
                               constant float  &threshold  [[buffer(1)]],
                               constant float  &thickness  [[buffer(2)]],
                               constant float4 &edgeColor  [[buffer(3)]],
                               constant float4 &bgColor    [[buffer(4)]]) {
            constexpr sampler smp(filter::linear, address::clamp_to_edge);
            float2 t = texelSize * thickness;
            float lum[9];
            int idx = 0;
            for (int y = -1; y <= 1; y++) {
                for (int x = -1; x <= 1; x++) {
                    float3 c = tex.sample(smp, in.uv + float2(float(x), float(y)) * t).rgb;
                    lum[idx++] = dot(c, float3(0.299, 0.587, 0.114));
                }
            }
            float gx = -lum[0] + lum[2] - 2.0 * lum[3] + 2.0 * lum[5] - lum[6] + lum[8];
            float gy = -lum[0] - 2.0 * lum[1] - lum[2] + lum[6] + 2.0 * lum[7] + lum[8];
            float mag = length(float2(gx, gy));
            float e = smoothstep(threshold, threshold * 2.0, mag);
            return mix(bgColor, edgeColor, e);
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

        var texel = SIMD2<Float>(1.0 / Float(out.width), 1.0 / Float(out.height))
        var threshold = ctx.inputFloat("threshold") ?? 0.2
        var thickness = ctx.inputFloat("thickness") ?? 1.0
        var edgeColor = simd4(ctx.inputFloats("edgeColor"), fallback: [1, 1, 1, 1])
        var bgColor = simd4(ctx.inputFloats("bgColor"), fallback: [0, 0, 0, 1])
        encoder.setFragmentBytes(&texel, length: MemoryLayout<SIMD2<Float>>.size, index: 0)
        encoder.setFragmentBytes(&threshold, length: MemoryLayout<Float>.size, index: 1)
        encoder.setFragmentBytes(&thickness, length: MemoryLayout<Float>.size, index: 2)
        encoder.setFragmentBytes(&edgeColor, length: MemoryLayout<SIMD4<Float>>.size, index: 3)
        encoder.setFragmentBytes(&bgColor, length: MemoryLayout<SIMD4<Float>>.size, index: 4)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }

    private func simd4(_ v: [Float]?, fallback: [Float]) -> SIMD4<Float> {
        let a = (v?.count ?? 0) >= 4 ? v! : fallback
        return SIMD4<Float>(a[0], a[1], a[2], a[3])
    }
}

enum SZNodeMain { static func make() -> SZNode { Node() } }
