#include <metal_stdlib>
using namespace metal;

// Fireflies (M7-PLAN 5). Each instance is one light: a core and its glow in one smooth falloff,
// or for a near firefly a soft out-of-focus disc; on a light screen it may darken around itself
// (the "shade" look) or go above SDR white (the "bright" look, the colour carries the gain).

struct Instance {
    float4 centre;  // x, y (pixels), the core's spread, the glow's spread (pixels)
    float4 shape;   // out-of-focus radius, the quad's half size, alpha now, the shade's spread
};

struct Uniforms {
    float4 target;  // output width, height, look (0 plain, 1 shade, 2 bright), the shade's alpha
    float4 look;    // the glow's share of the core's alpha
    float4 colour;  // linear colour of the light
    float4 core;    // linear colour at the core
    float4 shade;   // the colour around a light in the shade look
};

struct FireflyOut {
    float4 position [[position]];
    float2 offset;  // from the centre, pixels
    uint light [[flat]];
};

vertex FireflyOut fireflyVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                constant Instance *lights [[buffer(0)]],
                                constant Uniforms &u [[buffer(1)]]) {
    constant Instance &l = lights[iid];
    float2 offset = float2((vid & 1) ? 1 : -1, (vid >> 1) ? 1 : -1) * l.shape.y;
    float2 clip = (l.centre.xy + offset) / u.target.xy * 2 - 1;
    FireflyOut out;
    out.position = float4(clip.x, -clip.y, 0, 1);
    out.offset = offset;
    out.light = iid;
    return out;
}

fragment float4 fireflyFragment(FireflyOut in [[stage_in]],
                                constant Instance *lights [[buffer(0)]],
                                constant Uniforms &u [[buffer(1)]]) {
    constant Instance &l = lights[in.light];
    float r = length(in.offset);
    float coreSpread = l.centre.z, glowSpread = l.centre.w, blur = l.shape.x;
    // In focus: a sharp core in a wider glow, one falloff. Out of focus: the light spread over a
    // disc with a soft rim, dimmer for its size, still inside its glow.
    float core = exp(-0.5 * (r * r) / (coreSpread * coreSpread));
    float glow = exp(-0.5 * (r * r) / (glowSpread * glowSpread));
    float point = core + u.look.x * glow;
    if (blur > 0) {
        float disc = 1 - smoothstep(0.7 * blur, blur, r);
        float spread = clamp(blur / (3 * coreSpread), 0.0, 1.0);
        point = mix(point, 0.45 * disc + u.look.x * glow, spread);
    }
    // Fade to nothing before the quad's edge, so no square shows.
    float edge = 1 - smoothstep(0.8 * l.shape.y, l.shape.y, r);
    float a = clamp(l.shape.z * point * edge, 0.0, 1.0);
    float3 colour = mix(u.colour.rgb, u.core.rgb, 0.5 * core);
    float4 light = float4(colour * a, a);
    if (u.target.z == 1) {
        // The shade look: a dark halo that comes and goes with the light, under it.
        float s = u.target.w * l.shape.z * exp(-0.5 * (r * r) / (l.shape.w * l.shape.w)) * edge;
        s = clamp(s, 0.0, 1.0);
        light += float4(u.shade.rgb * s, s) * (1 - a);
    }
    return light;
}

// The inner orb (W1 trial): a smaller light of the first, yellower colour, with an edge that can
// be told, blurred as the light is, trailing behind it. Instance: centre = x, y, radius, the edge's
// half width; shape = blur, the quad's half size, alpha now, unused. `u.colour` is the orb's colour.
fragment float4 orbFragment(FireflyOut in [[stage_in]],
                            constant Instance *lights [[buffer(0)]],
                            constant Uniforms &u [[buffer(1)]]) {
    constant Instance &l = lights[in.light];
    float r = length(in.offset);
    float radius = l.centre.z, blur = l.shape.x;
    // Blurred, the edge widens by the blur and the light spreads over a larger disc.
    float edge = l.centre.w + 0.5 * blur;
    float disc = 1 - smoothstep(radius - edge, radius + edge, r);
    float spread = radius * radius / (radius * radius + 0.25 * blur * blur);
    float fade = 1 - smoothstep(0.8 * l.shape.y, l.shape.y, r);
    float a = clamp(l.shape.z * disc * spread * fade, 0.0, 1.0);
    return float4(u.colour.rgb * a, a);
}
