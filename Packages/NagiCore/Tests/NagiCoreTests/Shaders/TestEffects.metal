#include <metal_stdlib>
using namespace metal;

struct Out { float4 position [[position]]; };

vertex Out testFullscreenVertex(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    Out out;
    out.position = float4(p * 2 - 1, 0, 1);
    return out;
}

struct PatchUniforms {
    float4 rect;   // x0, y0, x1, y1 in pixels
    float4 color;  // premultiplied
};

fragment float4 patchFragment(Out in [[stage_in]], constant PatchUniforms &u [[buffer(0)]]) {
    float2 p = in.position.xy;
    if (p.x < u.rect.x || p.y < u.rect.y || p.x >= u.rect.z || p.y >= u.rect.w) discard_fragment();
    return u.color;
}

kernel void sampleTexture(texture2d<float, access::read> t [[texture(0)]],
                          device float4 *out [[buffer(0)]],
                          constant uint2 &point [[buffer(1)]]) {
    out[0] = t.read(point);
}
