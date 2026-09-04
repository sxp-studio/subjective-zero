// Chromatic aberration: samples red and blue offset away from `center` by `amount`, green in place.

const SHADER = `
uniform sampler2D uInput;
uniform float uAmount;
uniform vec2 uCenter;
void main() {
  vec2 off = (vUv - uCenter) * uAmount;
  float r = texture(uInput, clamp(vUv + off, 0.0, 1.0)).r;
  vec4 g = texture(uInput, vUv);
  float b = texture(uInput, clamp(vUv - off, 0.0, 1.0)).b;
  fragColor = vec4(r, g.g, b, g.a);
}`;

export default class Node {
  setup(ctx) {}

  update(ctx) {
    const input = ctx.inputTexture("input");
    if (!input) return;
    const center = ctx.inputFloats("center");
    // the Mac shader's centre is top-left based; flip y so the same value means the same point
    const c = center && center.length === 2 ? [center[0], 1.0 - center[1]] : [0.5, 0.5];
    ctx.shaderPass(SHADER, {
      uInput: input,
      uAmount: ctx.inputFloat("amount") ?? 0.01,
      uCenter: c,
    }, ctx.outputTexture("output"));
  }
}
