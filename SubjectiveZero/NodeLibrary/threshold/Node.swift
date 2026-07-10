// Threshold — converts the input to a soft black/white mask by luma (alpha preserved).
// Compute-kernel template: build the pipeline once in setup(), dispatch one thread per pixel in
// update(). Both knobs ride the scalar value channel (live-tunable).
@preconcurrency import Metal

final class Node: SZNode {
    private var pipeline: (any MTLComputePipelineState)?

    func setup(_ ctx: SZSetupContext) {
        let source = """
        #include <metal_stdlib>
        using namespace metal;
        kernel void threshold(texture2d<float, access::read>  inTex  [[texture(0)]],
                              texture2d<float, access::write> outTex [[texture(1)]],
                              constant float &threshold [[buffer(0)]],
                              constant float &softness  [[buffer(1)]],
                              uint2 gid [[thread_position_in_grid]]) {
            if (gid.x >= outTex.get_width() || gid.y >= outTex.get_height()) { return; }
            float4 c = inTex.read(gid);
            float l = dot(c.rgb, float3(0.299, 0.587, 0.114));
            float t = smoothstep(threshold - softness, threshold + softness, l);
            outTex.write(float4(float3(t), c.a), gid);
        }
        """
        guard let library = try? ctx.device.makeLibrary(source: source, options: nil),
              let function = library.makeFunction(name: "threshold"),
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
        var threshold = ctx.inputFloat("threshold") ?? 0.5
        var softness = ctx.inputFloat("softness") ?? 0.05
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(input, index: 0)
        encoder.setTexture(output, index: 1)
        encoder.setBytes(&threshold, length: MemoryLayout<Float>.size, index: 0)
        encoder.setBytes(&softness, length: MemoryLayout<Float>.size, index: 1)
        let width = pipeline.threadExecutionWidth
        let height = max(1, pipeline.maxTotalThreadsPerThreadgroup / width)
        let threadsPerGroup = MTLSize(width: width, height: height, depth: 1)
        let grid = MTLSize(width: output.width, height: output.height, depth: 1)
        encoder.dispatchThreads(grid, threadsPerThreadgroup: threadsPerGroup)
        encoder.endEncoding()
    }
}

enum SZNodeMain { static func make() -> SZNode { Node() } }
