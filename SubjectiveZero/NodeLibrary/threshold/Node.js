// Threshold: luma against `threshold` with a `softness` ramp, written as gray (alpha preserved).

const SHADER = `
uniform sampler2D uInput;
uniform float uThreshold;
uniform float uSoftness;
void main() {
  vec4 c = texture(uInput, vUv);
  float l = dot(c.rgb, vec3(0.299, 0.587, 0.114));
  float t = smoothstep(uThreshold - uSoftness, uThreshold + uSoftness, l);
  fragColor = vec4(vec3(t), c.a);
}`;

export default class Node {
  setup(ctx) {}

  update(ctx) {
    const input = ctx.inputTexture("input");
    if (!input) return;
    ctx.shaderPass(SHADER, {
      uInput: input,
      uThreshold: ctx.inputFloat("threshold") ?? 0.5,
      uSoftness: ctx.inputFloat("softness") ?? 0.05,
    }, ctx.outputTexture("output"));
  }
}
