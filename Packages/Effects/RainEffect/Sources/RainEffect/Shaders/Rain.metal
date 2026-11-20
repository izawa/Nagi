#include <metal_stdlib>
using namespace metal;

// Raindrops on the glass (SPEC 4.2). Each drop is one instanced quad around it. A drop is up to
// four round lobes joined into one smooth surface (a field that sums their bumps), so drops that
// ran together keep the trace of where each was. The surface's slope bends the screen behind it
// like a lens held close: upright and magnified in the middle, squeezed hard at the rim.

#define LOBES 4
struct Instance { float4 geometry; float4 lobes[LOBES]; };   // centre px, reach px, shape; lobe offset px, radius px
struct Uniforms { float4 light; float4 look; float4 misc; float4 target; };   // target: size px, points→px, seconds a frame

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

// How much longer than wide a running drop looks: it pulls itself out as it runs.
float stretchFor(float speed) { return 1 + min(speed / 500, 0.8); }

vertex DropOut dropVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                          const device Instance *drops [[buffer(0)]], constant Uniforms &u [[buffer(1)]]) {
    Instance d = drops[iid];
    float2 corner = float2(vid & 1, vid >> 1) * 2 - 1;
    // A running drop is drawn longer (stretch), so the quad reaches further up and down.
    // A running drop is also blurred over its frame's travel, half above and half below.
    float travel = d.lobes[0].w * u.target.z * u.target.w;
    float2 pixel = d.geometry.xy + corner * (d.geometry.z * reach * float2(1, stretchFor(d.lobes[0].w)) + float2(0, travel / 2));
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
    float stretch = stretchFor(d.lobes[0].w);
    for (int i = 0; i < LOBES; i++) {
        float r = d.lobes[i].z * scale;
        if (r <= 0) continue;
        float R = r * influence;
        float2 v = p - (d.geometry.xy + d.lobes[i].xy);
        v.y /= stretch;
        float s = dot(v, v) / (R * R);
        if (s >= 1) continue;
        float w = (1 - s) * (1 - s);
        f.value += w;
        f.gradient += -4 * (1 - s) * float2(v.x, v.y / stretch) / (R * R);
        f.radius += r * w;
        f.centre += (d.geometry.xy + d.lobes[i].xy) * w;
        weight += w;
    }
    f.radius = weight > 0 ? f.radius / weight : 1;
    f.centre = weight > 0 ? f.centre / weight : d.geometry.xy;
    return f;
}

// One drop seen at pixel `p` (premultiplied; 0 where neither the drop nor its shadow is).
// `screen` is the output pixel: the screen behind is sampled from there, while `p` places the drop
// (they differ in the motion blur's samples, where only the drop moves).
float4 shadeDrop(const device Instance &d, float2 p, float2 screen, float2 centre, float shape,
                 texture2d<float> backdrop, constant Uniforms &u) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 size = float2(backdrop.get_width(), backdrop.get_height());
    float presence = u.misc.y;
    float2 toLight = u.light.xy;
    float lightStrength = u.light.z;

    // A little irregular edge, by angle around the drop.
    float2 around = p - centre;
    float angle = atan2(around.y, around.x), seed = shape * 6.2831853;
    float edge = threshold * (1 + 0.4 * sin(2 * angle + 0.7 * seed) + 0.3 * sin(3 * angle + seed)
                              + 0.2 * sin(5 * angle + 2.1 * seed));

    Field f = field(d, p, max(presence, 0.001));
    // A running drop blurs to the eye: the text it carries fades with speed, so it does not
    // flicker past a pixel (SPEC 2.2, at most 3 flashes a second).
    float calm = 1 / (1 + d.lobes[0].w / 60);
    // Its ring and light are kept low enough that one runner passing a pixel is not a flash.
    float motion = 1 / (1 + d.lobes[0].w / 200);

    // About one pixel of the field, for a smooth edge (the gradient, as fwidth would give).
    float width = max(length(f.gradient), 1e-5);
    float inside = clamp((f.value - edge) / width, 0.0, 1.0);

    // Beside the drop: a soft shadow on the side away from the light.
    // Offset by the drop's size, which stays defined outside the water (unlike the field's radius).
    Field behind = field(d, p + toLight * 0.12 * d.geometry.z * max(presence, 0.001), max(presence, 0.001));
    float shadow = u.look.w * lightStrength * smoothstep(edge * 0.2, edge * 1.1, behind.value);
    if (inside <= 0) return float4(0, 0, 0, shadow);

    // The surface: height 0 at the edge, 1 where the water is deepest; its slope in drop units.
    float rise = max((f.value - edge) / (1 - edge), 0.0);
    float h = sqrt(min(rise, 1.0));
    float2 slope = f.gradient / ((1 - edge) * 2 * max(h, 0.05)) * f.radius;

    // A near lens around the local centre: sampling nearer the centre in the middle (magnified,
    // upright), beyond the rim at the edge (squeezed); the colours split a little at the rim.
    // How far out we are follows from the height, as on a round cap.
    float k = u.misc.x * calm;
    float out = sqrt(max(1 - h * h, 0.0));
    float rim4 = out * out * out * out;
    float2 fromCentre = p - f.centre;
    float3 colour;
    for (int c = 0; c < 3; c++) {
        float m = mix(1.0, 0.62 + 0.6 * rim4, k) * (1 + (float(c) - 1) * 0.025 * rim4 * k);
        colour[c] = linearize(backdrop.sample(s, (screen + f.centre + fromCentre * m - p) / size).rgb)[c];
    }
    float thin = 1 - h;
    // The dark ring where the surface turns the light away, and the sky's reflection there.
    colour *= 1 - u.look.x * motion * thin * thin * thin;
    float sky = u.misc.w * (u.misc.z > 0.5 ? 0.35 : 1.0);
    colour = mix(colour, float3(sky), u.look.y * motion * (0.04 + 0.96 * pow(thin, 4.0)));
    // The light: a sharp highlight where the surface faces it, a soft glow where it is focused.
    float3 normal = normalize(float3(-slope * 0.9, 1));
    float3 towardLight = normalize(float3(toLight * 0.75, 0.66));
    float highlight = pow(max(dot(normal, normalize(towardLight + float3(0, 0, 1))), 0.0), 120.0);
    float glow = pow(max(dot(normal, normalize(float3(-toLight * 0.6, 0.8))), 0.0), 24.0) * 0.2;
    colour += motion * u.look.z * lightStrength * (highlight * 1.6 + glow) * float3(1.0, 0.98, 0.95);
    // The lens over its own shadow, so the coverage runs on without a seam at the rim.
    return float4(colour * inside, inside + shadow * (1 - inside));
}

