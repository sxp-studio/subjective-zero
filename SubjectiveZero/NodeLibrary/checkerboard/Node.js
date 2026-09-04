// Checkerboard: a two-color checkerboard pattern texture source (no input texture).
// Full-screen pass through ctx.shaderPass: the fragment tiles UV space into `scale` cells per axis and
// mixes colorA/colorB on the parity of the cell. All controls live-tunable.

const SHADER = `
uniform float uScale;
uniform vec4 uColorA;
uniform vec4 uColorB;
void main() {
  float c = mod(floor(vUv.x * uScale) + floor(vUv.y * uScale), 2.0);
  fragColor = mix(uColorA, uColorB, c);
}`;

export default class Node {
  setup(ctx) {
    // Nothing to build: shaderPass caches its material per source string.
  }

  update(ctx) {
    const scale = ctx.inputFloat("scale") ?? 8.0;
    const colorA = vec4(ctx.inputFloats("colorA"), [0, 0, 0, 1]);
    const colorB = vec4(ctx.inputFloats("colorB"), [1, 1, 1, 1]);
    ctx.shaderPass(SHADER, { uScale: scale, uColorA: colorA, uColorB: colorB }, ctx.outputTexture("output"));
  }
}

// A colorRGBA input arrives as 4 numbers; guard the count before trusting it.
function vec4(v, fallback) { return v && v.length >= 4 ? v.slice(0, 4) : fallback; }
