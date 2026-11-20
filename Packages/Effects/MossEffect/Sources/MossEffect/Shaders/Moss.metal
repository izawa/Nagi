#include <metal_stdlib>
using namespace metal;

// Moss (SPEC 4.3, M3-LOG stage B0). Each instance is a patch: a band along a window's top edge
// and upper corners, or one of the screen's bottom corners. Moss grows in colonies: each starts
// at a point and spreads sideways along the edge while its height stays low, and each is one of
// three mosses, told apart at 1:1 by their leaves (needle tufts, rounded domes, fine upright
// blades); the needle tufts bear sporophytes once grown up. Shapes are worked out in points along the edge (s) and out from it (d); the output is
// premultiplied linear colour (SPEC 3.5).

struct Instance {
    float4 quad;    // pixels
    float4 base;    // the window, or the usable area for a screen corner (pixels)
    float4 info;    // seed, growth 0…1, kind (0 window, 1 bottom-left, 2 bottom-right), fronts
    float4 extra;   // the window's age in seconds (at the chosen speed), the wind's lean −1…1
    float4 fronts[16];
};

struct Uniforms {
    float scale, cornerRadius, inward, precipitation, depth;
    float spread;   // how far moss reaches, a share of the most (the setting)
    float fade;     // 0 … 1 while nagi leaves
    float dew;      // 0 … 1 on a still morning
    float time;     // seconds
};

struct Out {
    float4 position [[position]];
    uint instance [[flat]];
};

vertex Out mossVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                      constant Instance *instances [[buffer(0)]], constant float2 &size [[buffer(1)]]) {
    float4 q = instances[iid].quad;
    float2 p = mix(q.xy, q.zw, float2(vid & 1, vid >> 1));
    Out out;
    out.position = float4(p / size * float2(2, -2) + float2(-1, 1), 0, 1);
    out.instance = iid;
    return out;
}

// MARK: - Noise and geometry

static float hash(float2 p, float seed) {
    p = fract(p * float2(127.1, 311.7) + seed * float2(0.1271, 0.0741));
    p += dot(p, p.yx + 19.19);
    return fract((p.x + p.y) * p.x);
}

static float roundedBox(float2 p, float4 r, float radius) {
    float2 centre = (r.xy + r.zw) * 0.5, extent = (r.zw - r.xy) * 0.5;
    float2 q = abs(p - centre) - extent + radius;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
}

static bool covered(float2 p, constant Instance &patch, float radius) {
    int count = int(patch.info.w);
    for (int i = 0; i < count; i++) {
        if (roundedBox(p, patch.fronts[i], radius) < 0) return true;
    }
    return false;
}

// Distance from p to the segment from a to b, and how far along it (0…1).
static float2 segment(float2 p, float2 a, float2 b) {
    float2 ab = b - a;
    float t = saturate(dot(p - a, ab) / max(dot(ab, ab), 1e-6));
    return float2(length(p - a - ab * t), t);
}

// MARK: - Where on the edge

struct Frame {
    float s;          // along the edge, points
    float d;          // out from it, points (negative over the window)
    bool corner;      // round an upper corner or down a side, or a screen corner
    float stop;       // 1, falling to 0 where moss stops a little way round a window's upper corner
};

// A window: s is 0 where the straight top begins, less round the left corner and down its side,
// more round the right. A screen corner: s runs along the bottom (positive) and up the side
// (negative), and d is how far into the screen.
static Frame edgeFrame(float2 p, constant Instance &patch, constant Uniforms &u) {
    float4 b = patch.base / u.scale;
    if (int(patch.info.z) == 0) {
        float r = u.cornerRadius, straight = b.z - b.x - 2 * r;
        float d = roundedBox(p, b, r);
        float2 left = b.xy + r, right = float2(b.z - r, b.y + r);
        float s;
        if (p.x < left.x) {
            float2 v = p - left;
            s = p.y > left.y ? -M_PI_F * r / 2 - (p.y - left.y) : -r * atan2(-v.x, -v.y);
        } else if (p.x > right.x) {
            float2 v = p - right;
            s = p.y > right.y ? straight + M_PI_F * r / 2 + (p.y - right.y) : straight + r * atan2(v.x, -v.y);
        } else {
            s = p.x - left.x;
        }
        // Round the corner, not down the side (the author's mark at stop J0): the cushion keeps
        // its thickness and ends in a rounded cap over the last few points, so it does not thin
        // into a strand that reads as part of the window's frame.
        float end = M_PI_F * r / 2 * 0.85, cap = 6;
        float2 x = saturate(float2(s + end, straight + end - s) / cap);
        float stop = sqrt(1 - (1 - x.x) * (1 - x.x)) * sqrt(1 - (1 - x.y) * (1 - x.y));
        return Frame{s, d, s < 0 || s > straight, stop};
    }
    float2 corner = float2(int(patch.info.z) == 1 ? b.x : b.z, b.w);
    float along = abs(p.x - corner.x), up = corner.y - p.y;
    return up < along ? Frame{along, up, true, 1} : Frame{-up, along, true, 1};
}

