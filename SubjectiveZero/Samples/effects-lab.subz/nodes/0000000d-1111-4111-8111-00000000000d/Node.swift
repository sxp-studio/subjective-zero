// Vignette — darkens (or tints) the input toward `color` at the frame edges (alpha preserved).
// Compute-kernel template: build the pipeline once in setup(), dispatch one thread per pixel in
// update(). Scalar knobs ride the value channel; `color` arrives as 4 floats packed into a SIMD4.
@preconcurrency import Metal

final class Node: SZNode {
    private var pipeline: (any MTLComputePipelineState)?

    func setup(_ ctx: SZSetupContext) {
        let source = """
        #include <metal_stdlib>
        using namespace metal;
        kernel void vignette(texture2d<float, access::read>  inTex  [[texture(0)]],
                             texture2d<float, access::write> outTex [[texture(1)]],
                             constant float  &amount   [[buffer(0)]],
                             constant float  &radius   [[buffer(1)]],
                             constant float  &softness [[buffer(2)]],
                             constant float4 &color    [[buffer(3)]],
                             uint2 gid [[thread_position_in_grid]]) {
            if (gid.x >= outTex.get_width() || gid.y >= outTex.get_height()) { return; }
            float4 c = inTex.read(gid);
            float2 uv = (float2(gid) + 0.5) / float2(outTex.get_width(), outTex.get_height());
            float d = distance(uv, float2(0.5));
            float v = smoothstep(radius, radius - softness, d);
            float3 rgb = mix(c.rgb, color.rgb, (1.0 - v) * amount);
            outTex.write(float4(rgb, c.a), gid);
        }
        """
        guard let library = try? ctx.device.makeLibrary(source: source, options: nil),
              let function = library.makeFunction(name: "vignette"),
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
        var radius = ctx.inputFloat("radius") ?? 0.75
        var softness = ctx.inputFloat("softness") ?? 0.45
        var color = simd4(ctx.inputFloats("color"), fallback: [0, 0, 0, 1])
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(input, index: 0)
        encoder.setTexture(output, index: 1)
        encoder.setBytes(&amount, length: MemoryLayout<Float>.size, index: 0)
        encoder.setBytes(&radius, length: MemoryLayout<Float>.size, index: 1)
        encoder.setBytes(&softness, length: MemoryLayout<Float>.size, index: 2)
        encoder.setBytes(&color, length: MemoryLayout<SIMD4<Float>>.size, index: 3)
        let width = pipeline.threadExecutionWidth
        let height = max(1, pipeline.maxTotalThreadsPerThreadgroup / width)
        let threadsPerGroup = MTLSize(width: width, height: height, depth: 1)
        let grid = MTLSize(width: output.width, height: output.height, depth: 1)
        encoder.dispatchThreads(grid, threadsPerThreadgroup: threadsPerGroup)
        encoder.endEncoding()
    }

    private func simd4(_ v: [Float]?, fallback: [Float]) -> SIMD4<Float> {
        let a = (v?.count ?? 0) >= 4 ? v! : fallback
        return SIMD4<Float>(a[0], a[1], a[2], a[3])
    }
}

enum SZNodeMain { static func make() -> SZNode { Node() } }
