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

struct Ramp {
    float width;       // drawable width in pixels
    float maxAlpha;    // darkening at the right edge
    float dither;      // 0 or 1
    float pad;
};

// Interleaved gradient noise in [0, 1): a cheap, high-frequency (blue-noise-like) pattern.
// A real blue-noise texture is not tested here.
static float ign(float2 p) {
    return fract(52.9829189 * fract(dot(p, float2(0.06711056, 0.00583715))));
}

// S2: black with alpha ramping from 0 at the left to maxAlpha at the right (premultiplied).
// The dither is +-0.5 step of an 8-bit channel of interleaved gradient noise, added to alpha.
fragment half4 rampFragment(float4 position [[position]], constant Ramp &ramp [[buffer(0)]]) {
    float a = ramp.maxAlpha * position.x / ramp.width;
    if (ramp.dither > 0.5) {
        a += (ign(position.xy) - 0.5) / 255.0;
    }
    return half4(0.0h, 0.0h, 0.0h, half(clamp(a, 0.0, 1.0)));
}
