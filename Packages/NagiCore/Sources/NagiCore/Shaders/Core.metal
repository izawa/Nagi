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

// The last pass of a live frame: the composited effects times presence and strength.
// Colour and alpha both scale, so zero gain is exactly transparent (SPEC 3.3).
fragment half4 gainFragment(FullscreenOut in [[stage_in]],
                            texture2d<half, access::read> source [[texture(0)]],
                            constant float &gain [[buffer(0)]]) {
    return source.read(uint2(in.position.xy)) * half(gain);
}

// sRGB transfer, extended to negative and above-1 values by symmetry and continuation.
static float encodeSRGB(float x) {
    float a = abs(x);
    float y = a <= 0.0031308 ? 12.92 * a : 1.055 * pow(a, 1.0 / 2.4) - 0.055;
    return sign(x) * y;
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
        float3 encoded = float3(encodeSRGB(colour.r), encodeSRGB(colour.g), encodeSRGB(colour.b));
        result = below * (1 - over.a) + over.a * encoded;
    }
    return half4(half3(result), 1);
}
