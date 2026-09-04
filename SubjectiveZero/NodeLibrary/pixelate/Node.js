// Pixelate: snaps each pixel to its block's top-left color, producing a blocky mosaic.
// Full-screen pass through ctx.shaderPass. `size` (block edge in pixels) rides the value channel
// (live-tunable). Each fragment quantizes its coordinate to the block origin and reads that source texel.

const SHADER = `
uniform sampler2D uInput;
uniform float uSize;
void main() {
  float s = max(1.0, floor(uSize));
  vec2 b = floor(vUv * uResolution / s) * s;   // the block's bottom-left pixel (WebGL origin)
  b.y += s - 1.0;                              // its top row, as the Metal node reads it
  b = min(b, uResolution - 1.0);
  fragColor = texture(uInput, (b + 0.5) / uResolution);
}`;

export default class Node {
  setup(ctx) {
    // Nothing to build: shaderPass caches its material per source string.
  }

  update(ctx) {
    const input = ctx.inputTexture("input");
    if (!input) return;   // nothing upstream yet: skip the frame
    const size = ctx.inputFloat("size") ?? 8.0;
    ctx.shaderPass(SHADER, { uInput: input, uSize: size }, ctx.outputTexture("output"));
  }
}
