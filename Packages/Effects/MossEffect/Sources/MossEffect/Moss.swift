import CoreGraphics
import Foundation
import Metal
import NagiKit

/// A string from this package's catalog (Resources/Localizable.xcstrings).
func localized(_ key: String.LocalizationValue) -> LocalizedStringResource {
    LocalizedStringResource(key, bundle: .atURL(Bundle.module.bundleURL))
}

/// Moss on the windows left still (SPEC 4.3): along the top edge and the upper corners of each
/// window, and in the screen's bottom corners, growing from 10 minutes to 2 hours. Each patch is
/// drawn only where it is (an instanced quad); what windows in front cover is left out.
/// Moss grows in colonies that spread sideways from where they start, each one of three mosses
/// (M3-LOG stage B0); the shader works all of it out from the window's id and age.
public final class Moss: Effect {
    public static let descriptor = EffectDescriptor(
        id: "moss",
        displayName: localized("苔"),
        summary: localized("動かしていないウィンドウの縁に生える苔"),
        layer: .surface,
        capabilities: [.windows],
        parameters: [
            ParameterSpec(key: "speed", label: localized("生える速さ"), kind: .slider(range: 0.25...4, defaultValue: 1),
                          user: .steps([.init(label: localized("ゆっくり"), value: 0.5), .init(label: localized("ふつう"), value: 1),
                                        .init(label: localized("速い"), value: 2)])),
            ParameterSpec(key: "spread", label: localized("広がりの上限"), kind: .slider(range: 0.5...1, defaultValue: 1),
                          user: .slider(0.6...1)),
        ])

    /// Points: how far moss reaches out from an edge and in over a window (SPEC 4.3), the window's
    /// assumed corner radius (checkpoint H), and how far down the sides the upper corners wrap.
    static let outward = 20.0
    static let inward = 8.0
    static let cornerRadius = 16.0
    static let wrap = 28.0
    /// The screen's corners: how far moss spreads along the bottom and up the side.
    /// Points a window's top must leave below the top of its display's usable area (under the menu
    /// bar) for moss to grow on it: closer, the cushions would be cut off and look half grown
    /// (the author at stop K).
    static let headroom = 14.0
    /// Windows in front a patch is tested against; more are left out (16 windows over one band).
    static let frontCapacity = 16

