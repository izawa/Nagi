import Foundation
import Metal
import NagiKit

/// A string from this package's catalog (Resources/Localizable.xcstrings).
func localized(_ key: String.LocalizationValue) -> LocalizedStringResource {
    LocalizedStringResource(key, bundle: .atURL(Bundle.module.bundleURL))
}

/// Ripples on a shallow pool over the screen (M6-PLAN): drops fall straight down, rings spread
/// out and lower as they go, cross one another and come back off the display's edges. Nothing is
/// drawn on the waves; the screen under the water bends, and the light the waves gather falls on
/// it as bright and dark rings (the waves' shadow).
/// Per display and frame: one compute pass for each live drop's radial slope (the dispersive
/// response, exact in time), one for the slope on a 1 mm grid from every drop and mirror image,
/// and one full-screen pass that bends the screen and lights it.
public final class Ripples: Effect {
    public static let descriptor = EffectDescriptor(
        id: "ripples",
        displayName: localized("波紋"),
        summary: localized("画面に張った浅い水に落ちる水滴の波紋"),
        layer: .glass,
        capabilities: [.backdrop],
        parameters: [
            ParameterSpec(key: "amount", label: localized("滴の多さ"), kind: .slider(range: 0.3...2, defaultValue: 1),
                          user: .steps([.init(label: localized("少なめ"), value: 0.6), .init(label: localized("ふつう"), value: 1),
                                        .init(label: localized("多め"), value: 1.3)])),
            ParameterSpec(key: "height", label: localized("波の高さ"), kind: .slider(range: 0.2...1.5, defaultValue: 1),
                          user: .slider(0.4...1)),
            // Tuned in the gallery (W1); not translated (DECISIONS D24).
            ParameterSpec(key: "dent", label: "くぼみの深さ (mm)", kind: .slider(range: 0.5...6, defaultValue: 3)),
            ParameterSpec(key: "impulse", label: "着水の幅 (mm)", kind: .slider(range: 1...8, defaultValue: 3)),
            ParameterSpec(key: "waterDepth", label: "水深 (mm)", kind: .slider(range: 5...100, defaultValue: 20)),
            ParameterSpec(key: "opticalDepth", label: "屈折の水深 (mm)", kind: .slider(range: 0...40, defaultValue: 20)),
            ParameterSpec(key: "shortWaves", label: "短い波", kind: .slider(range: 0...1, defaultValue: 1)),
            // 0 is perfectly clean water; 1 a surface film, as ordinary water has (it damps the short waves).
            ParameterSpec(key: "film", label: "水面の膜", kind: .slider(range: 0...1, defaultValue: 0)),
            // 1 is real time; below 1 the waves run slower (the last of the flash levers, M6-PLAN 5).
            ParameterSpec(key: "timeScale", label: "波の時間の倍率", kind: .slider(range: 0.1...1, defaultValue: 1)),
            ParameterSpec(key: "lifetime", label: "寿命 (秒)", kind: .slider(range: 2...10, defaultValue: 5)),
            ParameterSpec(key: "wall", label: "壁の反射率", kind: .slider(range: 0...1, defaultValue: 1)),
            ParameterSpec(key: "shadowLight", label: "波の影の光", kind: .choice(options: [
                .init(key: "none", label: "なし"), .init(key: "sky", label: "空の光"), .init(key: "overhead", label: "真上の光"),
            ], defaultValue: "sky")),
            // Up to 0.4 the shadow alone keeps blank areas within the flash rule; 0.5 starts to break it (M6-LOG).
            ParameterSpec(key: "shadow", label: "波の影の強さ", kind: .slider(range: 0...4, defaultValue: 0.4)),
            // A single drop placed by hand, for W1 and the flash tests: seconds into the showing
            // (below 0: off), and where (0 … 1 of the display's width and height).
            ParameterSpec(key: "testDropAt", label: "試しの一滴 (秒)", kind: .slider(range: -1...30, defaultValue: -1)),
            ParameterSpec(key: "testDropX", label: "試しの一滴 x", kind: .slider(range: 0...1, defaultValue: 0.5)),
            ParameterSpec(key: "testDropY", label: "試しの一滴 y", kind: .slider(range: 0...1, defaultValue: 0.5)),
        ],
        // Real ripples flash over text 11–26 times a second; the rule's area allowance does not
        // hold on dense screens either (M6-LOG). Off by default, turned on by choice (SPEC 2.2).
        photosensitivityNotice: localized("波紋が文字の上を通ると、1 秒に 3 回を超えて点滅することがあります。光の点滅に敏感な方は、オフのままお使いください。"))

