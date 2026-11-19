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
};

struct MaskUniforms {
    float4 axes;          // across.xy, along.xy (unit vectors, millimetres)
    float4 originSize;    // mask origin.xy and size.xy, texels
    float4 strideOffset;  // stride (mm per texel), offset.xy (shadow offset, mm), weight
};

struct LeafOut {
    float4 position [[position]];
    float2 local;
    float3 transmission;
    float areaRatio;  // < 1 when the shape was enlarged to at least one texel
};

vertex LeafOut leafVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                          constant Leaf *leaves [[buffer(0)]],
                          constant MaskUniforms &mask [[buffer(1)]]) {
    Leaf leaf = leaves[iid];
    float2 corner = float2((vid & 1) ? 1.0 : -1.0, (vid & 2) ? 1.0 : -1.0);
    // A little margin so the anti-aliased edge fits inside the quad. A shape smaller than a mask
    // texel is drawn one texel wide with its light scaled by its true area, so a small gap on a
    // coarse mask (low sun) still lets its share of light through instead of popping.
    float2 local = corner * 1.15;
    float stride = mask.strideOffset.x;
    float2 size = max(float2(leaf.halfLength, leaf.halfWidth), float2(stride * 0.75));
    float2 extent = local * size;
    float c = cos(leaf.angle), s = sin(leaf.angle);
    float2 world = leaf.center + float2(c * extent.x - s * extent.y, s * extent.x + c * extent.y);
    float2 texel = float2(dot(world, mask.axes.xy), dot(world, mask.axes.zw)) / mask.strideOffset.x
                   - mask.originSize.xy;
    LeafOut out;
    out.position = float4(texel.x / mask.originSize.z * 2 - 1, 1 - texel.y / mask.originSize.w * 2, 0, 1);
    out.local = local;
    out.transmission = leaf.transmission;
    out.areaRatio = (leaf.halfLength * leaf.halfWidth) / (size.x * size.y);
    return out;
}

// A pointed leaf: half-width (1 − x²)^0.7 along its length. Multiplied into the mask.
fragment float4 leafFragment(LeafOut in [[stage_in]]) {
    float2 p = in.local;
    float halfWidth = pow(max(0.0, 1.0 - p.x * p.x), 0.7);
    float d = abs(p.y) - halfWidth;
    float coverage = clamp(0.5 - d / max(fwidth(d), 1e-4), 0.0, 1.0);
    return float4(mix(float3(1.0), in.transmission, coverage * in.areaRatio), 1.0);
}

// An opening in a closed crown: a soft-edged ellipse that lets the sky through (max-blended).
// `transmission` is the crown's own, so a gap scaled down by its area still adds to the crown.
fragment float4 gapFragment(LeafOut in [[stage_in]]) {
    float d = length(in.local) - 1.0;
    float coverage = clamp(0.5 - d / max(fwidth(d), 1e-4), 0.0, 1.0);
    return float4(mix(in.transmission, float3(1.0), coverage * in.areaRatio), 1.0);
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
        sum += mask.read(uint2(i, row));
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
    if (i < width) value += (x - whole) * mask.read(uint2(i, row));
    return value;
}

struct SunImage {
    float2 semiAxes;  // across, along; texels
    float2 origin;    // mask origin, texels
    float stride;     // millimetres per texel
    float spread;     // the image is scaled by 2^(spread · noise)
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
        filtered.write(mask.read(gid), gid);
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
    filtered.write(area > 0 ? sum / area : mask.read(gid), gid);
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
    float3 crown = max(layerTransmission(crownHigh, s, u.layers[0], ground),
                       layerTransmission(crownLow, s, u.layers[1], ground));
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
