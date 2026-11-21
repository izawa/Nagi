#include <metal_stdlib>
using namespace metal;

// Light under water (M4-PLAN). Two passes: points on the water surface each carry their share of
// light to the floor, spread as a Gaussian, into a quarter-size illuminance texture (flat water
// gives 1); then the composite turns illuminance into shade or light at full size.

struct SplatUniforms {
    float4 grid;      // sample region origin (mm), spacing (mm), columns
    float4 target;    // floor origin of the display (mm), mm per texel, waves in use
    float4 light;     // the light's direction of travel in the air above the water, water depth (mm)
    float4 sun;       // the sun's image covariance on the floor (mm²): xx, xy, yy; least variance
    float4 waves[16]; // direction x, y, wavenumber (rad/mm), amplitude (mm)
    float4 phases[4]; // four to an element
    float4 gustGains[4]; // how much each wave answers a gust, four to an element
    float4 front;     // gust fronts' direction (unit), their speed (mm/s), how many gusts
    float4 gusts[8];  // onset − now (s), rise (s), duration (s), strength
};

struct Splat {
    float4 position [[position]];
    float2 centre [[flat]];     // texels
    float3 inverse [[flat]];    // inverse covariance in texels: xx, xy, yy
    float weight [[flat]];      // the point's light over the Gaussian's normalisation
};

static float phaseOf(constant SplatUniforms &u, int i) { return u.phases[i / 4][i % 4]; }

// Gust strength 0…1 at a point on the water (mm): the front reaches points downwind later. The
// same curve as Wind.Gust.envelope in NagiKit (and komorebi's).
static float gustAt(float2 p, constant SplatUniforms &u) {
    float delay = dot(p, u.front.xy) / u.front.z;
    float strongest = 0;
    for (int i = 0; i < int(u.front.w); i++) {
        float4 g = u.gusts[i];
        float s = -g.x - delay;
        if (s <= 0 || s >= g.z) continue;
        strongest = max(strongest, g.w * smoothstep(0.0, g.y, s) * (1.0 - smoothstep(g.y, g.z, s)));
    }
    return strongest;
}

// Where light through the surface point p (mm) lands on the floor (mm).
static float2 landing(float2 p, constant SplatUniforms &u) {
    float height = 0;
    float2 gradient = 0;
    int count = int(u.target.w);
    // Where a gust front has arrived, the short ripples rise: the arcs crowd closer from the
    // windward side first, without a bright band running across.
    float gust = gustAt(p, u);
    for (int i = 0; i < count; i++) {
        float4 w = u.waves[i];
        float amplitude = w.w * (1 + gust * u.gustGains[i / 4][i % 4]);
        float theta = w.z * dot(w.xy, p) + phaseOf(u, i);
        height += amplitude * sin(theta);
        gradient += amplitude * w.z * cos(theta) * w.xy;
    }
    float3 normal = normalize(float3(-gradient, 1));
    float3 ray = refract(u.light.xyz, normal, 1.0 / 1.333);
    float t = (u.light.w + height) / max(-ray.z, 0.05);
    return p + ray.xy * t;
}

// Where every surface point's light lands, once a frame: a grid one larger than the splats', so
// each splat finds its neighbours' landings without working them out again.
kernel void landingKernel(uint2 gid [[thread_position_in_grid]], constant SplatUniforms &u [[buffer(0)]],
                          device float2 *landings [[buffer(1)]], constant uint2 &points [[buffer(2)]]) {
    if (gid.x >= points.x || gid.y >= points.y) return;
    float2 p = u.grid.xy + (float2(gid) + 0.5) * u.grid.z;
    landings[gid.y * points.x + gid.x] = landing(p, u);
}

vertex Splat splatVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                         constant SplatUniforms &u [[buffer(0)]], constant float2 &size [[buffer(1)]],
                         const device float2 *landings [[buffer(2)]]) {
    uint columns = uint(u.grid.w), stride = columns + 1;
    float spacing = u.grid.z;
    uint index = (iid / columns) * stride + iid % columns;
    float2 q = landings[index];
    // How the patch of surface this point stands for is stretched on the floor.
    float2 qx = landings[index + 1], qy = landings[index + stride];
    float2x2 j = float2x2((qx - q) / spacing, (qy - q) / spacing);
    float cell = spacing * spacing / 12;   // a uniform square's variance
    float2x2 c = j * float2x2(cell, 0, 0, cell) * transpose(j);
    float xx = c[0][0] + u.sun.x + u.sun.w, xy = c[1][0] + u.sun.y, yy = c[1][1] + u.sun.z + u.sun.w;
    float texel = u.target.z;
    xx /= texel * texel; xy /= texel * texel; yy /= texel * texel;
    float det = max(xx * yy - xy * xy, 1e-6);
    Splat out;
    out.centre = (q - u.target.xy) / texel;
    out.inverse = float3(yy, -xy, xx) / det;
    out.weight = (spacing / texel) * (spacing / texel) / (2 * M_PI_F * sqrt(det));
    // Three standard deviations either way, but no wider than a light point can matter.
    float2 extent = min(3 * sqrt(float2(xx, yy)), float2(48));
    float2 corner = out.centre + extent * float2(vid & 1 ? 1 : -1, vid & 2 ? 1 : -1);
    out.position = float4(corner / size * float2(2, -2) + float2(-1, 1), 0, 1);
    return out;
}

fragment float splatFragment(Splat in [[stage_in]]) {
    float2 d = in.position.xy - in.centre;
    float e = in.inverse.x * d.x * d.x + 2 * in.inverse.y * d.x * d.y + in.inverse.z * d.y * d.y;
    if (e > 9) discard_fragment();
    return in.weight * exp(-0.5 * e);
}

struct CompositeUniforms {
    float4 output;   // peak alpha, dark (1) or light (0), exposure, contrast
    float4 colour;
};

struct Out { float4 position [[position]]; float2 uv; };

vertex Out compositeVertex(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    Out out;
    out.position = float4(p * 2 - 1, 0, 1);
    out.uv = float2(p.x, 1 - p.y);
    return out;
}

fragment float4 compositeFragment(Out in [[stage_in]], texture2d<float> illuminance [[texture(0)]],
                                  sampler s [[sampler(0)]], constant CompositeUniforms &u [[buffer(0)]]) {
    float lit = illuminance.sample(s, in.uv).r;
    // Clouds, a low sun and entry/exit melt the net towards flat water (1).
    float e = mix(1.0, lit, u.output.w);
    float k = u.output.z;
    float alpha;
    if (u.output.y > 0.5) {
        // Dark: light where it gathers, above what flat water gives.
        alpha = u.output.x * (1 - exp(-k * max(e - 1, 0.0)));
    } else {
        // Light: shade where little light falls; the bright lines leave the page as it is.
        alpha = u.output.x * exp(-k * e) / exp(-k * 0.0);
    }
    if (alpha <= 0.0005) discard_fragment();
    return float4(u.colour.rgb * alpha, alpha);
}
