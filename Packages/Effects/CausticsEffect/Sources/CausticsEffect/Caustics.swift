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
        ])

    /// Most waves the shader sums.
    static let waveCapacity = 16
    /// The illuminance texture is this many times coarser than the display (M4-PLAN 5).
    static let reduction = 4
    /// Millimetres between the surface points that carry light.
    static let spacing = 1.0
    /// Most surface points a display may use (a 1.5 m × 1 m display at 1 mm).
    static let pointCapacity = 1_500_000
    /// The sun's angular diameter, radians (komorebi's too).
    static let sunDiameter = 0.0093
    static let refractiveIndex = 1.333
    /// Desktop-wide scale for display origins, so neighbouring displays meet in the water.
    static let desktopMillimetresPerPoint = 25.4 / 109
    /// The light rises from 5° to 10° above the horizon (komorebi's, D16).
    static let cutoffAltitude = 5 * Double.pi / 180
    static let fadeAltitude = 10 * Double.pi / 180

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
    }

    struct CompositeUniforms {
        /// Peak alpha × strength, 1 for dark appearance, exposure, contrast (0 flat … 1 full).
        var output: SIMD4<Float>
        /// The colour drawn (premultiplied by alpha in the shader).
        var colour: SIMD4<Float>
    }

    private let device: any MTLDevice
    private let splatPipeline: any MTLRenderPipelineState
    private let compositePipeline: any MTLRenderPipelineState
    private let landingPipeline: any MTLComputePipelineState
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
    }

    /// The last illuminance drawn for a display (tests).
    func lastIlluminance(display: UInt32) -> (any MTLTexture)? { illuminance[display] }

    // MARK: - Light

    /// The sun by day; the moon at night if moonlight is on. Weight 0 … 1 (komorebi's rule, D21).
    static func lightSource(_ frame: FrameState) -> (position: CelestialPosition, weight: Double, isMoon: Bool)? {
        let environment = frame.environment
        let day = smooth(cutoffAltitude, fadeAltitude, environment.sun.altitude)
        if day > 0 { return (environment.sun, day, false) }
        guard frame.flag("moonlight", default: true) else { return nil }
        let darkness = 1 - smooth(-6 * .pi / 180, 0, environment.sun.altitude)
        let lit = (1 - cos(2 * .pi * environment.moonPhase)) / 2
        let weight = darkness * smooth(cutoffAltitude, fadeAltitude, environment.moon.altitude) * max(0, (lit - 0.01) / 0.99)
        return weight > 0 ? (environment.moon, weight, true) : nil
    }

    public static func note(_ frame: FrameState) -> LocalizedStringResource? {
        switch lightSource(frame) {
        case let light? where !light.isMoon: nil
        case let light? where light.weight * frame.number("lightAlpha", default: 0.12) >= 0.02:
            localized("日が沈んでいます。水中の光は月明かりで薄く現れます")
        default: frame.environment.sun.altitude > 0
            ? localized("日が低いので、水中の光は現れません") : localized("日が沈んでいるので、水中の光は現れません")
        }
    }

    /// The direction light travels in the air towards the water (x east, y south, z up), from a
    /// light source at `position`.
    static func incidentDirection(_ position: CelestialPosition) -> SIMD3<Double> {
        let altitude = max(position.altitude, cutoffAltitude)
        return -SIMD3(cos(altitude) * sin(position.azimuth), -cos(altitude) * cos(position.azimuth), sin(altitude))
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
        let strength = frame.number("strength", default: 1) * (frame.accessibility.reduceStrength ? 0.6 : 1)
        let dark = frame.appearance == .dark
        let peak = frame.number(dark ? "darkAlpha" : "lightAlpha", default: dark ? 0.14 : 0.12) * strength
        guard peak > 0 else { return }

        let depth = Self.bounded(frame.number("waterDepth", default: 28), 10...60) * 10   // mm
        let count = Int(Self.bounded(frame.number("waves", default: 12), 3...16).rounded())
        let slope = Self.bounded(frame.number("slope", default: 0.07), 0...0.2)
        let waves = WaveField.windy(WaveField.waves(count: count, slope: slope, seed: frame.seed),
                                    wind: frame.environment.wind.velocity)
        let phases = WaveField.phases(waves, time: frame.environment.wind.time)
        let direction = Self.refractedDirection(light.position)
        let sun = Self.sunCovariance(direction: direction, incident: Self.incidentDirection(light.position), depth: depth)

        // The floor under this display, and the surface patch whose light can land on it: shifted
        // against the slanting light, and wider by how far a sloping surface can bend it.
        let millimetresPerPoint = view.millimetresPerPixel * view.scale
        let floorOrigin = SIMD2(view.frameInDesktop.minX, view.frameInDesktop.minY) * Self.desktopMillimetresPerPoint
        let floorSize = SIMD2(view.frameInDesktop.width, view.frameInDesktop.height) * millimetresPerPoint
        let shift = SIMD2(direction.x, direction.y) / max(-direction.z, 0.05) * depth
        let margin = depth * slope * 3 + 10
        // The surface points sit on one grid fixed to the water, whatever the display: moving a
        // display moves which points are drawn, not where they are.
        let regionOrigin = ((floorOrigin - shift - SIMD2(margin, margin)) / Self.spacing).rounded(.down) * Self.spacing
        let regionSize = floorSize + SIMD2(2 * margin + Self.spacing, 2 * margin + Self.spacing)
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
        for (index, wave) in waves.prefix(Self.waveCapacity).enumerated() {
            packed[index] = SIMD4(Float(wave.direction.x), Float(wave.direction.y), Float(wave.number), Float(wave.amplitude))
            packedPhases[index] = Float(phases[index])
        }
        func phase(_ i: Int) -> SIMD4<Float> { SIMD4(packedPhases[i], packedPhases[i + 1], packedPhases[i + 2], packedPhases[i + 3]) }
        var uniforms = SplatUniforms(
            grid: SIMD4(Float(regionOrigin.x), Float(regionOrigin.y), Float(Self.spacing), Float(columns)),
            target: SIMD4(Float(floorOrigin.x), Float(floorOrigin.y), Float(texel), Float(waves.count)),
            light: SIMD4(SIMD3<Float>(Self.incidentDirection(light.position)), Float(depth)),
            // A texel's own width keeps every splat at least a texel or so across.
            sun: SIMD4(Float(sun.xx), Float(sun.xy), Float(sun.yy), Float(max(texel * texel * 0.36, Self.spacing * Self.spacing * 0.36))),
            waves: (packed[0], packed[1], packed[2], packed[3], packed[4], packed[5], packed[6], packed[7],
                    packed[8], packed[9], packed[10], packed[11], packed[12], packed[13], packed[14], packed[15]),
            phases: (phase(0), phase(4), phase(8), phase(12)))

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

        // Clouds and entry/exit melt the net towards flat water (D20, D23); a low sun or the moon
        // weakens it the same way.
        let cloud = min(max(frame.environment.sunOcclusion, 0), 1)
        let entering = frame.phase == .calm ? 1 : min(max(frame.presence, 0), 1)
        let contrast = (1 - cloud) * entering
        // A low sun or a setting moon fades the whole overlay, so its last frame is clear.
        let shown = peak * light.weight
        let colour: SIMD3<Float> = switch (dark, light.isMoon) {
        case (true, false): Self.sunColour(kelvin: frame.environment.sunColorTemperature)
        case (false, false): SIMD3(0.0, 0.010, 0.016)   // near-black, a little blue-green
        case (true, true): SIMD3(0.65, 0.76, 0.90)
        case (false, true): SIMD3(0.003, 0.008, 0.018)
        }
        var composite = CompositeUniforms(
            output: SIMD4(Float(shown), dark ? 1 : 0, Float(Self.bounded(frame.number("exposure", default: 1.2), 0.3...4)), Float(contrast)),
            colour: SIMD4(colour, 0))
        encoder.renderToOutput { output in
            output.setRenderPipelineState(compositePipeline)
            output.setFragmentTexture(target, index: 0)
            output.setFragmentSamplerState(sampler, index: 0)
            output.setFragmentBytes(&composite, length: MemoryLayout<CompositeUniforms>.stride, index: 0)
            output.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
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
