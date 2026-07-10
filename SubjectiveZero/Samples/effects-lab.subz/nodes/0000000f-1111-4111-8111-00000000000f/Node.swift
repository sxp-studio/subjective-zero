// Pixelate — snaps each pixel to its block's top-left color, producing a blocky mosaic.
// Compute-kernel template: one thread per pixel. `size` (block edge in pixels) rides the value channel
// (live-tunable). Each thread quantizes its coordinate to the block origin and reads that source texel.
@preconcurrency import Metal

final class Node: SZNode {
    private var pipeline: (any MTLComputePipelineState)?

    func setup(_ ctx: SZSetupContext) {
        let source = """
        #include <metal_stdlib>
        using namespace metal;
        kernel void pixelate(texture2d<float, access::read>  inTex  [[texture(0)]],
                             texture2d<float, access::write> outTex [[texture(1)]],
                             constant float &size [[buffer(0)]],
                             uint2 gid [[thread_position_in_grid]]) {
            if (gid.x >= outTex.get_width() || gid.y >= outTex.get_height()) { return; }
            uint s = max(1u, uint(size));
            uint2 b = (gid / s) * s;
            float4 c = inTex.read(min(b, uint2(outTex.get_width() - 1, outTex.get_height() - 1)));
            outTex.write(c, gid);
        }
        """
        guard let library = try? ctx.device.makeLibrary(source: source, options: nil),
              let function = library.makeFunction(name: "pixelate"),
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
        var size = ctx.inputFloat("size") ?? 8.0
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(input, index: 0)
        encoder.setTexture(output, index: 1)
        encoder.setBytes(&size, length: MemoryLayout<Float>.size, index: 0)
        let width = pipeline.threadExecutionWidth
        let height = max(1, pipeline.maxTotalThreadsPerThreadgroup / width)
        let threadsPerGroup = MTLSize(width: width, height: height, depth: 1)
        let grid = MTLSize(width: output.width, height: output.height, depth: 1)
        encoder.dispatchThreads(grid, threadsPerThreadgroup: threadsPerGroup)
        encoder.endEncoding()
    }
}

enum SZNodeMain { static func make() -> SZNode { Node() } }
