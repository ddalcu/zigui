// Unified primitive vertex shader: expands one `gpu_scene.Instance` (nine
// per-instance float4 attributes) into a 4-vertex triangle strip quad and
// forwards the instance data flat to the fragment SDF evaluator.
//
// Compiled to SPIR-V by compile.sh; keep in sync with prim.metal.
#version 450

layout(set = 1, binding = 0) uniform Viewport {
    vec4 size; // viewport width, height in pixels (zw unused)
} u;

layout(location = 0) in vec4 i_pos;
layout(location = 1) in vec4 i_shape;
layout(location = 2) in vec4 i_color0;
layout(location = 3) in vec4 i_color1;
layout(location = 4) in vec4 i_ab;
layout(location = 5) in vec4 i_uv;
layout(location = 6) in vec4 i_clip;
layout(location = 7) in vec4 i_clip_rrect;
layout(location = 8) in vec4 i_params;

layout(location = 0) out vec2 v_px;
layout(location = 1) out vec2 v_uv;
layout(location = 2) flat out vec4 f_shape;
layout(location = 3) flat out vec4 f_color0;
layout(location = 4) flat out vec4 f_color1;
layout(location = 5) flat out vec4 f_ab;
layout(location = 6) flat out vec4 f_clip;
layout(location = 7) flat out vec4 f_clip_rrect;
layout(location = 8) flat out vec4 f_params;

void main() {
    // Strip corners: (0,0) (1,0) (0,1) (1,1).
    vec2 corner = vec2(float(gl_VertexIndex & 1), float((gl_VertexIndex >> 1) & 1));
    vec2 px = i_pos.xy + corner * i_pos.zw;
    v_px = px;
    v_uv = mix(i_uv.xy, i_uv.zw, corner);
    f_shape = i_shape;
    f_color0 = i_color0;
    f_color1 = i_color1;
    f_ab = i_ab;
    f_clip = i_clip;
    f_clip_rrect = i_clip_rrect;
    f_params = i_params;
    vec2 ndc = px / u.size.xy * 2.0 - 1.0;
    // SDL_GPU NDC is +Y up on every backend; pixel space is +Y down.
    gl_Position = vec4(ndc.x, -ndc.y, 0.0, 1.0);
}
