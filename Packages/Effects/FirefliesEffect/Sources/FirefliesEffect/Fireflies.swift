import CoreGraphics
import Foundation
import Metal
import NagiKit

/// A string from this package's catalog (Resources/Localizable.xcstrings).
func localized(_ key: String.LocalizationValue) -> LocalizedStringResource {
    LocalizedStringResource(key, bundle: .atURL(Bundle.module.bundleURL))
}

/// Fireflies (M7-PLAN): after sunset, yellow-green lights fly in the dark beyond the screen,
/// come on and die away. Only the light is drawn, no insect. Far ones are small sharp points,
/// near ones soft out-of-focus discs. One instanced quad per firefly.
public final class Fireflies: Effect {
    public static let descriptor = EffectDescriptor(
        id: "fireflies",
        displayName: localized("蛍"),
        summary: localized("日が沈むと、画面の向こうを蛍が飛ぶ"),
        layer: .light,
        // The "bright" look on a light screen draws above SDR white (M7-PLAN 5, c).
        capabilities: [.extendedRange],
        parameters: [
            // Tuned in the gallery and at W1 (区切り A); not translated (DECISIONS D24).
            ParameterSpec(key: "strength", label: "強さ", kind: .slider(range: 0...1, defaultValue: 1)),
            // How many fly once the calm is deep; the user sets it in Settings (the author asked, W1).
            ParameterSpec(key: "count", label: localized("数"), kind: .slider(range: 1...15, defaultValue: 12),
                          user: .slider(1...15)),
            ParameterSpec(key: "size", label: "大きさ", kind: .slider(range: 0.5...4, defaultValue: 3)),
            ParameterSpec(key: "focus", label: "ピントの距離", kind: .slider(range: 0.3...4, defaultValue: 1.5)),
            // No shorter than 3 s: a flash is lit for 2.2 s (W1).
            ParameterSpec(key: "period", label: "明滅の周期", kind: .slider(range: 3...5, defaultValue: 4)),
            ParameterSpec(key: "lightStyle", label: "ライトの外観", kind: .choice(options: [
                .init(key: "glow", label: "同じ色を置く"),
                .init(key: "shade", label: "まわりを暗く"),
                .init(key: "bright", label: "白より明るく"),
            ], defaultValue: "bright")),  // the author's choice at W1
            ParameterSpec(key: "glow", label: "にじみ", kind: .slider(range: 0...1, defaultValue: 0.35)),
            ParameterSpec(key: "shade", label: "まわりの暗さ", kind: .slider(range: 0...0.6, defaultValue: 0.3)),
            ParameterSpec(key: "edrGain", label: "白より明るく", kind: .slider(range: 1...4, defaultValue: 2)),
            // The inner orb (W1 trial): its alpha against the light's, its radius against the
            // light's seen radius, and how many seconds of flight it is offset by: negative ahead,
            // positive behind (W1: at −0.12 the author saw it lead; it should trail).
            ParameterSpec(key: "orb", label: "中の球", kind: .slider(range: 0...1, defaultValue: 0.8)),
            ParameterSpec(key: "orbSize", label: "中の球の大きさ", kind: .slider(range: 0.1...1, defaultValue: 0.25)),
            ParameterSpec(key: "orbLag", label: "中の球の遅れ", kind: .slider(range: -0.4...0.4, defaultValue: orbLag)),
            // How far the wind carries them, times `Firefly.breezeDrift` and `gustDrift`.
            ParameterSpec(key: "drift", label: "風で流れる", kind: .slider(range: 0...6, defaultValue: 1)),
        ])

    /// Strongest alpha at the core of a far and of a near light (M7-PLAN 5, 【仮】). The plan's
    /// 0.06 … 0.14 (komorebi's) showed almost nothing on black: a light of its own needs a bright core.
    static let farAlpha = 0.5, nearAlpha = 0.85
    /// Encoded Display P3 green with a little yellow, and the whiter colour at a core. The first
    /// (0.80, 1.0, 0.32) read too yellow to the author at W1.
    static let colour = SIMD3<Float>(0.55, 1.0, 0.40)
    static let coreColour = SIMD3<Float>(0.85, 1.0, 0.75)
    /// The inner orb's colour: yellower than the first colour (0.80, 1.0, 0.32), which read too
    /// yellow for the whole light (W1).
    static let orbColour = SIMD3<Float>(1.0, 0.95, 0.25)
    /// Seconds of flight the inner orb trails by: 0.3 times the first 0.12, which trailed too far
    /// when flying fast (W1).
    static let orbLag = 0.036
    /// The dark around a light in the "shade" look: komorebi's near-black (SPEC 4.1).
    static let shadeColour = SIMD3<Float>(0.0, 0.006, 0.004)

