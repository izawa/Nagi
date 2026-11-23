import Metal
import NagiKit

/// Runs the effects and composites them (SPEC 3.3, 3.5). The live overlay and nagi-render use
/// the same renderer, so what the CLI shows is what the screen gets.
///
/// Per display and frame, bottom layer first: each effect draws into a cleared layer texture
/// (premultiplied, linear, 16-bit float), and the layer is put onto the stack, which holds
/// encoded premultiplied values, by the rule WindowServer uses for the desktop (D1, D40). So an
/// effect looks the same over the lower layers as over the desktop. A `.backdrop` effect first
/// gets the screen under it: the backdrop with the stack so far over it. The last pass turns the
/// stack back into linear values and multiplies it by presence × strength.
@MainActor public final class FrameRenderer {
    public static let workingFormat = MTLPixelFormat.rgba16Float

    public let device: any MTLDevice
    public let queue: any MTLCommandQueue
    private let effects: [(descriptor: EffectDescriptor, instance: any Effect)]
    /// The ids of the effects this renderer runs, bottom layer first.
    public var effectIDs: [String] { effects.map(\.descriptor.id) }
    public var descriptors: [EffectDescriptor] { effects.map(\.descriptor) }
    private let layerPipeline: any MTLRenderPipelineState
    private let backdropPipeline: any MTLRenderPipelineState
    private let outputPipeline: any MTLRenderPipelineState
    private let blendPipeline: any MTLRenderPipelineState
    /// Saved parameter values by effect id and key; missing keys use the declared defaults.
    public var parameters: [String: [String: ParameterValue]] = [:]
    /// Effects not running in this showing (switched off, not drawn by random mode, or not
    /// permitted): they neither update nor draw.
    public var disabledIDs: Set<String> = [] {
        didSet { running = effects.filter { !disabledIDs.contains($0.descriptor.id) } }
    }
    private var running: [(descriptor: EffectDescriptor, instance: any Effect)]
    /// The layers so far, encoded and premultiplied.
    private var stack: [UInt32: any MTLTexture] = [:]
    /// The effect being drawn, linear and premultiplied.
    private var layer: [UInt32: any MTLTexture] = [:]
    private var backdropScratch: [UInt32: any MTLTexture] = [:]
    /// The overlay of a preview, before it is put over the background (DECISIONS D24).
    private var previewOverlay: [UInt32: any MTLTexture] = [:]

    public init(device: any MTLDevice, effects types: [any Effect.Type]) throws {
        guard let queue = device.makeCommandQueue() else { throw NagiCoreError("no command queue") }
        self.device = device
        self.queue = queue
        let context = EffectContext(device: device, pixelFormat: Self.workingFormat)
        effects = try types.map { (descriptor: $0.descriptor, instance: try $0.init(context: context)) }
            .sorted { $0.descriptor.layer < $1.descriptor.layer }
        running = effects
        let library = try device.makeDefaultLibrary(bundle: Bundle.module)
        layerPipeline = try Self.pipeline(device, library, fragment: "layerFragment", sourceOver: true)
        backdropPipeline = try Self.pipeline(device, library, fragment: "stackOverBackdropFragment")
        outputPipeline = try Self.pipeline(device, library, fragment: "stackOutputFragment")
        blendPipeline = try Self.pipeline(device, library, fragment: "desktopBlendFragment")
    }

    /// The running instance of an effect type (for tests and the gallery).
    public func instance<E: Effect>(of type: E.Type) -> E? {
        effects.lazy.compactMap { $0.instance as? E }.first
    }

    /// The notes of effects `ids` for `frame` (Effect.note), with their parameters.
    public func notes(_ frame: FrameState, of ids: Set<String>) -> [LocalizedStringResource] {
        effects.filter { ids.contains($0.descriptor.id) }
            .compactMap { type(of: $0.instance).note(frame.with($0.descriptor, parameters)) }
    }

    /// Fills in what the running effects share (the rain they make), advances them, and returns
    /// the frame to draw with: `encode` must get this one.
    public func update(_ frame: FrameState) -> FrameState {
        var frame = frame
        frame.environment.precipitation = running.map {
            let value = type(of: $0.instance).precipitation(frame.with($0.descriptor, parameters))
            return value.isNaN ? 0 : min(max(value, 0), 1)
        }.max() ?? 0
        for effect in running { effect.instance.update(frame.with(effect.descriptor, parameters)) }
        return frame
    }

    /// Encodes one display's frame into `target` (the live drawable or an offscreen texture):
    /// premultiplied linear colour, scaled by `presence × strength`.
    public func encode(_ frame: FrameState, view: DisplayView, strength: Double = 1,
                       into target: any MTLTexture, commandBuffer: any MTLCommandBuffer) throws {
        let stack = try texture(&stack, for: view)
        let layer = try texture(&layer, for: view)
        Self.clear(stack, commandBuffer: commandBuffer)

        let gain = Float(frame.presence * strength)
        for effect in running {
            var effectView = view
            effectView.backdrop = nil
            if effect.descriptor.capabilities.contains(.backdrop), let backdrop = view.backdrop {
                let scratch = try texture(&backdropScratch, for: view)
                // Full strength here: the final pass applies presence × strength once to
                // everything, including what this effect copies from its backdrop.
                encodeFullscreen(backdropPipeline, textures: [backdrop, stack], gain: 1, into: scratch,
                                 commandBuffer: commandBuffer)
                effectView.backdrop = scratch
            }
            Self.clear(layer, commandBuffer: commandBuffer)
            let encoder = PassEncoder(commandBuffer: commandBuffer, output: layer)
            try effect.instance.render(frame.with(effect.descriptor, parameters), view: effectView, encoder: encoder)
            encodeFullscreen(layerPipeline, textures: [layer], gain: 1, into: stack, load: true,
                             commandBuffer: commandBuffer)
        }
        encodeFullscreen(outputPipeline, textures: [stack], gain: gain, into: target, commandBuffer: commandBuffer)
    }

