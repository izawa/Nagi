import Foundation
import Metal
import NagiKit

/// A premultiplied colour patch over a pixel rectangle, both from parameters
/// (`r g b a`, `x0 y0 x1 y1`; the rectangle defaults to everything).
class PatchEffect: Effect {
    class var layer: EffectLayer { .surface }
    class var id: String { "test.patch" }
    static var descriptor: EffectDescriptor {
        EffectDescriptor(id: id, displayName: "Patch", summary: "Test", layer: layer)
    }

    private let pipeline: any MTLRenderPipelineState

    required init(context: EffectContext) throws {
        let library = try context.device.makeDefaultLibrary(bundle: Bundle.module)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "testFullscreenVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "patchFragment")
        descriptor.colorAttachments[0].pixelFormat = context.pixelFormat
        descriptor.colorAttachments[0].usePremultipliedSourceOver()
        pipeline = try context.device.makeRenderPipelineState(descriptor: descriptor)
    }

    func update(_ frame: FrameState) {}

    func render(_ frame: FrameState, view: DisplayView, encoder: any EffectEncoder) throws {
        let size = encoder.outputSize
        var uniforms = (
            SIMD4<Float>(Float(frame.number("x0", default: 0)), Float(frame.number("y0", default: 0)),
                         Float(frame.number("x1", default: Double(size.x))), Float(frame.number("y1", default: Double(size.y)))),
            SIMD4<Float>(Float(frame.number("r", default: 0)), Float(frame.number("g", default: 0)),
                         Float(frame.number("b", default: 0)), Float(frame.number("a", default: 0)))
        )
        encoder.renderToOutput { pass in
            pass.setRenderPipelineState(pipeline)
            pass.setFragmentBytes(&uniforms, length: MemoryLayout.size(ofValue: uniforms), index: 0)
            pass.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
    }

    func releaseResources() {}
}

final class SurfacePatch: PatchEffect {
    override class var id: String { "test.surface" }
}

final class LightPatch: PatchEffect {
    override class var layer: EffectLayer { .light }
    override class var id: String { "test.light" }
}

/// An effect without `.backdrop`: records whether it was handed a backdrop anyway.
final class PlainProbe: Effect {
    static let descriptor = EffectDescriptor(id: "test.plain", displayName: "Plain", summary: "Test", layer: .glass)
    private(set) var sawBackdrop = false
    init(context: EffectContext) throws {}
    func update(_ frame: FrameState) {}
    func render(_ frame: FrameState, view: DisplayView, encoder: any EffectEncoder) throws {
        sawBackdrop = sawBackdrop || view.backdrop != nil
    }
    func releaseResources() {}
}

/// A `.glass` effect that reads its backdrop at one pixel (parameters `px py`).
final class BackdropProbe: Effect {
    static let descriptor = EffectDescriptor(id: "test.backdrop", displayName: "Backdrop", summary: "Test",
                                             layer: .glass, capabilities: [.backdrop])
    private let pipeline: any MTLComputePipelineState
    let sample: any MTLBuffer
    private(set) var sawBackdrop = false

    init(context: EffectContext) throws {
        let library = try context.device.makeDefaultLibrary(bundle: Bundle.module)
        pipeline = try context.device.makeComputePipelineState(function: library.makeFunction(name: "sampleTexture")!)
        sample = context.device.makeBuffer(length: 16, options: .storageModeShared)!
    }

    func update(_ frame: FrameState) {}

    func render(_ frame: FrameState, view: DisplayView, encoder: any EffectEncoder) throws {
        guard let backdrop = view.backdrop else { return }
        sawBackdrop = true
        var point = SIMD2<UInt32>(UInt32(frame.number("px", default: 0)), UInt32(frame.number("py", default: 0)))
        encoder.compute { pass in
            pass.setComputePipelineState(pipeline)
            pass.setTexture(backdrop, index: 0)
            pass.setBuffer(sample, offset: 0, index: 0)
            pass.setBytes(&point, length: 8, index: 1)
            pass.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
        }
    }

    func releaseResources() {}

    var sampled: SIMD4<Float> { sample.contents().load(as: SIMD4<Float>.self) }
}

/// Makes it rain as hard as its "rain" parameter says, and records the precipitation it was given.
final class RainProbe: Effect {
    static let descriptor = EffectDescriptor(id: "test.rain", displayName: "Rain", summary: "Test", layer: .glass)
    static func precipitation(_ frame: FrameState) -> Double { frame.number("rain", default: 0) }
    private(set) var seen: Double?
    init(context: EffectContext) throws {}
    func update(_ frame: FrameState) { seen = frame.environment.precipitation }
    func render(_ frame: FrameState, view: DisplayView, encoder: any EffectEncoder) throws {}
    func releaseResources() {}
}
