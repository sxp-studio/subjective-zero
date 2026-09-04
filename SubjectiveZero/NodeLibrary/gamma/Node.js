// Gamma: raises every channel to 1/gamma (alpha preserved). gamma > 1 lifts midtones, < 1 crushes them.

const SHADER = `
uniform sampler2D uInput;
uniform float uGamma;
void main() {
  vec4 c = texture(uInput, vUv);
  fragColor = vec4(pow(max(c.rgb, vec3(0.0)), vec3(1.0 / max(uGamma, 1e-4))), c.a);
}`;

export default class Node {
  setup(ctx) {}

  update(ctx) {
    const input = ctx.inputTexture("input");
    if (!input) return;
    ctx.shaderPass(SHADER, { uInput: input, uGamma: ctx.inputFloat("gamma") ?? 1.0 }, ctx.outputTexture("output"));
  }
}