    /// One patch for the shader, in the display's pixels: the quad to draw, the window it grows
    /// from, then seed, growth, (unused) and the number of front rectangles that follow, and the age.
    struct Instance {
        var quad: SIMD4<Float>
        var base: SIMD4<Float>
        var info: SIMD4<Float>
        /// The window's age in seconds at the chosen speed (sporophytes come with age past full
        /// growth), and the wind's lean on the sporophytes here (−1…1).
        var extra: SIMD4<Float>
        var fronts: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>,
                     SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>,
                     SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>,
                     SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)
    }

    struct Uniforms {
        var scale: Float
        var cornerRadius: Float
        var inward: Float
        var precipitation: Float
        var depth: Float
        /// How far moss reaches, as a share of the most (the setting).
        var spread: Float
        /// 0 … 1 while nagi leaves: the colour drains to a dull grey-green.
        var fade: Float
        /// 0 … 1: dew on the leaf tips on a still morning.
        var dew: Float
        /// Seconds, for the dew's slow twinkle.
        var time: Float
    }

    /// Where moss may grow, in desktop points: a band along a window's top, with the rectangles in
    /// front that cover it. Not in the screen's bottom corners: above the Dock it seemed to float
    /// (the author at stop K).
    struct Patch: Equatable {
        var quad: CGRect
        var base: CGRect
        var seed: UInt32
        var age: Double
        var fronts: [CGRect]
    }

    /// Growth after the first two hours, 0 … 1 by four: colonies keep spreading to half as far
    /// again, and thicken a little (the author at stop K).
    static func lateGrowth(age: Double) -> Double {
        guard age.isFinite else { return age > 0 ? 1 : 0 }
        let t = min(max((age - 7200) / 7200, 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// Growth from 10 minutes to 2 hours (SPEC 4.3, M3-PLAN 5.1).
    static func growth(age: Double) -> Double {
        guard age.isFinite else { return age > 0 ? 1 : 0 }
        let t = min(max((age - 600) / (7200 - 600), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// The patches seen in `snapshot`: one per ordinary window whose band is not wholly covered,
    /// and the bottom corners of each display's usable area.
    static func patches(_ snapshot: WindowSnapshot) -> [Patch] {
        // A window over a whole display (full screen) has square corners; the shader rounds every
        // window, so such a window grows by enough for its rounded shape to cover its corners.
        let square = cornerRadius * (2.squareRoot() - 1) + 0.5
        let covers = snapshot.frontToBack.map { window in
            snapshot.usableAreas.contains { window.frame.contains($0) }
                ? window.frame.insetBy(dx: -square, dy: -square) : window.frame
        }
        let windows = snapshot.frontToBack
        func fronts(of quad: CGRect, before index: Int) -> [CGRect] {
            covers.prefix(index).filter { $0.intersects(quad) }
        }
        var patches: [Patch] = []
        for (index, window) in windows.enumerated() where window.role == .surface {
            let f = window.frame
            // The display the window is mostly on.
            let area = snapshot.usableAreas.max { a, b in
                let x = a.intersection(f), y = b.intersection(f)
                return x.width * x.height < y.width * y.height
            }
            if let area, area.intersects(f), f.minY - area.minY < headroom { continue }
            let quad = CGRect(x: f.minX - outward, y: f.minY - outward, width: f.width + 2 * outward,
                              height: outward + wrap)
            let covering = fronts(of: quad, before: index)
            if covering.contains(where: { Self.roundedContains($0, quad) }) { continue }
            patches.append(Patch(quad: quad, base: f, seed: window.id, age: window.stationarySeconds, fronts: covering))
        }
        return patches
    }

    /// Whether a window, with the corner radius the shader gives it, covers all of `rect`: its
    /// four corners inside the rounded rectangle (it is convex).
    static func roundedContains(_ window: CGRect, _ rect: CGRect) -> Bool {
        let r = cornerRadius
        func inside(_ p: CGPoint) -> Bool {
            let cx = min(max(p.x, window.minX + r), window.maxX - r), cy = min(max(p.y, window.minY + r), window.maxY - r)
            return window.contains(p) && hypot(p.x - cx, p.y - cy) <= r
        }
        return [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)].allSatisfy(inside)
    }

    static func bounded(_ value: Double, _ range: ClosedRange<Double>) -> Double {
        value.isFinite ? min(max(value, range.lowerBound), range.upperBound) : 1
    }

    /// The dew's slow twinkle (Moss.metal: `sin(time × 0.42)`), seconds.
    static let twinklePeriod = 2 * Double.pi / 0.42

    /// Millimetres per desktop point for where a gust is: one scale for the whole desktop, so a
    /// window across two displays leans the same on both (a 5K 27-inch display's).
    static let millimetresPerPoint = 25.4 / 218 * 2

    /// How much the shared wind leans the sporophytes of a patch (−1…1): the mean wind and the
    /// gust at the patch's middle, in the gust front's direction (D19).
    static func lean(_ wind: Wind, at quad: CGRect) -> Double {
        let middle = SIMD2(Double(quad.midX), Double(quad.midY)) * millimetresPerPoint
        let push = wind.velocity.x * 0.08 + wind.gust(at: middle) * 0.6 * wind.frontDirection.x
        return push.isFinite ? min(max(push, -1), 1) : 0
    }

    /// Dew on a still morning (M3-PLAN 5.3): the sun low in the east, up to about 20° high; less
    /// under rain; it comes as nagi deepens.
    static func dew(sun: CelestialPosition, depth: Double, precipitation: Double) -> Double {
        func smooth(_ a: Double, _ b: Double, _ x: Double) -> Double {
            let t = min(max((x - a) / (b - a), 0), 1)
            return t * t * (3 - 2 * t)
        }
        let degrees = sun.altitude * 180 / .pi
        // East of the meridian, fading to none as the sun reaches it (low winter suns stay low).
        let morning = sun.azimuth > 0 && sun.azimuth < .pi ? sin(sun.azimuth) : 0
        return smooth(0, 4, degrees) * (1 - smooth(14, 22, degrees)) * morning * smooth(30, 120, depth)
            * (1 - 0.8 * min(max(precipitation, 0), 1))
    }

    private let pipeline: any MTLRenderPipelineState
    private let device: any MTLDevice

    public init(context: EffectContext) throws {
        device = context.device
        let library = try context.device.makeDefaultLibrary(bundle: Bundle.module)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "mossVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "mossFragment")
        descriptor.colorAttachments[0].pixelFormat = context.pixelFormat
        descriptor.colorAttachments[0].usePremultipliedSourceOver()
        pipeline = try context.device.makeRenderPipelineState(descriptor: descriptor)
    }

    /// The presence when nagi began to leave: the colour drains from what was on screen then, even
    /// if the entry had not finished.
    private var leavingFrom: Double?

    public func update(_ frame: FrameState) {
        if frame.phase == .leaving {
            if leavingFrom == nil { leavingFrom = max(frame.presence, 1e-3) }
        } else {
            leavingFrom = nil
        }
    }

    /// 0 … 1 over the leaving: how far the colour has drained.
    private func fade(_ frame: FrameState) -> Double {
        guard frame.phase == .leaving, let from = leavingFrom else { return 0 }
        return 1 - min(max(frame.presence / from, 0), 1)
    }

    public func render(_ frame: FrameState, view: DisplayView, encoder: any EffectEncoder) throws {
        guard let snapshot = frame.windows else { return }
        let origin = view.frameInDesktop.origin, scale = view.scale
        func pixels(_ rect: CGRect) -> SIMD4<Float> {
            SIMD4(Float(rect.minX - origin.x), Float(rect.minY - origin.y),
                  Float(rect.maxX - origin.x), Float(rect.maxY - origin.y)) * Float(scale)
        }
        // Back to front, so where two windows' moss meet outside both, the front one's lies on top.
        let speed = Self.bounded(frame.number("speed", default: 1), 0.25...4)
        let visible = Self.patches(snapshot).reversed().filter {
            $0.quad.intersects(view.frameInDesktop) && Self.growth(age: $0.age * speed) > 0
        }
        let wind = frame.accessibility.reduceMotion ? nil : frame.environment.wind
        guard !visible.isEmpty else { return }
        var instances = visible.map { patch -> Instance in
            var fronts = [SIMD4<Float>](repeating: .zero, count: Self.frontCapacity)
            for (slot, rect) in patch.fronts.prefix(Self.frontCapacity).enumerated() { fronts[slot] = pixels(rect) }
            let age = patch.age * speed
            return Instance(quad: pixels(patch.quad), base: pixels(patch.base),
                            info: SIMD4(Float(patch.seed % 65536), Float(Self.growth(age: age)),
                                        0, Float(min(patch.fronts.count, Self.frontCapacity))),
                            extra: SIMD4(Float(age.isFinite ? min(age, 1e7) : 0),
                                         // Along the edge: the bottom-right corner runs right to left.
                                         Float(wind.map { Self.lean($0, at: patch.quad) } ?? 0),
                                         Float(Self.lateGrowth(age: age)), 0),
                            fronts: (fronts[0], fronts[1], fronts[2], fronts[3], fronts[4], fronts[5], fronts[6], fronts[7],
                                     fronts[8], fronts[9], fronts[10], fronts[11], fronts[12], fronts[13], fronts[14], fronts[15]))
        }
        guard let buffer = device.makeBuffer(bytes: &instances, length: MemoryLayout<Instance>.stride * instances.count,
                                             options: .storageModeShared) else { return }
        let depth = frame.depth.isFinite ? frame.depth : 0
        var uniforms = Uniforms(scale: Float(scale), cornerRadius: Float(Self.cornerRadius), inward: Float(Self.inward),
                                precipitation: Float(frame.environment.precipitation), depth: Float(depth),
                                spread: Float(Self.bounded(frame.number("spread", default: 1), 0.5...1)),
                                fade: Float(fade(frame)),
                                dew: Float(Self.dew(sun: frame.environment.sun, depth: depth,
                                                    precipitation: frame.environment.precipitation)),
                                // Wrapped at a whole number of twinkles, so the dew never jumps.
                                time: Float(frame.time.truncatingRemainder(dividingBy: Self.twinklePeriod * 200)))
        var size = SIMD2<Float>(Float(encoder.outputSize.x), Float(encoder.outputSize.y))
        encoder.renderToOutput { pass in
            pass.setRenderPipelineState(pipeline)
            pass.setVertexBuffer(buffer, offset: 0, index: 0)
            pass.setVertexBytes(&size, length: MemoryLayout<SIMD2<Float>>.size, index: 1)
            pass.setFragmentBuffer(buffer, offset: 0, index: 0)
            pass.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            pass.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: instances.count)
        }
    }

    public func releaseResources() {}
}