    /// Drops at most, and the longest radius the per-drop slope profile reaches (mm, 1 mm a sample).
    static let slots = DropSchedule.capacity
    static let profileLength = 3200
    /// A deep showing (a preview, or coming back deep) gets its first drop this long after it starts.
    static let firstDropDelay = 1.0
    static let previewDepth = 120.0
    /// How long a drop's waves take to fade out at the end of its life.
    static let endFade = 2.0

    /// One drop for the profile pass: where its coefficients start, how many, the wavenumber step.
    struct ProfileDrop {
        var offset: UInt32
        var count: UInt32
        var dk: Float
        /// Past this radius (mm) the drop's waves are faded out.
        var reach: Float
    }

    struct GridUniforms {
        /// Grid size in cells (1 mm each), the number of wave sources, unused.
        var size: SIMD4<Float>
    }

    struct CompositeUniforms {
        /// Output size in pixels, millimetres per pixel, 1 for the dark appearance.
        var target: SIMD4<Float>
        /// Grid size in cells, optical depth (mm), the waves' shadow strength (0: none).
        var optics: SIMD4<Float>
        /// Where the light that falls at a point crossed the surface, back from that point (px).
        var shadowShift: SIMD4<Float>
        /// The light's colour (linear), for the bright rings on a dark screen.
        var lightColour: SIMD4<Float>
    }

    /// A display's water: its own clock (it stands still while nagi leaves), drops and textures.
    private struct DisplayWater {
        var showing: Int
        var lastTime: Double
        var clock = 0.0
        var schedule: DropSchedule
        var profile: (any MTLTexture)?
        var grid: (any MTLTexture)?
    }

    /// The largest pool, in millimetres a side (a made-up display may be any size).
    static let largestPool = 3000.0
    /// No real display is smaller; below this the mirror images a drop reaches would run into millions.
    static let smallestPool = 50.0
    /// The moon lights the waves this much of the sun (komorebi's 0.15, D27).
    static let moonLight = 0.15

    private let device: any MTLDevice
    private let profilePipeline: any MTLComputePipelineState
    private let gridPipeline: any MTLComputePipelineState
    private let compositePipeline: any MTLRenderPipelineState
    private var displays: [UInt32: DisplayWater] = [:]
    /// The push for a 1 m dent, kept while the water stays the same (it costs a few ms).
    private var unitPush: (water: Water, scale: Double)?

    public init(context: EffectContext) throws {
        device = context.device
        let library = try context.device.makeDefaultLibrary(bundle: Bundle.module)
        profilePipeline = try device.makeComputePipelineState(function: library.makeFunction(name: "rippleProfile")!)
        gridPipeline = try device.makeComputePipelineState(function: library.makeFunction(name: "rippleGrid")!)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "rippleVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "rippleFragment")
        descriptor.colorAttachments[0].pixelFormat = context.pixelFormat
        descriptor.colorAttachments[0].usePremultipliedSourceOver()
        compositePipeline = try device.makeRenderPipelineState(descriptor: descriptor)
    }

    static func bounded(_ value: Double, _ range: ClosedRange<Double>, default fallback: Double) -> Double {
        value.isFinite ? min(max(value, range.lowerBound), range.upperBound) : fallback
    }

    private func number(_ frame: FrameState, _ key: String) -> Double {
        guard let spec = Self.descriptor.parameters.first(where: { $0.key == key }),
              case let .slider(range, fallback) = spec.kind else { return 0 }
        return Self.bounded(frame.number(key, default: fallback), range, default: fallback)
    }

    private func pushPerMetre(_ water: Water) -> Double {
        if let unitPush, unitPush.water == water { return unitPush.scale }
        let scale = water.pushScale(forDent: 1)
        unitPush = (water, scale)
        return scale
    }

    /// Toward the light that casts the waves' shadow, in screen terms (x right, y down, z out of
    /// the screen), its strength and colour: the shared sky (the sun, else the moon, a cloud taking
    /// what it hides) or a light straight above. Nil for no shadow.
    static func shadowLight(_ frame: FrameState) -> (direction: SIMD3<Double>, strength: Double, isMoon: Bool)? {
        let choice = if case let .choice(value) = frame.parameters["shadowLight"] { value } else { "sky" }
        switch choice {
        case "overhead":
            return (SIMD3(0, 0, 1), 1, false)
        case "sky":
            guard let light = SkyLight(frame.environment, moonlight: true) else { return nil }
            let altitude = light.position.altitude, azimuth = light.position.azimuth
            let strength = light.weight * (light.isMoon ? moonLight : 1)
                * (1 - min(max(frame.environment.sunOcclusion, 0), 1))
            let flat = cos(altitude)
            return (SIMD3(sin(azimuth) * flat, -cos(azimuth) * flat, sin(altitude)), strength, light.isMoon)
        default:
            return nil
        }
    }

