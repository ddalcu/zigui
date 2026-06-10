// MSL twin of prim.vert + prim.frag (see those files for the semantics; SDL's
// Metal backend compiles this source at runtime, so macOS needs no offline
// shader toolchain). SDL_GPU binding model: vertex attributes via [[stage_in]],
// uniforms at [[buffer(0)]], sampled textures/samplers at [[texture(0)]]/
// [[sampler(0)]].
#include <metal_stdlib>
using namespace metal;

struct VInput {
    float4 pos        [[attribute(0)]];
    float4 shape      [[attribute(1)]];
    float4 color0     [[attribute(2)]];
    float4 color1     [[attribute(3)]];
    float4 ab         [[attribute(4)]];
    float4 uv         [[attribute(5)]];
    float4 clip       [[attribute(6)]];
    float4 clip_rrect [[attribute(7)]];
    float4 params     [[attribute(8)]];
};

struct Viewport {
    float4 size;
};

struct VOut {
    float4 position [[position]];
    float2 px;
    float2 uv;
    float4 shape      [[flat]];
    float4 color0     [[flat]];
    float4 color1     [[flat]];
    float4 ab         [[flat]];
    float4 clip       [[flat]];
    float4 clip_rrect [[flat]];
    float4 params     [[flat]];
};

vertex VOut prim_vertex(VInput in [[stage_in]],
                        constant Viewport &u [[buffer(0)]],
                        uint vid [[vertex_id]]) {
    float2 corner = float2(float(vid & 1u), float((vid >> 1u) & 1u));
    float2 px = in.pos.xy + corner * in.pos.zw;
    VOut out;
    out.px = px;
    out.uv = mix(in.uv.xy, in.uv.zw, corner);
    out.shape = in.shape;
    out.color0 = in.color0;
    out.color1 = in.color1;
    out.ab = in.ab;
    out.clip = in.clip;
    out.clip_rrect = in.clip_rrect;
    out.params = in.params;
    float2 ndc = px / u.size.xy * 2.0 - 1.0;
    out.position = float4(ndc.x, -ndc.y, 0.0, 1.0);
    return out;
}

static float sdRoundBox(float2 p, float4 rect, float radius) {
    float r = min(radius, min(rect.z, rect.w) * 0.5);
    float2 center = rect.xy + rect.zw * 0.5;
    float2 q = abs(p - center) - (rect.zw * 0.5 - float2(r));
    return length(max(q, float2(0.0))) + min(max(q.x, q.y), 0.0) - r;
}

static float fillCov(float2 p, float4 rect, float radius) {
    return clamp(0.5 - sdRoundBox(p, rect, radius), 0.0, 1.0);
}

static float sdSegment(float2 p, float2 a, float2 b) {
    float2 pa = p - a;
    float2 ba = b - a;
    float len2 = dot(ba, ba);
    float h = len2 > 0.0 ? clamp(dot(pa, ba) / len2, 0.0, 1.0) : 0.0;
    return length(pa - ba * h);
}

fragment float4 prim_fragment(VOut in [[stage_in]],
                              texture2d<float> atlas [[texture(0)]],
                              sampler smp [[sampler(0)]]) {
    int kind = int(in.params.x);
    float radius = in.params.y;
    float half_w = in.params.z;
    float4 color = in.color0;
    float cov = 1.0;

    if (kind == 0) {
        cov = fillCov(in.px, in.shape, radius);
    } else if (kind == 1) {
        float d = abs(sdRoundBox(in.px, in.shape, radius)) - half_w;
        cov = clamp(0.5 - d, 0.0, 1.0);
    } else if (kind == 2) {
        cov = fillCov(in.px, in.shape, radius);
        float2 dir = in.ab.zw - in.ab.xy;
        float len2 = dot(dir, dir);
        float t = len2 > 0.0 ? clamp(dot(in.px - in.ab.xy, dir) / len2, 0.0, 1.0) : 0.0;
        color = mix(in.color0, in.color1, t);
    } else if (kind == 3) {
        cov = atlas.sample(smp, in.uv).a;
    } else if (kind == 4) {
        color = atlas.sample(smp, in.uv);
    } else {
        float d = sdSegment(in.px, in.ab.xy, in.ab.zw) - half_w;
        cov = clamp(0.5 - d, 0.0, 1.0);
    }

    cov *= fillCov(in.px, in.clip, 0.0);
    if (in.params.w > 0.0) cov *= fillCov(in.px, in.clip_rrect, in.params.w);

    return float4(color.rgb, color.a * cov);
}
