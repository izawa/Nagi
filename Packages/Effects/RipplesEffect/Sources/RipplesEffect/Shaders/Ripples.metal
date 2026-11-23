#include <metal_stdlib>
using namespace metal;

// Ripples (M6-PLAN): see Ripples.swift for the passes.

struct ProfileDrop {
    uint offset;     // where this drop's coefficients start
    uint count;
    float dk;        // wavenumber step (rad/m)
    float reach;     // mm
};

struct GridUniforms {
    float4 size;     // grid cells (x, y), wave sources
};

struct CompositeUniforms {
    float4 target;       // output size (px), mm per px, 1 for dark
    float4 optics;       // grid size (cells), optical depth (mm), shadow strength
    float4 shadowShift;  // px
    float4 lightColour;  // linear
};

// Bessel J1 (Numerical Recipes' rational approximations).
static float besselJ1(float x) {
    float ax = fabs(x);
    if (ax < 8.0) {
        float y = x * x;
        float a = x * (72362614232.0 + y * (-7895059235.0 + y * (242396853.1 + y * (-2972611.439
                  + y * (15704.48260 + y * (-30.16036606))))));
        float b = 144725228442.0 + y * (2300535178.0 + y * (18583304.74 + y * (99447.43394
                  + y * (376.9991397 + y))));
        return a / b;
    }
    float z = 8.0 / ax, y = z * z, xx = ax - 2.356194491;
    float a = 1.0 + y * (0.183105e-2 + y * (-0.3516396496e-4 + y * (0.2457520174e-5 + y * (-0.240337019e-6))));
    float b = 0.04687499995 + y * (-0.2002690873e-3 + y * (0.8449199096e-5 + y * (-0.88228987e-6 + y * 0.105787412e-6)));
    float r = sqrt(0.636619772 / ax) * (cos(xx) * a - z * sin(xx) * b);
    return x < 0 ? -r : r;
}

// The radial slope of one drop's surface at radius gid.x mm: the coefficients (Water.slopeCoefficients,
// everything but J1, for this drop's age) summed against J1(kr).
kernel void rippleProfile(texture2d<float, access::write> profile [[texture(0)]],
                          constant ProfileDrop *drops [[buffer(0)]],
                          const device float *coefficients [[buffer(1)]],
                          uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= profile.get_width() || gid.y >= profile.get_height()) return;
    ProfileDrop d = drops[gid.y];
    float rmm = float(gid.x);
    if (rmm > d.reach * 1.1) { profile.write(float4(0), gid); return; }
    float r = rmm * 0.001;
    float sum = 0;
    for (uint i = 0; i < d.count; i++) {
        sum += coefficients[d.offset + i] * besselJ1((float(i) + 0.5) * d.dk * r);
    }
    // Past the reach the waves left are faint: fade there (the images are taken out to 1.1 of it).
    profile.write(float4(sum * (1.0 - smoothstep(d.reach * 0.9, d.reach * 1.1, rmm))), gid);
}

// The slope (∂h/∂x, ∂h/∂y) at each 1 mm cell: every drop and mirror image adds its radial slope
// along the direction away from it.
kernel void rippleGrid(texture2d<float, access::sample> profile [[texture(0)]],
                       texture2d<float, access::write> grid [[texture(1)]],
                       constant float4 *sources [[buffer(0)]],
                       constant GridUniforms &u [[buffer(1)]],
                       uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= grid.get_width() || gid.y >= grid.get_height()) return;
    constexpr sampler smp(coord::pixel, filter::linear, address::clamp_to_zero);
    float2 p = float2(gid) + 0.5;
    float reachLimit = float(profile.get_width() - 1);
    float2 slope = 0;
    int count = int(u.size.z);
    for (int i = 0; i < count; i++) {
        float4 src = sources[i];
        float2 d = p - src.xy;
        float r = length(d);
        if (r >= reachLimit || r < 1e-3) continue;
        float radial = profile.sample(smp, float2(r + 0.5, src.w + 0.5)).r;
        slope += radial * src.z * d / r;
    }
    grid.write(float4(slope, 0, 0), gid);
}

