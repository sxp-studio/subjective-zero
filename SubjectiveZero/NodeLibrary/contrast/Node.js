// Contrast: scales the distance of every channel from `pivot` by `amount` (alpha preserved).
// One full-screen pass; `amount` and `pivot` ride the value channel and are read every frame.

const SHADER = `
uniform sampler2D uInput;
uniform float uAmount;
uniform float uPivot;
void main() {
  vec4 c = texture(uInput, vUv);
  fragColor = vec4((c.rgb - uPivot) * uAmount + uPivot, c.a);
}`;

export default class Node {
  setup(ctx) {}

  update(ctx) {
    const input = ctx.inputTexture("input");
    if (!input) return;
    ctx.shaderPass(SHADER, {
      uInput: input,
      uAmount: ctx.inputFloat("amount") ?? 1.0,
      uPivot: ctx.inputFloat("pivot") ?? 0.5,
    }, ctx.outputTexture("output"));
  }
}
