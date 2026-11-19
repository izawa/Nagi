#include <metal_stdlib>
using namespace metal;

// Komorebi (SPEC 4.1). Per canopy layer: leaves are drawn into an occlusion mask in a frame turned
// to the sun's azimuth (u across, v along), the mask is filtered with the sun's image (an ellipse
// whose axes lie along the mask's rows and columns), and the composite pass combines the layers
// and turns the transmitted sunlight into shadow (light appearance) or light (dark appearance).

struct Leaf {
    float2 center;      // layer millimetres
    float halfLength;
    float halfWidth;
    float angle;
    float3 transmission;
    float2 anchor;      // where the leaf's branch is attached, layer millimetres
};

struct MaskUniforms {
    float4 axes;          // across.xy, along.xy (unit vectors, millimetres)
    float4 originSize;    // mask origin.xy and size.xy, texels
    float4 strideOffset;  // stride (mm per texel), offset.xy (shadow offset, mm), weight
};

static float hash(float2 cell) {
    return fract(sin(dot(cell, float2(127.1, 311.7))) * 43758.5453);
}

// Smooth value noise in −1…1, one feature per `wavelength` millimetres.
static float valueNoise(float2 p) {
    float2 i = floor(p), f = fract(p);
    float2 w = f * f * (3.0 - 2.0 * f);
    float a = hash(i), b = hash(i + float2(1, 0)), c = hash(i + float2(0, 1)), d = hash(i + float2(1, 1));
    return mix(mix(a, b, w.x), mix(c, d, w.x), w.y) * 2.0 - 1.0;
}

// The wind on one layer this frame (DECISIONS D19). Times are relative to now, so floats keep
// their precision however long the wind clock has run.
struct SwayUniforms {
    float4 direction;   // mean wind direction.xy (unit), gust front direction.xy (unit)
    float4 strength;    // response gain (wind slider), mean-wind factor 0…1, front speed mm/s, gust count
    float4 amplitude;   // trunk mm, branch mm, branch turn rad, flutter rad
    float4 trunk;       // phases (cycles) of the trunk's three waves, 0.1–0.3 Hz
    float4 branch;      // of the branch's, 0.5–1 Hz
    float4 flutter;     // of the leaf's, 2–5 Hz
    float4 gusts[8];    // onset − now (s), rise (s), duration (s), strength
};

// Gust strength 0…1 at a ground point: the front reaches points downwind later. The same curve as
// Wind.Gust.envelope in NagiKit.
static float gustAt(float2 ground, constant SwayUniforms &sway) {
    float delay = dot(ground, sway.direction.zw) / sway.strength.z;
    float strongest = 0;
    for (int i = 0; i < int(sway.strength.w); i++) {
        float4 g = sway.gusts[i];
        float s = -g.x - delay;
        if (s <= 0 || s >= g.z) continue;
        strongest = max(strongest, g.w * smoothstep(0.0, g.y, s) * (1.0 - smoothstep(g.y, g.z, s)));
    }
    return strongest;
}

// Three waves with weights 0.5, 0.3, 0.2, each shifted by its own phase: smooth, −1…1, aperiodic.
static float waves(float4 phases, float3 shift) {
    float3 p = 2.0 * M_PI_F * (phases.xyz + shift);
    return 0.5 * sin(p.x) + 0.3 * sin(p.y) + 0.2 * sin(p.z);
}

// Moves a leaf with the wind: the trunk sways the layer smoothly over about a metre, the branch
// sways and turns about its anchor and leans downwind in a gust, and the leaf flutters. Returns the
// new centre; `turn` receives the added rotation.
static float2 swayed(Leaf leaf, float2 offset, constant SwayUniforms &sway, thread float &turn) {
    float gain = sway.strength.x;
    turn = 0;
    if (gain <= 0) return leaf.center;
    float2 along = sway.direction.xy, across = float2(-along.y, along.x);
    float gust = gustAt(leaf.anchor + offset, sway);
    float push = gain * (sway.strength.y + gust);
    float region = valueNoise(leaf.anchor / 1500.0);
    float2 trunk = sway.amplitude.x * push
                 * (along * (0.6 + 0.4 * waves(sway.trunk, float3(0.1 * region)))
                    + across * 0.5 * waves(sway.trunk, float3(0.37, 0.61, 0.83) + 0.1 * region));
    float3 seed = float3(hash(leaf.anchor), hash(leaf.anchor + 17.0), hash(leaf.anchor + 31.0));
    float2 branch = sway.amplitude.y * gain
                  * (along * (0.7 * gust + 0.3 * (sway.strength.y + gust) * waves(sway.branch, seed))
                     + across * 0.4 * (sway.strength.y + gust) * waves(sway.branch, seed.zxy));
    float bend = sway.amplitude.z * push * waves(sway.branch, seed.yzx);
    float flutter = sway.amplitude.w * push * waves(sway.flutter, float3(hash(leaf.center), hash(leaf.center + 7.0),
                                                                        hash(leaf.center + 13.0)));
    turn = bend + flutter;
    float c = cos(bend), s = sin(bend);
    float2 r = leaf.center - leaf.anchor;
    return leaf.anchor + float2(c * r.x - s * r.y, s * r.x + c * r.y) + trunk + branch;
}