struct RippleOut {
    float4 position [[position]];
};

vertex RippleOut rippleVertex(uint vid [[vertex_id]]) {
    float2 uv = float2((vid << 1) & 2, vid & 2);
    RippleOut out;
    out.position = float4(uv * 2.0 - 1.0, 0, 1);
    return out;
}

static float3 linearize(float3 c) { return select(pow((c + 0.055) / 1.055, 2.4), c / 12.92, c <= 0.04045); }

// Bends the screen under the water and lights it with what the waves gather (M6-PLAN 3).
fragment float4 rippleFragment(RippleOut in [[stage_in]],
                               texture2d<float> backdrop [[texture(0)]],
                               texture2d<float> grid [[texture(1)]],
                               constant CompositeUniforms &u [[buffer(0)]]) {
    constexpr sampler gridSampler(coord::pixel, filter::linear, address::clamp_to_edge);
    constexpr sampler screenSampler(filter::linear, address::clamp_to_edge);
    float2 p = in.position.xy;
    float mmPerPx = u.target.z, depth = u.optics.z, shadow = u.optics.w;
    float2 mm = p * mmPerPx;

    // Looking straight down through the tilted surface onto the screen `depth` mm below.
    float2 slope = grid.sample(gridSampler, mm).xy;
    float3 n = normalize(float3(-slope, 1));
    float3 t = refract(float3(0, 0, -1), n, 1.0 / 1.333);
    float2 offset = t.xy / max(-t.z, 0.05) * depth / mmPerPx;
    float2 size = float2(backdrop.get_width(), backdrop.get_height());
    float3 colour = linearize(backdrop.sample(screenSampler, (p + offset) / size).rgb);

    // The waves' shadow: the curved surface gathers light into bright rings and leaves dark ones;
    // the light that falls here crossed the surface `shadowShift` back. Brightness is the inverse
    // of how much a small patch of the surface spreads on the screen (1 / det J, J = I + D·Hess h).
    float light = 1;
    if (shadow > 0) {
        float2 q = (p - u.shadowShift.xy) * mmPerPx;
        float2 sxp = grid.sample(gridSampler, q + float2(1, 0)).xy, sxm = grid.sample(gridSampler, q - float2(1, 0)).xy;
        float2 syp = grid.sample(gridSampler, q + float2(0, 1)).xy, sym = grid.sample(gridSampler, q - float2(0, 1)).xy;
        float hxx = (sxp.x - sxm.x) * 0.5, hyy = (syp.y - sym.y) * 0.5;
        float hxy = 0.25 * ((sxp.y - sxm.y) + (syp.x - sym.x));
        float dz = depth * (1.0 - 1.0 / 1.333);
        float det = (1 + dz * hxx) * (1 + dz * hyy) - dz * dz * hxy * hxy;
        light = 1 + shadow * (1.0 / clamp(det, 0.25, 4.0) - 1);
    }
    // The floor's own colour takes the light it gets; on a dark screen the gathered light also
    // shows as light of its own colour (as the light under water does), or bright rings would
    // vanish on black.
    // The gathered light stops at white, but what is already brighter (EDR from the layers below)
    // stays as it was.
    float3 seen = colour;
    colour = colour * min(light, 1.0) + max(light - 1, 0.0) * (u.target.w > 0.5 ? u.lightColour.rgb * 0.35 : colour);
    colour = min(colour, max(seen, 1.0));

    // Opaque wherever there is water (this pass runs only while a drop is alive). The backdrop
    // already holds the layers below, and the screen is blended in encoded values (DECISIONS D1):
    // a part-covering water layer mixed its copy of them with the originals unevenly, which
    // brightened and darkened wide areas where the water barely moved (M6-LOG).
    return float4(colour, 1);
}
