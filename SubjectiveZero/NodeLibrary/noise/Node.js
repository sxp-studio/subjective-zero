// Noise: a procedural texture source. `type` picks white / value / fractal (fBm) / voronoi, `scale` the
// cell count across the frame, `speed` drifts the pattern with time, `octaves` the fBm depth.
// uv is flipped to top-left so a given scale and time show the Mac node's pattern.

const SHADER = `
uniform int uMode;
uniform float uScale;
uniform float uSpeed;
uniform int uOctaves;
float hash21(vec2 p) {
  p = fract(p * vec2(123.34, 456.21));
  p += dot(p, p + 45.32);
  return fract(p.x * p.y);
}
vec2 hash22(vec2 p) {
  float n = sin(dot(p, vec2(41.0, 289.0)));
  return fract(vec2(262144.0, 32768.0) * n);
}
float valueNoise(vec2 p) {
  vec2 i = floor(p), f = fract(p);
  vec2 u = f * f * (3.0 - 2.0 * f);
  float a = hash21(i), b = hash21(i + vec2(1, 0)), c = hash21(i + vec2(0, 1)), d = hash21(i + vec2(1, 1));
  return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}
float fbm(vec2 p, int octaves) {
  float sum = 0.0, amp = 0.5, norm = 0.0;
  for (int i = 0; i < 8; i++) {
    if (i >= octaves) break;
    sum += amp * valueNoise(p);
    norm += amp;
    p *= 2.0;
    amp *= 0.5;
  }
  return sum / max(norm, 1e-4);
}
float voronoi(vec2 p) {
  vec2 i = floor(p), f = fract(p);
  float minDist = 1.5;
  for (int y = -1; y <= 1; y++) {
    for (int x = -1; x <= 1; x++) {
      vec2 g = vec2(float(x), float(y));
      vec2 r = g + hash22(i + g) - f;
      minDist = min(minDist, dot(r, r));
    }
  }
  return sqrt(minDist);
}
void main() {
  vec2 uv = vec2(vUv.x, 1.0 - vUv.y);
  vec2 p = uv * uScale + uTime * uSpeed;
  float n;
  if (uMode == 0) n = hash21(floor(p));
  else if (uMode == 2) n = fbm(p, uOctaves);
  else if (uMode == 3) n = voronoi(p);
  else n = valueNoise(p);
  fragColor = vec4(vec3(n), 1.0);
}`;

const MODES = { white: 0, value: 1, fractal: 2, voronoi: 3 };

export default class Node {
  setup(ctx) {}

  update(ctx) {
    ctx.shaderPass(SHADER, {
      uMode: MODES[ctx.inputString("type") ?? "value"] ?? 1,
      uScale: ctx.inputFloat("scale") ?? 4.0,
      uSpeed: ctx.inputFloat("speed") ?? 0.0,
      uOctaves: Math.max(1, Math.min(8, Math.round(ctx.inputFloat("octaves") ?? 4))),
    }, ctx.outputTexture("output"));
  }
}
