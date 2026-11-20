import Foundation
import Metal
import NagiKit

/// A few round lenses drifting over the screen, magnifying what is behind them: checks the
/// screen capture and the `.glass`/`.backdrop` path before rain exists (M2-PLAN stage A).
/// Debug-only: the app registers it with `--debug-lens`, and nagi-render offers it.
public final class LensEffect: Effect {
    public static let descriptor = EffectDescriptor(id: "lens", displayName: "Lens", summary: "Capture check",
                                                    layer: .glass, capabilities: [.backdrop])
    static let count = 6

    private let pipeline: any MTLRenderPipelineState

    public init(context: EffectContext) throws {
        let library = try context.device.makeLibrary(source: Self.source, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "lensVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "lensFragment")
        descriptor.colorAttachments[0].pixelFormat = context.pixelFormat
        descriptor.colorAttachments[0].usePremultipliedSourceOver()
        pipeline = try context.device.makeRenderPipelineState(descriptor: descriptor)
    }

    public func update(_ frame: FrameState) {}

    public func render(_ frame: FrameState, view: DisplayView, encoder: any EffectEncoder) throws {
        // Without the screen behind (no capture yet, or no permission) there is nothing to bend.
        guard let backdrop = view.backdrop else { return }
        let size = SIMD2<Float>(Float(encoder.outputSize.x), Float(encoder.outputSize.y))
        let radius = Float(60 * view.scale)
        var lenses = (0..<Self.count).map { index -> SIMD4<Float> in
            // Spread over the display, each drifting slowly on its own small circle.
            let base = SIMD2<Float>(Float(index % 3) + 0.5, Float(index / 3) + 0.5) / SIMD2(3, 2) * size
            let angle = Float(frame.time) * 0.3 + Float(index)
            let centre = base + SIMD2(cos(angle), sin(angle)) * radius
            return SIMD4(centre.x, centre.y, radius, 0)
        }
        encoder.renderToOutput { pass in
            pass.setRenderPipelineState(pipeline)
            pass.setFragmentTexture(backdrop, index: 0)
            pass.setFragmentBytes(&lenses, length: MemoryLayout<SIMD4<Float>>.stride * lenses.count, index: 0)
            pass.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
    }

    public func releaseResources() {}

    private static let source = """
    #include <metal_stdlib>
    using namespace metal;
    struct Out { float4 position [[position]]; };
    vertex Out lensVertex(uint vid [[vertex_id]]) {
        float2 p = float2((vid << 1) & 2, vid & 2);
        Out out; out.position = float4(p * 2 - 1, 0, 1); return out;
    }
    // The backdrop is encoded Display P3 (sRGB transfer); effects output linear, premultiplied.
    float3 linearize(float3 c) { return select(pow((c + 0.055) / 1.055, 2.4), c / 12.92, c <= 0.04045); }
    fragment float4 lensFragment(Out in [[stage_in]], texture2d<float> backdrop [[texture(0)]],
                                 constant float4 *lenses [[buffer(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float2 p = in.position.xy;
        float2 size = float2(backdrop.get_width(), backdrop.get_height());
        for (int i = 0; i < \(count); i++) {
            float2 d = p - lenses[i].xy;
            float r = lenses[i].z, dist = length(d);
            if (dist >= r) continue;
            float t = dist / r;
            // A near lens: magnified, more so towards the rim; a dark ring at the edge.
            float2 source = lenses[i].xy + d * (0.7 - 0.15 * t * t);
            float3 colour = linearize(backdrop.sample(s, source / size).rgb) * (1 - 0.35 * smoothstep(0.8, 1, t));
            float alpha = clamp(r - dist, 0.0, 1.0);
            return float4(colour * alpha, alpha);
        }
        discard_fragment();
        return 0;
    }
    """
}
