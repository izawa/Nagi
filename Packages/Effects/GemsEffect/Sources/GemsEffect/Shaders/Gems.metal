#include <metal_stdlib>
using namespace metal;

// Gems (M5-PLAN). Each instance is one crystal: a hexagonal prism standing on a window's top
// edge, seen side-on, closed by a pointed tip. Each visible face shifts the screen behind it by
// its own amount (the refraction), so a line crossing the crystal breaks at its ridges.

struct Instance {
    float4 axis;    // root x, y; unit axis toward the tip x, y (pixels, y down)
    float4 shape;   // length, width (pixels), spin 0…1, number of fronts
    float4 tint;    // body colour (linear), grown 0…1
    float4 light;   // the cluster's deep light x, y, its depth behind the screen (pixels)
    float4 fronts[16];
};

struct Uniforms {
    float4 target;  // output width, height, pixels per point, 1 when dark
    float4 light;   // toward the sun or moon (x right, y down, z out), the glint's strength
    float4 look;    // refraction, ridge, (unused), dispersion
    float4 glow;    // glow strength, the quad's margin (pixels), presence
    float4 glint;   // the glint's colour
    float4 deep;    // the deep light's strength, how much the body around it darkens (light screen)
};

struct GemOut {
    float4 position [[position]];
    uint crystal [[flat]];
};

vertex GemOut gemVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                        const device Instance *crystals [[buffer(0)]],
                        constant Uniforms &u [[buffer(1)]], constant float &margin [[buffer(2)]]) {
    const device Instance &c = crystals[iid];
    float2 axis = c.axis.zw, across = float2(-axis.y, axis.x);
    float half_ = c.shape.y * 0.5 + margin;
    float along = (vid >> 1) ? c.shape.x + margin : -margin;
    float side = (vid & 1) ? half_ : -half_;
    float2 p = c.axis.xy + axis * along + across * side;
    float2 clip = p / u.target.xy * 2 - 1;
    GemOut out;
    out.position = float4(clip.x, -clip.y, 0, 1);
    out.crystal = iid;
    return out;
}

static float3 linearize(float3 c) { return select(pow((c + 0.055) / 1.055, 2.4), c / 12.92, c <= 0.04045); }

// Whether p is inside a window in front (rounded as the shader for moss assumes, 16 pt).
static bool covered(const device Instance &c, float2 p, float radius) {
    int count = int(c.shape.w);
    for (int i = 0; i < count; i++) {
        float4 r = c.fronts[i];
        // A small panel's corners can be no rounder than half its size.
        float rr = min(radius, 0.5 * min(r.z - r.x, r.w - r.y));
        float2 q = clamp(p, r.xy + rr, r.zw - rr);
        if (all(p >= r.xy) && all(p <= r.zw) && length(p - q) <= rr) return true;
    }
    return false;
}

