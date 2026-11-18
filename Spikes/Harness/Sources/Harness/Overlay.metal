#include <metal_stdlib>
using namespace metal;

struct Marker {
    float4 rects[2];   // x, y, width, height in drawable pixels, origin top-left
    float4 color;      // premultiplied, extended linear Display P3
};

vertex float4 fullScreenVertex(uint id [[vertex_id]]) {
    // One triangle that covers the whole drawable.
    float2 p = float2((id << 1) & 2, id & 2);
    return float4(p * 2.0 - 1.0, 0.0, 1.0);
}

fragment half4 markerFragment(float4 position [[position]], constant Marker &marker [[buffer(0)]]) {
    for (int i = 0; i < 2; i++) {
        float4 r = marker.rects[i];
        if (all(position.xy >= r.xy) && all(position.xy < r.xy + r.zw)) {
            return half4(marker.color);
        }
    }
    return half4(0.0h);
}
