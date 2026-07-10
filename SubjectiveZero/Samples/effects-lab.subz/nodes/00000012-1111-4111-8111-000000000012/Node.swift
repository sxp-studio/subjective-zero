// Grain — adds animated hash noise to the input, faking film/sensor grain. COMPUTE template: one thread
// per pixel. `ctx.time` rides a `time` uniform (scaled by `speed`) so the noise field visibly churns
// each frame. `amount` sets intensity, `size` the grain scale. Alpha is preserved.
@preconcurrency import Metal

final class Node: SZNode {
    private var pipeline: (any MTLComputePipelineState)?

    func setup(_ ctx: SZSetupContext) {
        let source = """
        #include <metal_stdlib>
        using namespace metal;
        kernel void grain(texture2d<float, access::read>  inTex  [[texture(0)]],
                          texture2d<float, access::write> outTex [[texture(1)]],
                          constant float &amount [[buffer(0)]],
                          constant float &size   [[buffer(1)]],
                          constant float &speed  [[buffer(2)]],
                          constant float &time   [[buffer(3)]],
                          uint2 gid [[thread_position_in_grid]]) {
            if (gid.x >= outTex.get_width() || gid.y >= outTex.get_height()) { return; }
            float2 dim = float2(outTex.get_width(), outTex.get_height());
            float2 uv = (float2(gid) + 0.5) / dim;
            float4 c = inTex.read(gid);
            float n = fract(sin(dot(uv * size * dim * 0.01 + time * speed,
                                    float2(12.9898, 78.233))) * 43758.5453);
            float3 rgb = c.rgb + (n - 0.5) * amount;
            outTex.write(float4(rgb, c.a), gid);
        }
        """
        guard let library = try? ctx.device.makeLibrary(source: source, options: nil),
              let function = library.makeFunction(name: "grain"),
              let state = try? ctx.device.makeComputePipelineState(function: function) else {
            return
        }
        pipeline = state
    }

    func update(_ ctx: SZFrameContext) {
        guard let pipeline,
              let input = ctx.inputTexture("input"),
              let output = ctx.outputTexture("output"),
              let encoder = ctx.commandBuffer.makeComputeCommandEncoder() else {
            return
        }
        var amount = ctx.inputFloat("amount") ?? 0.08
        var size = ctx.inputFloat("size") ?? 1.0
        var speed = ctx.inputFloat("speed") ?? 1.0
        var time = Float(ctx.time)
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(input, index: 0)
        encoder.setTexture(output, index: 1)
        encoder.setBytes(&amount, length: MemoryLayout<Float>.size, index: 0)
        encoder.setBytes(&size, length: MemoryLayout<Float>.size, index: 1)
        encoder.setBytes(&speed, length: MemoryLayout<Float>.size, index: 2)
        encoder.setBytes(&time, length: MemoryLayout<Float>.size, index: 3)
        let width = pipeline.threadExecutionWidth
        let height = max(1, pipeline.maxTotalThreadsPerThreadgroup / width)
        let threadsPerGroup = MTLSize(width: width, height: height, depth: 1)
        let grid = MTLSize(width: output.width, height: output.height, depth: 1)
        encoder.dispatchThreads(grid, threadsPerThreadgroup: threadsPerGroup)
        encoder.endEncoding()
    }
}

enum SZNodeMain { static func make() -> SZNode { Node() } }