    /// Millimetres of blur on the screen per dioptre out of focus (|1/distance − 1/focus|): about
    /// as much as the nearest firefly had before focus came in (W1).
    static let blurPerDioptre = 0.48

    struct Instance {
        /// Centre (x, y) in pixels, the core's and the glow's spread (pixels).
        var centre: SIMD4<Float>
        /// The out-of-focus disc's radius (pixels, 0 in focus), the quad's half size, the light's
        /// alpha now, how far the shade reaches (pixels).
        var shape: SIMD4<Float>
    }

    struct Uniforms {
        /// Output size in pixels, the look (0 plain, 1 shade, 2 bright), the shade's alpha.
        var target: SIMD4<Float>
        /// The glow's share of the core's alpha.
        var look: SIMD4<Float>
        /// Linear colour of the light (times the EDR gain), and of its core.
        var colour: SIMD4<Float>
        var core: SIMD4<Float>
        var shade: SIMD4<Float>
    }

    /// How dark the sky is: 0 with the sun up, 1 from 6° below the horizon (M7-PLAN 4).
    static func night(_ environment: SharedEnvironment) -> Double {
        let degree = Double.pi / 180
        return 1 - Firefly.smooth((environment.sun.altitude + 6 * degree) / (6 * degree))
    }

    static func bounded(_ value: Double, _ range: ClosedRange<Double>, default fallback: Double) -> Double {
        value.isFinite ? min(max(value, range.lowerBound), range.upperBound) : fallback
    }

    /// The share of the lights' alpha drawn now: night × strength, halved for Increase Contrast or
    /// Reduce Transparency (M7-PLAN 7). Not depth: a calm that starts at 0 still has fireflies.
    static func visibility(_ frame: FrameState) -> Double {
        let strength = frame.number("strength", default: 1) * (frame.accessibility.reduceStrength ? 0.5 : 1)
        return night(frame.environment) * strength
    }

    /// The share of the fireflies that fly in a deep calm: 1 in mid-June, 0.5 in mid-December,
    /// along a cosine over the year (M7-PLAN 4, question 2). Japan's seasons; not the southern ones.
    static func season(_ date: Date) -> Double {
        let peak = Date(timeIntervalSince1970: 1_781_449_200)  // 2026-06-15 00:00 JST
        let year = 365.2425 * 86_400
        let share = 0.75 + 0.25 * cos(2 * .pi * date.timeIntervalSince(peak) / year)
        return share.isFinite ? share : 1
    }

    /// How many fly once the calm is deep: the set number for the season, at least 1. The number is
    /// for a 27-inch display: a smaller desktop has fewer by its area; a larger one, or a second
    /// display, spreads the same number wider (M7-PLAN 6).
    /// `screen` is the desktop's area against a 27-inch display (`Swarm.share`).
    static func count(_ number: Int, on date: Date, screen share: Double = 1) -> Int {
        let screen = share.isFinite && share > 0 ? min(share, 1) : 1
        return max(1, Int((Double(number) * season(date) * screen).rounded()))
    }

    /// The share of the distance flown: half for Reduce Motion (M7-PLAN 7).
    static func motion(_ frame: FrameState) -> Double { frame.accessibility.reduceMotion ? 0.5 : 1 }

    public static func note(_ frame: FrameState) -> LocalizedStringResource? {
        night(frame.environment) > 0 ? nil : localized("蛍は日が沈むと現れます")
    }

    public static func isSilent(_ frame: FrameState) -> Bool { !(visibility(frame) > 0) }

    private let pipeline: any MTLRenderPipelineState
    private let orbPipeline: any MTLRenderPipelineState
    private var swarm: Swarm?
    /// What the swarm was made for: another showing, desktop or setting starts over.
    /// `flying` is `count` for the season the swarm was made in.
    private var world: (seed: UInt64, displays: [CGRect], count: Int, flying: Int, period: Double, screen: Double)?
    /// Each display's physical area, mm², by its rectangle, from `measured`: the latest view of
    /// each display id (mirrored displays do not take turns), kept while it is drawn (displays draw
    /// on their own schedules) and dropped a second after it stops (removed or replaced).
    private var millimetres: [[Double]: Double] = [:]
    private var measured: [UInt32: (key: [Double], area: Double?, time: Double)] = [:]
    private var lastTime: Double?
    private var lastDepth = 0.0
    private var lastDate: Date?

    public init(context: EffectContext) throws {
        let library = try context.device.makeDefaultLibrary(bundle: Bundle.module)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "fireflyVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "fireflyFragment")
        descriptor.colorAttachments[0].pixelFormat = context.pixelFormat
        descriptor.colorAttachments[0].usePremultipliedSourceOver()
        pipeline = try context.device.makeRenderPipelineState(descriptor: descriptor)
        descriptor.fragmentFunction = library.makeFunction(name: "orbFragment")
        orbPipeline = try context.device.makeRenderPipelineState(descriptor: descriptor)
    }

