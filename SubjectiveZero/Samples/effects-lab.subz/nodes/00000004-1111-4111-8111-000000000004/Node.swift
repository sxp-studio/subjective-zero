// Checkerboard — a two-color checkerboard pattern texture source (no input texture).
// Render-pass template: a full-screen triangle whose fragment shader tiles UV space into `scale`
// cells per axis and mixes colorA↔colorB on the parity of the cell. All controls live-tunable.
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
                               constant float  &scale  [[buffer(0)]],
                               constant float4 &colorA [[buffer(1)]],
                               constant float4 &colorB [[buffer(2)]]) {
            float2 uv = in.uv;
            float c = fmod(floor(uv.x * scale) + floor(uv.y * scale), 2.0);
            return mix(colorA, colorB, c);
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
        guard let out = ctx.outputTexture("output"), let pipeline else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = out
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = ctx.commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        defer { encoder.endEncoding() }
        encoder.setRenderPipelineState(pipeline)

        var scale = ctx.inputFloat("scale") ?? 8.0
        var colorA = simd4(ctx.inputFloats("colorA"), fallback: [0, 0, 0, 1])
        var colorB = simd4(ctx.inputFloats("colorB"), fallback: [1, 1, 1, 1])
        encoder.setFragmentBytes(&scale, length: MemoryLayout<Float>.size, index: 0)
        encoder.setFragmentBytes(&colorA, length: MemoryLayout<SIMD4<Float>>.size, index: 1)
        encoder.setFragmentBytes(&colorB, length: MemoryLayout<SIMD4<Float>>.size, index: 2)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }

    private func simd4(_ v: [Float]?, fallback: [Float]) -> SIMD4<Float> {
        let a = (v?.count ?? 0) >= 4 ? v! : fallback
        return SIMD4<Float>(a[0], a[1], a[2], a[3])
    }
}

enum SZNodeMain { static func make() -> SZNode { Node() } }
