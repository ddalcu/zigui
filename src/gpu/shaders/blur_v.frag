// Vertical box-blur + composite pass (second half of blur_rect). Samples the
// horizontally-blurred scratch texture over a vertical `2*br+1` window, then
// reproduces raster.zig's compositing: `result = tint.over(blurred)` and
// `dst = dst.lerp(result, cov)` where cov is the (rounded) blur rect's SDF
// coverage times the clip coverage. The lerp is performed by the pipeline's
// src_alpha blend with alpha = cov.
//
// Same uniform block as blur_h.frag (BlurUniform in gpu.zig); keep in sync
// with blur.metal.
#version 450

layout(set = 2, binding = 0) uniform sampler2D src;

layout(set = 3, binding = 0) uniform Blur {
    vec4 region; // x0, y0, x1, y1 snapshot bounds (px)
    vec4 texel_br; // 1/tex_w, 1/tex_h, box radius, unused
    vec4 shape; // blur rect (x, y, w, h)
    vec4 tint; // straight-alpha tint composited over the blur
    vec4 clip; // axis-aligned clip intersection
    vec4 clip_rrect; // innermost rounded clip rect
    vec4 radii; // shape corner radius, rounded-clip radius
} u;

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

void main() {
    vec2 p = gl_FragCoord.xy;
    float br = u.texel_br.z;
    vec4 sum = vec4(0.0);
    float cnt = 0.0;
    for (float k = -br; k <= br; k += 1.0) {
        float sy = p.y + k;
        if (sy < u.region.y || sy >= u.region.w) continue;
        sum += texture(src, vec2(p.x, sy) * u.texel_br.xy);
        cnt += 1.0;
    }
    vec4 blurred = cnt > 0.0 ? sum / cnt : vec4(0.0);

    // tint.over(blurred), straight alpha.
    float oa = u.tint.a + blurred.a * (1.0 - u.tint.a);
    vec3 orgb = oa > 0.0
        ? (u.tint.rgb * u.tint.a + blurred.rgb * blurred.a * (1.0 - u.tint.a)) / oa
        : vec3(0.0);

    float cov = fillCov(p, u.shape, u.radii.x);
    cov *= fillCov(p, u.clip, 0.0);
    if (u.radii.y > 0.0) cov *= fillCov(p, u.clip_rrect, u.radii.y);

    o_color = vec4(orgb, cov);
}
