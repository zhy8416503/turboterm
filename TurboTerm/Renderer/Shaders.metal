#include <metal_stdlib>
using namespace metal;

// 终端格子顶点: 背景色 + 字形 alpha 混合, 一次 draw call 画全屏
struct TermVertexIn {
    float2 pos    [[attribute(0)]];  // 设备像素, 左上原点
    float2 uv     [[attribute(1)]];  // 图集 uv
    float2 cellUV [[attribute(2)]];  // 格子内 uv (0..1, 左上 0,0)
    float4 fg     [[attribute(3)]];
    float4 bg     [[attribute(4)]];
    float  flags  [[attribute(5)]];  // bit1 = 下划线
};

struct TermVertexOut {
    float4 pos [[position]];
    float2 uv;
    float2 cellUV;
    float4 fg;
    float4 bg;
    float  flags;
};

vertex TermVertexOut term_vertex(TermVertexIn in [[stage_in]],
                                 constant float2 &viewportSize [[buffer(1)]]) {
    TermVertexOut out;
    float2 ndc = in.pos / viewportSize * 2.0f - 1.0f;
    ndc.y = -ndc.y;
    out.pos = float4(ndc, 0.0f, 1.0f);
    out.uv = in.uv;
    out.cellUV = in.cellUV;
    out.fg = in.fg;
    out.bg = in.bg;
    out.flags = in.flags;
    return out;
}

fragment float4 term_fragment(TermVertexOut in [[stage_in]],
                              texture2d<float> atlas [[texture(0)]]) {
    constexpr sampler smp(coord::normalized, filter::linear,
                          address::clamp_to_edge);
    float a = atlas.sample(smp, in.uv).r;
    float3 col = mix(in.bg.rgb, in.fg.rgb, a);
    // 下划线: 格子底部 ~10% 画前景色横线
    if (((int(in.flags) & 2) != 0) && in.cellUV.y > 0.90f) {
        col = in.fg.rgb;
    }
    return float4(col, 1.0f);
}