fragment float4 dropFragment(DropOut in [[stage_in]], texture2d<float> backdrop [[texture(0)]],
                             const device Instance *drops [[buffer(0)]], constant Uniforms &u [[buffer(1)]]) {
    const device Instance &d = drops[in.drop];
    float2 p = in.position.xy;
    // A running drop is seen blurred along its run, as an eye or a camera sees it: the frame is
    // the average of where it was over the frame's time. Without this the image it carries, its
    // ring and its light jump past a pixel frame by frame and flicker (SPEC 2.2).
    float travel = d.lobes[0].w * u.target.z * u.target.w;   // pixels the drop moves in one frame
    float4 colour = 0;
    if (travel < 0.5) {
        colour = shadeDrop(d, p, p, in.centre, in.shape, backdrop, u);
    } else {
        const int samples = 6;
        for (int i = 0; i < samples; i++) {
            float back = travel * (float(i) / float(samples - 1) - 0.5);
            colour += shadeDrop(d, p + float2(0, back), p, in.centre, in.shape, backdrop, u);
        }
        colour /= float(samples);
    }
    if (colour.a <= 0.001) discard_fragment();
    return colour;
}

// MARK: - Wet trails

// A runner's wet path: a thin film laid piece by piece, each piece a flat-ended band from one
// step's start to its end, so pieces join without overlap. Across the band the film rises a
// little and falls away smoothly to nothing; it bends the screen a hair and dries away.

struct TrailInstance { float4 ends; float4 look; };   // a.xy, b.xy (px); half-width (px), left 1…0

struct TrailOut {
    float4 position [[position]];
    float across;        // −1 … 1 over the band's width (with a margin)
    float2 normal;
    float halfWidth;
    float left;
};

constant float trailMargin = 1.6;   // the quad is a little wider than the film, for the fall-off

vertex TrailOut trailVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                            const device TrailInstance *pieces [[buffer(0)]], constant Uniforms &u [[buffer(1)]]) {
    TrailInstance t = pieces[iid];
    float2 a = t.ends.xy, b = t.ends.zw;
    float2 along = b - a;
    float2 normal = normalize(float2(-along.y, along.x) + 1e-6);
    float side = (vid & 1) ? 1.0 : -1.0;
    float2 pixel = ((vid >> 1) ? b : a) + normal * side * t.look.x * trailMargin;
    float2 clip = pixel / u.target.xy * 2 - 1;
    TrailOut out;
    out.position = float4(clip.x, -clip.y, 0, 1);
    out.across = side * trailMargin;
    out.normal = normal;
    out.halfWidth = t.look.x;
    out.left = t.look.y;
    return out;
}

fragment float4 trailFragment(TrailOut in [[stage_in]], texture2d<float> backdrop [[texture(0)]],
                              constant Uniforms &u [[buffer(1)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 size = float2(backdrop.get_width(), backdrop.get_height());
    // The film thins as it dries: narrower and fainter.
    float width = 0.5 + 0.5 * in.left;
    float x = in.across / width;
    if (abs(x) >= 1.3) discard_fragment();
    // A smooth bump across the band: full in the middle, to nothing at |x| = 1.3.
    float body = 1 - smoothstep(0.0, 1.3, abs(x));
    // The film's slope bends the screen a hair towards its middle.
    float2 source = in.position.xy - in.normal * in.across * in.halfWidth * 0.25 * body * u.misc.x;
    float3 colour = linearize(backdrop.sample(s, source / size).rgb);
    // Its edges catch a little light and a little shade, like the rim of a drop, faintly.
    colour *= 1 - 0.12 * u.look.x * smoothstep(0.3, 1.0, abs(x)) * body;
    float alpha = body * in.left * 0.6;
    return float4(colour * alpha, alpha);
}
