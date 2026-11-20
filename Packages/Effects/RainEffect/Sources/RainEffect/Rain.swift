import CoreGraphics
import Foundation
import Metal
import NagiKit

/// A string from this package's catalog (Resources/Localizable.xcstrings).
func localized(_ key: String.LocalizationValue) -> LocalizedStringResource {
    LocalizedStringResource(key, bundle: .atURL(Bundle.module.bundleURL))
}

/// Rain on the glass of the display (SPEC 4.2): drops bend the screen behind them like small
/// lenses held close to it, so the work stays upright, a little magnified, and bends hard at the
/// rim. Each drop is drawn only where it is (an instanced quad), to keep within the frame budget
/// left beside komorebi (M2-LOG stage A).
public final class Rain: Effect {
    public static let descriptor = EffectDescriptor(
        id: "rain",
        displayName: localized("雨"),
        summary: localized("ガラスにつく雨粒"),
        layer: .glass,
        capabilities: [.backdrop],
        parameters: [
            ParameterSpec(key: "intensity", label: localized("雨の強さ"), kind: .slider(range: 0.2...1.5, defaultValue: 1),
                          user: .slider(0.5...1.2)),
            ParameterSpec(key: "size", label: localized("粒の大きさ"), kind: .slider(range: 0.5...2, defaultValue: 1),
                          user: .slider(0.8...1.3)),
            ParameterSpec(key: "refraction", label: localized("屈折の強さ"), kind: .slider(range: 0...1.5, defaultValue: 1),
                          user: .slider(0.6...1.2)),
            // The author's tuning (the gallery): the dark rim, the sky's reflection, the highlight.
            ParameterSpec(key: "rim", label: "縁の暗さ", kind: .slider(range: 0...1, defaultValue: 0.45)),
            ParameterSpec(key: "fresnel", label: "空の映り込み", kind: .slider(range: 0...1, defaultValue: 0.35)),
            ParameterSpec(key: "highlight", label: "ハイライト", kind: .slider(range: 0...2, defaultValue: 1)),
            ParameterSpec(key: "shadow", label: "粒の影", kind: .slider(range: 0...0.5, defaultValue: 0.18)),
        ],
        weatherHint: WeatherHint(cloudBias: 0.4))

