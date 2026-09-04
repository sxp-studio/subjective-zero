// Gradient: a two-color gradient texture source (linear / radial / angular). No input texture.
// Full-screen pass through ctx.shaderPass: the fragment computes a parameter `t` per pixel and mixes
// colorA to colorB. All controls ride the value/string channels (live-tunable).

const SHADER = `
uniform float uMode;
uniform vec4 uColorA;
uniform vec4 uColorB;
uniform float uAngle;
uniform vec2 uCenter;
uniform float uScale;
void main() {
  vec2 uv = vec2(vUv.x, 1.0 - vUv.y);   // top-left origin, so angle and center match Node.swift
  float t;
  if (uMode > 1.5) {                      // angular
    vec2 d = uv - uCenter;
    t = (atan(d.y, d.x) / 6.2831853 + 0.5) * uScale;
  } else if (uMode > 0.5) {               // radial
    t = distance(uv, uCenter) * uScale;
  } else {                                // linear
    vec2 dir = vec2(cos(uAngle), sin(uAngle));
    t = dot(uv - 0.5, dir) * uScale + 0.5;
  }
  fragColor = mix(uColorA, uColorB, clamp(t, 0.0, 1.0));
}`;

export default class Node {
  setup(ctx) {
    // Nothing to build: shaderPass caches its material per source string.
  }

  update(ctx) {
    const mode = { radial: 1, angular: 2 }[ctx.inputString("type")] ?? 0;
    const colorA = vec4(ctx.inputFloats("colorA"), [0, 0, 0, 1]);
    const colorB = vec4(ctx.inputFloats("colorB"), [1, 1, 1, 1]);
    const center = ctx.inputFloats("center");
    ctx.shaderPass(SHADER, {
      uMode: mode,
      uColorA: colorA,
      uColorB: colorB,
      uAngle: ctx.inputFloat("angle") ?? 0,
      uCenter: center && center.length >= 2 ? [center[0], center[1]] : [0.5, 0.5],
      uScale: ctx.inputFloat("scale") ?? 1,
    }, ctx.outputTexture("output"));
  }
}

// A colorRGBA input arrives as 4 numbers; guard the count before trusting it.
function vec4(v, fallback) { return v && v.length >= 4 ? v.slice(0, 4) : fallback; }