fragment float4 gemFragment(GemOut in [[stage_in]], texture2d<float> backdrop [[texture(0)]],
                            const device Instance *crystals [[buffer(0)]], constant Uniforms &u [[buffer(1)]]) {
    const device Instance &c = crystals[in.crystal];
    float2 p = in.position.xy;
    float scale = u.target.z;
    if (covered(c, p, 16 * scale)) discard_fragment();

    float2 axis = c.axis.zw, across = float2(-axis.y, axis.x);
    float2 q = p - c.axis.xy;
    float v = dot(q, axis), x = dot(q, across);
    float L = c.shape.x, W = c.shape.y, R = W * 0.5;
    // The body widens a little from the root toward the tip, then the faces close quickly to a
    // point over the last 0.8 widths (the shape the author chose at W1). W is the widest.
    float tip = min(W * 0.8, L * 0.5);
    float body = max(L - tip, 1e-3);
    float halfWidth = R * (0.72 + 0.28 * clamp(v / body, 0.0, 1.0)) * clamp((L - v) / tip, 0.0, 1.0);

    // A soft contact shadow where the crystal meets the edge, outside it.
    float base = exp(-max(-v, 0.0) / (1.2 * scale)) * (1 - smoothstep(R * 0.3, R + 2 * scale, abs(x))) * step(v, 1.0);
    float shadow = 0.10 * base * smoothstep(-2 * scale, 0.0, v + 2 * scale);

    float edge = clamp(halfWidth - abs(x) + 0.5, 0.0, 1.0) * clamp(v + 0.5, 0.0, 1.0) * clamp(L - v + 0.5, 0.0, 1.0);
    // A slight glow around the stone, in its colour (the author at W1): fading over a few points
    // outside the outline. Not along the root, which stands on the window.
    // The line's colour, and a deeper one for the glow: a pale glow over a dark screen read as
    // white once several crystals' glows overlapped (the author at W1).
    float3 lineColour = clamp(1 - 2 * (1 - c.tint.rgb), 0.0, 1.0);
    float3 glowColour = clamp(1 - 4 * (1 - c.tint.rgb), 0.0, 1.0);
    float outside = max(abs(x) - halfWidth, v - L);
    // A Gaussian falloff, gone well before the quad's edge, so no cut-off edge shows; small
    // crystals glow less, so the glows of a cluster do not pile up to white.
    float reach = (3 + 3 * u.glow.x) * scale;
    float d = max(outside, 0.0) / reach;
    float glow = c.tint.w * min(u.glow.x * 0.22, 0.45) * clamp(W / (14 * scale), 0.25, 1.0) * exp(-d * d)
        * smoothstep(-1.0, 2 * scale, v) * (1 - smoothstep(0.6 * u.glow.y, 0.95 * u.glow.y, max(outside, 0.0)));
    if (edge <= 0) {
        if (shadow + glow <= 0.002) discard_fragment();
        // The glow over the contact shadow (premultiplied).
        return float4(glowColour * glow, glow + shadow * (1 - glow));
    }

    // Which face: across the crystal, s runs −1…1 (converging to the apex in the tip). The faces
    // of the hexagon are 60° apart, turned by the spin; a face is seen when it faces the viewer.
    // The visible faces span from the leftmost to the rightmost projected corner; the drawn
    // outline is stretched over that span, so every point of it falls on a face.
    float turn = 6.2831853 * c.shape.z;
    float left = 1, right = -1;
    for (int k = 0; k < 6; k++) {
        float centre = turn + float(k) * 1.0471976;
        if (cos(centre) <= 0) continue;
        left = min(left, sin(centre - 0.5235988));
        right = max(right, sin(centre + 0.5235988));
    }
    float s = mix(left, right, clamp(x / max(halfWidth, 1e-3), -1.0, 1.0) * 0.5 + 0.5);
    float inTip = smoothstep(L - tip, L - tip + scale, v);
    float3 normal = float3(0, 0, 1);
    float ridge = 1;
    for (int k = 0; k < 6; k++) {
        float centre = turn + float(k) * 1.0471976;
        if (cos(centre) <= 0) continue;
        float lo = sin(centre - 0.5235988), hi = sin(centre + 0.5235988);
        if (s < lo || s > hi) continue;
        normal = float3(sin(centre), 0, cos(centre));
        ridge = min(s - lo, hi - s) / max(right - left, 1e-3) * 2 * halfWidth;
        break;
    }
    // Tip faces lean toward the tip.
    normal = normalize(float3(normal.x, 0.9 * inTip, normal.z));
    // Faces turned to the side, and the tip, shift the screen behind more; the face facing the
    // viewer hardly at all (a flat slab barely moves what is seen through it).
    float2 tilt = across * normal.x + axis * normal.y;
    float2 shift = -tilt * u.look.x * W;
    // Never show through what a window in front shows (every colour's sample): there, see
    // straight through instead.
    float spread = u.look.w * 0.06;
    if (covered(c, p + shift * (1 - spread), 16 * scale) || covered(c, p + shift, 16 * scale)
        || covered(c, p + shift * (1 + spread), 16 * scale)) shift = 0;
    float2 size = float2(backdrop.get_width(), backdrop.get_height());
    constexpr sampler smp(filter::linear, address::clamp_to_edge);
    float3 colour;
    for (int ch = 0; ch < 3; ch++) {
        float2 at = p + shift * (1 + (float(ch) - 1) * spread);
        colour[ch] = linearize(backdrop.sample(smp, at / size).rgb)[ch];
    }

    bool dark = u.target.w > 0.5;
    // The body colour, a little deeper toward the root where the light has crossed more stone.
    float depthHere = 0.6 + 0.4 * clamp(1 - v / max(L, 1e-3), 0.0, 1.0);
    colour *= mix(float3(1), c.tint.rgb, depthHere);
    // Faces turned away reflect more of the sky (Fresnel).
    float grazing = pow(1 - normal.z, 3.0);
    float3 sky = dark ? float3(0.018, 0.022, 0.03) : float3(0.93, 0.95, 0.98);
    colour = mix(colour, sky, 0.5 * grazing);
    // The deep light: a point behind the root, seen through each face. A face tilted by `tilt`
    // shows it displaced along the tilt, so one point falls apart at the ridges into several
    // images. Soft, a few points across, and less in small and young crystals, so the base does
    // not light up as a row of lamps. On a dark screen a pale image; on a light one the stone's
    // deeper colour, read by colour and shape (no light brighter than white, M5-PLAN 3).
    if (u.deep.x > 0) {
        float sigma = 2.5 * scale;
        float2 image = c.light.xy + c.light.z * tilt;
        float d2 = length_squared(p - image) / (sigma * sigma);
        float k = u.deep.x * c.tint.w * clamp(W / (14 * scale), 0.25, 1.0);
        float core = exp(-0.5 * d2) * k;
        if (!dark) colour *= 1 - 0.6 * u.deep.y * k * (exp(-0.125 * d2) - exp(-0.5 * d2));
        colour = mix(colour, dark ? lineColour : glowColour, core);
    }
    // Lines along the crystal's straight edges (the author at W1: refraction alone was hard to
    // see): where two faces meet, the outline, and where the tip faces begin. White for quartz,
    // pale blue for aquamarine and topaz. On a light screen a thin grey beside the line lets a
    // white line read on white.
    float lineDistance = min(ridge, abs(v - (L - tip)) + (1 - step(1.0, halfWidth)) * 1e3);
    float line = (1 - smoothstep(0.15 * scale, 0.6 * scale, lineDistance)) * u.look.y;
    if (!dark) colour *= 1 - 0.18 * u.look.y * (1 - smoothstep(0.6 * scale, 1.4 * scale, lineDistance)) * (1 - line);
    colour = mix(colour, lineColour, line);
    // One face may catch the sun.
    float3 h = normalize(u.light.xyz + float3(0, 0, 1));
    float3 screenNormal = float3(across * normal.x + axis * normal.y, normal.z);
    // A flat face would light all over; the sheen runs across it in a soft band instead, as a
    // face that is never quite flat.
    float band = exp(-pow((v / max(L, 1e-3) - 0.62) / 0.12, 2.0));
    // The glint comes in after the stone on entry and goes first on leaving (glow.z: presence).
    float glint = u.light.w > 0 ? pow(max(dot(screenNormal, h), 0.0), 300.0) * u.light.w * u.glow.z * band : 0;
    colour += glint * (dark ? 0.15 : 0.25) * u.glint.rgb;

    // The glow lies over the stone too, a little.
    colour = mix(colour, glowColour, glow * 0.5);
    // Never above SDR white: the flash check cannot count what is brighter (M5-PLAN 3).
    colour = min(colour, float3(1));
    // The stone over its glow and shadow, so its antialiased rim blends into the halo.
    float4 halo = float4(glowColour * glow, glow + shadow * (1 - glow));
    return float4(colour * edge, edge) + halo * (1 - edge);
}