    /// Per drop, for the shader: centre and reach in pixels, and the outline's seed; then each
    /// lobe's offset and radius in pixels (radius 0: no lobe).
    struct Instance {
        var geometry: SIMD4<Float>
        var lobes: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)
    }

    struct Uniforms {
        /// Towards the light on the screen (y down), and its strength (0 at night).
        var light: SIMD4<Float>
        /// rim, fresnel, highlight, shadow
        var look: SIMD4<Float>
        /// refraction, presence, appearance (0 light, 1 dark), sky brightness
        var misc: SIMD4<Float>
        /// The output's size in pixels.
        var target: SIMD4<Float>
    }

    private let pipeline: any MTLRenderPipelineState
    private let device: any MTLDevice
    private var drops: [Drop] = []
    private var key: DropKey?
    /// Each display's drops as GPU instances, kept until the drops or the display change; a draw
    /// in flight keeps the buffer it was given.
    private var buffers: [UInt32: (view: DisplayView.Geometry, key: DropKey, buffer: any MTLBuffer)] = [:]

    private struct DropKey: Equatable {
        var displays: [CGRect]
        /// Whole seconds up to the downpour: drops change at most once a second, and not after.
        var depthStep: Int
        var intensity: Double
        var size: Double
        var seed: UInt64
        var fewer: Bool
    }

    /// A parameter within its declared range; the default when it is not a finite number.
    static func bounded(_ value: Double, key: String) -> Double {
        guard let spec = descriptor.parameters.first(where: { $0.key == key }),
              case let .slider(range, defaultValue) = spec.kind else { return value }
        return value.isFinite ? min(max(value, range.lowerBound), range.upperBound) : defaultValue
    }

    public init(context: EffectContext) throws {
        device = context.device
        let library = try context.device.makeDefaultLibrary(bundle: Bundle.module)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "dropVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "dropFragment")
        descriptor.colorAttachments[0].pixelFormat = context.pixelFormat
        descriptor.colorAttachments[0].usePremultipliedSourceOver()
        pipeline = try context.device.makeRenderPipelineState(descriptor: descriptor)
    }

    public func update(_ frame: FrameState) {
        // Within the declared ranges (nagi-render passes --param values as they are).
        let intensity = Self.bounded(frame.number("intensity", default: 1), key: "intensity")
        let size = Self.bounded(frame.number("size", default: 1), key: "size")
        let fewer = frame.accessibility.reduceStrength
        // Still drops (stage B): placed again only when what they depend on changes.
        let depth = frame.depth.isFinite ? min(max(frame.depth, 0), 120) : 0
        let key = DropKey(displays: frame.displays, depthStep: Int(depth), intensity: intensity, size: size,
                          seed: frame.seed &+ UInt64(frame.showing), fewer: fewer)
        guard key != self.key else { return }
        self.key = key
        drops = Drops.scatter(displays: key.displays, depth: Double(key.depthStep), intensity: intensity, size: size,
                              seed: key.seed)
        // Increase Contrast or Reduce Transparency: half the drops (SPEC 2.2), even when the
        // count, not the coverage, limited them.
        if fewer { drops = drops.enumerated().filter { $0.offset % 2 == 0 }.map(\.element) }
    }

    public func render(_ frame: FrameState, view: DisplayView, encoder: any EffectEncoder) throws {
        // Without the screen behind (no capture yet, or no permission) a drop has nothing to bend.
        guard let backdrop = view.backdrop, let key, let buffer = instances(for: view, key: key) else { return }
        let count = buffer.length / MemoryLayout<Instance>.stride
        var uniforms = Self.uniforms(frame)
        uniforms.target = SIMD4(Float(encoder.outputSize.x), Float(encoder.outputSize.y), 0, 0)
        encoder.renderToOutput { pass in
            pass.setRenderPipelineState(pipeline)
            pass.setVertexBuffer(buffer, offset: 0, index: 0)
            pass.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            pass.setFragmentBuffer(buffer, offset: 0, index: 0)
            pass.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            pass.setFragmentTexture(backdrop, index: 0)
            pass.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: count)
        }
    }

    /// The drops on `view`, in its pixels, as a buffer (nil when none fall on it).
    private func instances(for view: DisplayView, key: DropKey) -> (any MTLBuffer)? {
        let geometry = view.geometry
        if let cached = buffers[view.id], cached.view == geometry, cached.key == key { return cached.buffer }
        let near = view.frameInDesktop.insetBy(dx: -40, dy: -40)
        let origin = SIMD2(Double(view.frameInDesktop.minX), Double(view.frameInDesktop.minY))
        let instances = drops.filter { near.contains(CGPoint(x: $0.center.x, y: $0.center.y)) }.map { drop in
            let center = (drop.center - origin) * view.scale
            var lobes = drop.lobes.map { SIMD4(Float($0.offset.x * view.scale), Float($0.offset.y * view.scale),
                                               Float($0.radius * view.scale), 0) }
            lobes += Array(repeating: SIMD4<Float>.zero, count: Drop.maxLobes - lobes.count)
            return Instance(geometry: SIMD4(Float(center.x), Float(center.y), Float(drop.reach * view.scale), Float(drop.shape)),
                            lobes: (lobes[0], lobes[1], lobes[2], lobes[3]))
        }
        guard !instances.isEmpty,
              let buffer = device.makeBuffer(bytes: instances, length: MemoryLayout<Instance>.stride * instances.count,
                                             options: .storageModeShared) else {
            buffers[view.id] = nil
            return nil
        }
        buffers[view.id] = (geometry, key, buffer)
        return buffer
    }

    public func releaseResources() {
        buffers.removeAll()
    }

    static func uniforms(_ frame: FrameState) -> Uniforms {
        let environment = frame.environment
        // The screen is the ground seen from above: north up, east right (komorebi's convention).
        // By day the light comes from the sun's side; at night from above, faintly (the room).
        let day = min(max(environment.sun.altitude / 0.2, 0), 1) * (1 - environment.sunOcclusion * 0.7)
        let azimuth = day > 0 ? environment.sun.azimuth : 0
        let light = SIMD4<Float>(Float(sin(azimuth)), Float(-cos(azimuth)), Float(0.35 + 0.65 * day), 0)
        let look = SIMD4<Float>(Float(frame.number("rim", default: 0.45)), Float(frame.number("fresnel", default: 0.35)),
                                Float(frame.number("highlight", default: 1)), Float(frame.number("shadow", default: 0.18)))
        let misc = SIMD4<Float>(Float(frame.number("refraction", default: 1)), Float(frame.presence),
                                frame.appearance == .dark ? 1 : 0, Float(0.4 + 0.6 * day))
        return Uniforms(light: light, look: look, misc: misc, target: .zero)
    }
}

extension DisplayView {
    /// Where the display is and how dense: what places drops on it.
    struct Geometry: Equatable {
        var frame: CGRect
        var scale: Double
    }

    var geometry: Geometry { Geometry(frame: frameInDesktop, scale: scale) }
}
