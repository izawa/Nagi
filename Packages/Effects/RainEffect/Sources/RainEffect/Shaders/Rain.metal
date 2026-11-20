#include <metal_stdlib>
using namespace metal;

// Raindrops on the glass (SPEC 4.2). Each drop is one instanced quad around it. A drop is up to
// four round lobes joined into one smooth surface (a field that sums their bumps), so drops that
// ran together keep the trace of where each was. The surface's slope bends the screen behind it
// like a lens held close: upright and magnified in the middle, squeezed hard at the rim.

#define LOBES 4
struct Instance { float4 geometry; float4 lobes[LOBES]; };   // centre px, reach px, shape; lobe offset px, radius px
struct Uniforms { float4 light; float4 look; float4 misc; float4 target; };

struct DropOut {
    float4 position [[position]];
    float2 centre;
    float shape;
    uint drop [[flat]];
};

constant float reach = 1.45;      // the quad also covers the shadow beside the drop
constant float threshold = 0.15;  // the field's value at the water's edge
// A lobe's bump reaches past its edge so that neighbours join smoothly: with the threshold above,
// a lone lobe's edge falls at its radius.
constant float influence = 1.0 / 0.783;

vertex DropOut dropVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                          const device Instance *drops [[buffer(0)]], constant Uniforms &u [[buffer(1)]]) {
    Instance d = drops[iid];
    float2 corner = float2(vid & 1, vid >> 1) * 2 - 1;
    float2 pixel = d.geometry.xy + corner * d.geometry.z * reach;
    float2 clip = pixel / u.target.xy * 2 - 1;
    DropOut out;
    out.position = float4(clip.x, -clip.y, 0, 1);
    out.centre = d.geometry.xy;
    out.shape = d.geometry.w;
    out.drop = iid;
    return out;
}

float3 linearize(float3 c) { return select(pow((c + 0.055) / 1.055, 2.4), c / 12.92, c <= 0.04045); }

// The field, its gradient, and where it is centred here: the lobes' centres and radii weighted by
// how much each counts at this point (a merged drop bends around the lobe you are over).
struct Field { float value; float2 gradient; float radius; float2 centre; };

// The drop's field at `p` (pixels): the sum of its lobes' bumps, their gradient, and the mean
// lobe radius weighted by how much each lobe counts here. `scale` shrinks the lobes (evaporation).
Field field(const device Instance &d, float2 p, float scale) {
    Field f = { 0, float2(0), 0, float2(0) };
    float weight = 0;
    for (int i = 0; i < LOBES; i++) {
        float r = d.lobes[i].z * scale;
        if (r <= 0) continue;
        float R = r * influence;
        float2 v = p - (d.geometry.xy + d.lobes[i].xy);
        float s = dot(v, v) / (R * R);
        if (s >= 1) continue;
        float w = (1 - s) * (1 - s);
        f.value += w;
        f.gradient += -4 * (1 - s) * v / (R * R);
        f.radius += r * w;
        f.centre += (d.geometry.xy + d.lobes[i].xy) * w;
        weight += w;
    }
    f.radius = weight > 0 ? f.radius / weight : 1;
    f.centre = weight > 0 ? f.centre / weight : d.geometry.xy;
    return f;
}

fragment float4 dropFragment(DropOut in [[stage_in]], texture2d<float> backdrop [[texture(0)]],
                             const device Instance *drops [[buffer(0)]], constant Uniforms &u [[buffer(1)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 size = float2(backdrop.get_width(), backdrop.get_height());
    const device Instance &d = drops[in.drop];
    float presence = u.misc.y;
    float2 p = in.position.xy;
    float2 toLight = u.light.xy;
    float lightStrength = u.light.z;

    // A little irregular edge, by angle around the drop.
    float2 around = p - in.centre;
    float angle = atan2(around.y, around.x), seed = in.shape * 6.2831853;
    float edge = threshold * (1 + 0.25 * sin(3 * angle + seed) + 0.15 * sin(5 * angle + 2.1 * seed));

    Field f = field(d, p, max(presence, 0.001));
    float width = max(fwidth(f.value), 1e-5);
    float inside = clamp((f.value - edge) / width, 0.0, 1.0);

    // Beside the drop: a soft shadow on the side away from the light.
    // Offset by the drop's size, which stays defined outside the water (unlike the field's radius).
    Field behind = field(d, p + toLight * 0.12 * d.geometry.z * max(presence, 0.001), max(presence, 0.001));
    float shadow = u.look.w * lightStrength * smoothstep(edge * 0.2, edge * 1.1, behind.value);
    if (inside <= 0 && shadow <= 0.001) discard_fragment();
    if (inside <= 0) return float4(0, 0, 0, shadow);

    // The surface: height 0 at the edge, 1 where the water is deepest; its slope in drop units.
    float rise = max((f.value - edge) / (1 - edge), 0.0);
    float h = sqrt(min(rise, 1.0));
    float2 slope = f.gradient / ((1 - edge) * 2 * max(h, 0.05)) * f.radius;

    // A near lens around the local centre: sampling nearer the centre in the middle (magnified,
    // upright), beyond the rim at the edge (squeezed); the colours split a little at the rim.
    // How far out we are follows from the height, as on a round cap.
    float k = u.misc.x;
    float out = sqrt(max(1 - h * h, 0.0));
    float rim4 = out * out * out * out;
    float2 fromCentre = p - f.centre;
    float3 colour;
    for (int c = 0; c < 3; c++) {
        float m = mix(1.0, 0.62 + 0.95 * rim4, k) * (1 + (float(c) - 1) * 0.025 * rim4 * k);
        colour[c] = linearize(backdrop.sample(s, (f.centre + fromCentre * m) / size).rgb)[c];
    }
    float thin = 1 - h;
    // The dark ring where the surface turns the light away, and the sky's reflection there.
    colour *= 1 - u.look.x * thin * thin * thin;
    float sky = u.misc.w * (u.misc.z > 0.5 ? 0.35 : 1.0);
    colour = mix(colour, float3(sky), u.look.y * (0.04 + 0.96 * pow(thin, 4.0)));
    // The light: a sharp highlight where the surface faces it, a soft glow where it is focused.
    float3 normal = normalize(float3(-slope * 0.9, 1));
    float3 towardLight = normalize(float3(toLight * 0.75, 0.66));
    float highlight = pow(max(dot(normal, normalize(towardLight + float3(0, 0, 1))), 0.0), 120.0);
    float glow = pow(max(dot(normal, normalize(float3(-toLight * 0.6, 0.8))), 0.0), 24.0) * 0.2;
    colour += u.look.z * lightStrength * (highlight * 1.6 + glow) * float3(1.0, 0.98, 0.95);
    // The lens over its own shadow, so the coverage runs on without a seam at the rim.
    return float4(colour * inside, inside + shadow * (1 - inside));
}
