// Animated screen-space gradient — a camera-free, permission-free sample for easy visual debugging.
// Renders a time-animated rainbow gradient via a full-screen triangle (the classic cosine palette);
// no inputs, one texture output. Animation comes from `ctx.time` fed to the fragment shader.
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
        fragment float4 f_main(VOut in [[stage_in]], constant float &t [[buffer(0)]]) {
            float3 col = 0.5 + 0.5 * cos(t + float3(in.uv.x, in.uv.y, in.uv.x) * 6.2831853 + float3(0.0, 2.0, 4.0));
            return float4(col, 1.0);
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
        // `speed` scales the animation rate — an unconnected scalar input read via the v3 ABI channel,
        // live-tunable from the slider / ui_set_input_default (defaults to 1 if unset).
        var t = Float(ctx.time) * (ctx.inputFloat("speed") ?? 1.0)
        encoder.setFragmentBytes(&t, length: MemoryLayout<Float>.size, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }
}

enum SZNodeMain { static func make() -> SZNode { Node() } }
