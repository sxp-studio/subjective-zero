// Blend: composites `blend` over `base` with a Photoshop-style mode and an `opacity` mix. Alpha is the
// base's. The mode arrives as a string on the value channel and maps to the shader's integer switch.

const SHADER = `
uniform sampler2D uBase;
uniform sampler2D uBlend;
uniform int uMode;
uniform float uOpacity;
vec3 overlayCh(vec3 b, vec3 s) {
  return mix(2.0 * b * s, 1.0 - 2.0 * (1.0 - b) * (1.0 - s), step(0.5, b));
}
vec3 softLightCh(vec3 b, vec3 s) {
  return mix(2.0 * b * s + b * b * (1.0 - 2.0 * s), 2.0 * b * (1.0 - s) + sqrt(b) * (2.0 * s - 1.0), step(0.5, s));
}
void main() {
  vec4 base = texture(uBase, vUv);
  vec4 over = texture(uBlend, vUv);
  vec3 b0 = base.rgb, b1 = over.rgb, blended;
  if (uMode == 1) blended = b0 * b1;
  else if (uMode == 2) blended = 1.0 - (1.0 - b0) * (1.0 - b1);
  else if (uMode == 3) blended = overlayCh(b0, b1);
  else if (uMode == 4) blended = softLightCh(b0, b1);
  else if (uMode == 5) blended = overlayCh(b1, b0);
  else if (uMode == 6) blended = abs(b0 - b1);
  else blended = b0 + b1;
  fragColor = vec4(mix(b0, blended, uOpacity), base.a);
}`;

const MODES = { add: 0, multiply: 1, screen: 2, overlay: 3, softlight: 4, hardlight: 5, difference: 6 };

export default class Node {
  setup(ctx) {}

  update(ctx) {
    const base = ctx.inputTexture("base");
    const blend = ctx.inputTexture("blend");
    if (!base || !blend) return;
    ctx.shaderPass(SHADER, {
      uBase: base,
      uBlend: blend,
      uMode: MODES[ctx.inputString("mode") ?? "add"] ?? 0,
      uOpacity: ctx.inputFloat("opacity") ?? 1.0,
    }, ctx.outputTexture("output"));
  }
}