struct LeafOut {
    float4 position [[position]];
    float2 local;        // texels from the shape's centre, along and across the shape
    float3 transmission;
    float2 halfTexels;   // the shape's half-size in texels, at least one texel for the edge
    float2 sigma;        // the blob's spread in texels along and across the shape
    float areaRatio;     // < 1 when the edge shape was enlarged to one texel
    float area;          // the shape's area in texels (as an ellipse)
    float edge;          // 0 draws a blob, 1 an edge, between them a mix (see leafVertex)
};

vertex LeafOut leafVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                          constant Leaf *leaves [[buffer(0)]],
                          constant MaskUniforms &mask [[buffer(1)]],
                          constant SwayUniforms &sway [[buffer(2)]]) {
    Leaf leaf = leaves[iid];
    float turn;
    leaf.center = swayed(leaf, mask.strideOffset.yz, sway, turn);
    leaf.angle += turn;
    float2 corner = float2((vid & 1) ? 1.0 : -1.0, (vid & 2) ? 1.0 : -1.0);
    // The wind moves shapes by fractions of a texel, so the light a shape lets through must not
    // depend on where it sits within a texel (DECISIONS D19). A shape under about two texels
    // across its narrow side is drawn as a Gaussian blob with the shape's area, spread σ = half-axis
    // / √2 (its peak is then at most one: fully open) and at least a texel: a blob that smooth sums to the
    // same light wherever it sits. A wider shape gets an anti-aliased edge two texels wide, which
    // the sun's image (several texels) blurs anyway. Between 1.8 and 2.6 texels the two are mixed,
    // so a shape does not jump as the sun changes the mask's texel.
    float stride = mask.strideOffset.x;
    float2 trueTexels = float2(leaf.halfLength, leaf.halfWidth) / stride;
    float2 halfTexels = max(trueTexels, float2(1.0));
    float2 sigma = max(trueTexels * M_SQRT1_2_F, float2(1.0));
    float edge = smoothstep(1.8, 2.6, min(trueTexels.x, trueTexels.y));
    // Room for the edge, and for the blob's tails only when the blob is drawn.
    // A leaf's tip closes at 1.0113 of its half-length (leafFragment), past the ellipse's.
    float2 shapeReach = halfTexels * float2(1.012, 1.0) + 1.0;
    float2 reach = edge < 1.0 ? max(shapeReach, 3.0 * sigma) : shapeReach;
    float2 local = corner * reach;
    float2 extent = local * stride;
    float c = cos(leaf.angle), s = sin(leaf.angle);
    float2 world = leaf.center + float2(c * extent.x - s * extent.y, s * extent.x + c * extent.y);
    float2 texel = float2(dot(world, mask.axes.xy), dot(world, mask.axes.zw)) / mask.strideOffset.x
                   - mask.originSize.xy;
    LeafOut out;
    out.position = float4(texel.x / mask.originSize.z * 2 - 1, 1 - texel.y / mask.originSize.w * 2, 0, 1);
    out.local = local;
    out.transmission = leaf.transmission;
    out.halfTexels = halfTexels;
    out.sigma = sigma;
    out.areaRatio = (trueTexels.x * trueTexels.y) / (halfTexels.x * halfTexels.y);
    out.area = M_PI_F * trueTexels.x * trueTexels.y;
    out.edge = edge;
    return out;
}

// A blob: a Gaussian with the shape's spread holding `area` texels of light.
static float blobCoverage(LeafOut in, float area) {
    float2 q = in.local / in.sigma;
    return min(1.0, area / (2.0 * M_PI_F * in.sigma.x * in.sigma.y) * exp(-0.5 * dot(q, q)));
}

