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
/// left beside komorebi (M2-LOG stage A). The drops live in a simulation on the CPU (RainSimulation).
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
    /// lobe's offset and radius in pixels (radius 0: no lobe). The first lobe's last value is the
    /// drop's speed in points per second; the second's, how fast it went over the last step
    /// (RainSimulation.pace), for the motion blur.
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
        /// The output's size in pixels, pixels per point, and the frame's length in seconds.
        var target: SIMD4<Float>
    }

    /// A piece of wet trail, for the shader: its two ends in pixels, then its half-width in
    /// pixels and how much of it is left (1 … 0).
    struct TrailInstance {
        var ends: SIMD4<Float>
        var look: SIMD4<Float>
    }

    private let pipeline: any MTLRenderPipelineState
    private let trailPipeline: any MTLRenderPipelineState
    private let device: any MTLDevice
    private var simulation: RainSimulation?
    /// The frame time the simulation was last moved to: it follows the scene's clock, so a paused
    /// gallery stays still and a clock set back starts over.
    private var simulatedTime: Double?
    /// What a running simulation was started for: a change starts a new one.
    private var world: World?
    /// Counts updates, so each display's instances are written once per frame.
    private var generation = 0
    /// Per display and kind (drops, trails), a few instance buffers used in turn.
    private var buffers: [InstanceRing.Key: InstanceRing] = [:]

    /// What the glass is started from: when one of these changes, it starts over (the drops on
    /// it would not match), rather than drifting towards the new values.
    private struct World: Equatable {
        var displays: [CGRect]
        var size: Double
        var intensity: Double
        var fewer: Bool
        var seed: UInt64
    }
    /// The depth last simulated: a jump (a preview's slider) starts over too.
    private var simulatedDepth = 0.0

    /// A parameter within its declared range; the default when it is not a finite number.
    static func bounded(_ value: Double, key: String) -> Double {
        guard let spec = descriptor.parameters.first(where: { $0.key == key }),
              case let .slider(range, defaultValue) = spec.kind else { return value }
        return value.isFinite ? min(max(value, range.lowerBound), range.upperBound) : defaultValue
    }

    public init(context: EffectContext) throws {
        device = context.device
        let library = try context.device.makeDefaultLibrary(bundle: Bundle.module)
        func make(_ vertex: String, _ fragment: String) throws -> any MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: vertex)
            descriptor.fragmentFunction = library.makeFunction(name: fragment)
            descriptor.colorAttachments[0].pixelFormat = context.pixelFormat
            descriptor.colorAttachments[0].usePremultipliedSourceOver()
            return try context.device.makeRenderPipelineState(descriptor: descriptor)
        }
        pipeline = try make("dropVertex", "dropFragment")
        trailPipeline = try make("trailVertex", "trailFragment")
    }

    /// How hard it rains: the share of the glass drops cover, against a downpour's (D32). The
    /// same curve the drops follow, so the wet comes with the rain, not with counting drops.
    public static func precipitation(_ frame: FrameState) -> Double {
        let intensity = bounded(frame.number("intensity", default: 1), key: "intensity")
        let depth = frame.depth.isFinite ? min(max(frame.depth, 0), 600) : 0
        return Drops.coverage(depth: depth, intensity: intensity) / Drops.maximumCoverage
    }

    public func update(_ frame: FrameState) {
        // Within the declared ranges (nagi-render passes --param values as they are).
        let intensity = Self.bounded(frame.number("intensity", default: 1), key: "intensity")
        let size = Self.bounded(frame.number("size", default: 1), key: "size")
        let depth = frame.depth.isFinite ? min(max(frame.depth, 0), 600) : 0
        // The wind's sideways push, a little: metres per second to points per second.
        let drift = frame.environment.wind.velocity.x * 6
        let settings = RainSimulation.Settings(depth: depth, intensity: intensity, size: size,
                                               fewer: frame.accessibility.reduceStrength,
                                               arriving: frame.phase != .leaving, drift: drift.isFinite ? drift : 0)
        // A new showing, other displays, another drop size, or the clock set back: start over.
        let world = World(displays: frame.displays, size: size, intensity: intensity,
                          fewer: frame.accessibility.reduceStrength, seed: frame.seed &+ UInt64(frame.showing))
        // The rain runs on the wind's clock: monotonic, and slowed for Reduce Motion in the
        // live overlay and the previews alike (SPEC 2.2).
        let clock = frame.environment.wind.time
        let elapsed = simulatedTime.map { clock - $0 } ?? -1
        // A depth that jumps, or changes while the clock stands still (a paused preview's slider).
        let seek = abs(depth - simulatedDepth) > max(2 * elapsed, 2) + 1 || (elapsed == 0 && depth != simulatedDepth)
        if world != self.world || simulation == nil || elapsed < 0 || seek {
            self.world = world
            simulation = RainSimulation(displays: world.displays, settings: settings, seed: world.seed)
        } else {
            simulation?.advance(by: elapsed, settings)
        }
        simulatedTime = clock
        simulatedDepth = depth
        generation += 1
    }

    public func render(_ frame: FrameState, view: DisplayView, encoder: any EffectEncoder) throws {
        // Without the screen behind (no capture yet, or no permission) a drop has nothing to bend.
        guard let backdrop = view.backdrop else { return }
        var uniforms = Self.uniforms(frame)
        // The frame's length, for the motion blur of running drops (1/60 s when unknown).
        let frameTime = frame.deltaTime > 0 && frame.deltaTime < 0.1 ? frame.deltaTime : 1.0 / 60
        uniforms.target = SIMD4(Float(encoder.outputSize.x), Float(encoder.outputSize.y), Float(view.scale), Float(frameTime))
        let trails = write(trailInstances(for: view), view: view, kind: .trails)
        let drops = write(dropInstances(for: view), view: view, kind: .drops)
        guard trails != nil || drops != nil else { return }
        encoder.renderToOutput { pass in
            pass.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            pass.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            pass.setFragmentTexture(backdrop, index: 0)
            // The trails first: a drop sits on the wet path it left.
            for (layer, state) in [(trails, trailPipeline), (drops, pipeline)] {
                guard let (buffer, count) = layer else { continue }
                pass.setRenderPipelineState(state)
                pass.setVertexBuffer(buffer, offset: 0, index: 0)
                pass.setFragmentBuffer(buffer, offset: 0, index: 0)
                pass.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: count)
            }
        }
    }

    /// The drops whose quad (with its shadow) reaches `view`, in its pixels. Built every frame for
    /// thousands of drops, so without temporary arrays.
    private func dropInstances(for view: DisplayView) -> [Instance] {
        let frame = view.frameInDesktop
        let origin = SIMD2(Double(frame.minX), Double(frame.minY))
        let scale = view.scale
        guard let simulation else { return [] }
        var instances: [Instance] = []
        instances.reserveCapacity(simulation.field.slots.count)
        simulation.forEachDrop { drop in
            // A running drop is drawn up to 1.8 times as long, and blurred over a frame's travel.
            let pace = simulation.pace(of: drop)
            let extent = drop.reach * 1.6 * 1.8 + pace * 0.1
            guard drop.center.x + extent >= frame.minX, drop.center.x - extent <= frame.maxX,
                  drop.center.y + extent >= frame.minY, drop.center.y - extent <= frame.maxY else { return }
            func lobe(_ i: Int) -> SIMD4<Float> {
                guard i < drop.lobes.count else { return .zero }
                let l = drop.lobes[i]
                return SIMD4(Float(l.offset.x * scale), Float(l.offset.y * scale), Float(l.radius * scale), 0)
            }
            var first = lobe(0), second = lobe(1)
            first.w = Float(drop.speed)
            second.w = Float(pace)
            let center = (drop.center - origin) * scale
            instances.append(Instance(geometry: SIMD4(Float(center.x), Float(center.y), Float(drop.reach * scale), Float(drop.shape)),
                                      lobes: (first, second, lobe(2), lobe(3))))
        }
        return instances
    }

    /// The trail pieces that reach `view`, in its pixels.
    private func trailInstances(for view: DisplayView) -> [TrailInstance] {
        let origin = SIMD2(Double(view.frameInDesktop.minX), Double(view.frameInDesktop.minY))
        // Each piece's band, with the width it is drawn at, against the view.
        return (simulation?.trailPieces ?? []).filter { piece in
            let margin = piece.halfWidth * 1.6
            let band = CGRect(x: min(piece.from.x, piece.to.x) - margin, y: min(piece.from.y, piece.to.y) - margin,
                              width: abs(piece.to.x - piece.from.x) + 2 * margin,
                              height: abs(piece.to.y - piece.from.y) + 2 * margin)
            return view.frameInDesktop.intersects(band)
        }.map { piece in
            let a = (piece.from - origin) * view.scale, b = (piece.to - origin) * view.scale
            return TrailInstance(ends: SIMD4(Float(a.x), Float(a.y), Float(b.x), Float(b.y)),
                                 look: SIMD4(Float(piece.halfWidth * view.scale), Float(piece.left), 0, 0))
        }
    }

    /// Writes this frame's instances for `view` into its ring (once per frame: a second draw of
    /// the same frame reuses them). Nil when there are none.
    private func write<T>(_ items: @autoclosure () -> [T], view: DisplayView,
                          kind: InstanceRing.Kind) -> (buffer: any MTLBuffer, count: Int)? {
        let key = InstanceRing.Key(display: view.id, kind: kind)
        var ring = buffers[key] ?? InstanceRing()
        defer { buffers[key] = ring }
        return ring.write(items, generation: generation, device: device)
    }

    /// The drops go with the showing; the buffers are rebuilt on the next one.
    public func releaseResources() {
        buffers.removeAll()
        simulation = nil
        world = nil
        simulatedTime = nil
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

/// A few instance buffers used in turn, so the GPU can still read one frame's while the next is
/// written (frames in flight).
struct InstanceRing {
    enum Kind: Hashable { case drops, trails }
    struct Key: Hashable {
        var display: UInt32
        var kind: Kind
    }

    static let framesInFlight = 3
    private var ring: [any MTLBuffer] = []
    private var next = framesInFlight - 1
    private var written = -1
    private var count = 0

    mutating func write<T>(_ items: () -> [T], generation: Int, device: any MTLDevice) -> (buffer: any MTLBuffer, count: Int)? {
        if written == generation { return count > 0 && next < ring.count ? (ring[next], count) : nil }
        let items = items()
        guard !items.isEmpty else {
            (written, count) = (generation, 0)
            return nil
        }
        // The next slot, made ready before anything says it holds this frame.
        let slot = (next + 1) % Self.framesInFlight
        let length = MemoryLayout<T>.stride * items.count
        if slot >= ring.count || ring[slot].length < length {
            // Room for half as many again, so a growing rain does not reallocate every frame.
            guard slot <= ring.count,
                  let buffer = device.makeBuffer(length: length * 3 / 2, options: .storageModeShared) else { return nil }
            if slot < ring.count { ring[slot] = buffer } else { ring.append(buffer) }
        }
        items.withUnsafeBytes { ring[slot].contents().copyMemory(from: $0.baseAddress!, byteCount: length) }
        (next, written, count) = (slot, generation, items.count)
        return (ring[slot], count)
    }
}
