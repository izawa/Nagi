import Foundation
import Metal
import NagiKit

/// Draws what the window service sees, before moss exists (M3-PLAN stage A1, checkpoint H):
/// each window's outline with an assumed corner radius (green: moss may grow on it, red: it only
/// covers), the band along its top where moss would grow (filled from the left as its age goes
/// from 10 minutes to 2 hours), and the screen's bottom corners. Whatever a window in front
/// covers is not drawn. Debug-only: the app registers it with `--debug-windows`.
public final class WindowCheckEffect: Effect {
    public static let descriptor = EffectDescriptor(id: "windowcheck", displayName: "Window check",
                                                    summary: "Window service check", layer: .surface,
                                                    capabilities: [.windows])
    static let capacity = 64
    /// Points: the assumed corner radius, and how far moss reaches out and in (SPEC 4.3).
    static let cornerRadius: Float = 16
    static let outward: Float = 20
    static let inward: Float = 8

    private let pipeline: any MTLRenderPipelineState

    public init(context: EffectContext) throws {
        let library = try context.device.makeLibrary(source: Self.source, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "windowCheckVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "windowCheckFragment")
        descriptor.colorAttachments[0].pixelFormat = context.pixelFormat
        descriptor.colorAttachments[0].usePremultipliedSourceOver()
        pipeline = try context.device.makeRenderPipelineState(descriptor: descriptor)
    }

    public func update(_ frame: FrameState) {}

    /// Growth from 10 minutes to 2 hours (M3-PLAN 5.1).
    static func growth(_ seconds: Double) -> Float {
        let t = min(max((seconds - 600) / (7200 - 600), 0), 1)
        return Float(t * t * (3 - 2 * t))
    }

    public func render(_ frame: FrameState, view: DisplayView, encoder: any EffectEncoder) throws {
        guard let snapshot = frame.windows else { return }
        let origin = view.frameInDesktop.origin, scale = Float(view.scale)
        func pixels(_ rect: CGRect) -> SIMD4<Float> {
            SIMD4(Float(rect.minX - origin.x), Float(rect.minY - origin.y),
                  Float(rect.maxX - origin.x), Float(rect.maxY - origin.y)) * scale
        }
        // Per window near this display: its rectangle in pixels; then role (1 surface, 0
        // occluder), growth and corner radius (none for a window filling the display).
        let reach = view.frameInDesktop.insetBy(dx: -CGFloat(Self.outward), dy: -CGFloat(Self.outward))
        var rects: [SIMD4<Float>] = [], info: [SIMD4<Float>] = []
        for window in snapshot.frontToBack.filter({ $0.frame.intersects(reach) }).prefix(Self.capacity) {
            rects.append(pixels(window.frame))
            let radius = window.frame.contains(view.frameInDesktop) ? 0 : Self.cornerRadius
            info.append(SIMD4(window.role == .surface ? 1 : 0, Self.growth(window.stationarySeconds), radius, 0))
        }
        let usable = snapshot.usableAreas.first { $0.intersects(view.frameInDesktop) } ?? view.frameInDesktop
        var uniforms = Uniforms(count: Int32(rects.count), scale: scale,
                                outward: Self.outward, inward: Self.inward,
                                desktopGrowth: Self.growth(snapshot.desktopSeconds), usable: pixels(usable))
        rects.append(.zero)  // never an empty buffer
        info.append(.zero)
        encoder.renderToOutput { pass in
            pass.setRenderPipelineState(pipeline)
            pass.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            pass.setFragmentBytes(rects, length: MemoryLayout<SIMD4<Float>>.stride * rects.count, index: 1)
            pass.setFragmentBytes(info, length: MemoryLayout<SIMD4<Float>>.stride * info.count, index: 2)
            pass.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
    }

    public func releaseResources() {}

    struct Uniforms {
        var count: Int32
        var scale: Float
        var outward: Float
        var inward: Float
        var desktopGrowth: Float
        var usable: SIMD4<Float>
    }

    private static let source = """
    #include <metal_stdlib>
    using namespace metal;
    struct Out { float4 position [[position]]; };
    struct Uniforms { int count; float scale, outward, inward, desktopGrowth; float4 usable; };
    vertex Out windowCheckVertex(uint vid [[vertex_id]]) {
        float2 p = float2((vid << 1) & 2, vid & 2);
        Out out; out.position = float4(p * 2 - 1, 0, 1); return out;
    }
    // Signed distance to a rounded rectangle (negative inside), pixels.
    float roundedBox(float2 p, float4 r, float radius) {
        float2 centre = (r.xy + r.zw) * 0.5, extent = (r.zw - r.xy) * 0.5;
        float2 q = abs(p - centre) - extent + radius;
        return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
    }
    float4 over(float4 top, float4 below) { return top + below * (1 - top.a); }
    // Whether a window in front of window i covers point p.
    bool coveredBefore(int i, float2 p, constant float4 *rects, constant float4 *info, float scale) {
        for (int j = 0; j < i; j++) if (roundedBox(p, rects[j], info[j].z * scale) < 0) return true;
        return false;
    }
    fragment float4 windowCheckFragment(Out in [[stage_in]], constant Uniforms &u [[buffer(0)]],
                                        constant float4 *rects [[buffer(1)]], constant float4 *info [[buffer(2)]]) {
        float2 p = in.position.xy;
        float line = 1.5 * u.scale;
        float4 colour = 0;
        bool covered = false;
        // Front to back: draw each window's marks until a window covers this pixel.
        for (int i = 0; i < u.count && !covered; i++) {
            float4 r = rects[i];
            float d = roundedBox(p, r, info[i].z * u.scale);
            bool surface = info[i].x > 0.5;
            if (abs(d) < line) {
                colour = over(colour, surface ? float4(0.1, 0.8, 0.2, 1) * 0.9 : float4(0.9, 0.15, 0.1, 1) * 0.9);
            } else if (surface && d < u.outward * u.scale && d > -u.inward * u.scale
                       && p.y < r.y + 24 * u.scale
                       && !coveredBefore(i, float2(clamp(p.x, r.x + info[i].z * u.scale, r.z - info[i].z * u.scale), r.y + 1),
                                         rects, info, u.scale)) {
                // Not where the edge it grows from is covered: no band without a root. Around a
                // corner, the root is the nearest point of the straight top edge.
                // The band along the top, filled from the left as the window ages.
                bool grown = (p.x - r.x) / max(r.z - r.x, 1.0) < info[i].y;
                colour = over(colour, grown ? float4(0.1, 0.7, 0.2, 1) * 0.35 : float4(0.5, 0.5, 0.5, 1) * 0.15);
            }
            covered = d < 0;
        }
        // The screen's bottom corners, 40 points square, where nothing covers them.
        if (!covered) {
            float size = 40 * u.scale;
            bool corner = p.y > u.usable.w - size && p.y < u.usable.w
                && ((p.x > u.usable.x && p.x < u.usable.x + size) || (p.x < u.usable.z && p.x > u.usable.z - size));
            if (corner) colour = over(float4(0.2, 0.5, 0.9, 1) * (0.15 + 0.5 * u.desktopGrowth), colour);
        }
        if (colour.a <= 0) discard_fragment();
        return colour;
    }
    """
}
