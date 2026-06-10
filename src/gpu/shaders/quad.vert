// Plain quad vertex shader for the blur passes: covers a pixel rect given via
// uniforms; the fragment shaders work from gl_FragCoord, so nothing else is
// forwarded.
//
// Compiled to SPIR-V by compile.sh; keep in sync with blur.metal.
#version 450

layout(set = 1, binding = 0) uniform Quad {
    vec4 viewport; // width, height (zw unused)
    vec4 rect; // x, y, w, h in pixels
} u;

void main() {
    vec2 corner = vec2(float(gl_VertexIndex & 1), float((gl_VertexIndex >> 1) & 1));
    vec2 px = u.rect.xy + corner * u.rect.zw;
    vec2 ndc = px / u.viewport.xy * 2.0 - 1.0;
    gl_Position = vec4(ndc.x, -ndc.y, 0.0, 1.0);
}
