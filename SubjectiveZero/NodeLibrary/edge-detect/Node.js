// Edge detect: a Sobel operator on luma, thresholded, painted `edgeColor` over `bgColor`.
// `thickness` scales the sampling step in texels.

const SHADER = `
uniform sampler2D uInput;
uniform float uThreshold;
uniform float uThickness;
uniform vec4 uEdgeColor;
uniform vec4 uBgColor;
void main() {
  vec2 t = uThickness / uResolution;
  float lum[9];
  int idx = 0;
  for (int y = -1; y <= 1; y++) {
    for (int x = -1; x <= 1; x++) {
      vec3 c = texture(uInput, clamp(vUv + vec2(float(x), float(y)) * t, 0.0, 1.0)).rgb;
      lum[idx++] = dot(c, vec3(0.299, 0.587, 0.114));
    }
  }
  float gx = -lum[0] + lum[2] - 2.0 * lum[3] + 2.0 * lum[5] - lum[6] + lum[8];
  float gy = -lum[0] - 2.0 * lum[1] - lum[2] + lum[6] + 2.0 * lum[7] + lum[8];
  float mag = length(vec2(gx, gy));
  float e = smoothstep(uThreshold, uThreshold * 2.0, mag);
  fragColor = mix(uBgColor, uEdgeColor, e);
}`;

function rgba(v, fallback) { return v && v.length === 4 ? v : fallback; }

export default class Node {
  setup(ctx) {}

  update(ctx) {
    const input = ctx.inputTexture("input");
    if (!input) return;
    ctx.shaderPass(SHADER, {
      uInput: input,
      uThreshold: ctx.inputFloat("threshold") ?? 0.2,
      uThickness: ctx.inputFloat("thickness") ?? 1.0,
      uEdgeColor: rgba(ctx.inputFloats("edgeColor"), [1, 1, 1, 1]),
      uBgColor: rgba(ctx.inputFloats("bgColor"), [0, 0, 0, 1]),
    }, ctx.outputTexture("output"));
  }
}
