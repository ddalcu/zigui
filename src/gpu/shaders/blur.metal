// MSL twin of quad.vert + blur_h.frag + blur_v.frag (see those files for the
// semantics). SDL_GPU binding model: uniforms at [[buffer(0)]], sampled
// texture/sampler at [[texture(0)]]/[[sampler(0)]].
#include <metal_stdlib>
using namespace metal;

struct Quad {
    float4 viewport;
    float4 rect;
};

struct Blur {
    float4 region;
    float4 texel_br;
    float4 shape;
    float4 tint;
    float4 clip;
    float4 clip_rrect;
    float4 radii;
};

struct QOut {
    float4 position [[position]];
};

vertex QOut quad_vertex(constant Quad &u [[buffer(0)]], uint vid [[vertex_id]]) {
    float2 corner = float2(float(vid & 1u), float((vid >> 1u) & 1u));
    float2 px = u.rect.xy + corner * u.rect.zw;
    float2 ndc = px / u.viewport.xy * 2.0 - 1.0;
    QOut out;
    out.position = float4(ndc.x, -ndc.y, 0.0, 1.0);
    return out;
}

fragment float4 blur_h_fragment(QOut in [[stage_in]],
                                texture2d<float> src [[texture(0)]],
                                sampler smp [[sampler(0)]],
                                constant Blur &u [[buffer(0)]]) {
    float2 p = in.position.xy;
    float br = u.texel_br.z;
    float4 sum = float4(0.0);
    float cnt = 0.0;
    for (float k = -br; k <= br; k += 1.0) {
        float sx = p.x + k;
        if (sx < u.region.x || sx >= u.region.z) continue;
        sum += src.sample(smp, float2(sx, p.y) * u.texel_br.xy);
        cnt += 1.0;
    }
    return cnt > 0.0 ? sum / cnt : float4(0.0);
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

fragment float4 blur_v_fragment(QOut in [[stage_in]],
                                texture2d<float> src [[texture(0)]],
                                sampler smp [[sampler(0)]],
                                constant Blur &u [[buffer(0)]]) {
    float2 p = in.position.xy;
    float br = u.texel_br.z;
    float4 sum = float4(0.0);
    float cnt = 0.0;
    for (float k = -br; k <= br; k += 1.0) {
        float sy = p.y + k;
        if (sy < u.region.y || sy >= u.region.w) continue;
        sum += src.sample(smp, float2(p.x, sy) * u.texel_br.xy);
        cnt += 1.0;
    }
    float4 blurred = cnt > 0.0 ? sum / cnt : float4(0.0);

    float oa = u.tint.a + blurred.a * (1.0 - u.tint.a);
    float3 orgb = oa > 0.0
        ? (u.tint.rgb * u.tint.a + blurred.rgb * blurred.a * (1.0 - u.tint.a)) / oa
        : float3(0.0);

    float cov = fillCov(p, u.shape, u.radii.x);
    cov *= fillCov(p, u.clip, 0.0);
    if (u.radii.y > 0.0) cov *= fillCov(p, u.clip_rrect, u.radii.y);

    return float4(orgb, cov);
}
