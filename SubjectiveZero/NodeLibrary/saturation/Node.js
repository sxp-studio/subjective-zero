// Saturation: mixes each pixel between its luma and its color by `amount` (0 = grayscale, 1 = unchanged,
// > 1 oversaturated). Alpha preserved.

const SHADER = `
uniform sampler2D uInput;
uniform float uAmount;
void main() {
  vec4 c = texture(uInput, vUv);
  float l = dot(c.rgb, vec3(0.299, 0.587, 0.114));
  fragColor = vec4(mix(vec3(l), c.rgb, uAmount), c.a);
}`;

export default class Node {
  setup(ctx) {}

  update(ctx) {
    const input = ctx.inputTexture("input");
    if (!input) return;
    ctx.shaderPass(SHADER, { uInput: input, uAmount: ctx.inputFloat("amount") ?? 1.0 }, ctx.outputTexture("output"));
  }
}