    public func update(_ frame: FrameState) {
        let depth = frame.depth.isFinite ? min(max(frame.depth, 0), 3600) : 0
        let motion = Self.motion(frame)
        let count = Int(Self.bounded(frame.number("count", default: 12), 1...15, default: 12).rounded())
        let period = Self.bounded(frame.number("period", default: 4), 3...5, default: 4)
        let seed = frame.seed &+ UInt64(frame.showing)
        let elapsed = lastTime.map { frame.time - $0 } ?? -1
        // The season is read when the swarm is made, so midnight in a calm makes nothing anew. Only
        // a date moved apart from the clock (the gallery's date, the Mac's clock set) into another
        // number starts over.
        // The first frame may not know a display's physical size yet; once render has seen it, the
        // swarm is reweighed, or made anew if the number changes. Mirrored displays (one rectangle)
        // take the largest size, whichever drew last.
        measured = measured.filter { abs(frame.time - $0.value.time) <= 1 }
        millimetres = measured.values.reduce(into: [:]) { sizes, view in
            if let area = view.area { sizes[view.key] = max(sizes[view.key] ?? 0, area) }
        }
        let screen = Swarm.share(frame.displays, millimetres: millimetres)
        let flying = Self.count(count, on: frame.date, screen: screen)
        let dated = lastDate.map { abs(frame.date.timeIntervalSince($0) - elapsed) > 60 } ?? false
        // A depth that jumps or goes back (a preview's slider), the clock set back, or a long stall:
        // start over, as rain does.
        let seek = abs(depth - lastDepth) > max(2 * elapsed, 2) + 1 || elapsed > 2
            || (depth < lastDepth - 0.5 && frame.phase != .leaving)
        if Swarm.screens(frame.displays).isEmpty {
            swarm = nil
        } else if frame.phase == .leaving, swarm != nil, world?.seed == seed {
            // Leaving, the lights hold still where they were (render): nothing moves, is born, let
            // go or made anew until the next showing.
        } else if let world, world.seed == seed, world.displays == Swarm.screens(frame.displays), world.count == count,
                  !dated || world.flying == flying, world.period == period, swarm != nil, elapsed >= 0, !seek,
                  // A size that changes the number today starts over; one that does not keeps the lights.
                  Self.count(count, on: frame.date, screen: world.screen) == flying {
            swarm?.reweigh(millimetres: millimetres)
            self.world?.screen = screen
            swarm?.advance(to: frame.time, depth: depth, motion: motion, wind: frame.environment.wind,
                           drift: Self.bounded(frame.number("drift", default: 1), 0...6, default: 1))
        } else {
            world = (seed, Swarm.screens(frame.displays), count, flying, period, screen)
            swarm = Swarm(seed: seed, displays: frame.displays, millimetres: millimetres, count: flying, period: period, depth: depth,
                          now: frame.time)
        }
        lastTime = frame.time
        lastDepth = depth
        lastDate = frame.date
    }

