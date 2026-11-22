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
    float4 base;    // the window (pixels)
    float4 info;    // seed, growth 0…1, (unused), fronts
    float4 extra;   // the window's age in seconds (at the chosen speed), the wind's lean −1…1,
                    // and the growth after two hours (0 … 1 by four hours)
    float4 fronts[16];
};

struct Uniforms {
    float scale, cornerRadius, inward, precipitation, depth;
    float spread;   // how far moss reaches, a share of the most (the setting)
    float fade;     // 0 … 1 while nagi leaves
    float dew;      // 0 … 1 on a still morning
    float time;     // seconds
    float deep;     // 0 … 1 as nagi deepens (30 … 90 s): the thin leaflets let the light through
    float dark;     // 1 for the dark appearance: the light through the tips glows past them too
    float4 light;   // toward the sun or moon (x right, y down, z toward the viewer) and its
                    // directional strength 0…1 (SkyLight, less what a cloud hides)
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

// The hash for the leaves' own pattern: from whole lattice coordinates, mixed as integers.
// `hash` steps its fraction by 0.1 and 0.7 per cell, so ten cells on it nearly repeats; on the
// fine leaves that showed as a pattern repeating every few points.
static float leafHash(float2 p, float seed) {
    uint2 q = uint2(int2(floor(p)));
    uint h = q.x * 0x8da6b343u ^ q.y * 0xd8163841u ^ as_type<uint>(seed) * 0xcb1ab31fu;
    h ^= h >> 16; h *= 0x7feb352du; h ^= h >> 15; h *= 0x846ca68bu; h ^= h >> 16;
    return float(h >> 8) * (1.0 / 16777216.0);
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

// Smooth noise, 0…1, a feature about every `size` points.
static float smoothNoise(float2 p, float size, float seed) {
    float2 q = p / size, i = floor(q), f = fract(q);
    f = f * f * (3 - 2 * f);
    return mix(mix(leafHash(i, seed), leafHash(i + float2(1, 0), seed), f.x),
               mix(leafHash(i + float2(0, 1), seed), leafHash(i + float2(1, 1), seed), f.x), f.y);
}

// Gradient noise, about −0.7 … 0.7, a feature about every unit: the value and its gradient.
static float3 gradientNoise(float2 p, float seed) {
    float2 i = floor(p), f = fract(p);
    float2 u = f * f * f * (f * (f * 6 - 15) + 10), du = 30 * f * f * (f - 1) * (f - 1);
    float a0 = 6.2831853 * leafHash(i, seed), a1 = 6.2831853 * leafHash(i + float2(1, 0), seed);
    float a2 = 6.2831853 * leafHash(i + float2(0, 1), seed), a3 = 6.2831853 * leafHash(i + float2(1, 1), seed);
    float2 ga = float2(cos(a0), sin(a0)), gb = float2(cos(a1), sin(a1));
    float2 gc = float2(cos(a2), sin(a2)), gd = float2(cos(a3), sin(a3));
    float va = dot(ga, f), vb = dot(gb, f - float2(1, 0)), vc = dot(gc, f - float2(0, 1)), vd = dot(gd, f - 1);
    float k = va - vb - vc + vd;
    float value = va + u.x * (vb - va) + u.y * (vc - va) + u.x * u.y * k;
    float2 gradient = ga + u.x * (gb - ga) + u.y * (gc - ga) + u.x * u.y * (ga - gb - gc + gd)
        + du * (u.yx * k + float2(vb - va, vc - va));
    return float3(value, gradient);
}

// Gradient noise sampled in a rotated, stretched frame (`size` points across and along, turned
// by `angle`): the value and its gradient per point, back in the edge's frame.
static float3 orientedNoise(float2 q, float2 size, float angle, float seed) {
    float c = cos(angle), sn = sin(angle);
    float2 r = float2(c * q.x + sn * q.y, -sn * q.x + c * q.y) / size;
    float3 n = gradientNoise(r, seed);
    float2 g = n.yz / size;
    return float3(n.x, c * g.x - sn * g.y, sn * g.x + c * g.y);
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
    bool corner;      // round an upper corner or down a side
    float stop;       // 1, falling to 0 where moss stops a little way round a window's upper corner
    float straight;   // the length of the straight top, points
    float2 outward;   // out from the edge on screen (y down): (0, −1) on the straight top
};

// s is 0 where the window's straight top begins, less round the left corner and down its side,
// more round the right.
static Frame edgeFrame(float2 p, constant Instance &patch, constant Uniforms &u) {
    float4 b = patch.base / u.scale;
    float r = u.cornerRadius, straight = b.z - b.x - 2 * r;
    float d = roundedBox(p, b, r);
    float2 left = b.xy + r, right = float2(b.z - r, b.y + r);
    float s;
    float2 outward = float2(0, -1);
    if (p.x < left.x) {
        float2 v = p - left;
        outward = p.y > left.y ? float2(-1, 0) : v / max(length(v), 1e-3);
        s = p.y > left.y ? -M_PI_F * r / 2 - (p.y - left.y) : -r * atan2(-v.x, -v.y);
    } else if (p.x > right.x) {
        float2 v = p - right;
        outward = p.y > right.y ? float2(1, 0) : v / max(length(v), 1e-3);
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
    return Frame{s, d, s < 0 || s > straight, stop, straight, outward};
}

// MARK: - Colonies

struct Colony {
    float reach;    // when moss arrives here, on the growth clock T (0 … 2); > 2 where it never does
    float inside;   // points behind the colony's growing front (negative ahead of it)
    float age;      // T since moss arrived here: how long this spot has had to grow up
    float spread;   // how far out along the edge this place is, 0 at the start … 1 at two hours' reach
    float rival;    // the next colony's arrival here: where two meet, a crease
    float start;    // the growth at which the colony first showed
    float species;  // 0 needle tufts, 1 rounded domes, 2 fine upright blades
    float seed;
    float2 slope;   // how `inside` and `age` change along s (per point), for the light
};

// A colony starting at s0 that first shows at growth b and spreads radiusLeft/Right points along
// the edge by two hours, half as far again by four (the author at stops J0 and K). `growth` is
// the growth clock T: 0 … 1 over the first two hours, 1 … 2 over the next two.
static void consider(thread Colony &best, float s, float s0, float b, float radiusLeft, float radiusRight,
                     float species, float seed, float growth) {
    if (growth <= b) return;   // not started yet: no stray leaves where it will
    float x = abs(s - s0), radius = s < s0 ? radiusLeft : radiusRight;
    float a = x / radius;
    if (a > 1.5) return;
    // Farther places later: within the first reach by two hours, the rest by four.
    float reach = a <= 1 ? b + (1 - b) * a * a : 1 + 2 * (a - 1);
    if (reach >= best.reach) {
        best.rival = min(best.rival, reach);
        return;
    }
    float front = growth < 1 ? radius * sqrt(saturate((growth - b) / (1 - b))) : radius * (1 + 0.5 * (growth - 1));
    float side = s < s0 ? -1 : 1;
    float reachSlope = (a <= 1 ? (1 - b) * 2 * a : 2) * side / radius;
    best = Colony{reach, front - x, growth - reach, a, best.reach, b, species, seed, float2(-side, -reachSlope)};
}

// The colony that has, or will first have, the moss at s.
static Colony colonyAt(float s, constant Instance &patch, constant Uniforms &u) {
    float seed = patch.info.x, g = patch.info.y + patch.extra.z;
    Colony best = {3, -1e3, 0, 1, 3, 0, 0, 0, float2(0)};
    // One start in about two thirds of the 96-point stretches of the top; the upper corners
    // always have one, and they come first.
    float span = 96;
    int k = int(floor(s / span));
    for (int i = k - 1; i <= k + 1; i++) {
        float2 id = float2(i, 1);
        if (hash(id, seed) > 0.67) continue;
        float s0 = (i + 0.5 + (hash(id + 2, seed) - 0.5) * 0.5) * span;
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
// How far out a mature cushion reaches, points. Past two hours it thickens a little more (a fifth
// by four hours: taller, and the sporophytes would sink into it).
static float reachOut(float species, bool corner, constant Uniforms &u, float late) {
    return (species < 0.5 ? 10.5 : species < 1.5 ? 12 : 9) * (corner ? 1.25 : 1) * u.spread * (1 + 0.2 * late);
}

static float profile(float d, float maturity, float species, bool corner, constant Uniforms &u, float late) {
    float out = reachOut(species, corner, u, late) * maturity;
    float in = min(3.0, u.inward) * u.spread * maturity;
    float crest = out * 0.25;
    float t = d > crest ? (d - crest) / max(out - crest, 1e-3) : (crest - d) / max(crest + in, 1e-3);
    return t < 1 ? sqrt(1 - t * t) : 0;
}

// How grown the colony is here. Each spot grows up from the time moss reached it (the author at
// stop K): thin where it has just spread to, full height about an hour and a half of growth later, so the
// colony rises from where it started outwards and its ends are still low when growth stops.
static float maturity(Colony colony, Frame f) {
    // Where two colonies meet they press together: a shallow crease.
    float crease = 0.2 + 0.8 * smoothstep(0.0, 0.25, colony.rival - colony.reach);
    return smoothstep(-1.0, 3.0, colony.inside) * (0.08 + 0.92 * smoothstep(0.0, 0.8, colony.age)) * crease * f.stop;
}

// How fast `maturity` changes along the edge, per point: where a colony is still growing out, or
// at its young ends, the cushion falls away along the edge and its sides take the light. The
// crease and the corner's cap are left out (short, and the profile already rounds them).
static float maturitySlope(Colony colony, Frame f) {
    float crease = 0.2 + 0.8 * smoothstep(0.0, 0.25, colony.rival - colony.reach);
    float front = smoothstep(-1.0, 3.0, colony.inside), grown = 0.08 + 0.92 * smoothstep(0.0, 0.8, colony.age);
    // The slope of smoothstep(e0, e1, x): 6t(1 − t) / (e1 − e0).
    float tf = saturate((colony.inside + 1) / 4), ta = saturate(colony.age / 0.8);
    float frontSlope = 6 * tf * (1 - tf) / 4 * colony.slope.x;
    float grownSlope = 0.92 * 6 * ta * (1 - ta) / 0.8 * colony.slope.y;
    return (frontSlope * grown + front * grownSlope) * crease * f.stop;
}

// MARK: - Leaves

// Smooth noise along the edge, a tuft every few points: the value and its slope along s.
static float2 tufts(float s, float seed) {
    float i = floor(s / 4.5), f = fract(s / 4.5);
    float a = leafHash(float2(i, 13), seed), b = leafHash(float2(i + 1, 13), seed);
    return float2(mix(a, b, f * f * (3 - 2 * f)), (b - a) * 6 * f * (1 - f) / 4.5);
}

struct Leaves {
    float cover;    // 0…1: leaf here (gaps show through)
    float tip;      // 0…1: young, light tip or thin rim
    float shade;    // 0…1: darker (overlap, base)
    float gloss;    // 0…1: where a wet leaf catches the light
    float glow;     // 0…1: near a free leaf tip, where the light through it shows as nagi deepens
};

// Needle tufts (タマゴケ): from bases about 2.6 points apart, 5 fine leaves opening outwards.
// Only tips no farther out than `limit` (d, points) glow: the ones on leaves that are drawn.
static Leaves needles(float2 q, float seed, float limit) {
    Leaves l = {0, 0, 0, 0, 0};
    float cell = 2.6;
    float2 id = floor(q / cell);
    float near = 1e3;   // squared distance to the nearest glowing tip, (points / 0.9)²
    for (int j = -1; j <= 1; j++) {
        for (int i = -1; i <= 1; i++) {
            float2 c = id + float2(i, j);
            float2 base = (c + 0.5 + (float2(leafHash(c, seed), leafHash(c + 1, seed)) - 0.5) * 0.8) * cell;
            for (int n = 0; n < 5; n++) {
                float a = (leafHash(c + float2(n, 3), seed) - 0.5) * 2.4 + 1.5708;   // mostly outward (+d)
                float len = 2.0 + 1.2 * leafHash(c + float2(n, 5), seed);
                float2 tipEnd = base + float2(cos(a), sin(a)) * len;
                float2 st = segment(q, base, tipEnd);
                float2 r = (q - tipEnd) / 0.9;
                if (tipEnd.y <= limit) near = min(near, dot(r, r));
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
    l.glow = exp(-near);
    return l;
}

// Rounded domes (ホソバオキナゴケ): pale, dense, the leaves too short to see one by one (their
// velvet is the carpet's relief, `carpetRelief`).
// `slope` is the bump's slope along the edge (for the light; bounded near a dome's end).
static Leaves domes(float2 q, float seed, thread float &bump, thread float &slope) {
    Leaves l = {1, 0, 0, 0, 0};
    float cell = 8;
    float k = floor(q.x / cell);
    bump = 0;
    slope = 0;
    for (int i = -1; i <= 1; i++) {
        float c = k + i;
        float centre = (c + 0.5 + (leafHash(float2(c, 1), seed) - 0.5) * 0.6) * cell;
        float w = 4 + 3 * leafHash(float2(c, 2), seed);
        float x = (q.x - centre) / w;
        float root = sqrt(saturate(1 - x * x)), height = 0.6 + 0.4 * leafHash(float2(c, 3), seed);
        if (root * height > bump) {
            bump = root * height;
            slope = -x / max(root, 0.3) * height / w;
        }
    }
    return l;
}

// Fine upright blades (the third moss): dense, short, side by side like a fine lawn, each a
// little lighter or darker than the next; wet, a thin glint down one side.
static Leaves blades(float2 q, float top, float seed) {
    Leaves l = {0, 0, 0, 0, 0};
    float near = 1e3;
    float spacing = 0.55;
    float k = floor(q.x / spacing);
    // Three blades either side for the tips' glow (it reaches about 1.2 points, and only blades
    // whose tip leans less than half a point glow, so none is cut off), two for the blades.
    for (int i = -3; i <= 3; i++) {
        float c = k + i;
        float lean = (leafHash(float2(c, 21), seed) - 0.5) * 0.5;
        float tall = top * (0.75 + 0.4 * leafHash(float2(c, 22), seed));
        float base = -1.5, foot = (c + 0.5 + (leafHash(float2(c, 23), seed) - 0.5) * 0.6) * spacing;
        float shift = lean * (tall - base);
        float2 r = (q - float2(foot + shift, tall)) / 0.55;
        if (abs(shift) < 0.5) near = min(near, dot(r, r));
        if (abs(i) > 2) continue;
        float t = (q.y - base) / max(tall - base, 1e-3);   // 0 at the base … 1 at the tip
        if (t < 0 || t > 1) continue;
        float x = foot + lean * (q.y - base);
        float width = mix(0.38, 0.06, t * t);
        float off = q.x - x;
        if (abs(off) >= width) continue;
        float edge = saturate((width - abs(off)) / 0.1);
        l.cover = max(l.cover, edge);
        float tone = leafHash(float2(c, 24), seed);
        l.tip = max(l.tip, edge * (smoothstep(0.55, 1.0, t) * 0.8 + tone * 0.35));
        l.shade = max(l.shade, edge * (1 - tone) * 0.5 * (1 - t));
        l.gloss = max(l.gloss, edge * (1 - smoothstep(0.0, 0.08, abs(off + width * 0.4))) * smoothstep(0.3, 0.8, t));
    }
    l.glow = exp(-near);
    return l;
}

// A moss carpet as relief that the light picks out, in two sizes: groups of leaflets
// (`group` points across and along, turned by `turn`), and within them a fine nap (`fine`,
// stretched along the edge's outward direction), pushed sideways by up to `lean` points with
// each group's value, so the groups' nap does not line up. (A push, not a turn: turning about
// the edge's start by an angle that changes from pixel to pixel would move the samples far
// apart on a wide window.) The nap fades to its mean where it would be finer than about three
// pixels, so it never shimmers.
// Value about −1 … 1, gradient per point.
struct Carpet {
    float2 group, fine;
    float turn, lean, groupWeight, fineWeight;
};

static float3 carpetRelief(float2 q, Carpet c, float seed, float scale) {
    float3 group = orientedNoise(q, c.group, c.turn, seed + 81);
    float sharp = smoothstep(2.0, 3.0, min(c.fine.x, c.fine.y) * scale);
    float3 fine = sharp > 0 ? orientedNoise(q + float2(c.lean * group.x, 0), c.fine, 0.0, seed + 82) : float3(0);
    fine.yz += c.lean * fine.y * group.yz;   // the push moves with the group, so its slope counts too
    return group * c.groupWeight + fine * c.fineWeight * sharp;
}

// The three carpets: the needle moss in small groups opening each its own way, the domes a
// fine even velvet, the upright moss in narrow upright groups.
constant Carpet needleCarpet = {float2(4.2, 3.4), float2(1.5, 2.2), 0.7, 0.5, 0.6, 1.0};
constant Carpet domeCarpet = {float2(5.0, 5.0), float2(1.5, 1.5), 0.3, 0.0, 0.35, 0.8};
constant Carpet bladeCarpet = {float2(1.8, 4.0), float2(1.0, 2.6), 0.0, 0.0, 0.6, 0.9};

// Where the carpet gives way to leaves drawn one by one near the outline (`edge` 0 … 1).
static Leaves mixLeaves(Leaves a, Leaves b, float t) {
    return Leaves{mix(a.cover, b.cover, t), mix(a.tip, b.tip, t), mix(a.shade, b.shade, t), mix(a.gloss, b.gloss, t),
                  mix(a.glow, b.glow, t)};
}

// The carpet's leaves: lit tips where the relief stands up, shade in its hollows.
static Leaves carpetLeaves(float cover, float3 relief, float tips, float shade) {
    return Leaves{cover, smoothstep(0.25, 0.85, relief.x) * tips, (1 - smoothstep(-0.7, 0.1, relief.x)) * shade,
                  smoothstep(0.4, 0.9, relief.x) * 0.3, 0};
}

// Short hairs along a dome's outline, so even the rounded moss ends in fine tips against the
// sky: a sparse row, rooted just inside the outline, 0.6 … 1.6 points out. Returns coverage
// and writes how far along a hair the pixel is (0 at its root) and how near a hair's tip.
static float hairs(float2 q, float outline, float room, float seed, thread float &tip, thread float &glow) {
    float cell = 1.4, k = floor(q.x / cell), cover = 0;
    tip = 0;
    float near = 1e3;
    for (int i = -1; i <= 1; i++) {
        float c = k + i;
        if (leafHash(float2(c, 71), seed) > 0.7) continue;
        float2 root = float2((c + 0.5 + (leafHash(float2(c, 72), seed) - 0.5) * 0.7) * cell, outline - 0.5);
        // Whole hairs only, within the reach the sporophytes keep to (`room` points out).
        float len = min(1.1 + 1.0 * leafHash(float2(c, 73), seed), room - root.y);
        if (len < 0.4) continue;
        float lean = (leafHash(float2(c, 74), seed) - 0.5) * 0.8;
        float2 end = root + normalize(float2(lean, 1)) * len;
        float2 st = segment(q, root, end);
        float2 r = (q - end) / 0.8;
        near = min(near, dot(r, r));
        float width = mix(0.3, 0.08, st.y);
        if (st.x < width) {
            float a = saturate((width - st.x) / 0.12);
            cover = max(cover, a);
            tip = max(tip, a * smoothstep(0.3, 1.0, st.y));
        }
    }
    glow = exp(-near);
    return cover;
}

// Sporophytes on a grown-up colony (タマゴケ): a fine reddish-brown stalk with a small round
// brown capsule, rising as nagi deepens. Returns coverage (0…1) and writes the colour.
static float sporophytes(float2 q, float bed, float plenty, float rise, float limit, float sway, float straight,
                         float seed, thread float3 &colour) {
    float spacing = 5.5;
    float k = floor(q.x / spacing);
    float cover = 0;
    for (int i = -1; i <= 1; i++) {
        float c = k + i;
        if (hash(float2(c, 31), seed) > plenty) continue;
        float2 base = float2((c + 0.5 + (hash(float2(c, 32), seed) - 0.5) * 0.7) * spacing, bed);
        // Whole stalks only, rooted on the straight top (they stand straight up there).
        if (base.x < 3 || base.x > straight - 3) continue;
        // The capsule (0.6 + 1.1 points past the tip) stays within the limit too.
        // All about as tall, all upright (the author at stop K): only the wind leans them, the
        // taller the more (D19).
        float tall = min(9.0 * (0.96 + 0.08 * hash(float2(c, 33), seed)) * (0.35 + 0.65 * rise), limit - 1.8 - bed);
        float2 tip = base + float2(sway * tall * 0.3, tall);
        float2 st = segment(q, base, tip);
        // Bent by the wind, the stalk bows a little: offset by a curve along it.
        float2 bow = float2(0.4 * sway * tall * 0.3 * st.y * (1 - st.y), 0);
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

// The cushion's surface for the light: `profile` read as a mound rising toward
// the viewer, `shadingHeight` points high, so its upper shoulder faces up, the lip by the window
// faces down, and each tuft or dome leans along the edge. Worked out from the profile itself, not
// by sampling heights around the pixel. In the edge's frame: (along s, out along d, toward the viewer).
static float shadingHeight(float species) {
    return species < 0.5 ? 4.5 : species < 1.5 ? 5.5 : 3.0;
}

static float3 cushionNormal(float d, float tuft, float tuftSlope, float maturity, float maturitySlope, float species,
                            bool corner, constant Uniforms &u, float late) {
    float out = reachOut(species, corner, u, late) * maturity;
    float in = min(3.0, u.inward) * u.spread * maturity;
    float crest = out * 0.25, x = d / tuft;
    float width = max(x > crest ? out - crest : crest + in, 0.25);
    float t = clamp((x - crest) / width, -1.0, 1.0);
    float high = shadingHeight(species) * u.spread, rise = high * maturity * t / (tuft * width);
    float across = sqrt(1 - t * t);
    // Along the edge: the tufts' own rise and fall, and the colony thinning towards its ends,
    // where it grows lower and narrower too (crest and width scale with maturity).
    float thinning = across * across + t * (t + crest / width);
    float2 slope = float2(-rise * x * tuftSlope - high * thinning * maturitySlope, rise);
    // Round a corner, s is measured along the window's edge; out at d it is spread over r + d.
    if (corner) slope.x *= u.cornerRadius / (u.cornerRadius + max(d, 0.0));
    return normalize(float3(slope, max(across, 0.15)));
}

fragment float4 mossFragment(Out in [[stage_in]], constant Instance *instances [[buffer(0)]],
                             constant Uniforms &u [[buffer(1)]]) {
    constant Instance &patch = instances[in.instance];
    float2 pixel = in.position.xy;
    float radius = u.cornerRadius * u.scale;
    if (covered(pixel, patch, radius)) discard_fragment();
    // No moss without a root: the edge it grows from must be in sight. Round a corner, the root
    // is on the curve: towards the corner's centre from the pixel.
    float4 b = patch.base;
    float2 centre = float2(clamp(pixel.x, b.x + radius, b.z - radius), b.y + radius);
    float2 root = pixel.y < centre.y && pixel.x != centre.x
        ? centre + normalize(pixel - centre) * (radius - u.scale)
        : float2(pixel.x, b.y + u.scale);
    if (pixel.y >= centre.y) root = float2(clamp(pixel.x, b.x + u.scale, b.z - u.scale), pixel.y);
    if (covered(root, patch, radius)) discard_fragment();
    float2 p = pixel / u.scale;
    Frame f = edgeFrame(p, patch, u);
    Colony colony = colonyAt(f.s, patch, u);
    // Leaves at the growing front show a little before the cushion fills in behind them; past the
    // rounded end at a corner, nothing (not even a stray needle or stalk).
    if (colony.inside < -1.0 || f.stop <= 0.02) discard_fragment();
    float m = maturity(colony, f);
    float2 q = float2(f.s, f.d);
    bool domed = colony.species > 0.5 && colony.species < 1.5;
    float late = patch.extra.z;
    float bump = 0, bumpSlope = 0;
    Leaves l = domed ? domes(q, colony.seed, bump, bumpSlope) : Leaves{0, 0, 0, 0, 0};
    // The top's outline: rounded domes, or small tufts; never a ruled line.
    float2 tuftNoise = tufts(f.s, colony.seed);
    float tuft = domed ? 0.75 + 0.35 * bump : 0.85 + 0.3 * tuftNoise.x;
    float tuftSlope = domed ? 0.35 * bumpSlope : 0.3 * tuftNoise.y;
    float h = profile(f.d / tuft, m, colony.species, f.corner, u, late) * m;
    // How far out the cushion's outline is here, points.
    float outline = reachOut(colony.species, f.corner, u, late) * m * tuft;
    // As nagi deepens, the light through the free leaf tips shows on a dark screen as a faint
    // glow just around each tip (as round the gems), within the reach the sporophytes keep to.
    // On a light screen it would only tint the white, so there the tips glow in their colour only.
    float3 glowColour = mix(float3(0.62, 0.90, 0.16), dot(float3(0.62, 0.90, 0.16), float3(0.2126, 0.7152, 0.0722)) * float3(1.0), u.fade);
    // Only where the moss has grown up, as for the sporophytes' rounded ends (a young colony's
    // few leaves would glow as a block).
    float grownUp = smoothstep(0.3, 0.6, m) * smoothstep(0.5, 0.9, f.stop);
    float glowReach = u.deep * u.dark * 0.35 * grownUp * (1 - smoothstep(18.5 * u.spread, 19.5 * u.spread, f.d));
#define DISCARD_UNLESS_GLOW { float g = glowReach * l.glow; if (g > 0.004) return float4(glowColour * g, g); discard_fragment(); }
    float3 low, mid, light;
    // The carpet's fine relief (value, gradient per point) and how high it stands, points.
    float3 relief = float3(0);
    float reliefHeight = 0;
    if (colony.species < 0.5) {
        // Needle tips reach a little past the cushion.
        float fringe = profile((f.d - 1.5) / tuft, max(m, 0.15), colony.species, f.corner, u, late);
        // Inside, a carpet of leaflets drawn by the light on its relief; over the last few points
        // to the outline, the needle tufts one by one (they stand apart against the sky).
        float edge = smoothstep(outline - 3.4, outline - 2.0, f.d);
        // The tufts' tips glow a little past them, so look for them over the whole fringe band;
        // leaves themselves only where the cushion reaches.
        bool leaves = h > 0 || fringe > 0, glowing = glowReach > 0.004 && f.d < outline + 3.5;
        Leaves strokes = edge > 0 && (leaves || glowing) ? needles(q, colony.seed, outline + 1.5) : Leaves{0, 0, 0, 0, 0};
        if (!leaves) strokes = Leaves{0, 0, 0, 0, strokes.glow};
        float body = smoothstep(0.0, 0.25, h) * (1 - smoothstep(outline - 2.2, outline - 0.4, f.d));
        relief = carpetRelief(q, needleCarpet, colony.seed, u.scale);
        reliefHeight = 0.55 * smoothstep(0.0, 0.3, h);
        strokes.cover = max(strokes.cover, body * 0.9);
        strokes.tip *= 1 - body * 0.5;
        l = mixLeaves(carpetLeaves(body, relief, 0.8, 0.7), strokes, edge);
        low = float3(0.045, 0.065, 0.014); mid = float3(0.110, 0.230, 0.035); light = float3(0.480, 0.650, 0.070);
    } else if (domed) {
        float hairTip = 0, hairGlow = 0;
        // Hairs end at most 1.6 points out; their glow fades over about two more.
        float hair = f.d - outline > -2.0 && f.d - outline < 3.5
            ? hairs(q, outline, 19.5 * u.spread, colony.seed, hairTip, hairGlow) * grownUp : 0;
        // The hairs stand close, so their glow is weaker: it should not ring the dome.
        hairGlow = f.d - outline > -2.0 && f.d - outline < 3.5 ? 0.5 * hairGlow : 0;
        l.glow = hairGlow;
        if (h <= 0 && hair <= 0) DISCARD_UNLESS_GLOW
        relief = carpetRelief(q, domeCarpet, colony.seed, u.scale);
        reliefHeight = 0.2 * smoothstep(0.0, 0.3, h);
        l = carpetLeaves(max(smoothstep(0.0, 0.12, h), hair), relief, 0.5, 0.5);
        l.tip = max(l.tip, hairTip);
        l.glow = hairGlow;
        low = float3(0.065, 0.095, 0.035); mid = float3(0.170, 0.290, 0.095); light = float3(0.470, 0.590, 0.160);
    } else {
        // The blades one by one, their tips uneven against the sky; packed below, where the
        // carpet of upright groups takes over from them.
        float top = outline + 1;
        Leaves strokes = blades(q, top, colony.seed);
        float packed = (1 - smoothstep(top * 0.35, top * 0.7, f.d)) * step(-1.5, f.d) * smoothstep(0.0, 0.15, m);
        strokes.shade = max(strokes.shade, packed * (1 - strokes.cover) * 0.6);
        strokes.cover = max(strokes.cover, packed);
        relief = carpetRelief(q, bladeCarpet, colony.seed, u.scale);
        reliefHeight = 0.45 * smoothstep(0.0, 0.15, m);
        float edge = smoothstep(top * 0.45, top * 0.75, f.d);
        l = mixLeaves(carpetLeaves(strokes.cover, relief, 0.7, 0.6), strokes, edge);
        if (l.cover <= 0) DISCARD_UNLESS_GLOW
        low = float3(0.030, 0.060, 0.012); mid = float3(0.085, 0.230, 0.030); light = float3(0.400, 0.630, 0.065);
    }
    // Thin here and there (the reference's mottled moss): over a broad, uneven field the carpet
    // thins to its standing leaflets, which still catch the light, and the window shows between
    // them. Not a hole with a rim: no shade or contact darkening where it is thin, and the
    // outline stays whole. More often thin out towards a colony's young ends.
    // Thinning only in the lower part of the cushion, and less in the dense domes; never below
    // two thirds (the author: weaker), so a thin place is moss with the window between its
    // leaflets, not a gap.
    float patches = orientedNoise(q, float2(11.0, 4.0), 0.12, colony.seed + 91).x + 0.35 * relief.x;
    float thinning = (1 - smoothstep(0.35 * outline, 0.65 * outline, f.d)) * (domed ? 0.5 : 1.0);
    float density = 1 - 0.35 * thinning * (1 - smoothstep(-0.5, 0.0, patches - 0.3 * colony.spread));
    float standing = smoothstep(-0.2, 0.3, relief.x - 0.3 * (1 - density));
    l.cover *= mix(standing, 1.0, density);
    l.shade *= density;
    // A grown-up colony bears sporophytes: an hour after it first showed here (with some colonies
    // later than others), more of them over the next half hour (the author's idea at stop J0).
    float3 sporeColour = float3(0);
    float spore = 0;
    // Only along the straight top, so every sporophyte stands straight up.
    if (colony.species < 0.5 && f.s > -4 && f.s < f.straight + 4) {
        float start = 600 + 6600 * sqrt(colony.start / 3);
        float adultAt = start + 3600 + 1800 * hash(float2(41, 1), colony.seed);
        float plenty = 0.8 * smoothstep(adultAt, adultAt + 1800, patch.extra.x) * (1 - smoothstep(0.4, 0.75, colony.spread)) * smoothstep(0.5, 0.9, f.stop);
        if (plenty > 0) {
            float bed = reachOut(colony.species, f.corner, u, patch.extra.z) * m * tuft * 0.55;
            spore = sporophytes(q, bed, plenty, smoothstep(20.0, 120.0, u.depth), 19.5 * u.spread, patch.extra.y,
                                f.straight, colony.seed, sporeColour);
        }
    }
    if (l.cover <= 0 && spore <= 0) DISCARD_UNLESS_GLOW

    // The light. The sky, from above and in front, always: the upper shoulder bright, the lip by
    // the window dark, so the cushion reads as a mound and not a sticker. Then the sun or moon,
    // its direction mirrored to come from above (a southern sun is towards the bottom of the
    // screen and would light the lip); east or west, and how high, still show. A cloud takes away
    // the sun's share of contrast, not the moss's brightness (D20).
    float3 n = cushionNormal(f.d, tuft, tuftSlope, m, maturitySlope(colony, f), colony.species, f.corner, u, late);
    // The leaflets' own tilt on top of the cushion's (round a corner, s is spread over r + d).
    float2 tilt = reliefHeight * relief.yz;
    if (f.corner) tilt.x *= u.cornerRadius / (u.cornerRadius + max(f.d, 0.0));
    n = normalize(n / max(n.z, 0.15) - float3(tilt, 0));
    float3 normal = normalize(float3(n.x * float2(-f.outward.y, f.outward.x) + n.y * f.outward, n.z));
    float sky = saturate(0.5 + 0.5 * dot(normal, float3(0, -0.95, 0.31)));
    float direct = u.light.w;
    float3 toLight = normalize(float3(u.light.x, -abs(u.light.y), max(u.light.z, 0.05)));
    float facing = dot(normal, toLight);
    // What the cushion as a whole receives: the average of its normals, toward the light. The sun
    // moves light from the faces turned away to the faces turned to it (linear in the normal, so
    // the two cancel over the cushion), and the moss as a whole stays as bright as under cloud
    // or at night.
    float typical = dot(float3(0, -0.2, 0.9), toLight);
    // Light through the thin tips at the outline: mostly the sky's, more when the sun is low.
    float through = 0.45 + 0.55 * direct * (1 - 0.5 * saturate(u.light.z));
    float fine = smoothNoise(q, 6.0, colony.seed + 61), broad = smoothNoise(q, 20.0, colony.seed + 62);
    float3 colour = mix(low, mid, saturate(0.25 + 0.75 * h + 0.15 * bump));
    // Where the light falls full, yellow-green.
    float sunny = saturate(smoothstep(0.5, 0.92, sky) + 0.6 * direct * (facing - typical));
    colour = mix(colour, light, 0.55 * sunny);
    // Tips catch the light where they stand free at the outline; inside the cushion, less.
    float free = mix(0.35, 1.0, smoothstep(outline - 4.0, outline - 0.5, f.d));
    colour = mix(colour, light, l.tip * free * mix(0.5, 0.95, through));
    // As nagi deepens, the light comes through the thin leaflets (as the gems' deep light comes
    // up in the stone): the standing groups on the upper shoulder and the tips at the outline
    // glow a clear yellow-green. Within white; by colour, not glare.
    float thinLeaves = (domed ? 0.0 : smoothstep(0.1, 0.7, relief.x) * smoothstep(0.4 * outline, 0.85 * outline, f.d))
        + l.tip * free + l.glow * grownUp;
    colour = mix(colour, float3(0.72, 0.95, 0.18) * mix(0.85, 1.0, through), u.deep * 0.6 * saturate(thinLeaves));
    // The lower part lies in the shade of the moss above it.
    float under = mix(0.5, 1.0, smoothstep(-0.5 * outline, outline, f.d));
    float fill = mix(0.4, 1.4, sky);
    colour *= max(fill + direct * (facing - typical), 0.6 * fill) * under * (1 - 0.45 * l.shade);
    // Rooted: the lip where the cushion meets the window is in its own shade, broken here and there.
    float lip = min(3.0, u.inward) * u.spread * m * tuft;
    float contact = (1 - smoothstep(0.0, 0.9, abs(f.d + lip))) * mix(0.4, 1.0, fine);
    colour = mix(colour, low, 0.5 * contact * density);
    // No two places quite alike (the author at stop K): patches a little lighter or darker, a
    // little yellower or bluer (more often yellower), over a few points and over ten or more,
    // and each colony its own.
    float patchy = fine * 0.4 + broad * 0.6;
    float hue = (smoothNoise(q, 14.0, colony.seed + 63) - 0.5) * 1.0 + (hash(float2(64, 1), colony.seed) - 0.5) * 0.6 + 0.15;
    colour *= 0.62 + 0.75 * smoothstep(0.15, 0.85, patchy);
    colour *= float3(1 + 0.3 * hue, 1 + 0.05 * hue, 1 - 0.5 * hue);
    // Wet: deeper, and the clear leaves glint (D32).
    float wet = u.precipitation;
    colour *= mix(1.0, 0.7, wet);
    colour += float3(0.6, 0.75, 0.6) * l.gloss * wet * sky * 1.5;
    colour = min(colour, float3(1.0));
    float alpha = saturate(l.cover);
    // Dew on the outer leaves on a still morning: small beads, fixed in place, that brighten and
    // dim slowly (a period of about 15 seconds: far from the flash limit, D19).
    if (u.dew > 0 && h > 0.25) {
        float cell = 3.5;
        float k = floor(f.s / cell);
        for (int i = -1; i <= 1; i++) {
            float c = k + i;
            if (hash(float2(c, 51), colony.seed) > 0.3) continue;
            float edge = reachOut(colony.species, f.corner, u, patch.extra.z) * m * tuft;
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
    float halo = glowReach * l.glow;
    result += float4(glowColour * halo, halo) * (1 - alpha);
    return float4(sporeColour * spore, spore) + result * (1 - spore);
}
