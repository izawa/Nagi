import Foundation
import Metal
import NagiKit

/// A flat premultiplied colour over a rectangle, for calibrating nagi-render against the screen
/// (M1-PLAN 7.1). Parameters: r g b a (premultiplied, linear Display P3), x0 y0 x1 y1 (pixels).
/// Debug-only: nagi-render offers it, and the app registers it only with `--debug-patch`.
public final class PatchEffect: Effect {
    public static let descriptor = EffectDescriptor(id: "patch", displayName: "Patch", summary: "Calibration", layer: .light)

    private let pipeline: any MTLRenderPipelineState

    public init(context: EffectContext) throws {
        let library = try context.device.makeLibrary(source: Self.source, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "patchVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "patchFragment")
        descriptor.colorAttachments[0].pixelFormat = context.pixelFormat
        descriptor.colorAttachments[0].usePremultipliedSourceOver()
        pipeline = try context.device.makeRenderPipelineState(descriptor: descriptor)
    }

    public func update(_ frame: FrameState) {}

    public func render(_ frame: FrameState, view: DisplayView, encoder: any EffectEncoder) throws {
        let size = encoder.outputSize
        var uniforms = (
            SIMD4<Float>(Float(frame.number("x0", default: 0)), Float(frame.number("y0", default: 0)),
                         Float(frame.number("x1", default: Double(size.x))), Float(frame.number("y1", default: Double(size.y)))),
            SIMD4<Float>(Float(frame.number("r", default: 0)), Float(frame.number("g", default: 0)),
                         Float(frame.number("b", default: 0)), Float(frame.number("a", default: 0.08)))
        )
        encoder.renderToOutput { pass in
            pass.setRenderPipelineState(pipeline)
            pass.setFragmentBytes(&uniforms, length: MemoryLayout.size(ofValue: uniforms), index: 0)
            pass.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
    }

    public func releaseResources() {}

    private static let source = """
    #include <metal_stdlib>
    using namespace metal;
    struct Out { float4 position [[position]]; };
    vertex Out patchVertex(uint vid [[vertex_id]]) {
        float2 p = float2((vid << 1) & 2, vid & 2);
        Out out; out.position = float4(p * 2 - 1, 0, 1); return out;
    }
    struct Uniforms { float4 rect; float4 color; };
    fragment float4 patchFragment(Out in [[stage_in]], constant Uniforms &u [[buffer(0)]]) {
        float2 p = in.position.xy;
        if (p.x < u.rect.x || p.y < u.rect.y || p.x >= u.rect.z || p.y >= u.rect.w) discard_fragment();
        return u.color;
    }
    """
}
