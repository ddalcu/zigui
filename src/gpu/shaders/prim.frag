// Unified primitive fragment shader. Mirrors the software rasterizer's SDF
// coverage math (raster.zig) exactly: rounded-box and segment SDFs with
// `clamp(0.5 - sd, 0, 1)` anti-aliasing, multiplied by the clip coverage.
// Kinds must match `gpu_scene.Kind`. Output is straight alpha; the pipeline
// blend state (src_alpha / one_minus_src_alpha) performs the `over`.
//
// Compiled to SPIR-V by compile.sh; keep in sync with prim.metal.
#version 450

layout(set = 2, binding = 0) uniform sampler2D atlas;

layout(location = 0) in vec2 v_px;
layout(location = 1) in vec2 v_uv;
layout(location = 2) flat in vec4 f_shape;
layout(location = 3) flat in vec4 f_color0;
layout(location = 4) flat in vec4 f_color1;
layout(location = 5) flat in vec4 f_ab;
layout(location = 6) flat in vec4 f_clip;
layout(location = 7) flat in vec4 f_clip_rrect;
layout(location = 8) flat in vec4 f_params;

layout(location = 0) out vec4 o_color;

float sdRoundBox(vec2 p, vec4 rect, float radius) {
    float r = min(radius, min(rect.z, rect.w) * 0.5);
    vec2 center = rect.xy + rect.zw * 0.5;
    vec2 q = abs(p - center) - (rect.zw * 0.5 - vec2(r));
    return length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0) - r;
}

float fillCov(vec2 p, vec4 rect, float radius) {
    return clamp(0.5 - sdRoundBox(p, rect, radius), 0.0, 1.0);
}

float sdSegment(vec2 p, vec2 a, vec2 b) {
    vec2 pa = p - a;
    vec2 ba = b - a;
    float len2 = dot(ba, ba);
    float h = len2 > 0.0 ? clamp(dot(pa, ba) / len2, 0.0, 1.0) : 0.0;
    return length(pa - ba * h);
}

void main() {
    int kind = int(f_params.x);
    float radius = f_params.y;
    float half_w = f_params.z;
    vec4 color = f_color0;
    float cov = 1.0;

    if (kind == 0) { // fill_rrect
        cov = fillCov(v_px, f_shape, radius);
    } else if (kind == 1) { // stroke_rrect (centered on the edge)
        float d = abs(sdRoundBox(v_px, f_shape, radius)) - half_w;
        cov = clamp(0.5 - d, 0.0, 1.0);
    } else if (kind == 2) { // linear_gradient clipped to a rounded rect
        cov = fillCov(v_px, f_shape, radius);
        vec2 dir = f_ab.zw - f_ab.xy;
        float len2 = dot(dir, dir);
        float t = len2 > 0.0 ? clamp(dot(v_px - f_ab.xy, dir) / len2, 0.0, 1.0) : 0.0;
        color = mix(f_color0, f_color1, t);
    } else if (kind == 3) { // glyph: coverage in atlas alpha, tinted by color0
        cov = texture(atlas, v_uv).a;
    } else if (kind == 4) { // image: RGBA straight from the atlas
        color = texture(atlas, v_uv);
    } else { // line segment with round caps
        float d = sdSegment(v_px, f_ab.xy, f_ab.zw) - half_w;
        cov = clamp(0.5 - d, 0.0, 1.0);
    }

    // Clip: axis-aligned intersection of the stack + innermost rounded clip.
    cov *= fillCov(v_px, f_clip, 0.0);
    if (f_params.w > 0.0) cov *= fillCov(v_px, f_clip_rrect, f_params.w);

    o_color = vec4(color.rgb, color.a * cov);
}
