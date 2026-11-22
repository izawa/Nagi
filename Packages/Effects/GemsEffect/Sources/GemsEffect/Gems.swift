import CoreGraphics
import Foundation
import Metal
import NagiKit

/// A string from this package's catalog (Resources/Localizable.xcstrings).
func localized(_ key: String.LocalizationValue) -> LocalizedStringResource {
    LocalizedStringResource(key, bundle: .atURL(Bundle.module.bundleURL))
}

/// Gems on the windows left still (M5-PLAN): small clusters of clear crystals, mostly quartz with
/// some pale aquamarine and topaz, grow on the top edge of a window that keeps its place. Each
/// crystal is a hexagonal prism seen side-on; each face shifts the screen behind it by its own
/// amount, so lines and letters break at the ridges, and one face may catch the sun.
/// One instanced quad per crystal; what windows in front cover is left out.
public final class Gems: Effect {
    public static let descriptor = EffectDescriptor(
        id: "gems",
        displayName: localized("宝石"),
        summary: localized("動かしていないウィンドウの縁に育つ水晶"),
        layer: .surface,
        capabilities: [.windows, .backdrop],
        parameters: [
            ParameterSpec(key: "amount", label: localized("生える量"), kind: .slider(range: 0.3...2, defaultValue: 1),
                          user: .slider(0.3...2)),
            ParameterSpec(key: "speed", label: localized("育つ速さ"), kind: .slider(range: 0.25...4, defaultValue: 1),
                          user: .steps([.init(label: localized("ゆっくり"), value: 0.5), .init(label: localized("ふつう"), value: 1),
                                        .init(label: localized("速い"), value: 2)])),
            // Tuned in the gallery (W1); not translated (DECISIONS D24).
            ParameterSpec(key: "height", label: "高さ", kind: .slider(range: 0.5...1.6, defaultValue: 1)),
            ParameterSpec(key: "refraction", label: "屈折の強さ", kind: .slider(range: 0...1, defaultValue: 0.35)),
            ParameterSpec(key: "ridge", label: "線の濃さ", kind: .slider(range: 0...1, defaultValue: 0.7)),
            ParameterSpec(key: "highlight", label: "照りの強さ", kind: .slider(range: 0...2, defaultValue: 1)),
            ParameterSpec(key: "dispersion", label: "分散", kind: .slider(range: 0...1, defaultValue: 0)),
            ParameterSpec(key: "glow", label: "グロー", kind: .slider(range: 0...2, defaultValue: 1)),
        ])

    /// Points around a crystal's quad for its glow, soft contact shadow and smooth edges.
    static let margin = Placement.halo
    /// Windows in front a crystal is tested against (a cluster meeting more is left out).
    static let frontCapacity = Placement.maxFronts

