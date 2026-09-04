// Gaussian blur: a separable 9-tap kernel, horizontal into a scratch target then vertical into the
// output. `radius` scales the tap spacing in texels. The scratch target follows the project size.

const SHADER = `
uniform sampler2D uInput;
uniform vec2 uDirection;
uniform float uRadius;
void main() {
  float weights[9] = float[9](0.01, 0.02, 0.06, 0.12, 0.18, 0.12, 0.06, 0.02, 0.01);
  float sum = 0.6;
  vec2 texel = uDirection / uResolution;
  vec4 acc = vec4(0.0);
  for (int i = -4; i <= 4; i++) {
    vec2 off = texel * uRadius * float(i);
    acc += texture(uInput, clamp(vUv + off, 0.0, 1.0)) * (weights[i + 4] / sum);
  }
  fragColor = acc;
}`;

export default class Node {
  setup(ctx) {
    this.scratch = null;
  }

  update(ctx) {
    const input = ctx.inputTexture("input");
    if (!input) return;
    if (!this.scratch || this.scratch.width !== ctx.width || this.scratch.height !== ctx.height) {
      if (this.scratch) this.scratch.dispose();
      this.scratch = new ctx.three.WebGLRenderTarget(ctx.width, ctx.height, {
        format: ctx.three.RGBAFormat, type: ctx.three.UnsignedByteType,
        minFilter: ctx.three.LinearFilter, magFilter: ctx.three.LinearFilter,
        depthBuffer: false, stencilBuffer: false, generateMipmaps: false,
      });
    }
    const radius = ctx.inputFloat("radius") ?? 3.0;
    ctx.shaderPass(SHADER, { uInput: input, uDirection: [1, 0], uRadius: radius }, this.scratch);
    ctx.shaderPass(SHADER, { uInput: this.scratch.texture, uDirection: [0, 1], uRadius: radius }, ctx.outputTexture("output"));
  }

  teardown() {
    if (this.scratch) { this.scratch.dispose(); this.scratch = null; }
  }
}
