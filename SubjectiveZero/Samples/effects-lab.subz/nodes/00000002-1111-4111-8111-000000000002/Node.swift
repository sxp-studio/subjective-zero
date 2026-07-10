// Noise — animated procedural noise texture source (white / value / fractal fBm / voronoi). No input.
// Render-pass template: a full-screen triangle whose fragment shader hashes UV*scale, optionally
// offset by time*speed, and returns a grayscale value. `type` rides the string channel → Int32 mode.
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

        // Scalar hash → [0,1).
        float hash21(float2 p) {
            p = fract(p * float2(123.34, 456.21));
            p += dot(p, p + 45.32);
            return fract(p.x * p.y);
        }
        // Vector hash → [0,1)^2 (cell feature point for voronoi).
        float2 hash22(float2 p) {
            float n = sin(dot(p, float2(41.0, 289.0)));
            return fract(float2(262144.0, 32768.0) * n);
        }
        // Bilinear-interpolated value noise.
        float valueNoise(float2 p) {
            float2 i = floor(p);
            float2 f = fract(p);
            float2 u = f * f * (3.0 - 2.0 * f);
            float a = hash21(i + float2(0, 0));
            float b = hash21(i + float2(1, 0));
            float c = hash21(i + float2(0, 1));
            float d = hash21(i + float2(1, 1));
            return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
        }
        // fBm: sum `octaves` octaves of value noise, halving amplitude / doubling frequency.
        float fbm(float2 p, int octaves) {
            float sum = 0.0;
            float amp = 0.5;
            float norm = 0.0;
            for (int i = 0; i < 8; i++) {
                if (i >= octaves) { break; }
                sum += amp * valueNoise(p);
                norm += amp;
                p *= 2.0;
                amp *= 0.5;
            }
            return sum / max(norm, 1e-4);
        }
        // Voronoi cellular F1 distance, normalized to ~[0,1].
        float voronoi(float2 p) {
            float2 i = floor(p);
            float2 f = fract(p);
            float minDist = 1.5;
            for (int y = -1; y <= 1; y++) {
                for (int x = -1; x <= 1; x++) {
                    float2 g = float2(float(x), float(y));
                    float2 o = hash22(i + g);
                    float2 r = g + o - f;
                    minDist = min(minDist, dot(r, r));
                }
            }
            return sqrt(minDist);
        }

        fragment float4 f_main(VOut in [[stage_in]],
                               constant int   &mode  [[buffer(0)]],
                               constant float &scale [[buffer(1)]],
                               constant float &time  [[buffer(2)]],
                               constant float &speed [[buffer(3)]],
                               constant int   &octaves [[buffer(4)]]) {
            float2 p = in.uv * scale + time * speed;
            float n;
            if (mode == 0) {                          // white
                n = hash21(floor(p));
            } else if (mode == 2) {                   // fractal fBm
                n = fbm(p, octaves);
            } else if (mode == 3) {                   // voronoi
                n = voronoi(p);
            } else {                                  // value
                n = valueNoise(p);
            }
            n = clamp(n, 0.0, 1.0);
            return float4(float3(n), 1.0);
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

        var mode: Int32 = {
            switch ctx.inputString("type") {
            case "white": return 0
            case "fractal": return 2
            case "voronoi": return 3
            default: return 1   // value
            }
        }()
        var scale = ctx.inputFloat("scale") ?? 4.0
        var time = Float(ctx.time)
        var speed = ctx.inputFloat("speed") ?? 0.0
        var octaves = Int32(max(1, min(8, Int((ctx.inputFloat("octaves") ?? 4.0).rounded()))))
        encoder.setFragmentBytes(&mode, length: MemoryLayout<Int32>.size, index: 0)
        encoder.setFragmentBytes(&scale, length: MemoryLayout<Float>.size, index: 1)
        encoder.setFragmentBytes(&time, length: MemoryLayout<Float>.size, index: 2)
        encoder.setFragmentBytes(&speed, length: MemoryLayout<Float>.size, index: 3)
        encoder.setFragmentBytes(&octaves, length: MemoryLayout<Int32>.size, index: 4)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }
}

enum SZNodeMain { static func make() -> SZNode { Node() } }
