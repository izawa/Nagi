#include <metal_stdlib>
using namespace metal;

struct FullscreenOut {
    float4 position [[position]];
};

// One triangle that covers the target.
vertex FullscreenOut fullscreenVertex(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    FullscreenOut out;
    out.position = float4(p * 2 - 1, 0, 1);
    return out;
}

// sRGB transfer, extended to negative and above-1 values by symmetry and continuation.
static float encodeSRGB(float x) {
    float a = abs(x);
    float y = a <= 0.0031308 ? 12.92 * a : 1.055 * pow(a, 1.0 / 2.4) - 0.055;
    return sign(x) * y;
}

static float decodeSRGB(float x) {
    float a = abs(x);
    float y = a <= 0.04045 ? a / 12.92 : pow((a + 0.055) / 1.055, 2.4);
    return sign(x) * y;
}

static float3 encodeSRGB3(float3 c) { return float3(encodeSRGB(c.r), encodeSRGB(c.g), encodeSRGB(c.b)); }
static float3 decodeSRGB3(float3 c) { return float3(decodeSRGB(c.r), decodeSRGB(c.g), decodeSRGB(c.b)); }

// The layers are stacked in encoded, premultiplied values (P, A), each one put over what is below
// it by the rule WindowServer uses for the desktop (D1, DECISIONS D40). Source-over in these
// values is that rule, and it chains: a layer looks the same over Nagi's lower layers as over the
// desktop.

// One effect's layer (linear, premultiplied, as the effect drew it) in encoded values, for
// source-over onto the stack.
fragment float4 layerFragment(FullscreenOut in [[stage_in]],
                              texture2d<float, access::read> layer [[texture(0)]],
                              constant float &gain [[buffer(0)]]) {
    float4 c = layer.read(uint2(in.position.xy));
    if (c.a <= 0) return float4(0);
    return float4(c.a * encodeSRGB3(c.rgb / c.a), c.a);
}

// What a `.backdrop` effect sees: the stack so far over the backdrop (encoded). Output: encoded.
fragment half4 stackOverBackdropFragment(FullscreenOut in [[stage_in]],
                                         texture2d<float, access::read> background [[texture(0)]],
                                         texture2d<float, access::read> stack [[texture(1)]],
                                         constant float &gain [[buffer(0)]]) {
    uint2 p = uint2(in.position.xy);
    float4 s = stack.read(p);
    return half4(half3(background.read(p).rgb * (1 - s.a) + s.rgb), 1);
}

// The last pass of a live frame: the stack back in linear premultiplied values, which
// WindowServer puts over the desktop, times presence and strength. Colour and alpha both scale,
// so zero gain is exactly transparent (SPEC 3.3).
fragment float4 stackOutputFragment(FullscreenOut in [[stage_in]],
                                    texture2d<float, access::read> stack [[texture(0)]],
                                    constant float &gain [[buffer(0)]]) {
    float4 s = stack.read(uint2(in.position.xy));
    if (s.a <= 0 || gain <= 0) return float4(0);
    return float4(s.a * decodeSRGB3(s.rgb / s.a), s.a) * gain;
}

// How WindowServer put an overlay over the desktop in M0 (SPEC 3.5, SPIKES S2):
// enc(screen) = enc(below) × (1 − α) + α × enc(C / α). Alpha zero adds nothing.
// background: encoded Display P3. overlay: premultiplied, linear Display P3. Output: encoded.
fragment half4 desktopBlendFragment(FullscreenOut in [[stage_in]],
                                    texture2d<float, access::read> background [[texture(0)]],
                                    texture2d<float, access::read> overlay [[texture(1)]],
                                    constant float &gain [[buffer(0)]]) {
    uint2 p = uint2(in.position.xy);
    float3 below = background.read(p).rgb;
    float4 over = overlay.read(p) * gain;
    float3 result = below;
    if (over.a > 0) {
        float3 colour = over.rgb / over.a;
        result = below * (1 - over.a) + over.a * encodeSRGB3(colour);
    }
    return half4(half3(result), 1);
}
