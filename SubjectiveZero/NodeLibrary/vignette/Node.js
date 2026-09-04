// Vignette: darkens (or tints, via `color`) toward the frame edge. `radius` is where the falloff starts
// in uv distance from the centre, `softness` its width, `amount` its strength. Alpha preserved.

const SHADER = `
uniform sampler2D uInput;
uniform float uAmount;
uniform float uRadius;
uniform float uSoftness;
uniform vec4 uColor;
void main() {
  vec4 c = texture(uInput, vUv);
  float d = distance(vUv, vec2(0.5));
  float v = smoothstep(uRadius, uRadius - uSoftness, d);
  fragColor = vec4(mix(c.rgb, uColor.rgb, (1.0 - v) * uAmount), c.a);
}`;

export default class Node {
  setup(ctx) {}

  update(ctx) {
    const input = ctx.inputTexture("input");
    if (!input) return;
    const color = ctx.inputFloats("color");
    ctx.shaderPass(SHADER, {
      uInput: input,
      uAmount: ctx.inputFloat("amount") ?? 1.0,
      uRadius: ctx.inputFloat("radius") ?? 0.75,
      uSoftness: ctx.inputFloat("softness") ?? 0.45,
      uColor: color && color.length === 4 ? color : [0, 0, 0, 1],
    }, ctx.outputTexture("output"));
  }
}