// Coverage with an edge two texels wide, from the signed distance `d` and its gradient, both in
// shape units (half-sizes of 1), worked out exactly so the edge is as wide everywhere. A ramp that
// wide over a curved edge adds about π/3 texels² to the area; pulling the edge in by
// 1 / (3 (a + b)) texels takes it back, so a shape lets through its own area at any size.
static float edgeCoverage(float d, float2 gradient, float2 halfTexels) {
    float perTexel = length(gradient / halfTexels);
    float distance = d / max(perTexel, 1e-4) + 1.0 / (3.0 * (halfTexels.x + halfTexels.y));
    return clamp(0.5 - 0.5 * distance, 0.0, 1.0);
}

// A pointed leaf: half-width (1 − x²)^0.7 along its length, 0.93 of its ellipse's area.
// Multiplied into the mask.
fragment float4 leafFragment(LeafOut in [[stage_in]]) {
    float2 p = in.local / in.halfTexels;
    // Near the tips the curve is continued as a straight cone (same value and slope where they
    // meet, closing at |x| ≈ 1.01), so the distance and its gradient stay smooth past the tip.
    const float tipStart = 0.97468, tipWidth = 0.12281, tipSlope = 3.3511;  // 1 − x² = 0.05
    float x = abs(p.x);
    float halfWidth = x < tipStart ? pow(1.0 - x * x, 0.7) : tipWidth - tipSlope * (x - tipStart);
    float slope = x < tipStart ? 1.4 * x * pow(1.0 - x * x, -0.3) : tipSlope;
    float d = abs(p.y) - halfWidth;
    float2 gradient = float2(slope * sign(p.x), sign(p.y));
    float coverage = mix(blobCoverage(in, 0.93 * in.area), edgeCoverage(d, gradient, in.halfTexels) * in.areaRatio,
                         in.edge);
    return float4(mix(float3(1.0), in.transmission, coverage), 1.0);
}

// An opening in a closed crown: a soft-edged ellipse that lets the sky through. The light it adds
// over the crown's own transmission is added to the mask, so openings that share texels (a split
// pair, or blobs on a coarse mask) keep all their light; the filter caps the mask at open sky.
fragment float4 gapFragment(LeafOut in [[stage_in]]) {
    float2 p = in.local / in.halfTexels;
    float r = max(length(p), 1e-4);
    float coverage = mix(blobCoverage(in, in.area), edgeCoverage(r - 1.0, p / r, in.halfTexels) * in.areaRatio,
                         in.edge);
    return float4((1.0 - in.transmission) * coverage, 0.0);
}

// A mask texel, capped at open sky: a crown's openings are added, and two that overlap would
// otherwise pass more light than no crown at all.
static float4 maskAt(texture2d<float, access::read> mask, uint2 texel) {
    return min(mask.read(texel), float4(1.0));
}

// Running sums along each mask row: prefix[i] = sum of mask[0 ..< i]. One thread per row.
kernel void prefixRows(texture2d<float, access::read> mask [[texture(0)]],
                       texture2d<float, access::write> prefix [[texture(1)]],
                       uint row [[thread_position_in_grid]]) {
    if (row >= mask.get_height()) return;
    uint width = mask.get_width();
    float4 sum = 0;
    prefix.write(sum, uint2(0, row));
    for (uint i = 0; i < width; i++) {
        sum += maskAt(mask, uint2(i, row));
        prefix.write(sum, uint2(i + 1, row));
    }
}

// The row sum from 0 to x (texels, fractional).
static float4 prefixAt(texture2d<float, access::read> prefix, texture2d<float, access::read> mask,
                       uint row, float x) {
    uint width = mask.get_width();
    x = clamp(x, 0.0, float(width));
    float whole = floor(x);
    uint i = uint(whole);
    float4 value = prefix.read(uint2(i, row));
    if (i < width) value += (x - whole) * maskAt(mask, uint2(i, row));
    return value;
}

struct SunImage {
    float2 semiAxes;  // across, along; texels
    float2 origin;    // mask origin, texels
    float stride;     // millimetres per texel
    float spread;     // the image is scaled by 2^(spread · noise)
};

