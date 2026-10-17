#include <flutter/runtime_effect.glsl>
precision highp float;
uniform vec2 uSize;
uniform vec2 uImageSize;
uniform float uYaw;
uniform float uPitch;
uniform float uFov;
uniform sampler2D uTexture;
out vec4 fragColor;
const float PI = 3.141592653589793;
void main() {
  vec2 xy = (FlutterFragCoord().xy / uSize - 0.5) * 2.0;
  float scale = tan(uFov * 0.5);
  vec3 ray = normalize(vec3(xy.x * (uSize.x / uSize.y) * scale, -xy.y * scale, 1.0));
  ray = vec3(ray.x, ray.y * cos(uPitch) + ray.z * sin(uPitch), -ray.y * sin(uPitch) + ray.z * cos(uPitch));
  ray = vec3(ray.x * cos(uYaw) + ray.z * sin(uYaw), ray.y, -ray.x * sin(uYaw) + ray.z * cos(uYaw));
  vec2 uv = vec2(fract(atan(ray.x, ray.z) / (2.0 * PI) + 0.5), 0.5 - asin(clamp(ray.y, -1.0, 1.0)) / PI);
  // Sample texel centres to avoid exposing transparent edges at the poles.
  uv.y = clamp(uv.y, 0.5 / uImageSize.y, 1.0 - 0.5 / uImageSize.y);
  fragColor = texture(uTexture, uv);
}
