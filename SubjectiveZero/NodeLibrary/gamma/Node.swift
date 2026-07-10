// Gamma — applies a per-channel power curve to the input texture's RGB (alpha preserved).
// Compute-kernel template: build the pipeline once in setup(), dispatch one thread per pixel in
// update(). `gamma` rides the scalar value channel (live-tunable).
@preconcurrency import Metal

final class Node: SZNode {
    private var pipeline: (any MTLComputePipelineState)?

    func setup(_ ctx: SZSetupContext) {
        let source = """
        #include <metal_stdlib>
        using namespace metal;
        kernel void gammaCorrect(texture2d<float, access::read>  inTex  [[texture(0)]],
                                 texture2d<float, access::write> outTex [[texture(1)]],
                                 constant float &gamma [[buffer(0)]],
                                 uint2 gid [[thread_position_in_grid]]) {
            if (gid.x >= outTex.get_width() || gid.y >= outTex.get_height()) { return; }
            float4 c = inTex.read(gid);
            float3 rgb = pow(max(c.rgb, 0.0), float3(1.0 / max(gamma, 1e-3)));
            outTex.write(float4(rgb, c.a), gid);
        }
        """
        guard let library = try? ctx.device.makeLibrary(source: source, options: nil),
              let function = library.makeFunction(name: "gammaCorrect"),
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
        var gamma = ctx.inputFloat("gamma") ?? 1.0
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(input, index: 0)
        encoder.setTexture(output, index: 1)
        encoder.setBytes(&gamma, length: MemoryLayout<Float>.size, index: 0)
        let width = pipeline.threadExecutionWidth
        let height = max(1, pipeline.maxTotalThreadsPerThreadgroup / width)
        let threadsPerGroup = MTLSize(width: width, height: height, depth: 1)
        let grid = MTLSize(width: output.width, height: output.height, depth: 1)
        encoder.dispatchThreads(grid, threadsPerThreadgroup: threadsPerGroup)
        encoder.endEncoding()
    }
}

enum SZNodeMain { static func make() -> SZNode { Node() } }