    public func render(_ frame: FrameState, view: DisplayView, encoder: any EffectEncoder) throws {
        // A display that no longer reports its size (another one in its place) falls back to points.
        let physical = view.physicalSize.map { $0.x * $0.y }
        measured[view.id] = (Swarm.key(view.frameInDesktop), physical.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }, frame.time)
        let visibility = Self.visibility(frame)
        guard visibility > 0, let swarm else { return }
        let pixelsPerMillimetre = 1 / view.millimetresPerPixel
        let light = frame.appearance == .light
        let style: Float = switch (light, frame.parameters["lightStyle"]) {
        case (true, .choice("shade")?): 1
        case (true, .choice("glow")?): 0
        case (true, _): 2
        default: 0
        }
        // Millimetres on the screen to pixels, times the size (3: the author's choice at W1).
        let size = Self.bounded(frame.number("size", default: 3), 0.5...4, default: 3) * pixelsPerMillimetre
        let focus = Self.bounded(frame.number("focus", default: 1.5), Firefly.distances, default: 1.5)
        let shade = Self.bounded(frame.number("shade", default: 0.3), 0...0.6, default: 0.3)
        let orb = Self.bounded(frame.number("orb", default: 0.8), 0...1, default: 0.8)
        let orbSize = Self.bounded(frame.number("orbSize", default: 0.25), 0.1...1, default: 0.25)
        let orbLag = Self.bounded(frame.number("orbLag", default: Self.orbLag), -0.4...0.4, default: Self.orbLag)
        let motion = Self.motion(frame)
        var instances: [Instance] = [], orbs: [Instance] = []
        // Leaving, each light keeps where and how bright it was at the last frame before the input,
        // and the core fades it (M7-PLAN 6).
        let time = swarm.time
        for case let firefly? in swarm.fireflies {
            let brightness = firefly.brightness(at: time)
            guard brightness > 0 else { continue }
            let near = firefly.nearness(at: time)
            let distance = Firefly.distance(nearness: near)
            // Sizes on the screen in millimetres (M7-PLAN 5, 【仮】): the far core about half the near.
            let core = (0.25 + 0.3 * near) * size
            // A little sharper than first drawn (W1): the glow 0.85 times as wide.
            let glow = 0.85 * (0.9 + 1.4 * near) * size
            // Out of focus as an eye or a lens is: by how far the distance is from the focus, in
            // dioptres. Near ones blur most; far ones a little.
            let blur = Self.blurPerDioptre * abs(1 / distance - 1 / focus) * size
            let reach = (style == 1 ? 1.8 : 1) * max(3.2 * glow, 1.4 * blur) + 2
            let point = firefly.position
            let x = (point.x - view.frameInDesktop.minX) * view.scale
            let y = (point.y - view.frameInDesktop.minY) * view.scale
            // The inner orb trails by orbLag seconds of flight along the path it flies (the wind's
            // drift too), so further when it flies fast; one still on the screen keeps its light drawn.
            let lag = orb > 0 ? (firefly.velocity(at: time) * motion + firefly.carried) * orbLag * view.scale : .zero
            let margin = reach + (lag.x * lag.x + lag.y * lag.y).squareRoot()
            guard x > -margin, y > -margin, x < Double(view.pixelSize.x) + margin, y < Double(view.pixelSize.y) + margin
            else { continue }
            let alpha = (Self.farAlpha + (Self.nearAlpha - Self.farAlpha) * near) * brightness * visibility
            instances.append(Instance(centre: SIMD4(Float(x), Float(y), Float(core), Float(glow)),
                                      shape: SIMD4(Float(blur), Float(reach), Float(alpha), Float(1.8 * glow))))
            if orb > 0 {
                // A share (orbSize) of the bright part's radius: two core spreads in focus, the disc out
                // of it; 0.25 looks half the green (W1). Its blur is scaled with it, so it stays inside the green (W1: at the
                // light's own blur it spread over the whole light).
                let radius = orbSize * max(2 * core, blur)
                let orbBlur = orbSize * blur
                // The edge a little softer than first drawn (W1: 15 % of the radius).
                let edge = 0.2 * radius + 0.5
                orbs.append(Instance(centre: SIMD4(Float(x - lag.x), Float(y - lag.y), Float(radius), Float(edge)),
                                     shape: SIMD4(Float(orbBlur), Float(radius + 2 * edge + orbBlur + 2), Float(alpha * orb), 0)))
            }
        }
        guard !instances.isEmpty else { return }
        let length = MemoryLayout<Instance>.stride * instances.count  // at most 15 × 32 bytes
        let gain = style == 2 && view.edrHeadroom > 1
            ? Float(min(view.edrHeadroom, Self.bounded(frame.number("edrGain", default: 2), 1...4, default: 2))) : 1
        var uniforms = Uniforms(
            target: SIMD4(Float(encoder.outputSize.x), Float(encoder.outputSize.y), style, Float(shade)),
            look: SIMD4(Float(Self.bounded(frame.number("glow", default: 0.35), 0...1, default: 0.35)), 0, 0, 0),
            colour: SIMD4(Self.linear(Self.colour) * gain, 0),
            core: SIMD4(Self.linear(Self.coreColour) * gain, 0),
            shade: SIMD4(Self.shadeColour, 0))
        encoder.renderToOutput { pass in
            pass.setRenderPipelineState(pipeline)
            pass.setVertexBytes(&instances, length: length, index: 0)
            pass.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            pass.setFragmentBytes(&instances, length: length, index: 0)
            pass.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            pass.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: instances.count)
            guard !orbs.isEmpty else { return }
            var orbUniforms = uniforms
            orbUniforms.colour = SIMD4(Self.linear(Self.orbColour) * gain, 0)
            pass.setRenderPipelineState(self.orbPipeline)
            pass.setVertexBytes(&orbs, length: MemoryLayout<Instance>.stride * orbs.count, index: 0)
            pass.setVertexBytes(&orbUniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            pass.setFragmentBytes(&orbs, length: MemoryLayout<Instance>.stride * orbs.count, index: 0)
            pass.setFragmentBytes(&orbUniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            pass.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: orbs.count)
        }
    }


    public func releaseResources() {}

    static func linear(_ c: SIMD3<Float>) -> SIMD3<Float> {
        func one(_ x: Float) -> Float { x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
        return SIMD3(one(c.x), one(c.y), one(c.z))
    }
}
