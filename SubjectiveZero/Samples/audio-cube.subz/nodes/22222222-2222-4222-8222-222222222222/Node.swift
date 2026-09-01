// Blend — composites two textures (`base` + `blend`) with a selectable Photoshop-style mode, mixed
// back over the base by `opacity`. Compute-kernel template: pipeline built once in setup(), one
// thread per pixel in update(). `mode` rides the string channel → Int32; `opacity` the value channel.
@preconcurrency import Metal

final class Node: SZNode {
    private var pipeline: (any MTLComputePipelineState)?

    func setup(_ ctx: SZSetupContext) {
        let source = """
        #include <metal_stdlib>
        using namespace metal;

        float3 overlayCh(float3 b, float3 s) {
            return select(2.0 * b * s,
                          1.0 - 2.0 * (1.0 - b) * (1.0 - s),
                          b > 0.5);
        }
        float3 softLightCh(float3 b, float3 s) {
            return select(2.0 * b * s + b * b * (1.0 - 2.0 * s),
                          2.0 * b * (1.0 - s) + sqrt(b) * (2.0 * s - 1.0),
                          s > 0.5);
        }

        kernel void blend(texture2d<float, access::read>  baseTex  [[texture(0)]],
                          texture2d<float, access::read>  blendTex [[texture(1)]],
                          texture2d<float, access::write> outTex   [[texture(2)]],
                          constant int   &mode    [[buffer(0)]],
                          constant float &opacity [[buffer(1)]],
                          uint2 gid [[thread_position_in_grid]]) {
            if (gid.x >= outTex.get_width() || gid.y >= outTex.get_height()) { return; }
            float4 base = baseTex.read(gid);
            float4 over = blendTex.read(gid);
            float3 b0 = base.rgb;
            float3 b1 = over.rgb;
            float3 blended;
            if (mode == 1) {                          // multiply
                blended = b0 * b1;
            } else if (mode == 2) {                   // screen
                blended = 1.0 - (1.0 - b0) * (1.0 - b1);
            } else if (mode == 3) {                   // overlay
                blended = overlayCh(b0, b1);
            } else if (mode == 4) {                   // soft light
                blended = softLightCh(b0, b1);
            } else if (mode == 5) {                   // hard light (overlay with base/blend swapped)
                blended = overlayCh(b1, b0);
            } else if (mode == 6) {                   // difference
                blended = abs(b0 - b1);
            } else {                                  // add
                blended = b0 + b1;
            }
            float3 outRGB = mix(b0, blended, opacity);
            outTex.write(float4(outRGB, base.a), gid);
        }
        """
        guard let library = try? ctx.device.makeLibrary(source: source, options: nil),
              let function = library.makeFunction(name: "blend"),
              let state = try? ctx.device.makeComputePipelineState(function: function) else {
            return
        }
        pipeline = state
    }

    func update(_ ctx: SZFrameContext) {
        guard let pipeline,
              let base = ctx.inputTexture("base"),
              let blend = ctx.inputTexture("blend"),
              let output = ctx.outputTexture("output"),
              let encoder = ctx.commandBuffer.makeComputeCommandEncoder() else {
            return
        }
        var mode: Int32 = {
            switch ctx.inputString("mode") {
            case "multiply": return 1
            case "screen": return 2
            case "overlay": return 3
            case "softlight": return 4
            case "hardlight": return 5
            case "difference": return 6
            default: return 0   // add
            }
        }()
        var opacity = ctx.inputFloat("opacity") ?? 1.0
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(base, index: 0)
        encoder.setTexture(blend, index: 1)
        encoder.setTexture(output, index: 2)
        encoder.setBytes(&mode, length: MemoryLayout<Int32>.size, index: 0)
        encoder.setBytes(&opacity, length: MemoryLayout<Float>.size, index: 1)
        let width = pipeline.threadExecutionWidth
        let height = max(1, pipeline.maxTotalThreadsPerThreadgroup / width)
        let threadsPerGroup = MTLSize(width: width, height: height, depth: 1)
        let grid = MTLSize(width: output.width, height: output.height, depth: 1)
        encoder.dispatchThreads(grid, threadsPerThreadgroup: threadsPerGroup)
        encoder.endEncoding()
    }
}

enum SZNodeMain { static func make() -> SZNode { Node() } }