    /// Puts a premultiplied linear overlay over an encoded Display P3 background the way
    /// WindowServer did in M0 (SPEC 3.5). The result is encoded Display P3.
    public func encodeDesktopBlend(background: any MTLTexture, overlay: any MTLTexture, gain: Float = 1,
                                   into target: any MTLTexture, commandBuffer: any MTLCommandBuffer) {
        encodeFullscreen(blendPipeline, textures: [background, overlay], gain: gain, into: target,
                         commandBuffer: commandBuffer)
    }

    /// What the screen would show: this frame's overlay over `background` (encoded Display P3,
    /// composited as WindowServer does), into `target`. nagi-render and the gallery both use it.
    /// Call `update` first.
    public func encodeScreen(_ frame: FrameState, view: DisplayView, strength: Double = 1,
                             background: any MTLTexture, into target: any MTLTexture,
                             commandBuffer: any MTLCommandBuffer) throws {
        let overlay = try texture(&previewOverlay, for: view)
        var view = view
        if view.backdrop == nil { view.backdrop = background }
        // The live path applies presence in `encode`; the blend must not apply it again.
        try encode(frame, view: view, strength: strength, into: overlay, commandBuffer: commandBuffer)
        encodeDesktopBlend(background: background, overlay: overlay, into: target, commandBuffer: commandBuffer)
    }

    /// Frees one display's textures (the display went away).
    public func forget(display: UInt32) {
        stack[display] = nil
        layer[display] = nil
        backdropScratch[display] = nil
        previewOverlay[display] = nil
    }

    /// Frees per-display textures and lets the effects free theirs (while nagi is not shown).
    public func releaseResources() {
        stack.removeAll()
        layer.removeAll()
        backdropScratch.removeAll()
        previewOverlay.removeAll()
        for effect in effects { effect.instance.releaseResources() }
    }

    public func makeTexture(size: SIMD2<Int>, format: MTLPixelFormat = workingFormat,
                            storage: MTLStorageMode = .private) throws -> any MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format, width: size.x, height: size.y, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead, .shaderWrite]
        descriptor.storageMode = storage
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw NagiCoreError("could not make a \(size.x)×\(size.y) texture")
        }
        return texture
    }

    private func texture(_ cache: inout [UInt32: any MTLTexture], for view: DisplayView) throws -> any MTLTexture {
        if let texture = cache[view.id], texture.width == view.pixelSize.x, texture.height == view.pixelSize.y {
            return texture
        }
        let texture = try makeTexture(size: view.pixelSize)
        cache[view.id] = texture
        return texture
    }

    private static func clear(_ texture: any MTLTexture, commandBuffer: any MTLCommandBuffer) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        commandBuffer.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
    }

    private func encodeFullscreen(_ pipeline: any MTLRenderPipelineState, textures: [any MTLTexture], gain: Float,
                                  into target: any MTLTexture, load: Bool = false,
                                  commandBuffer: any MTLCommandBuffer) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = load ? .load : .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(pipeline)
        for (index, texture) in textures.enumerated() { encoder.setFragmentTexture(texture, index: index) }
        var gain = gain
        encoder.setFragmentBytes(&gain, length: MemoryLayout<Float>.size, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    private static func pipeline(_ device: any MTLDevice, _ library: any MTLLibrary,
                                 fragment: String, sourceOver: Bool = false) throws -> any MTLRenderPipelineState {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "fullscreenVertex")
        descriptor.fragmentFunction = library.makeFunction(name: fragment)
        descriptor.colorAttachments[0].pixelFormat = workingFormat
        if sourceOver { descriptor.colorAttachments[0].usePremultipliedSourceOver() }
        return try device.makeRenderPipelineState(descriptor: descriptor)
    }
}

/// Lends an effect its passes for one display and frame.
private final class PassEncoder: EffectEncoder {
    let commandBuffer: any MTLCommandBuffer
    let output: any MTLTexture

    init(commandBuffer: any MTLCommandBuffer, output: any MTLTexture) {
        self.commandBuffer = commandBuffer
        self.output = output
    }

    var outputSize: SIMD2<Int> { SIMD2(output.width, output.height) }

    func renderToOutput(_ body: (any MTLRenderCommandEncoder) throws -> Void) rethrows {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = output
        pass.colorAttachments[0].loadAction = .load
        pass.colorAttachments[0].storeAction = .store
        try render(to: pass, body)
    }

    func render(to pass: MTLRenderPassDescriptor,
                _ body: (any MTLRenderCommandEncoder) throws -> Void) rethrows {
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        defer { encoder.endEncoding() }
        try body(encoder)
    }

    func compute(_ body: (any MTLComputeCommandEncoder) throws -> Void) rethrows {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        defer { encoder.endEncoding() }
        try body(encoder)
    }
}

public struct NagiCoreError: LocalizedError {
    public let errorDescription: String?
    public init(_ message: String) { errorDescription = message }
}

private extension FrameState {
    /// The frame as one effect sees it: its own parameters, defaults filled in.
    func with(_ descriptor: EffectDescriptor, _ saved: [String: [String: ParameterValue]]) -> FrameState {
        var frame = self
        var values = Dictionary(uniqueKeysWithValues: descriptor.parameters.map { ($0.key, $0.defaultValue) })
        values.merge(saved[descriptor.id] ?? [:]) { _, saved in saved }
        frame.parameters = values
        if !descriptor.capabilities.contains(.windows) { frame.windows = nil }
        return frame
    }
}