    /// One crystal for the shader, in the display's pixels.
    struct Instance {
        /// Root (x, y), axis pointing to the tip (x, y), all in pixels.
        var axis: SIMD4<Float>
        /// Length, width, spin (0 … 1), the number of front rectangles that follow.
        var shape: SIMD4<Float>
        /// The stone's body colour (linear), and how far the crystal has grown (0 … 1).
        var tint: SIMD4<Float>
        var fronts: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>,
                     SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>,
                     SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>,
                     SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)
    }

    struct Uniforms {
        /// Output size in pixels, pixels per point, 1 for the dark appearance.
        var target: SIMD4<Float>
        /// Toward the sun on the screen (x right, y down, z out of the screen), and its strength.
        var light: SIMD4<Float>
        /// Refraction, ridge, highlight, dispersion.
        var look: SIMD4<Float>
        /// The glow's strength, and the quad's margin in pixels (the glow is gone before it).
        var glow: SIMD4<Float>
    }

    /// The body colours (linear): clear quartz, pale green-blue aquamarine, pale clear blue topaz,
    /// pale pink morganite, pale green prasiolite.
    static func tint(_ stone: Stone) -> SIMD3<Float> {
        switch stone {
        case .quartz: SIMD3(0.97, 0.98, 1.0)
        case .aquamarine: SIMD3(0.78, 0.93, 0.94)
        case .topaz: SIMD3(0.80, 0.89, 1.0)
        case .morganite: SIMD3(0.98, 0.84, 0.88)
        case .prasiolite: SIMD3(0.86, 0.96, 0.84)
        }
    }

    /// Toward the sun in screen terms (screen up is north, as for komorebi), and how strongly it
    /// lights: none below 5°, full from 10° (as komorebi and the light under water).
    static func sunlight(_ sun: CelestialPosition) -> SIMD4<Float> {
        let altitude = sun.altitude, azimuth = sun.azimuth
        let t = min(max((altitude * 180 / .pi - 5) / 5, 0), 1)
        let strength = t * t * (3 - 2 * t)
        let flat = cos(altitude)
        return SIMD4(Float(sin(azimuth) * flat), Float(-cos(azimuth) * flat), Float(sin(altitude)), Float(strength))
    }

    static func bounded(_ value: Double, _ range: ClosedRange<Double>, default fallback: Double) -> Double {
        value.isFinite ? min(max(value, range.lowerBound), range.upperBound) : fallback
    }

    private let pipeline: any MTLRenderPipelineState
    private let device: any MTLDevice

    public init(context: EffectContext) throws {
        device = context.device
        let library = try context.device.makeDefaultLibrary(bundle: Bundle.module)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "gemVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "gemFragment")
        descriptor.colorAttachments[0].pixelFormat = context.pixelFormat
        descriptor.colorAttachments[0].usePremultipliedSourceOver()
        pipeline = try context.device.makeRenderPipelineState(descriptor: descriptor)
    }

    /// The clusters for the last window snapshot, speed and height: placement is redone only when
    /// those change (the window list comes about five times a second), not per display and frame.
    private var placed: (snapshot: WindowSnapshot, speed: Double, height: Double, amount: Double, clusters: [Cluster])?

    func clusters(_ snapshot: WindowSnapshot, speed: Double, height: Double, amount: Double) -> [Cluster] {
        if let placed, placed.snapshot == snapshot, placed.speed == speed, placed.height == height, placed.amount == amount {
            return placed.clusters
        }
        let clusters = Placement.clusters(snapshot, speed: speed, heightScale: height, amount: amount)
        placed = (snapshot, speed, height, amount, clusters)
        return clusters
    }

    public func update(_ frame: FrameState) {}

    public func render(_ frame: FrameState, view: DisplayView, encoder: any EffectEncoder) throws {
        // Without the screen behind (no capture yet, or no permission) there is nothing to bend.
        guard let backdrop = view.backdrop, let snapshot = frame.windows else { return }
        let origin = view.frameInDesktop.origin, scale = view.scale
        func pixels(_ p: CGPoint) -> SIMD2<Float> {
            SIMD2(Float((p.x - origin.x) * scale), Float((p.y - origin.y) * scale))
        }
        func pixels(_ rect: CGRect) -> SIMD4<Float> {
            SIMD4(Float(rect.minX - origin.x), Float(rect.minY - origin.y),
                  Float(rect.maxX - origin.x), Float(rect.maxY - origin.y)) * Float(scale)
        }
        let speed = Self.bounded(frame.number("speed", default: 1), 0.25...4, default: 1)
        let height = Self.bounded(frame.number("height", default: 1), 0.5...1.6, default: 1)
        let amount = Self.bounded(frame.number("amount", default: 1), 0.3...2, default: 1)
        // Back to front: the windows behind first.
        let clusters = clusters(snapshot, speed: speed, height: height, amount: amount).reversed()
            .filter { $0.bounds.insetBy(dx: -Self.margin, dy: -Self.margin).intersects(view.frameInDesktop) }
        var instances: [Instance] = []
        for cluster in clusters {
            var fronts = [SIMD4<Float>](repeating: .zero, count: Self.frontCapacity)
            for (slot, rect) in cluster.fronts.prefix(Self.frontCapacity).enumerated() { fronts[slot] = pixels(rect) }
            // The larger crystals behind, the small ones at the base in front.
            for crystal in cluster.crystals.sorted(by: { $0.fullLength > $1.fullLength }) {
                let axis = SIMD2(Float(sin(crystal.angle)), Float(-cos(crystal.angle)))
                instances.append(Instance(
                    axis: SIMD4(lowHalf: pixels(crystal.root), highHalf: axis),
                    shape: SIMD4(Float(crystal.length * scale), Float(crystal.width * scale * crystal.length / crystal.fullLength),
                                 Float(crystal.spin), Float(min(cluster.fronts.count, Self.frontCapacity))),
                    tint: SIMD4(Self.tint(crystal.stone), Float(crystal.length / crystal.fullLength)),
                    fronts: (fronts[0], fronts[1], fronts[2], fronts[3], fronts[4], fronts[5], fronts[6], fronts[7],
                             fronts[8], fronts[9], fronts[10], fronts[11], fronts[12], fronts[13], fronts[14], fronts[15])))
            }
        }
        guard !instances.isEmpty,
              let buffer = device.makeBuffer(bytes: &instances, length: MemoryLayout<Instance>.stride * instances.count,
                                             options: .storageModeShared) else { return }
        var uniforms = Uniforms(
            target: SIMD4(Float(encoder.outputSize.x), Float(encoder.outputSize.y), Float(scale),
                          frame.appearance == .dark ? 1 : 0),
            light: Self.sunlight(frame.environment.sun),
            look: SIMD4(Float(Self.bounded(frame.number("refraction", default: 0.35), 0...1, default: 0.35)),
                        Float(Self.bounded(frame.number("ridge", default: 0.7), 0...1, default: 0.7)),
                        Float(Self.bounded(frame.number("highlight", default: 1), 0...2, default: 1)),
                        Float(Self.bounded(frame.number("dispersion", default: 0), 0...1, default: 0))),
            glow: SIMD4(Float(Self.bounded(frame.number("glow", default: 1), 0...2, default: 1)),
                        Float(Self.margin * scale), 0, 0))
        var margin = Float(Self.margin * scale)
        encoder.renderToOutput { pass in
            pass.setRenderPipelineState(pipeline)
            pass.setVertexBuffer(buffer, offset: 0, index: 0)
            pass.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            pass.setVertexBytes(&margin, length: MemoryLayout<Float>.size, index: 2)
            pass.setFragmentBuffer(buffer, offset: 0, index: 0)
            pass.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            pass.setFragmentTexture(backdrop, index: 0)
            pass.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: instances.count)
        }
    }

    public func releaseResources() { placed = nil }
}
