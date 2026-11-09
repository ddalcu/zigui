// HLSL twin of quad.vert + blur_h.frag + blur_v.frag (see those files for
// the semantics). Compiled at runtime to DXBC SM5.1 by gpu.zig for SDL's
// Direct3D 12 backend; see prim.hlsl for the binding model. Vertex uniforms
// at (b0, space1); pixel texture/sampler at (t0/s0, space2), pixel uniforms
// at (b0, space3).

struct Quad {
    float4 viewport; // width, height (zw unused)
    float4 rect; // x, y, w, h in pixels
};
ConstantBuffer<Quad> uq : register(b0, space1);

struct Blur {
    float4 region; // x0, y0, x1, y1 snapshot bounds (px)
    float4 texel_br; // 1/tex_w, 1/tex_h, box radius, unused
    float4 shape; // blur rect (x, y, w, h)
    float4 tint; // straight-alpha tint composited over the blur
    float4 clip; // axis-aligned clip intersection
    float4 clip_rrect; // innermost rounded clip rect
    float4 radii; // shape corner radius, rounded-clip radius
};
ConstantBuffer<Blur> u : register(b0, space3);

Texture2D<float4> src : register(t0, space2);
SamplerState smp : register(s0, space2);

float4 quad_vertex(uint vid : SV_VertexID) : SV_Position {
    float2 corner = float2((float)(vid & 1u), (float)((vid >> 1u) & 1u));
    float2 px = uq.rect.xy + corner * uq.rect.zw;
    float2 ndc = px / uq.viewport.xy * 2.0 - 1.0;
    return float4(ndc.x, -ndc.y, 0.0, 1.0);
}

float4 blur_h_fragment(float4 pos : SV_Position) : SV_Target0 {
    float2 p = pos.xy;
    float br = u.texel_br.z;
    float4 sum = (float4)0;
    float cnt = 0.0;
    [loop]
    for (float k = -br; k <= br; k += 1.0) {
        float sx = p.x + k;
        if (sx < u.region.x || sx >= u.region.z) continue;
        sum += src.SampleLevel(smp, float2(sx, p.y) * u.texel_br.xy, 0);
        cnt += 1.0;
    }
    return cnt > 0.0 ? sum / max(cnt, 1.0) : (float4)0;
}

float sdRoundBox(float2 p, float4 rect, float radius) {
    float r = min(radius, min(rect.z, rect.w) * 0.5);
    float2 center = rect.xy + rect.zw * 0.5;
    float2 q = abs(p - center) - (rect.zw * 0.5 - r.xx);
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

float fillCov(float2 p, float4 rect, float radius) {
    return saturate(0.5 - sdRoundBox(p, rect, radius));
}

float4 blur_v_fragment(float4 pos : SV_Position) : SV_Target0 {
    float2 p = pos.xy;
    float br = u.texel_br.z;
    float4 sum = (float4)0;
    float cnt = 0.0;
    [loop]
    for (float k = -br; k <= br; k += 1.0) {
        float sy = p.y + k;
        if (sy < u.region.y || sy >= u.region.w) continue;
        sum += src.SampleLevel(smp, float2(p.x, sy) * u.texel_br.xy, 0);
        cnt += 1.0;
    }
    float4 blurred = cnt > 0.0 ? sum / max(cnt, 1.0) : (float4)0;

    // tint.over(blurred), straight alpha.
    float oa = u.tint.a + blurred.a * (1.0 - u.tint.a);
    float3 orgb = oa > 0.0
        ? (u.tint.rgb * u.tint.a + blurred.rgb * blurred.a * (1.0 - u.tint.a)) / max(oa, 1e-30)
        : (float3)0;

    float cov = fillCov(p, u.shape, u.radii.x);
    cov *= fillCov(p, u.clip, 0.0);
    if (u.radii.y > 0.0) cov *= fillCov(p, u.clip_rrect, u.radii.y);

    return float4(orgb, cov);
}
