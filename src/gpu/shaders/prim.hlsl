// HLSL twin of prim.vert + prim.frag (see those files for the semantics).
// SDL's Direct3D 12 backend on Windows consumes DXBC; gpu.zig compiles this
// source at runtime with D3DCompile (d3dcompiler_47.dll ships with Windows),
// targeting shader model 5.1, so no offline shader toolchain is needed.
//
// SDL_GPU binding model for DXBC: vertex attributes use semantic TEXCOORD<n>
// where n = attribute location; vertex uniforms at (b0, space1); pixel
// textures/samplers at (t0/s0, space2). Sampling uses SampleLevel(…, 0): the
// atlas has a single mip and nearest filtering, so it is identical to an
// implicit-derivative sample but legal inside non-uniform branches.

struct Viewport {
    float4 size; // viewport width, height in pixels (zw unused)
};
ConstantBuffer<Viewport> u : register(b0, space1);

Texture2D<float4> atlas : register(t0, space2);
SamplerState smp : register(s0, space2);

struct VInput {
    float4 pos        : TEXCOORD0;
    float4 shape      : TEXCOORD1;
    float4 color0     : TEXCOORD2;
    float4 color1     : TEXCOORD3;
    float4 ab         : TEXCOORD4;
    float4 uv         : TEXCOORD5;
    float4 clip       : TEXCOORD6;
    float4 clip_rrect : TEXCOORD7;
    float4 params     : TEXCOORD8;
    uint vid          : SV_VertexID;
};

struct VOut {
    float4 position                   : SV_Position;
    float2 px                         : TEXCOORD0;
    float2 uv                         : TEXCOORD1;
    nointerpolation float4 shape      : TEXCOORD2;
    nointerpolation float4 color0     : TEXCOORD3;
    nointerpolation float4 color1     : TEXCOORD4;
    nointerpolation float4 ab         : TEXCOORD5;
    nointerpolation float4 clip       : TEXCOORD6;
    nointerpolation float4 clip_rrect : TEXCOORD7;
    nointerpolation float4 params     : TEXCOORD8;
};

VOut prim_vertex(VInput i) {
    // Strip corners: (0,0) (1,0) (0,1) (1,1).
    float2 corner = float2((float)(i.vid & 1u), (float)((i.vid >> 1u) & 1u));
    float2 px = i.pos.xy + corner * i.pos.zw;
    VOut o;
    o.px = px;
    o.uv = lerp(i.uv.xy, i.uv.zw, corner);
    o.shape = i.shape;
    o.color0 = i.color0;
    o.color1 = i.color1;
    o.ab = i.ab;
    o.clip = i.clip;
    o.clip_rrect = i.clip_rrect;
    o.params = i.params;
    float2 ndc = px / u.size.xy * 2.0 - 1.0;
    // SDL_GPU NDC is +Y up on every backend; pixel space is +Y down.
    o.position = float4(ndc.x, -ndc.y, 0.0, 1.0);
    return o;
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

float sdSegment(float2 p, float2 a, float2 b) {
    float2 pa = p - a;
    float2 ba = b - a;
    float len2 = dot(ba, ba);
    float h = len2 > 0.0 ? saturate(dot(pa, ba) / len2) : 0.0;
    return length(pa - ba * h);
}

float4 prim_fragment(VOut i) : SV_Target0 {
    int kind = (int)i.params.x;
    float radius = i.params.y;
    float half_w = i.params.z;
    float4 color = i.color0;
    float cov = 1.0;

    if (kind == 0) { // fill_rrect
        cov = fillCov(i.px, i.shape, radius);
    } else if (kind == 1) { // stroke_rrect (centered on the edge)
        float d = abs(sdRoundBox(i.px, i.shape, radius)) - half_w;
        cov = saturate(0.5 - d);
    } else if (kind == 2) { // linear_gradient clipped to a rounded rect
        cov = fillCov(i.px, i.shape, radius);
        float2 dir = i.ab.zw - i.ab.xy;
        float len2 = dot(dir, dir);
        float t = len2 > 0.0 ? saturate(dot(i.px - i.ab.xy, dir) / len2) : 0.0;
        color = lerp(i.color0, i.color1, t);
    } else if (kind == 3) { // glyph: coverage in atlas alpha, tinted by color0
        cov = atlas.SampleLevel(smp, i.uv, 0).a;
        // Coverage gamma (text contrast) in params.y; see prim.frag.
        if (i.params.y != 1.0) cov = pow(abs(cov), i.params.y);
    } else if (kind == 4) { // image: RGBA straight from the atlas
        color = atlas.SampleLevel(smp, i.uv, 0);
    } else { // line segment with round caps
        float d = sdSegment(i.px, i.ab.xy, i.ab.zw) - half_w;
        cov = saturate(0.5 - d);
    }

    // Clip: axis-aligned intersection of the stack + innermost rounded clip.
    cov *= fillCov(i.px, i.clip, 0.0);
    if (i.params.w > 0.0) cov *= fillCov(i.px, i.clip_rrect, i.params.w);

    return float4(color.rgb, color.a * cov);
}
