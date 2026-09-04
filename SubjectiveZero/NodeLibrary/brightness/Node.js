// Brightness: multiplies the input texture's RGB by a live `amount` gain (alpha preserved).
// Full-screen pass through ctx.shaderPass, one fragment per pixel. `amount` rides the scalar value
// channel (unconnected default 1.0, live-tunable).

const SHADER = `
uniform sampler2D uInput;
uniform float uAmount;
void main() {
  vec4 c = texture(uInput, vUv);
  fragColor = vec4(c.rgb * uAmount, c.a);
}`;

export default class Node {
  setup(ctx) {
    // Nothing to build: shaderPass caches its material per source string.
  }

  update(ctx) {
    const input = ctx.inputTexture("input");
    if (!input) return;   // nothing upstream yet: skip the frame
    const amount = ctx.inputFloat("amount") ?? 1.0;
    ctx.shaderPass(SHADER, { uInput: input, uAmount: amount }, ctx.outputTexture("output"));
  }
}
