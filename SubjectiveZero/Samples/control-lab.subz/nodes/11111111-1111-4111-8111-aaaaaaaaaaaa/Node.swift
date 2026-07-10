// Pattern Source — a camera-free control playground. Renders a screen-space pattern driven by
// every input control type: `color`/`mode`/`cells` enums (read via the v4 string channel), `brightness`/
// `gamma` sliders + an `invert` toggle (the v3 scalar channel), and a freeform `note` string field
// (read but not drawn — there to exercise the text widget + persistence). One texture output.
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
                               constant float4 &p0 [[buffer(0)]],   // rgb + brightness
                               constant float4 &p1 [[buffer(1)]]) {  // gamma, invert, mode, cells
            float3 base = p0.rgb;
            float brightness = p0.a;
            float gamma = max(p1.x, 0.001);
            bool invert = p1.y > 0.5;
            int mode = int(p1.z);
            int cells = int(p1.w);
            float3 col = base;
            if (mode == 1) {                                  // gradient, left → right
                col = base * in.uv.x;
            } else if (mode == 2 && cells > 0) {              // checkerboard
                float2 g = floor(in.uv * float(cells));
                float c = fmod(g.x + g.y, 2.0);
                col = base * (c < 0.5 ? 1.0 : 0.15);
            }
            col *= brightness;
            col = pow(max(col, float3(0.0)), float3(1.0 / gamma));
            if (invert) { col = float3(1.0) - col; }
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
        guard let out = ctx.outputTexture("texture"), let pipeline else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = out
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = ctx.commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        defer { encoder.endEncoding() }

        // Enum choices arrive as their `value` string over the v4 channel; sliders/toggle over the v3.
        let rgb = Self.color(ctx.inputString("color") ?? "white")
        let brightness = ctx.inputFloat("brightness") ?? 0.8
        let gamma = ctx.inputFloat("gamma") ?? 1.0
        let invert = (ctx.inputFloat("invert") ?? 0) > 0.5
        let mode = Self.mode(ctx.inputString("mode") ?? "solid")
        let cells = Int(ctx.inputString("cells") ?? "8") ?? 8
        _ = ctx.inputString("note")   // freeform field: exercises the v4 channel, not drawn

        encoder.setRenderPipelineState(pipeline)
        var p0 = SIMD4<Float>(rgb.0, rgb.1, rgb.2, brightness)
        var p1 = SIMD4<Float>(gamma, invert ? 1 : 0, Float(mode), Float(cells))
        encoder.setFragmentBytes(&p0, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        encoder.setFragmentBytes(&p1, length: MemoryLayout<SIMD4<Float>>.stride, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }

    private static func color(_ s: String) -> (Float, Float, Float) {
        switch s {
        case "red": (1, 0, 0)
        case "green": (0, 1, 0)
        case "blue": (0, 0, 1)
        case "black": (0, 0, 0)
        default: (1, 1, 1)   // white
        }
    }

    private static func mode(_ s: String) -> Int {
        switch s {
        case "gradient": 1
        case "checker": 2
        default: 0   // solid
        }
    }
}

enum SZNodeMain { static func make() -> SZNode { Node() } }
