// Grain: adds animated per-pixel noise. `amount` is the strength, `size` the grain scale, `speed` how
// fast the pattern changes. Alpha preserved. uv is flipped to top-left so the pattern matches the Mac node.

const SHADER = `
uniform sampler2D uInput;
uniform float uAmount;
uniform float uSize;
uniform float uSpeed;
void main() {
  vec2 uv = vec2(vUv.x, 1.0 - vUv.y);
  vec4 c = texture(uInput, vUv);
  float n = fract(sin(dot(uv * uSize * uResolution * 0.01 + uTime * uSpeed, vec2(12.9898, 78.233))) * 43758.5453);
  fragColor = vec4(c.rgb + (n - 0.5) * uAmount, c.a);
}`;

export default class Node {
  setup(ctx) {}

  update(ctx) {
    const input = ctx.inputTexture("input");
    if (!input) return;
    ctx.shaderPass(SHADER, {
      uInput: input,
      uAmount: ctx.inputFloat("amount") ?? 0.08,
      uSize: ctx.inputFloat("size") ?? 1.0,
      uSpeed: ctx.inputFloat("speed") ?? 1.0,
    }, ctx.outputTexture("output"));
  }
}
