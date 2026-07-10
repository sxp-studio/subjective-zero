// Saturation — mixes the input toward or past its luma by `amount` (alpha preserved).
// Compute-kernel template: build the pipeline once in setup(), dispatch one thread per pixel in
// update(). `amount` rides the scalar value channel (live-tunable).
@preconcurrency import Metal

final class Node: SZNode {
    private var pipeline: (any MTLComputePipelineState)?

    func setup(_ ctx: SZSetupContext) {
        let source = """
        #include <metal_stdlib>
        using namespace metal;
        kernel void saturation(texture2d<float, access::read>  inTex  [[texture(0)]],
                               texture2d<float, access::write> outTex [[texture(1)]],
                               constant float &amount [[buffer(0)]],
                               uint2 gid [[thread_position_in_grid]]) {
            if (gid.x >= outTex.get_width() || gid.y >= outTex.get_height()) { return; }
            float4 c = inTex.read(gid);
            float l = dot(c.rgb, float3(0.299, 0.587, 0.114));
            float3 rgb = mix(float3(l), c.rgb, amount);
            outTex.write(float4(rgb, c.a), gid);
        }
        """
        guard let library = try? ctx.device.makeLibrary(source: source, options: nil),
              let function = library.makeFunction(name: "saturation"),
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
        var amount = ctx.inputFloat("amount") ?? 1.0
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(input, index: 0)
        encoder.setTexture(output, index: 1)
        encoder.setBytes(&amount, length: MemoryLayout<Float>.size, index: 0)
        let width = pipeline.threadExecutionWidth
        let height = max(1, pipeline.maxTotalThreadsPerThreadgroup / width)
        let threadsPerGroup = MTLSize(width: width, height: height, depth: 1)
        let grid = MTLSize(width: output.width, height: output.height, depth: 1)
        encoder.dispatchThreads(grid, threadsPerThreadgroup: threadsPerGroup)
        encoder.endEncoding()
    }
}

enum SZNodeMain { static func make() -> SZNode { Node() } }