// MARK: - Colonies

struct Colony {
    float reach;    // the growth at which moss arrives here; > 1 where it never does
    float inside;   // points behind the colony's growing front (negative ahead of it)
    float age;      // growth since the colony started
    float spread;   // how far out along the edge this place is, 0 at the start … 1 at full reach
    float rival;    // the next colony's reach here: where two meet, a crease
    float start;    // the growth at which the colony first showed
    float species;  // 0 needle tufts, 1 rounded domes, 2 fine upright blades
    float seed;
};

// A colony starting at s0 that first shows at growth b and spreads radiusLeft/Right points along
// the edge: farther places need more growth (M3-LOG stage B0).
static void consider(thread Colony &best, float s, float s0, float b, float radiusLeft, float radiusRight,
                     float species, float seed, float growth) {
    if (growth <= b) return;   // not started yet: no stray leaves where it will
    float x = s - s0, radius = x < 0 ? radiusLeft : radiusRight;
    float a = abs(x) / radius;
    if (a > 1) return;
    float reach = b + (1 - b) * a * a;
    if (reach >= best.reach) {
        best.rival = min(best.rival, reach);
        return;
    }
    float front = growth > b ? radius * sqrt(min((growth - b) / (1 - b), 1.0)) : 0;
    best = Colony{reach, front - abs(x), growth - b, a, best.reach, b, species, seed};
}

// The colony that has, or will first have, the moss at s.
static Colony colonyAt(float s, constant Instance &patch, constant Uniforms &u) {
    float seed = patch.info.x, g = patch.info.y;
    Colony best = {2, -1e3, 0, 1, 2, 0, 0, 0};
    if (int(patch.info.z) != 0) {
        consider(best, s, 0, 0, 55, 65, floor(hash(float2(9, 1), seed) * 3), seed + 201, g);
        return best;
    }
    // One start in about two thirds of the 96-point stretches of the top; the upper corners
    // always have one, and they come first.
    float stretch = 96;
    int k = int(floor(s / stretch));
    for (int i = k - 1; i <= k + 1; i++) {
        float2 id = float2(i, 1);
        if (hash(id, seed) > 0.67) continue;
        float s0 = (i + 0.5 + (hash(id + 2, seed) - 0.5) * 0.5) * stretch;
        consider(best, s, s0, 0.05 + hash(id + 3, seed) * 0.2, 35 + 30 * hash(id + 4, seed),
                 35 + 30 * hash(id + 5, seed), floor(hash(id + 6, seed) * 3), seed + i, g);
    }
    float r = u.cornerRadius, straight = (patch.base.z - patch.base.x) / u.scale - 2 * r;
    float arc = M_PI_F * r / 4;
    consider(best, s, -arc, 0, 45, 40 + 25 * hash(float2(7, 1), seed), floor(hash(float2(8, 1), seed) * 3), seed + 101, g);
    consider(best, s, straight + arc, 0, 40 + 25 * hash(float2(10, 1), seed), 45,
             floor(hash(float2(11, 1), seed) * 3), seed + 102, g);
    return best;
}

// The cushion's cross-section: low, its crest just outside the edge. Height 0…1 at d for a
// colony this mature.
static float reachOut(float species, bool corner, constant Uniforms &u) {
    return (species < 0.5 ? 13 : species < 1.5 ? 12 : 9) * (corner ? 1.25 : 1) * u.spread;
}