// The mean of the mask over the sun's image (an ellipse, semi-axes a across and b along), as a sum
// of horizontal chords read from the row sums: exact for a flat region, so the disk has a flat
// interior, and at most 2⌊b⌋ + 1 rows per texel. The image size varies slowly over the layer, as
// the leaves' heights do.
kernel void chordFilter(texture2d<float, access::read> mask [[texture(0)]],
                        texture2d<float, access::read> prefix [[texture(1)]],
                        texture2d<float, access::write> filtered [[texture(2)]],
                        constant SunImage &image [[buffer(0)]],
                        uint2 gid [[thread_position_in_grid]]) {
    uint width = mask.get_width(), height = mask.get_height();
    if (gid.x >= width || gid.y >= height) return;
    float scale = 1.0;
    if (image.spread > 0) {
        float2 millimetres = (image.origin + float2(gid) + 0.5) * image.stride;
        scale = exp2(image.spread * valueNoise(millimetres / 350.0));
    }
    float a = image.semiAxes.x * scale, b = image.semiAxes.y * scale;
    if (b < 0.5) {
        filtered.write(maskAt(mask, gid), gid);
        return;
    }
    int reach = int(floor(b));
    float4 sum = 0;
    float area = 0;
    for (int k = -reach; k <= reach; k++) {
        float w = a * sqrt(max(0.0, 1.0 - (float(k) / b) * (float(k) / b)));
        if (w <= 0) continue;
        uint row = uint(clamp(int(gid.y) + k, 0, int(height) - 1));
        float centre = float(gid.x) + 0.5;
        // Clip the chord to the mask so the edge texels are not darkened by missing area.
        float x0 = max(centre - w, 0.0), x1 = min(centre + w, float(width));
        sum += prefixAt(prefix, mask, row, x1) - prefixAt(prefix, mask, row, x0);
        area += x1 - x0;
    }
    filtered.write(area > 0 ? sum / area : maskAt(mask, gid), gid);
}

struct FullscreenOut {
    float4 position [[position]];
};

vertex FullscreenOut komorebiFullscreen(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    FullscreenOut out;
    out.position = float4(p * 2 - 1, 0, 1);
    return out;
}

struct CompositeUniforms {
    float4 display;   // desktop origin.xy (millimetres), points per pixel, millimetres per point
    float4 output;    // alpha at full effect, clear-sky weight g, dark appearance (0/1), exposure
    float4 colour;    // straight (unpremultiplied) linear Display P3 colour of the output; w: shadow curve
    MaskUniforms layers[4];
};

static float3 layerTransmission(texture2d<float> filtered, sampler s, MaskUniforms layer, float2 ground) {
    float weight = layer.strideOffset.w;
    if (weight <= 0) return float3(1.0);
    float2 q = ground - layer.strideOffset.yz;
    float2 texel = float2(dot(q, layer.axes.xy), dot(q, layer.axes.zw)) / layer.strideOffset.x - layer.originSize.xy;
    float3 t = filtered.sample(s, texel / layer.originSize.zw).rgb;
    return mix(float3(1.0), t, weight);
}

fragment float4 komorebiComposite(FullscreenOut in [[stage_in]],
                                  texture2d<float> crownHigh [[texture(0)]],
                                  texture2d<float> crownLow [[texture(1)]],
                                  texture2d<float> middle [[texture(2)]],
                                  texture2d<float> low [[texture(3)]],
                                  sampler s [[sampler(0)]],
                                  constant CompositeUniforms &u [[buffer(0)]]) {
    float2 ground = u.display.xy + in.position.xy * u.display.z * u.display.w;
    // The two crowns are one canopy with gaps at two heights: light comes through either.
    float3 high = layerTransmission(crownHigh, s, u.layers[0], ground);
    float3 lowCrown = layerTransmission(crownLow, s, u.layers[1], ground);
    // A smooth max: where the two crowns' light crosses, a hard max has a corner, and a crown
    // swaying across the other turns that corner into flicker above 3 Hz (DECISIONS D19). The
    // rounding scales with the light (+6 % where they are equal), so the shade stays dark, and
    // the result never passes open sky.
    float3 gap = high - lowCrown, round = 0.06 * (high + lowCrown);
    float3 crown = min(0.5 * (high + lowCrown + sqrt(gap * gap + round * round)), float3(1.0));
    float3 transmission = crown
                        * layerTransmission(middle, s, u.layers[2], ground)
                        * layerTransmission(low, s, u.layers[3], ground);
    // Direct sunlight reaching this point, relative to an open sky, then exposed for the eye
    // adapted to the shade: a sun disk from a small gap carries only a few per cent of full sun.
    // A soft shoulder instead of a clip, so overlapping disks stay brighter than single ones:
    // t = 1 − e^(−x). The light appearance's shade (1 − t)^curve is e^(−x·curve), computed directly
    // so it still fades where t rounds to 1.
    float x = max(0.0, dot(transmission, float3(0.2126, 0.7152, 0.0722))) * u.output.w;
    float t = 1.0 - exp(-x);
    float g = u.output.y;
    // Light appearance: the shade, lifted in the middle by the curve (< 1 darkens the half-shade).
    float shade = exp(-x * max(u.colour.w, 0.05));
    float alpha = u.output.x * g * (u.output.z > 0.5 ? t : shade);
    return float4(u.colour.rgb * alpha, alpha);
}