    /// Where light toward `direction` lands on the screen `depth` mm under flat water, from where
    /// it crossed the surface (mm, x right, y down).
    static func landing(_ direction: SIMD3<Double>, depth: Double) -> SIMD2<Double> {
        let across = SIMD2(-direction.x, -direction.y) / Water.refractiveIndex
        let down = (1 - min((across * across).sum(), 1)).squareRoot()
        return across / max(down, 0.05) * depth
    }

    public func update(_ frame: FrameState) {}

    public func render(_ frame: FrameState, view: DisplayView, encoder: any EffectEncoder) throws {
        guard let backdrop = view.backdrop else { return }
        let mmPerPixel = view.millimetresPerPixel
        let pool = Pool(width: Double(view.pixelSize.x) * mmPerPixel, height: Double(view.pixelSize.y) * mmPerPixel)
        guard pool.width.isFinite, pool.height.isFinite, pool.width >= Self.smallestPool, pool.height >= Self.smallestPool,
              pool.width <= Self.largestPool, pool.height <= Self.largestPool else { return }
        let lifetime = number(frame, "lifetime")
        // Reduce Motion: half the drops, half as high. The waves keep their real speed (the
        // settings preview already runs its clock at half speed).
        let calmer = frame.accessibility.reduceMotion ? 0.5 : 1

        // The water's clock follows the frames, stands still while nagi leaves (no new drop over
        // the held picture), and starts over on still water for a new showing or a clock that
        // went back (the gallery's restart).
        var water = displays[view.id] ?? DisplayWater(showing: frame.showing - 1, lastTime: frame.time,
                                                      schedule: DropSchedule(seed: 0))
        let dt = frame.phase == .leaving ? 0 : frame.time - water.lastTime
        if water.showing != frame.showing || dt < 0 {
            water = DisplayWater(showing: frame.showing, lastTime: frame.time,
                                 schedule: DropSchedule(seed: frame.seed ^ UInt64(truncatingIfNeeded: frame.showing)
                                     &* 0x9e3779b97f4a7c15 ^ UInt64(view.id) << 32),
                                 profile: water.profile, grid: water.grid)
            let testAt = number(frame, "testDropAt")
            if testAt >= 0 {
                water.schedule.place(Drop(x: number(frame, "testDropX") * pool.width, y: number(frame, "testDropY") * pool.height,
                                          time: testAt, strength: 1))
            } else if frame.depth >= Self.previewDepth {
                water.schedule.place(Drop(x: 0.5 * pool.width, y: 0.45 * pool.height, time: Self.firstDropDelay, strength: 1))
            }
        } else {
            // Slower waves keep the drops a real minute the same.
            let timeScale = number(frame, "timeScale")
            water.clock += dt * timeScale
            if number(frame, "testDropAt") < 0 {
                let area = pool.width * pool.height / DropSchedule.referenceArea
                water.schedule.step(time: water.clock, dt: dt * timeScale, depth: frame.depth,
                                    rate: area * number(frame, "amount") * calmer / timeScale,
                                    pool: pool, lifetime: lifetime, strength: 0.7...1.3)
            }
        }
        water.lastTime = frame.time
        let gridSize = SIMD2(Int(pool.width.rounded(.up)), Int(pool.height.rounded(.up)))
        if water.profile == nil {
            water.profile = makeTexture(.r32Float, Self.profileLength, Self.slots)
        }
        if water.grid.map({ $0.width != gridSize.x || $0.height != gridSize.y }) ?? true {
            water.grid = makeTexture(.rg32Float, gridSize.x, gridSize.y)
        }
        displays[view.id] = water
        guard let profile = water.profile, let grid = water.grid else { return }

        // The drops in the water now: each one's slope coefficients for its age, and its sources.
        let physics = Water(depth: number(frame, "waterDepth") / 1000, impulseWidth: number(frame, "impulse") / 1000,
                            shortWaves: number(frame, "shortWaves"), film: number(frame, "film"))
        let push = pushPerMetre(physics) * number(frame, "dent") / 1000 * number(frame, "height") * calmer
        var profileDrops: [ProfileDrop] = []
        var coefficients: [Float] = []
        var sources: [SIMD4<Float>] = []
        for drop in water.schedule.drops {
            let age = water.clock - drop.time
            guard age > 0, age < lifetime, profileDrops.count < Self.slots else { continue }
            let reach = Water.reach(age: age)
            // Fade the last seconds of a drop's life smoothly, so the cut at `lifetime` is not seen.
            let left = min(max((lifetime - age) / Self.endFade, 0), 1)
            let fade = left * left * (3 - 2 * left)
            let (dk, values) = physics.slopeCoefficients(age: age, reach: reach, push: push * drop.strength * fade)
            let slot = profileDrops.count
            profileDrops.append(ProfileDrop(offset: UInt32(coefficients.count), count: UInt32(values.count),
                                            dk: Float(dk), reach: Float(reach * 1000)))
            coefficients += values
            // The profile fades out between 0.9 and 1.1 of the reach: take every image within that.
            for source in pool.sources(of: drop, index: slot, reach: reach * 1100, reflectance: number(frame, "wall")) {
                sources.append(SIMD4(Float(source.x), Float(source.y), Float(source.gain), Float(slot)))
            }
        }
        guard !profileDrops.isEmpty, !sources.isEmpty,
              let dropBuffer = device.makeBuffer(bytes: &profileDrops, length: MemoryLayout<ProfileDrop>.stride * profileDrops.count,
                                                 options: .storageModeShared),
              let coefficientBuffer = device.makeBuffer(bytes: &coefficients, length: MemoryLayout<Float>.stride * coefficients.count,
                                                        options: .storageModeShared),
              let sourceBuffer = device.makeBuffer(bytes: &sources, length: MemoryLayout<SIMD4<Float>>.stride * sources.count,
                                                   options: .storageModeShared) else { return }

        var gridUniforms = GridUniforms(size: SIMD4(Float(gridSize.x), Float(gridSize.y), Float(sources.count), 0))
        let dropCount = profileDrops.count
        encoder.compute { pass in
            pass.setComputePipelineState(profilePipeline)
            pass.setTexture(profile, index: 0)
            pass.setBuffer(dropBuffer, offset: 0, index: 0)
            pass.setBuffer(coefficientBuffer, offset: 0, index: 1)
            pass.dispatchThreads(MTLSize(width: Self.profileLength, height: dropCount, depth: 1),
                                 threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
        }
        encoder.compute { pass in
            pass.setComputePipelineState(gridPipeline)
            pass.setTexture(profile, index: 0)
            pass.setTexture(grid, index: 1)
            pass.setBuffer(sourceBuffer, offset: 0, index: 0)
            pass.setBytes(&gridUniforms, length: MemoryLayout<GridUniforms>.stride, index: 1)
            pass.dispatchThreads(MTLSize(width: gridSize.x, height: gridSize.y, depth: 1),
                                 threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        }

        // Increase Contrast or Reduce Transparency: the screen bends and the shadow falls half as much.
        let weaker = frame.accessibility.reduceStrength ? 0.5 : 1
        let depth = number(frame, "opticalDepth") * weaker
        var shadow = 0.0, shift = SIMD2<Double>.zero, colour = SIMD3<Float>(1, 0.97, 0.9)
        if let light = Self.shadowLight(frame) {
            shadow = light.strength * number(frame, "shadow") * weaker
            shift = Self.landing(light.direction, depth: depth) / mmPerPixel
            if light.isMoon { colour = SIMD3(0.80, 0.87, 1.0) }
        }
        var composite = CompositeUniforms(
            target: SIMD4(Float(encoder.outputSize.x), Float(encoder.outputSize.y), Float(mmPerPixel),
                          frame.appearance == .dark ? 1 : 0),
            optics: SIMD4(Float(gridSize.x), Float(gridSize.y), Float(depth), Float(shadow)),
            shadowShift: SIMD4(Float(shift.x), Float(shift.y), 0, 0),
            lightColour: SIMD4(colour, 0))
        encoder.renderToOutput { pass in
            pass.setRenderPipelineState(compositePipeline)
            pass.setFragmentBytes(&composite, length: MemoryLayout<CompositeUniforms>.stride, index: 0)
            pass.setFragmentTexture(backdrop, index: 0)
            pass.setFragmentTexture(grid, index: 1)
            pass.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
    }

    private func makeTexture(_ format: MTLPixelFormat, _ width: Int, _ height: Int) -> (any MTLTexture)? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height,
                                                                  mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        return device.makeTexture(descriptor: descriptor)
    }

    public func releaseResources() { displays.removeAll() }
}