static float profile(float d, float maturity, float species, bool corner, constant Uniforms &u) {
    float out = reachOut(species, corner, u) * maturity;
    float in = min(3.0, u.inward) * u.spread * maturity;
    float crest = out * 0.25;
    float t = d > crest ? (d - crest) / max(out - crest, 1e-3) : (crest - d) / max(crest + in, 1e-3);
    return t < 1 ? sqrt(1 - t * t) : 0;
}

// How grown the colony is here: rounded shoulders over the last 10 points to the growing front,
// and a colony that rises over its first stretch of growth, then stays low while it spreads.
static float maturity(Colony colony, Frame f) {
    // Oldest, and so fullest, where it started; lower towards where it spread to.
    float mound = 0.7 + 0.3 * (1 - colony.spread * colony.spread);
    // Where two colonies meet they press together: a shallow crease.
    float crease = 0.2 + 0.8 * smoothstep(0.0, 0.25, colony.rival - colony.reach);
    return smoothstep(-1.0, 12.0, colony.inside) * smoothstep(0.0, 0.3, colony.age) * mound * crease * f.stop;
}

// MARK: - Leaves

// Smooth noise along the edge, a tuft every few points.
static float tufts(float s, float seed) {
    float i = floor(s / 4.5), f = fract(s / 4.5);
    f = f * f * (3 - 2 * f);
    return mix(hash(float2(i, 13), seed), hash(float2(i + 1, 13), seed), f);
}

struct Leaves {
    float cover;    // 0…1: leaf here (gaps show through)
    float tip;      // 0…1: young, light tip or thin rim
    float shade;    // 0…1: darker (overlap, base)
    float gloss;    // 0…1: where a wet leaf catches the light
};

// Needle tufts (タマゴケ): from bases about 2.6 points apart, 5 fine leaves opening outwards.
static Leaves needles(float2 q, float seed) {
    Leaves l = {0, 0, 0, 0};
    float cell = 2.6;
    float2 id = floor(q / cell);
    for (int j = -1; j <= 1; j++) {
        for (int i = -1; i <= 1; i++) {
            float2 c = id + float2(i, j);
            float2 base = (c + 0.5 + (float2(hash(c, seed), hash(c + 1, seed)) - 0.5) * 0.8) * cell;
            for (int n = 0; n < 5; n++) {
                float a = (hash(c + float2(n, 3), seed) - 0.5) * 2.4 + 1.5708;   // mostly outward (+d)
                float len = 2.0 + 1.2 * hash(c + float2(n, 5), seed);
                float2 st = segment(q, base, base + float2(cos(a), sin(a)) * len);
                float width = mix(0.33, 0.06, st.y);
                if (st.x < width) {
                    float edge = saturate((width - st.x) / 0.12);
                    l.cover = max(l.cover, edge);
                    l.tip = max(l.tip, smoothstep(0.55, 1.0, st.y) * edge);
                }
            }
        }
    }
    l.shade = 1 - l.cover;
    return l;
}

// Rounded domes (ホソバオキナゴケ): pale, dense, the leaves too short to see one by one.
static Leaves domes(float2 q, float seed, thread float &bump) {
    Leaves l = {1, 0, 0, 0};
    float cell = 8;
    float k = floor(q.x / cell);
    bump = 0;
    for (int i = -1; i <= 1; i++) {
        float c = k + i;
        float centre = (c + 0.5 + (hash(float2(c, 1), seed) - 0.5) * 0.6) * cell;
        float w = 4 + 3 * hash(float2(c, 2), seed);
        float x = (q.x - centre) / w;
        bump = max(bump, sqrt(saturate(1 - x * x)) * (0.6 + 0.4 * hash(float2(c, 3), seed)));
    }
    // Short leaves: a fine, soft grain, not cells.
    float2 g0 = floor(q / 0.7), gf = fract(q / 0.7);
    float2 gu = gf * gf * (3 - 2 * gf);
    float grain = mix(mix(hash(g0, seed), hash(g0 + float2(1, 0), seed), gu.x),
                      mix(hash(g0 + float2(0, 1), seed), hash(g0 + float2(1, 1), seed), gu.x), gu.y);
    l.tip = smoothstep(0.55, 1.0, grain) * 0.6;
    l.shade = (1 - smoothstep(0.0, 0.45, grain)) * 0.5;
    return l;
}

