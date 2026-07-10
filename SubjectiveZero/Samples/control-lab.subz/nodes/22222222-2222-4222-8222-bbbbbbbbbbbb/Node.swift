// Tint — samples the input texture and multiplies it by a warm/cool tint, blended by `amount`. A second
// generated node so the graph has two `texture` outputs to switch between with ui_toggle_display. The
// `tint` enum is read via the v4 string channel; `amount` via the v3 scalar channel.
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
        fragment float4 f_main(VOut in [[stage_in]],
                               texture2d<float> tex [[texture(0)]],
                               constant float4 &p [[buffer(0)]]) {   // rgb tint + amount
            constexpr sampler s(filter::linear, address::clamp_to_edge);
            float3 c = tex.sample(s, in.uv).rgb;
            float3 tinted = c * p.rgb;
            return float4(mix(c, tinted, p.a), 1.0);
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

        guard let input = ctx.inputTexture("input") else { return }   // black until upstream renders
        let tint = Self.tint(ctx.inputString("tint") ?? "none")
        let amount = ctx.inputFloat("amount") ?? 0.6

        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(input, index: 0)
        var p = SIMD4<Float>(tint.0, tint.1, tint.2, amount)
        encoder.setFragmentBytes(&p, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }

    private static func tint(_ s: String) -> (Float, Float, Float) {
        switch s {
        case "warm": (1.0, 0.8, 0.6)
        case "cool": (0.6, 0.8, 1.0)
        default: (1, 1, 1)   // none
        }
    }
}

enum SZNodeMain { static func make() -> SZNode { Node() } }
