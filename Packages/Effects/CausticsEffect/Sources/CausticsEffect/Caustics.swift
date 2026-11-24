import CoreGraphics
import Foundation
import Metal
import NagiKit

/// A string from this package's catalog (Resources/Localizable.xcstrings).
func localized(_ key: String.LocalizationValue) -> LocalizedStringResource {
    LocalizedStringResource(key, bundle: .atURL(Bundle.module.bundleURL))
}

/// Light under water (M4-PLAN): the desktop is the floor of clear, shallow water, and sunlight
/// refracted by its rippled surface gathers there into a moving net of bright lines.
///
/// Each frame, a fixed grid of points on the water surface (about a millimetre apart) refracts
/// the light once; each point's share of light is spread on the floor where it lands, as a small
/// Gaussian the size of the sun's image there and of the patch of surface it stands for, into a
/// quarter-resolution illuminance texture (flat water gives 1 everywhere). The composite then
/// turns illuminance into a shade (light appearance) or light (dark appearance) at full size.
public final class Caustics: Effect {
    public static let descriptor = EffectDescriptor(
        id: "caustics",
        displayName: localized("水中の光"),
        summary: localized("浅い水の底に揺れる光"),
        layer: .light,
        parameters: [
            ParameterSpec(key: "strength", label: "強さ", kind: .slider(range: 0...1, defaultValue: 1)),
            ParameterSpec(key: "moonlight", label: localized("月明かり"), kind: .toggle(defaultValue: true), user: .toggle),
            // The author's tuning (the gallery, not translated).
            ParameterSpec(key: "waterDepth", label: "水深 (cm)", kind: .slider(range: 10...60, defaultValue: 28)),
            ParameterSpec(key: "waves", label: "波の数", kind: .slider(range: 3...16, defaultValue: 12)),
            ParameterSpec(key: "slope", label: "波の傾き", kind: .slider(range: 0...0.2, defaultValue: 0.07)),
            ParameterSpec(key: "exposure", label: "露出", kind: .slider(range: 0.3...4, defaultValue: 1.2)),
            ParameterSpec(key: "lightAlpha", label: "影の濃さ", kind: .slider(range: 0...0.3, defaultValue: 0.12)),
            ParameterSpec(key: "darkAlpha", label: "光の強さ", kind: .slider(range: 0...0.3, defaultValue: 0.14)),
            // Komorebi's moonlight strength (D27), in both appearances, until stop W3.
            ParameterSpec(key: "moonAlpha", label: "月明かりの強さ", kind: .slider(range: 0...0.3, defaultValue: 0.15)),
        ])

    /// Most waves the shader sums.
    static let waveCapacity = 16
    /// The illuminance texture is this many times coarser than the display (M4-PLAN 5).
    static let reduction = 4
    /// Millimetres between the surface points that carry light. The lines' width comes from the
    /// sun's image and the texture; at 1.4 mm instead of 1 the picture differs by at most 14/255
    /// and the GPU time falls from about 1.6 to 1.0 ms at 5K (M4-LOG stage B).
    static let spacing = 1.4
    /// Most surface points a display may use (a 1.5 m × 1 m display at 1 mm).
    static let pointCapacity = 1_500_000
    /// The sun's angular diameter, radians (komorebi's too).
    static let sunDiameter = 0.0093
    static let refractiveIndex = 1.333
    /// Desktop-wide scale for display origins, so neighbouring displays meet in the water.
    static let desktopMillimetresPerPoint = 25.4 / 109