// Fine upright blades (the third moss): dense, short, side by side like a fine lawn, each a
// little lighter or darker than the next; wet, a thin glint down one side.
static Leaves blades(float2 q, float top, float seed) {
    Leaves l = {0, 0, 0, 0};
    float spacing = 0.55;
    float k = floor(q.x / spacing);
    for (int i = -2; i <= 2; i++) {
        float c = k + i;
        float lean = (hash(float2(c, 21), seed) - 0.5) * 0.5;
        float tall = top * (0.75 + 0.4 * hash(float2(c, 22), seed));
        float base = -1.5;
        float t = (q.y - base) / max(tall - base, 1e-3);   // 0 at the base … 1 at the tip
        if (t < 0 || t > 1) continue;
        float x = (c + 0.5 + (hash(float2(c, 23), seed) - 0.5) * 0.6) * spacing + lean * (q.y - base);
        float width = mix(0.38, 0.06, t * t);
        float off = q.x - x;
        if (abs(off) >= width) continue;
        float edge = saturate((width - abs(off)) / 0.1);
        l.cover = max(l.cover, edge);
        float tone = hash(float2(c, 24), seed);
        l.tip = max(l.tip, edge * (smoothstep(0.55, 1.0, t) * 0.8 + tone * 0.35));
        l.shade = max(l.shade, edge * (1 - tone) * 0.5 * (1 - t));
        l.gloss = max(l.gloss, edge * (1 - smoothstep(0.0, 0.08, abs(off + width * 0.4))) * smoothstep(0.3, 0.8, t));
    }
    return l;
}

// Sporophytes on a grown-up colony (タマゴケ): a fine reddish-brown stalk with a small round
// brown capsule, rising as nagi deepens. Returns coverage (0…1) and writes the colour.
static float sporophytes(float2 q, float bed, float plenty, float rise, float limit, float sway, float seed,
                         thread float3 &colour) {
    float spacing = 5.5;
    float k = floor(q.x / spacing);
    float cover = 0;
    for (int i = -1; i <= 1; i++) {
        float c = k + i;
        if (hash(float2(c, 31), seed) > plenty) continue;
        float2 base = float2((c + 0.5 + (hash(float2(c, 32), seed) - 0.5) * 0.7) * spacing, bed);
        // The capsule (0.6 + 1.1 points past the tip) stays within the limit too.
        float tall = min((4.5 + 3.5 * hash(float2(c, 33), seed)) * (0.35 + 0.65 * rise), limit - 1.8 - bed);
        float lean = (hash(float2(c, 34), seed) - 0.5) * 1.2;
        // Leaning with the wind, the taller the more (D19).
        float2 tip = base + float2(lean + sway * tall * 0.3, tall);
        float2 st = segment(q, base, tip);
        // The stalk bows a little: offset by a curve along it.
        float2 bow = float2(0.4 * lean * st.y * (1 - st.y), 0);
        st = segment(q - bow, base, tip);
        if (st.x < 0.26) {
            float a = saturate((0.26 - st.x) / 0.1);
            if (a > cover) { cover = a; colour = float3(0.20, 0.06, 0.02) * (0.7 + 0.5 * st.y); }
        }
        float r = length(q - tip - float2(0, 0.6)) / 1.1;
        if (r < 1) {
            float a = saturate((1 - r) / 0.15);
            float shine = 1 - smoothstep(0.0, 0.7, length(q - tip - float2(-0.4, 1.0)));
            if (a >= cover) { cover = a; colour = mix(float3(0.16, 0.08, 0.025), float3(0.55, 0.30, 0.12), shine * 0.6); }
        }
    }
    return cover;
}

// MARK: - Shading

