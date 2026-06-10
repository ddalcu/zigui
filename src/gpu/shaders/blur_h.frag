// Horizontal box-blur pass (first half of blur_rect). Samples the scene
// texture over a `2*br+1` window clamped to `region`, mirroring the software
// rasterizer's boxAverage (samples outside the snapshot region are dropped
// from the average, not clamped). Writes into the scratch texture; the
// vertical pass then composites back into the scene.
//
// Uses the same 7-vec4 uniform block as blur_v.frag (BlurUniform in gpu.zig);
// only region and texel_br matter here. Keep in sync with blur.metal.
#version 450

layout(set = 2, binding = 0) uniform sampler2D src;

layout(set = 3, binding = 0) uniform Blur {
    vec4 region; // x0, y0, x1, y1 snapshot bounds (px)
    vec4 texel_br; // 1/tex_w, 1/tex_h, box radius, unused
    vec4 shape;
    vec4 tint;
    vec4 clip;
    vec4 clip_rrect;
    vec4 radii;
} u;

layout(location = 0) out vec4 o_color;

void main() {
    vec2 p = gl_FragCoord.xy;
    float br = u.texel_br.z;
    vec4 sum = vec4(0.0);
    float cnt = 0.0;
    for (float k = -br; k <= br; k += 1.0) {
        float sx = p.x + k;
        if (sx < u.region.x || sx >= u.region.z) continue;
        sum += texture(src, vec2(sx, p.y) * u.texel_br.xy);
        cnt += 1.0;
    }
    o_color = cnt > 0.0 ? sum / cnt : vec4(0.0);
}