    struct SplatUniforms {
        /// Sample region origin (mm), spacing (mm), columns.
        var grid: SIMD4<Float>
        /// Floor origin of the display (mm), millimetres per texel, waves in use.
        var target: SIMD4<Float>
        /// The light's direction of travel in the air above the water, and the water depth (mm).
        var light: SIMD4<Float>
        /// The sun's image on the floor as a covariance (mm²): xx, xy, yy; then the least variance.
        var sun: SIMD4<Float>
        /// Per wave: direction x, y, wavenumber (rad/mm), amplitude (mm).
        var waves: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>,
                    SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)
        /// The waves' phases, four to an element.
        var phases: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)
        /// How much each wave answers a gust (its shortness × the gust gain), four to an element.
        var gustGains: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)
        /// The gust fronts' direction (unit), their speed (mm/s), how many gusts follow.
        var front: SIMD4<Float>
        /// Per gust: onset − now (s), rise (s), duration (s), strength (Wind.Gust).
        var gusts: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)
    }

    static let maxGusts = 8
    /// How much a full gust raises the shortest ripples (they triple); the long swell barely moves.
    /// At 1 (doubling) the author could not see a gust cross at stop W2.
    static let gustGain = 2.0

    struct CompositeUniforms {
        /// Peak alpha × strength, 1 for dark appearance, exposure, how far a cloud hides the sun.
        var output: SIMD4<Float>
        /// The colour drawn (premultiplied by alpha in the shader).
        var colour: SIMD4<Float>
    }

    private let device: any MTLDevice
    private let splatPipeline: any MTLRenderPipelineState
    private let compositePipeline: any MTLRenderPipelineState
    private let landingPipeline: any MTLComputePipelineState
    private let meanPipeline: any MTLComputePipelineState
    /// Each display's mean clear alpha (one float), written by `causticsMean` on the GPU.
    private var means: [UInt32: any MTLBuffer] = [:]
    private var landings: [UInt32: any MTLBuffer] = [:]
    private let sampler: any MTLSamplerState
    private var illuminance: [UInt32: any MTLTexture] = [:]

    public init(context: EffectContext) throws {
        device = context.device
        let library = try context.device.makeDefaultLibrary(bundle: Bundle.module)
        let splat = MTLRenderPipelineDescriptor()
        splat.vertexFunction = library.makeFunction(name: "splatVertex")
        splat.fragmentFunction = library.makeFunction(name: "splatFragment")
        splat.colorAttachments[0].pixelFormat = .r32Float
        splat.colorAttachments[0].isBlendingEnabled = true
        splat.colorAttachments[0].rgbBlendOperation = .add
        splat.colorAttachments[0].sourceRGBBlendFactor = .one
        splat.colorAttachments[0].destinationRGBBlendFactor = .one
        splat.colorAttachments[0].alphaBlendOperation = .add
        splat.colorAttachments[0].sourceAlphaBlendFactor = .one
        splat.colorAttachments[0].destinationAlphaBlendFactor = .one
        splatPipeline = try context.device.makeRenderPipelineState(descriptor: splat)
        let composite = MTLRenderPipelineDescriptor()
        composite.vertexFunction = library.makeFunction(name: "compositeVertex")
        composite.fragmentFunction = library.makeFunction(name: "compositeFragment")
        composite.colorAttachments[0].pixelFormat = context.pixelFormat
        composite.colorAttachments[0].usePremultipliedSourceOver()
        compositePipeline = try context.device.makeRenderPipelineState(descriptor: composite)
        guard let landing = library.makeFunction(name: "landingKernel") else { throw CausticsError("no landing kernel") }
        landingPipeline = try context.device.makeComputePipelineState(function: landing)
        guard let mean = library.makeFunction(name: "causticsMean") else { throw CausticsError("no mean kernel") }
        meanPipeline = try context.device.makeComputePipelineState(function: mean)
        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        guard let sampler = context.device.makeSamplerState(descriptor: samplerDescriptor) else {
            throw CausticsError("no sampler")
        }
        self.sampler = sampler
    }

    public func update(_ frame: FrameState) {}

    public func releaseResources() {
        illuminance.removeAll()
        landings.removeAll()
        means.removeAll()
    }

    /// The last illuminance drawn for a display (tests).
    func lastIlluminance(display: UInt32) -> (any MTLTexture)? { illuminance[display] }

    // MARK: - Light

    /// The sun by day; the moon at night if moonlight is on (SkyLight, komorebi's rule, D21).
    static func lightSource(_ frame: FrameState) -> SkyLight? {
        SkyLight(frame.environment, moonlight: frame.flag("moonlight", default: true))
    }

    public static func note(_ frame: FrameState) -> LocalizedStringResource? {
        switch lightSource(frame) {
        case let light? where !light.isMoon: nil
        case _? where !isSilent(frame):
            localized("日が沈んでいます。水中の光は月明かりで薄く現れます")
        default: frame.environment.sun.altitude > 0
            ? localized("日が低いので、水中の光は現れません") : localized("日が沈んでいるので、水中の光は現れません")
        }
    }

    /// No light, moonlight too faint to see, or nothing drawn (`render`'s rule).
    public static func isSilent(_ frame: FrameState) -> Bool {
        guard let light = lightSource(frame) else { return true }
        let alpha = peak(frame, isMoon: light.isMoon) * strength(frame)
        return light.isMoon ? !(light.weight * alpha >= 0.02) : !(alpha > 0)
    }

    static func strength(_ frame: FrameState) -> Double {
        frame.number("strength", default: 1) * (frame.accessibility.reduceStrength ? 0.6 : 1)
    }

    /// The overlay's strongest alpha: the moon has its own, the sun one per appearance.
    static func peak(_ frame: FrameState, isMoon: Bool) -> Double {
        if isMoon { return bounded(frame.number("moonAlpha", default: 0.15), 0...0.3) }
        return frame.appearance == .dark ? bounded(frame.number("darkAlpha", default: 0.14), 0...0.3)
            : bounded(frame.number("lightAlpha", default: 0.12), 0...0.3)
    }

    /// The direction light travels in the air towards the water (x east, y south, z up), from a
    /// light source at `position`.
    static func incidentDirection(_ position: CelestialPosition) -> SIMD3<Double> {
        let altitude = max(position.altitude, SkyLight.cutoffAltitude)
        return -SIMD3(cos(altitude) * sin(position.azimuth), -cos(altitude) * cos(position.azimuth), sin(altitude))
    }

    /// How far (mm), along x and y, a surface tilted by up to `slope` in any direction can move
    /// where the light lands, compared with flat water `depth` mm deep: the least and the most.
    /// One-sided at a low sun: a tilt towards it bends the light far, away from it little.
    /// Tilts that turn the surface from the light let none through and are left out.
    static func deflection(incident: SIMD3<Double>, slope: Double, depth: Double) -> (low: SIMD2<Double>, high: SIMD2<Double>) {
        func landing(_ normal: SIMD3<Double>) -> SIMD2<Double> {
            let ray = refract(incident, normal: normal, eta: 1 / refractiveIndex)
            return SIMD2(ray.x, ray.y) / max(-ray.z, 0.05) * depth
        }
        let flat = landing(SIMD3(0, 0, 1))
        var low = SIMD2<Double>(0, 0), high = SIMD2<Double>(0, 0)
        // Every direction, and slopes short of the steepest too: near grazing a gentler slope can
        // bend further than a steep one that turns the surface from the light.
        for step in 0..<32 {
            let angle = Double(step) * .pi / 16
            for fraction in stride(from: 0.01, through: 1.0, by: 0.01) {
                let tilted = SIMD3(-slope * fraction * cos(angle), -slope * fraction * sin(angle), 1)
                let normal = tilted / (tilted * tilted).sum().squareRoot()
                guard (normal * incident).sum() < 0 else { continue }
                let delta = landing(normal) - flat
                low = pointwiseMin(low, delta)
                high = pointwiseMax(high, delta)
            }
        }
        // Between samples, close to grazing, the bend still grows a little: a tenth more.
        return (low * 1.1, high * 1.1)
    }

    /// The direction it travels in the water under a flat surface.
    static func refractedDirection(_ position: CelestialPosition) -> SIMD3<Double> {
        refract(incidentDirection(position), normal: SIMD3(0, 0, 1), eta: 1 / refractiveIndex)
    }

    static func refract(_ incident: SIMD3<Double>, normal: SIMD3<Double>, eta: Double) -> SIMD3<Double> {
        let cosine = -(normal * incident).sum()
        let k = 1 - eta * eta * (1 - cosine * cosine)
        return eta * incident + (eta * cosine - k.squareRoot()) * normal
    }

    /// The sun's image on the floor through flat water `depth` mm deep, as a covariance (mm²):
    /// a disk's variance is r²/4. Across the plane of incidence the sun's angle shrinks by the
    /// refractive index; within it by cos(incidence) / (n cos(refraction)) (Snell's law), and the
    /// slanting path and floor stretch it by 1 / cos(refraction) twice.
    static func sunCovariance(direction: SIMD3<Double>, incident: SIMD3<Double>, depth: Double) -> (xx: Double, xy: Double, yy: Double) {
        let cosine = max(-direction.z, 0.05), incidence = max(-incident.z, 0.05)
        let minor = sunDiameter / refractiveIndex * depth / cosine / 2
        let major = sunDiameter * incidence / (refractiveIndex * cosine) * depth / (cosine * cosine) / 2
        let horizontal = SIMD2(direction.x, direction.y)
        let along = (horizontal * horizontal).sum() > 1e-12 ? horizontal / (horizontal * horizontal).sum().squareRoot() : SIMD2(1, 0)
        let (a, b) = (major * major / 4, minor * minor / 4)
        return (a * along.x * along.x + b * along.y * along.y, (a - b) * along.x * along.y, a * along.y * along.y + b * along.x * along.x)
    }

    // MARK: - Drawing

    public func render(_ frame: FrameState, view: DisplayView, encoder: any EffectEncoder) throws {
        guard let light = Self.lightSource(frame) else { return }
        let strength = Self.strength(frame)
        let dark = frame.appearance == .dark
        let peak = Self.peak(frame, isMoon: light.isMoon) * strength
        guard peak > 0 else { return }

        let depth = Self.bounded(frame.number("waterDepth", default: 28), 10...60) * 10   // mm
        let count = Int(Self.bounded(frame.number("waves", default: 12), 3...16).rounded())
        let slope = Self.bounded(frame.number("slope", default: 0.07), 0...0.2)
        let waves = WaveField.deepened(WaveField.windy(WaveField.waves(count: count, slope: slope, seed: frame.seed),
                                                       wind: frame.environment.wind.velocity),
                                       depth: frame.depth.isFinite ? frame.depth : 0)
        let phases = WaveField.phases(waves, time: WaveField.flow(time: frame.environment.wind.time, seed: frame.seed))
        let direction = Self.refractedDirection(light.position)
        let sun = Self.sunCovariance(direction: direction, incident: Self.incidentDirection(light.position), depth: depth)

        // The floor under this display, and the surface patch whose light can land on it: shifted
        // against the slanting light, and wider by how far a sloping surface can bend it.
        let millimetresPerPoint = view.millimetresPerPixel * view.scale
        let floorOrigin = SIMD2(view.frameInDesktop.minX, view.frameInDesktop.minY) * Self.desktopMillimetresPerPoint
        let floorSize = SIMD2(view.frameInDesktop.width, view.frameInDesktop.height) * millimetresPerPoint
        let shift = SIMD2(direction.x, direction.y) / max(-direction.z, 0.05) * depth
        // As far as the steepest likely surface (three times the mean slope, a full gust on top)
        // can bend the light at this sun, plus a little for the splats' own width.
        let steepest = slope * 3 * 1.3 * (1 + Self.gustGain)
        let bent = Self.deflection(incident: Self.incidentDirection(light.position), slope: steepest, depth: depth)
        // A surface point lights the floor at p + shift + bend, so the points to draw run from
        // the floor's origin minus the largest bend to its far edge minus the smallest.
        let margin = SIMD2<Double>(6, 6)
        // The surface points sit on one grid fixed to the water, whatever the display: moving a
        // display moves which points are drawn, not where they are.
        let regionOrigin = ((floorOrigin - shift - bent.high - margin) / Self.spacing).rounded(.down) * Self.spacing
        let regionSize = floorOrigin + floorSize - shift - bent.low + margin - regionOrigin + Self.spacing
        let extent = regionSize / Self.spacing
        guard extent.x.isFinite, extent.y.isFinite, extent.x * extent.y <= Double(Self.pointCapacity) else {
            throw CausticsError("a display of \(Int(floorSize.x)) × \(Int(floorSize.y)) mm is too large for the water")
        }
        let columns = Int(extent.x.rounded(.up)), rows = Int(extent.y.rounded(.up))

        let size = SIMD2((view.pixelSize.x + Self.reduction - 1) / Self.reduction, (view.pixelSize.y + Self.reduction - 1) / Self.reduction)
        let texel = floorSize.x / Double(size.x)
        let target = try illuminanceTexture(display: view.id, size: size)

        var packed = [SIMD4<Float>](repeating: .zero, count: Self.waveCapacity)
        var packedPhases = [Float](repeating: 0, count: Self.waveCapacity)
        var packedGains = [Float](repeating: 0, count: Self.waveCapacity)
        // Gusts join as nagi deepens, with the short ripples (30–50 s, M4-PLAN 4); under Reduce
        // Motion they stir the water half as much (the wind's clock is slowed too).
        let gustGain = Self.gustGain * Self.smooth(30, 50, frame.depth.isFinite ? frame.depth : 0)
            * (frame.accessibility.reduceMotion ? 0.5 : 1)
        for (index, wave) in waves.prefix(Self.waveCapacity).enumerated() {
            packed[index] = SIMD4(Float(wave.direction.x), Float(wave.direction.y), Float(wave.number), Float(wave.amplitude))
            packedPhases[index] = Float(phases[index])
            packedGains[index] = Float(gustGain * (0.2 + 0.8 * WaveField.shortness(wave)))
        }
        func four(_ values: [Float], _ i: Int) -> SIMD4<Float> { SIMD4(values[i], values[i + 1], values[i + 2], values[i + 3]) }
        func phase(_ i: Int) -> SIMD4<Float> { four(packedPhases, i) }
        let wind = frame.environment.wind
        var gustSlots = [SIMD4<Float>](repeating: .zero, count: Self.maxGusts)
        for (index, gust) in wind.gusts.prefix(Self.maxGusts).enumerated() {
            gustSlots[index] = SIMD4(Float(gust.onset - wind.time), Float(gust.rise), Float(gust.duration), Float(gust.strength))
        }
        var uniforms = SplatUniforms(
            grid: SIMD4(Float(regionOrigin.x), Float(regionOrigin.y), Float(Self.spacing), Float(columns)),
            target: SIMD4(Float(floorOrigin.x), Float(floorOrigin.y), Float(texel), Float(waves.count)),
            light: SIMD4(SIMD3<Float>(Self.incidentDirection(light.position)), Float(depth)),
            // A texel's own width keeps every splat at least a texel or so across.
            sun: SIMD4(Float(sun.xx), Float(sun.xy), Float(sun.yy), Float(max(texel * texel * 0.36, Self.spacing * Self.spacing * 0.36))),
            waves: (packed[0], packed[1], packed[2], packed[3], packed[4], packed[5], packed[6], packed[7],
                    packed[8], packed[9], packed[10], packed[11], packed[12], packed[13], packed[14], packed[15]),
            phases: (phase(0), phase(4), phase(8), phase(12)),
            gustGains: (four(packedGains, 0), four(packedGains, 4), four(packedGains, 8), four(packedGains, 12)),
            front: SIMD4(Float(wind.frontDirection.x), Float(wind.frontDirection.y), Float(Wind.frontSpeed),
                         Float(min(wind.gusts.count, Self.maxGusts))),
            gusts: (gustSlots[0], gustSlots[1], gustSlots[2], gustSlots[3], gustSlots[4], gustSlots[5], gustSlots[6], gustSlots[7]))

        var points = SIMD2<UInt32>(UInt32(columns + 1), UInt32(rows + 1))
        let landing = try landingBuffer(display: view.id, count: (columns + 1) * (rows + 1))
        encoder.compute { compute in
            compute.setComputePipelineState(landingPipeline)
            compute.setBytes(&uniforms, length: MemoryLayout<SplatUniforms>.stride, index: 0)
            compute.setBuffer(landing, offset: 0, index: 1)
            compute.setBytes(&points, length: MemoryLayout<SIMD2<UInt32>>.stride, index: 2)
            compute.dispatchThreads(MTLSize(width: columns + 1, height: rows + 1, depth: 1),
                                    threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        var textureSize = SIMD2<Float>(Float(size.x), Float(size.y))
        encoder.render(to: pass) { splat in
            splat.setRenderPipelineState(splatPipeline)
            splat.setVertexBytes(&uniforms, length: MemoryLayout<SplatUniforms>.stride, index: 0)
            splat.setVertexBytes(&textureSize, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
            splat.setVertexBuffer(landing, offset: 0, index: 2)
            splat.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: columns * rows)
        }

        // Clouds melt the net towards its mean (D20). Entry and exit do not, unlike komorebi's
        // (D23): the net comes and goes with presence alone. Water has no uniform shade to show
        // first, and with presence² it stayed invisible for two seconds after "see it now"; an
        // exit-only melt would make the net jump when input cuts an entry short (2026-11-21).
        let hidden = min(max(frame.environment.sunOcclusion, 0), 1)
        // A low sun or a setting moon fades the whole overlay, so its last frame is clear.
        let shown = peak * light.weight
        let colour: SIMD3<Float> = switch (dark, light.isMoon) {
        case (true, false): Self.sunColour(kelvin: frame.environment.sunColorTemperature)
        case (false, false): SIMD3(0.0, 0.010, 0.016)   // near-black, a little blue-green
        case (true, true): SIMD3(0.65, 0.76, 0.90)
        case (false, true): SIMD3(0.003, 0.008, 0.018)
        }
        var composite = CompositeUniforms(
            output: SIMD4(Float(shown), dark ? 1 : 0, Float(Self.bounded(frame.number("exposure", default: 1.2), 0.3...4)), Float(hidden)),
            colour: SIMD4(colour, 0))
        let mean = try meanBuffer(display: view.id)
        if hidden > 0 {
            encoder.compute { compute in
                compute.setComputePipelineState(meanPipeline)
                compute.setTexture(target, index: 0)
                compute.setSamplerState(sampler, index: 0)
                compute.setBytes(&composite, length: MemoryLayout<CompositeUniforms>.stride, index: 0)
                compute.setBuffer(mean, offset: 0, index: 1)
                compute.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1),
                                             threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
            }
        }
        encoder.renderToOutput { output in
            output.setRenderPipelineState(compositePipeline)
            output.setFragmentTexture(target, index: 0)
            output.setFragmentSamplerState(sampler, index: 0)
            output.setFragmentBytes(&composite, length: MemoryLayout<CompositeUniforms>.stride, index: 0)
            output.setFragmentBuffer(mean, offset: 0, index: 1)
            output.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
    }

    private func meanBuffer(display: UInt32) throws -> any MTLBuffer {
        if let buffer = means[display] { return buffer }
        guard let buffer = device.makeBuffer(length: MemoryLayout<Float>.stride, options: .storageModePrivate) else {
            throw CausticsError("could not make the mean buffer")
        }
        means[display] = buffer
        return buffer
    }

    private func landingBuffer(display: UInt32, count: Int) throws -> any MTLBuffer {
        let length = count * MemoryLayout<SIMD2<Float>>.stride
        if let buffer = landings[display], buffer.length >= length { return buffer }
        guard let buffer = device.makeBuffer(length: length, options: .storageModePrivate) else {
            throw CausticsError("no landing buffer")
        }
        landings[display] = buffer
        return buffer
    }

    private func illuminanceTexture(display: UInt32, size: SIMD2<Int>) throws -> any MTLTexture {
        if let texture = illuminance[display], texture.width == size.x, texture.height == size.y { return texture }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: size.x, height: size.y, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared   // unified memory: tests read it back
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw CausticsError("no illuminance texture") }
        illuminance[display] = texture
        return texture
    }

    static func bounded(_ value: Double, _ range: ClosedRange<Double>) -> Double {
        value.isFinite ? min(max(value, range.lowerBound), range.upperBound) : range.lowerBound
    }

    static func smooth(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = min(max((x - a) / (b - a), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// Linear Display P3 of direct sunlight at a colour temperature, brightest channel 1 (the same
    /// approximation komorebi uses; effects do not share code, SPEC 3.2).
    static func sunColour(kelvin: Double) -> SIMD3<Float> {
        let t = min(max(kelvin, 1500), 6500) / 100
        let red = t <= 66 ? 1.0 : min(1, 1.292936 * pow(t - 60, -0.1332047592))
        let green = t <= 66 ? min(1, max(0, 0.3900815788 * log(t) - 0.6318414438))
            : min(1, 1.129890861 * pow(t - 60, -0.0755148492))
        let blue = t >= 66 ? 1.0 : (t <= 19 ? 0 : min(1, max(0, 0.5432067891 * log(t - 10) - 1.19625408914)))
        func linear(_ v: Double) -> Float { Float(v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)) }
        let srgb = SIMD3(linear(red), linear(green), linear(blue))
        let p3 = SIMD3<Float>(0.8225 * srgb.x + 0.1774 * srgb.y,
                              0.0332 * srgb.x + 0.9669 * srgb.y,
                              0.0171 * srgb.x + 0.0724 * srgb.y + 0.9108 * srgb.z)
        return p3 / max(p3.max(), 1e-6)
    }
}

struct CausticsError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}