static float heightAt(float2 p, constant Instance &patch, constant Uniforms &u) {
    Frame f = edgeFrame(p, patch, u);
    Colony colony = colonyAt(f.s, patch, u);
    float m = maturity(colony, f);
    float bump = 0;
    if (colony.species > 0.5 && colony.species < 1.5) domes(float2(f.s, f.d), colony.seed, bump);
    float tuft = colony.species > 0.5 && colony.species < 1.5 ? 0.75 + 0.35 * bump : 0.85 + 0.3 * tufts(f.s, colony.seed);
    return profile(f.d / tuft, m, colony.species, f.corner, u) * m;
}

fragment float4 mossFragment(Out in [[stage_in]], constant Instance *instances [[buffer(0)]],
                             constant Uniforms &u [[buffer(1)]]) {
    constant Instance &patch = instances[in.instance];
    float2 pixel = in.position.xy;
    float radius = u.cornerRadius * u.scale;
    if (covered(pixel, patch, radius)) discard_fragment();
    if (int(patch.info.z) == 0) {
        // No moss without a root: the edge it grows from must be in sight.
        // Round a corner, the root is on the curve: towards the corner's centre from the pixel.
        float4 b = patch.base;
        float2 centre = float2(clamp(pixel.x, b.x + radius, b.z - radius), b.y + radius);
        float2 root = pixel.y < centre.y && pixel.x != centre.x
            ? centre + normalize(pixel - centre) * (radius - u.scale)
            : float2(pixel.x, b.y + u.scale);
        if (pixel.y >= centre.y) root = float2(clamp(pixel.x, b.x + u.scale, b.z - u.scale), pixel.y);
        if (covered(root, patch, radius)) discard_fragment();
    }
    float2 p = pixel / u.scale;
    Frame f = edgeFrame(p, patch, u);
    Colony colony = colonyAt(f.s, patch, u);
    // Leaves at the growing front show a little before the cushion fills in behind them; past the
    // rounded end at a corner, nothing (not even a stray needle or stalk).
    if (colony.inside < -1.0 || f.stop <= 0.02) discard_fragment();
    float m = maturity(colony, f);
    float2 q = float2(f.s, f.d);
    float bump = 0;
    Leaves l = colony.species > 0.5 && colony.species < 1.5 ? domes(q, colony.seed, bump) : Leaves{0, 0, 0, 0};
    // The top's outline: rounded domes, or small tufts; never a ruled line.
    float tuft = colony.species > 0.5 && colony.species < 1.5 ? 0.75 + 0.35 * bump : 0.85 + 0.3 * tufts(f.s, colony.seed);
    float h = profile(f.d / tuft, m, colony.species, f.corner, u) * m;
    float3 low, mid, light;
    if (colony.species < 0.5) {
        // Needle tips reach a little past the cushion.
        float fringe = profile((f.d - 1.5) / tuft, max(m, 0.15), colony.species, f.corner, u);
        l = h > 0 || fringe > 0 ? needles(q, colony.seed) : Leaves{0, 0, 0, 0};
        float body = smoothstep(0.0, 0.25, h);   // dense below the needles
        l.cover = max(l.cover, body * 0.9);
        l.tip *= 1 - body * 0.5;
        low = float3(0.012, 0.045, 0.012); mid = float3(0.070, 0.200, 0.035); light = float3(0.380, 0.580, 0.080);
    } else if (colony.species < 1.5) {
        if (h <= 0) discard_fragment();
        l.cover = smoothstep(0.0, 0.12, h);
        low = float3(0.030, 0.090, 0.040); mid = float3(0.110, 0.270, 0.110); light = float3(0.300, 0.470, 0.240);
    } else {
        float top = reachOut(colony.species, f.corner, u) * m * tuft + 1;
        l = blades(q, top, colony.seed);
        // Packed below: the blades' lower parts hide what is behind.
        float packed = (1 - smoothstep(top * 0.35, top * 0.7, f.d)) * step(-1.5, f.d) * smoothstep(0.0, 0.15, m);
        l.shade = max(l.shade, packed * (1 - l.cover) * 0.6);
        l.cover = max(l.cover, packed);
        if (l.cover <= 0) discard_fragment();
        low = float3(0.010, 0.050, 0.010); mid = float3(0.050, 0.220, 0.040); light = float3(0.300, 0.660, 0.110);
    }
    // A grown-up colony bears sporophytes: an hour after it first showed here (with some colonies
    // later than others), more of them over the next half hour (the author's idea at stop J0).
    float3 sporeColour = float3(0);
    float spore = 0;
    if (colony.species < 0.5) {
        float start = 600 + 6600 * sqrt(colony.start / 3);
        float adultAt = start + 3600 + 1800 * hash(float2(41, 1), colony.seed);
        float plenty = 0.8 * smoothstep(adultAt, adultAt + 1800, patch.extra.x) * (1 - smoothstep(0.4, 0.75, colony.spread)) * smoothstep(0.5, 0.9, f.stop);
        if (plenty > 0) {
            float bed = reachOut(colony.species, f.corner, u) * m * tuft * 0.55;
            spore = sporophytes(q, bed, plenty, smoothstep(20.0, 120.0, u.depth), 19.5 * u.spread, patch.extra.y,
                                colony.seed, sporeColour);
        }
    }
    if (l.cover <= 0 && spore <= 0) discard_fragment();

    // The cushion's slope (and a dome's own): light from the sky above (y is down).
    float e = 0.6;
    float hx = heightAt(p + float2(e, 0), patch, u) - heightAt(p - float2(e, 0), patch, u);
    float hy = heightAt(p + float2(0, e), patch, u) - heightAt(p - float2(0, e), patch, u);
    float domeTilt = colony.species > 0.5 && colony.species < 1.5 ? (bump - 0.5) * 0.4 : 0;
    float3 normal = normalize(float3(-hx * 3, -hy * 3 - domeTilt, 1));
    float sky = saturate(dot(normal, normalize(float3(-0.25, -0.8, 0.55))));
    float3 colour = mix(low, mid, saturate(h * 1.2 + bump * 0.3));
    colour = mix(colour, light, l.tip * 0.85);
    colour *= (0.55 + 0.75 * sky) * (1 - 0.45 * l.shade);
    // Wet: deeper, and the clear leaves glint (D32).
    float wet = u.precipitation;
    colour *= mix(1.0, 0.7, wet);
    colour += float3(0.6, 0.75, 0.6) * l.gloss * wet * sky * 1.5;
    float alpha = saturate(l.cover);
    // Dew on the outer leaves on a still morning: small beads, fixed in place, that brighten and
    // dim slowly (a period of about 15 seconds: far from the flash limit, D19).
    if (u.dew > 0 && h > 0.25) {
        float cell = 3.5;
        float k = floor(f.s / cell);
        for (int i = -1; i <= 1; i++) {
            float c = k + i;
            if (hash(float2(c, 51), colony.seed) > 0.3) continue;
            float edge = reachOut(colony.species, f.corner, u) * m * tuft;
            float2 bead = float2((c + 0.5 + (hash(float2(c, 52), colony.seed) - 0.5) * 0.6) * cell,
                                 edge * (0.6 + 0.25 * hash(float2(c, 53), colony.seed)));
            float r = length(q - bead) / 0.5;
            if (r >= 1) continue;
            float twinkle = 0.7 + 0.3 * sin(u.time * 0.42 + hash(float2(c, 54), colony.seed) * 6.283);
            float glint = (1 - smoothstep(0.0, 0.6, length(q - bead - float2(-0.15, 0.2)) / 0.5));
            // Within SDR white: moss asks for no extended range.
            colour = mix(colour, min(float3(0.5, 0.65, 0.55) + float3(0.5) * glint * twinkle, float3(1.0)),
                         u.dew * saturate((1 - r) / 0.2));
        }
    }
    // Leaving: the colour drains towards a dull grey-green of the same brightness.
    float3 dull = dot(colour, float3(0.2126, 0.7152, 0.0722)) * float3(0.95, 1.05, 0.9);
    colour = mix(colour, dull, u.fade);
    sporeColour = mix(sporeColour, dot(sporeColour, float3(0.2126, 0.7152, 0.0722)) * float3(1.0), u.fade);
    float4 result = float4(colour * alpha, alpha);
    // The sporophytes stand in front of the cushion.
    return float4(sporeColour * spore, spore) + result * (1 - spore);
}
