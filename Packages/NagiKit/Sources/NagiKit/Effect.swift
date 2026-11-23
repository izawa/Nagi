import Foundation
import Metal

/// An effect (SPEC 3.4). One instance per effect type; the core calls `update` once per frame
/// and `render` once per display, serially, from the same thread.
public protocol Effect: AnyObject {
    static var descriptor: EffectDescriptor { get }

    /// Creates the effect's pipelines and resources. The effect loads its shaders from its own
    /// package (`Bundle.module`).
    init(context: EffectContext) throws

    /// Advances the simulation. Called once per frame, before `render`.
    func update(_ frame: FrameState)

    /// Draws into `encoder`'s output for one display.
    func render(_ frame: FrameState, view: DisplayView, encoder: any EffectEncoder) throws

    /// Frees what can be rebuilt. May be called while nagi is not shown.
    func releaseResources()

    /// A short line for the menu when the effect draws nothing or little at `frame`'s time and
    /// place (komorebi after sunset), so "see it now" showing nothing is not mistaken for a fault.
    /// Nil when it shows as usual.
    static func note(_ frame: FrameState) -> LocalizedStringResource?

    /// How hard this effect makes it rain at `frame`, 0 … 1 (its own parameters and depth). The
    /// core shares the largest as `SharedEnvironment.precipitation`, so other effects can get
    /// wet without knowing this one (DECISIONS D32). 0 for effects that bring no rain.
    static func precipitation(_ frame: FrameState) -> Double
}

extension Effect {
    public static func note(_ frame: FrameState) -> LocalizedStringResource? { nil }
    public static func precipitation(_ frame: FrameState) -> Double { 0 }
}

/// What the core lends an effect at creation.
public struct EffectContext {
    public let device: any MTLDevice
    /// The working format of every effect output: premultiplied RGBA, linear extended-range
    /// Display P3, 16-bit float (SPEC 3.5).
    public let pixelFormat: MTLPixelFormat

    public init(device: any MTLDevice, pixelFormat: MTLPixelFormat) {
        self.device = device
        self.pixelFormat = pixelFormat
    }
}

/// Lends an effect its passes for one frame on one display. The core owns the command buffer;
/// the effect only encodes inside the closures.
public protocol EffectEncoder: AnyObject {
    /// The size of the output in pixels.
    var outputSize: SIMD2<Int> { get }

    /// A render pass into the effect's layer for this frame (linear, premultiplied). It starts
    /// clear and keeps what earlier passes of this effect drew (`loadAction` is `.load`); the core
    /// puts it over the lower layers afterwards. Draw with premultiplied source-over blending:
    /// `rgb = src.rgb + dst.rgb × (1 − src.a)`, `a = src.a + dst.a × (1 − src.a)`.
    func renderToOutput(_ body: (any MTLRenderCommandEncoder) throws -> Void) rethrows

    /// A render pass into the effect's own scratch texture.
    func render(to pass: MTLRenderPassDescriptor, _ body: (any MTLRenderCommandEncoder) throws -> Void) rethrows

    /// A compute pass for scratch work.
    func compute(_ body: (any MTLComputeCommandEncoder) throws -> Void) rethrows
}

extension MTLRenderPipelineColorAttachmentDescriptor {
    /// The blending every effect uses when drawing into its output (premultiplied source-over).
    public func usePremultipliedSourceOver() {
        isBlendingEnabled = true
        rgbBlendOperation = .add
        alphaBlendOperation = .add
        sourceRGBBlendFactor = .one
        sourceAlphaBlendFactor = .one
        destinationRGBBlendFactor = .oneMinusSourceAlpha
        destinationAlphaBlendFactor = .oneMinusSourceAlpha
    }
}
