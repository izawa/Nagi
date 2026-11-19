import CoreGraphics
import Foundation
import Metal
import NagiKit
import simd

/// Komorebi, sunlight through leaves (SPEC 4.1).
///
/// Two crowns (3 m and 1.5 m) and two leaf layers (0.9 m and 0.25 m). Each gap is a pinhole that images the sun's disk, so a
/// layer's occlusion is filtered with the sun's image: a disk 0.0093·h/sin θ across, stretched by
/// 1/sin θ along the azimuth. High layers give soft circles, low leaves sharp shapes. Shallow nagi
/// shows only the high layer; the lower ones come in as it deepens (SPEC 4.1 深まり方).
public final class Komorebi: Effect {
    public static let descriptor = EffectDescriptor(
        id: "komorebi",
        displayName: "木漏れ日",
        summary: "梢の隙間から落ちる日の光",
        layer: .light,
        capabilities: [.extendedRange],
        parameters: [
            ParameterSpec(key: "strength", label: "強さ", kind: .slider(range: 0...1, defaultValue: 1)),
            ParameterSpec(key: "density", label: "樹冠の密度", kind: .slider(range: 0.3...1.5, defaultValue: 1)),
            ParameterSpec(key: "wind", label: "風の強さ", kind: .slider(range: 0...1, defaultValue: 0.5)),
            ParameterSpec(key: "scale", label: "スケール", kind: .slider(range: 0.5...2, defaultValue: 1)),
            ParameterSpec(key: "moonlight", label: "月明かり", kind: .toggle(defaultValue: true)),
            // The strongest moonlight (a full moon high in a dark sky), as alpha: 0.08, where the
            // author could see it in both appearances (DECISIONS D21).
            ParameterSpec(key: "moonAlpha", label: "月明かりの強さ", kind: .slider(range: 0...0.1, defaultValue: 0.08)),
            // Tuned at stop B (M1-PLAN 3): the strongest shadow in light appearance (DECISIONS D3),
            // and the light in dark appearance with its EDR gain cap.
            ParameterSpec(key: "lightAlpha", label: "影の濃さ", kind: .slider(range: 0...0.4, defaultValue: 0.2)),
            ParameterSpec(key: "darkAlpha", label: "光の強さ", kind: .slider(range: 0...0.4, defaultValue: 0.2)),
            ParameterSpec(key: "edrGain", label: "EDR の明るさ", kind: .slider(range: 1...4, defaultValue: 2)),
            // Multiplies every canopy height: the sun disks scale with it.
            ParameterSpec(key: "heightScale", label: "木の高さ", kind: .slider(range: 0.3...1.5, defaultValue: 1)),
            // Below 1 darkens the half-shade between sun and shadow (light appearance, stop B).
            ParameterSpec(key: "shadowCurve", label: "影の階調", kind: .slider(range: 0.3...1.5, defaultValue: 0.7)),
            // How bright a sun disk looks to an eye adapted to the shade: t = 1 − exp(−exposure·T),
            // a soft shoulder, so overlapping disks stay brighter (2026-11-19, replaces stop B's clip at 16).
            ParameterSpec(key: "exposure", label: "木漏れ日の明るさ", kind: .slider(range: 1...40, defaultValue: 12)),
            // How much the sun's image (and an edge's blur) varies over a layer, as leaf heights do.
            ParameterSpec(key: "blurSpread", label: "ぼけの揺らぎ", kind: .slider(range: 0...1.5, defaultValue: 0.6)),
        ]
    )

    /// Below this the sun draws nothing; it fades in up to `fadeAltitude` (radians).
    static let cutoffAltitude = 5.0 * .pi / 180
    static let fadeAltitude = 10.0 * .pi / 180
    /// Millimetres per desktop point for placing displays in the canopy (a Studio Display's pitch).
    static let desktopMillimetresPerPoint = 25.4 / 109

    private let device: any MTLDevice
    private let leafPipeline: any MTLRenderPipelineState
    private let gapPipeline: any MTLRenderPipelineState
    private let compositePipeline: any MTLRenderPipelineState
    private let meanPipeline: any MTLComputePipelineState
    /// Each display's mean clear alpha (one float), written by `komorebiMean` on the GPU.
    private var means: [UInt32: any MTLBuffer] = [:]
    private let filter: SunImageFilter
    private let sampler: any MTLSamplerState
    private let white: any MTLTexture
    private var layers: [LayerKey: LayerResources] = [:]

    public init(context: EffectContext) throws {
        device = context.device
        let library = try device.makeDefaultLibrary(bundle: Bundle.module)
        leafPipeline = try Self.maskPipeline(.leaves, device: device, library: library)
        gapPipeline = try Self.maskPipeline(.gaps, device: device, library: library)
        let composite = MTLRenderPipelineDescriptor()
        composite.vertexFunction = library.makeFunction(name: "komorebiFullscreen")
        composite.fragmentFunction = library.makeFunction(name: "komorebiComposite")
        composite.colorAttachments[0].pixelFormat = context.pixelFormat
        composite.colorAttachments[0].usePremultipliedSourceOver()
        compositePipeline = try device.makeRenderPipelineState(descriptor: composite)
        guard let mean = library.makeFunction(name: "komorebiMean") else { throw KomorebiError("no komorebiMean") }
        meanPipeline = try device.makeComputePipelineState(function: mean)
        filter = try SunImageFilter(device: device, library: library)
        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        sampler = device.makeSamplerState(descriptor: samplerDescriptor)!
        white = try Self.texture(device, size: SIMD2(1, 1), format: .rgba16Float, storage: .shared)
        let one = [Float16](repeating: 1, count: 4)
        one.withUnsafeBytes { white.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 8) }
    }

    public func update(_ frame: FrameState) {
        // Drop the resources of displays that stopped drawing (a display was removed).
        frameCount += 1
        layers = layers.filter { frameCount - $0.value.lastUsed < 120 }
    }

    private var frameCount = 0

    public func render(_ frame: FrameState, view: DisplayView, encoder: any EffectEncoder) throws {
        guard let light = Self.lightSource(frame) else { return }
        let sun = light.position
        // Clouds do not fade the effect: they melt it towards its mean (the composite, DECISIONS D20).
        let clearSky = light.weight
        let strength = frame.number("strength", default: 1) * (frame.accessibility.reduceStrength ? 0.6 : 1)
        let dark = frame.appearance == .dark
        let peak = light.isMoon ? Self.clamped(frame.number("moonAlpha", default: 0.08), 0...0.1, default: 0.08)
            : frame.number(dark ? "darkAlpha" : "lightAlpha", default: 0.2)
        guard clearSky * strength * peak > 0 else { return }

        // Display origins use one desktop-wide scale so neighbouring displays meet in the canopy;
        // positions inside a display use its own pitch (SPEC 3.4).
        let millimetresPerPoint = view.millimetresPerPixel * view.scale
        let origin = SIMD2(view.frameInDesktop.minX, view.frameInDesktop.minY) * Self.desktopMillimetresPerPoint
        let ground = CGRect(x: origin.x, y: origin.y, width: view.frameInDesktop.width * millimetresPerPoint,
                            height: view.frameInDesktop.height * millimetresPerPoint)
        let weights = Self.layerWeights(depth: frame.depth)
        let wind = Self.windUniforms(frame)
        let spread = Float(Self.clamped(frame.number("blurSpread", default: 0.6), 0...1.5, default: 0.6))
        var masks: [MaskUniforms] = []
        var textures: [any MTLTexture] = []
        for (index, style) in LayerStyle.all.enumerated() {
            guard weights[index] > 0 else {
                masks.append(MaskUniforms())
                textures.append(white)
                continue
            }
            let heightScale = Self.clamped(frame.number("heightScale", default: 1), 0.3...1.5, default: 1)
            let geometry = Self.geometry(height: style.height * heightScale, baseStride: style.baseStride * heightScale,
                                         sun: sun, ground: ground, imageScale: Double(exp2(spread)))
            let resources = try prepare(layer: index, style: style, geometry: geometry, ground: ground, frame: frame,
                                        spread: spread, display: view.id)
            encodeMask(resources, style: style, sway: wind.with(style.sway), encoder: encoder)
            var uniforms = resources.uniforms
            uniforms.strideOffset.w = Float(weights[index])
            masks.append(uniforms)
            textures.append(resources.filtered)
        }

        let edr = Self.descriptor.capabilities.contains(.extendedRange) && view.edrHeadroom > 1 && !light.isMoon
        let sunColour = Self.sunColour(kelvin: frame.environment.sunColorTemperature)
        let colour: SIMD3<Float> = switch (dark, light.isMoon) {
        case (true, false): sunColour * Float(edr ? min(view.edrHeadroom, frame.number("edrGain", default: 2)) : 1)
        case (false, false): SIMD3(0.0, 0.006, 0.014)  // near-black, a little green-blue (SPEC 4.1)
        // Moonlight: silver-blue light, a bluer shade; night vision loses colour and leans blue (D21).
        case (true, true): SIMD3(0.65, 0.76, 0.90)
        case (false, true): SIMD3(0.003, 0.008, 0.018)
        }
        var composite = CompositeUniforms(
            display: SIMD4(Float(origin.x), Float(origin.y), Float(1 / view.scale), Float(millimetresPerPoint)),
            output: SIMD4(Float(peak * strength),
                          Float(clearSky), dark ? 1 : 0, Float(Self.clamped(frame.number("exposure", default: 12), 1...40, default: 12))),
            colour: SIMD4(colour, Float(frame.number("shadowCurve", default: 0.7))),
            sky: SIMD4(Float(min(max(frame.environment.sunOcclusion, 0), 1)), Float(view.pixelSize.x),
                       Float(view.pixelSize.y), 0),
            layers: (masks[0], masks[1], masks[2], masks[3]))
        let mean = try meanBuffer(display: view.id)
        if composite.sky.x > 0 {
            encoder.compute { compute in
                compute.setComputePipelineState(meanPipeline)
                for (index, texture) in textures.enumerated() { compute.setTexture(texture, index: index) }
                compute.setSamplerState(sampler, index: 0)
                compute.setBytes(&composite, length: MemoryLayout<CompositeUniforms>.stride, index: 0)
                compute.setBuffer(mean, offset: 0, index: 1)
                compute.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1),
                                             threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
            }
        }
        encoder.renderToOutput { pass in
            pass.setRenderPipelineState(compositePipeline)
            for (index, texture) in textures.enumerated() { pass.setFragmentTexture(texture, index: index) }
            pass.setFragmentSamplerState(sampler, index: 0)
            pass.setFragmentBytes(&composite, length: MemoryLayout<CompositeUniforms>.stride, index: 0)
            pass.setFragmentBuffer(mean, offset: 0, index: 1)
            pass.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
    }

    private func meanBuffer(display: UInt32) throws -> any MTLBuffer {
        if let buffer = means[display] { return buffer }
        guard let buffer = device.makeBuffer(length: MemoryLayout<Float>.stride, options: .storageModePrivate) else {
            throw KomorebiError("could not make the mean buffer")
        }
        means[display] = buffer
        return buffer
    }

    public func releaseResources() {
        layers.removeAll()
        means.removeAll()
    }

    /// How much each layer (the two crowns, middle, low) shows at a given depth (SPEC 4.1 深まり方).
    /// Both crowns always show: a crown left out would read as open sky in the `max`.
    static func layerWeights(depth: Double) -> [Double] {
        [1, 1, smoothstep(10, 25, depth), smoothstep(20, 40, depth)]
    }

    // MARK: - Per layer

    private struct LayerKey: Hashable {
        let display: UInt32
        let layer: Int
    }

    /// What one layer of one display needs this frame; the leaves are kept while their cells,
    /// seed, density and scale stay the same.
    private final class LayerResources {
        var uniforms = MaskUniforms()
        var image = SunImageFilter.Image()
        var mask: any MTLTexture
        var prefix: any MTLTexture
        var filtered: any MTLTexture
        var leaves: (any MTLBuffer)?
        var leafCount = 0
        var leafKey: LeafKey?
        var lastUsed = 0

        init(mask: any MTLTexture, prefix: any MTLTexture, filtered: any MTLTexture) {
            self.mask = mask
            self.prefix = prefix
            self.filtered = filtered
        }
    }

    private struct LeafKey: Equatable {
        let cells: [Int]
        let seed: UInt64
        let density: Double
        let scale: Double
    }

    /// The layer's geometry, with the mask texel widened when the mask would pass `maxMaskTexels`
    /// (a wide display under a high sun), so the whole display keeps its canopy.
    static func geometry(height: Double, baseStride: Double, sun: CelestialPosition, ground: CGRect,
                         imageScale: Double) -> LayerGeometry {
        let geometry = LayerGeometry(height: height, altitude: sun.altitude, azimuth: sun.azimuth, baseStride: baseStride)
        // A rotated rectangle spans at most width + height along either mask axis.
        let bounds = geometry.layerBounds(forGround: ground, imageScale: imageScale)
        let needed = (bounds.width + bounds.height) / Double(maxMaskTexels - 8)
        guard needed > geometry.stride else { return geometry }
        return LayerGeometry(height: height, altitude: sun.altitude, azimuth: sun.azimuth, baseStride: needed)
    }

    static let maxMaskTexels = 4096

    private func prepare(layer: Int, style: LayerStyle, geometry: LayerGeometry, ground: CGRect, frame: FrameState,
                         spread: Float, display: UInt32) throws -> LayerResources {
        let bounds = geometry.layerBounds(forGround: ground, imageScale: Double(exp2(spread)))
        let corners = [CGPoint(x: bounds.minX, y: bounds.minY), CGPoint(x: bounds.maxX, y: bounds.minY),
                       CGPoint(x: bounds.minX, y: bounds.maxY), CGPoint(x: bounds.maxX, y: bounds.maxY)]
            .map { geometry.maskCoordinates(ofLayer: SIMD2($0.x, $0.y)) }
        let low = corners.reduce(corners[0]) { simd_min($0, $1) }.rounded(.down)
        let high = corners.reduce(corners[0]) { simd_max($0, $1) }.rounded(.up)
        let size = SIMD2(Int(min(high.x - low.x, Double(Self.maxMaskTexels))), Int(min(high.y - low.y, Double(Self.maxMaskTexels))))

        let key = LayerKey(display: display, layer: layer)
        let resources: LayerResources
        if let existing = layers[key], existing.mask.width == size.x, existing.mask.height == size.y {
            resources = existing
        } else {
            resources = LayerResources(
                mask: try Self.texture(device, size: size, format: .rgba16Float),
                prefix: try Self.texture(device, size: SIMD2(size.x + 1, size.y), format: .rgba32Float),
                filtered: try Self.texture(device, size: size, format: .rgba16Float))
            layers[key] = resources
        }
        resources.lastUsed = frameCount
        resources.uniforms = MaskUniforms(
            axes: SIMD4(Float(geometry.across.x), Float(geometry.across.y), Float(geometry.along.x), Float(geometry.along.y)),
            originSize: SIMD4(Float(low.x), Float(low.y), Float(size.x), Float(size.y)),
            strideOffset: SIMD4(Float(geometry.stride), Float(geometry.offset.x), Float(geometry.offset.y), 1))
        resources.image = SunImageFilter.Image(
            semiAxes: SIMD2(Float(geometry.semiAcross), Float(geometry.semiAlong)),
            origin: SIMD2(Float(low.x), Float(low.y)), stride: Float(geometry.stride),
            spread: spread)

        let density = Self.clamped(frame.number("density", default: 1), 0...3, default: 1)
        let scale = Self.clamped(frame.number("scale", default: 1), 0.25...4, default: 1)
        let cells = Canopy.cellRange(bounds, style: style, scale: scale)
        let leafKey = LeafKey(cells: [cells.x.lowerBound, cells.x.upperBound, cells.y.lowerBound, cells.y.upperBound],
                              seed: frame.seed, density: density, scale: scale)
        if resources.leafKey != leafKey {
            let leaves = Canopy.leaves(in: bounds, layer: layer, style: style, seed: frame.seed, density: density, scale: scale)
            resources.leafCount = leaves.count
            resources.leaves = leaves.isEmpty ? nil
                : leaves.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }
            resources.leafKey = leafKey
        }
        return resources
    }

    private func encodeMask(_ resources: LayerResources, style: LayerStyle, sway: SwayUniforms,
                            encoder: any EffectEncoder) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = resources.mask
        pass.colorAttachments[0].loadAction = .clear
        let crown = LayerStyle.crownTransmission
        pass.colorAttachments[0].clearColor = style.kind == .gaps
            ? MTLClearColor(red: Double(crown.x), green: Double(crown.y), blue: Double(crown.z), alpha: 1)
            : MTLClearColor(red: 1, green: 1, blue: 1, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        var uniforms = resources.uniforms
        var sway = sway
        encoder.render(to: pass) { render in
            guard let leaves = resources.leaves, resources.leafCount > 0 else { return }
            render.setRenderPipelineState(style.kind == .gaps ? gapPipeline : leafPipeline)
            render.setVertexBuffer(leaves, offset: 0, index: 0)
            render.setVertexBytes(&uniforms, length: MemoryLayout<MaskUniforms>.stride, index: 1)
            render.setVertexBytes(&sway, length: MemoryLayout<SwayUniforms>.stride, index: 2)
            render.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: resources.leafCount)
        }
        encoder.compute { compute in
            filter.encode(mask: resources.mask, prefix: resources.prefix, filtered: resources.filtered,
                          image: resources.image, into: compute)
        }
    }

    /// The pipeline that draws a layer's shapes into its mask.
    static func maskPipeline(_ kind: LayerStyle.Kind, device: any MTLDevice,
                             library: any MTLLibrary) throws -> any MTLRenderPipelineState {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "leafVertex")
        descriptor.colorAttachments[0].pixelFormat = .rgba16Float
        descriptor.colorAttachments[0].isBlendingEnabled = true
        switch kind {
        case .leaves:
            // Multiply: the mask starts at 1 (open sky) and each leaf multiplies in its transmission.
            descriptor.fragmentFunction = library.makeFunction(name: "leafFragment")
            descriptor.colorAttachments[0].sourceRGBBlendFactor = .destinationColor
            descriptor.colorAttachments[0].destinationRGBBlendFactor = .zero
            descriptor.colorAttachments[0].sourceAlphaBlendFactor = .zero
            descriptor.colorAttachments[0].destinationAlphaBlendFactor = .one
        case .gaps:
            // Add: an opening adds the light it lets through to the crown's transmission.
            descriptor.fragmentFunction = library.makeFunction(name: "gapFragment")
            descriptor.colorAttachments[0].sourceRGBBlendFactor = .one
            descriptor.colorAttachments[0].destinationRGBBlendFactor = .one
            descriptor.colorAttachments[0].sourceAlphaBlendFactor = .zero
            descriptor.colorAttachments[0].destinationAlphaBlendFactor = .one
        }
        return try device.makeRenderPipelineState(descriptor: descriptor)
    }

    // MARK: - Light source

    /// What lights the canopy: the sun by day; at night, if moonlight is on, the moon (DECISIONS
    /// D21), weighted by how dark the sky is (it comes in through civil twilight), how high the
    /// moon is (the same 5–10° fade as the sun) and how much of it is lit. Nil when nothing does.
    static func lightSource(_ frame: FrameState) -> (position: CelestialPosition, weight: Double, isMoon: Bool)? {
        let environment = frame.environment
        let day = smoothstep(cutoffAltitude, fadeAltitude, environment.sun.altitude)
        if day > 0 { return (environment.sun, day, false) }
        guard frame.flag("moonlight", default: true) else { return nil }
        let degree = Double.pi / 180
        let darkness = 1 - smoothstep(-6 * degree, 0, environment.sun.altitude)
        let lit = (1 - cos(2 * .pi * environment.moonPhase)) / 2
        // Clear around new moon: under 1 % lit counts as dark, without a step.
        let phase = max(0, (lit - 0.01) / 0.99)
        let weight = darkness * smoothstep(cutoffAltitude, fadeAltitude, environment.moon.altitude) * phase
        return weight > 0 ? (environment.moon, weight, true) : nil
    }

    // MARK: - Wind

    /// The waves of the three tiers (SPEC 4.1: trunk 0.1–0.3 Hz, branch 0.5–1 Hz, leaf 2–5 Hz),
    /// spaced by powers of the golden ratio, so no two share a period (and all of them never
    /// realign) however long the wind blows.
    static let golden = (1 + 5.0.squareRoot()) / 2
    static let trunkWaves = 0.11 * SIMD3<Double>(1, golden, golden * golden)
    static let branchWaves = 0.53 * SIMD3<Double>(1, golden.squareRoot(), golden)
    static let flutterWaves = 2.2 * SIMD3<Double>(1, golden.squareRoot(), golden)
    /// The mean wind that gives the full response without a gust, metres per second.
    static let fullWind = 3.5

    /// This frame's wind for the leaf shader, before the layer's amplitudes (DECISIONS D19). The
    /// phases are taken modulo one cycle in double precision, so a long-running wind clock does
    /// not make the waves stutter.
    static func windUniforms(_ frame: FrameState) -> SwayUniforms {
        let wind = frame.environment.wind
        // The slider runs linearly from a light stir (0) through the author's choice (0.5) to
        // half as much again (1); the canopy never stands quite still (DECISIONS D19).
        let slider = clamped(frame.number("wind", default: 0.5), 0...1, default: 0.5)
        let gain = (0.25 + 0.5 * slider) * (frame.accessibility.reduceMotion ? 0.25 : 1)
        let speed = simd_length(wind.velocity)
        let along = speed > 1e-6 ? wind.velocity / speed : wind.frontDirection
        func phases(_ waves: SIMD3<Double>) -> SIMD4<Float> {
            let cycles = waves * wind.time
            return SIMD4(SIMD3<Float>(cycles - cycles.rounded(.down)), 0)
        }
        var uniforms = SwayUniforms()
        uniforms.direction = SIMD4(Float(along.x), Float(along.y), Float(wind.frontDirection.x), Float(wind.frontDirection.y))
        let gusts = wind.gusts.prefix(SwayUniforms.maxGusts)
        uniforms.strength = SIMD4(Float(gain), Float(min(speed / fullWind, 1)), Float(Wind.frontSpeed), Float(gusts.count))
        uniforms.trunk = phases(trunkWaves)
        uniforms.branch = phases(branchWaves)
        uniforms.flutter = phases(flutterWaves)
        withUnsafeMutableBytes(of: &uniforms.gusts) { raw in
            let slots = raw.bindMemory(to: SIMD4<Float>.self)
            for (index, gust) in gusts.enumerated() {
                slots[index] = SIMD4(Float(gust.onset - wind.time), Float(gust.rise), Float(gust.duration), Float(gust.strength))
            }
        }
        return uniforms
    }

    // MARK: - Helpers

    static func clamped(_ value: Double, _ range: ClosedRange<Double>, default fallback: Double) -> Double {
        value.isFinite ? min(max(value, range.lowerBound), range.upperBound) : fallback
    }

    static func texture(_ device: any MTLDevice, size: SIMD2<Int>, format: MTLPixelFormat,
                        storage: MTLStorageMode = .private) throws -> any MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: max(size.x, 1),
                                                                  height: max(size.y, 1), mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead, .shaderWrite]
        descriptor.storageMode = storage
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw KomorebiError("could not make a \(size.x)×\(size.y) texture")
        }
        return texture
    }

    /// Linear RGB of direct sunlight at a colour temperature, normalised so the brightest
    /// channel is 1 (a smooth approximation of the Planckian locus; enough for warm evenings).
    static func sunColour(kelvin: Double) -> SIMD3<Float> {
        let t = min(max(kelvin, 1500), 6500) / 100
        let red = t <= 66 ? 1.0 : min(1, 1.292936 * pow(t - 60, -0.1332047592))
        let green = t <= 66 ? min(1, max(0, 0.3900815788 * log(t) - 0.6318414438))
            : min(1, 1.129890861 * pow(t - 60, -0.0755148492))
        let blue = t >= 66 ? 1.0 : (t <= 19 ? 0 : min(1, max(0, 0.5432067891 * log(t - 10) - 1.19625408914)))
        // The fit is in sRGB-encoded values; decode to linear.
        func linear(_ v: Double) -> Float { Float(v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)) }
        let srgb = SIMD3(linear(red), linear(green), linear(blue))
        // Linear sRGB to linear Display P3 (the working space, SPEC 3.5).
        let p3 = SIMD3<Float>(0.8225 * srgb.x + 0.1774 * srgb.y,
                              0.0332 * srgb.x + 0.9669 * srgb.y,
                              0.0171 * srgb.x + 0.0724 * srgb.y + 0.9108 * srgb.z)
        return p3 / max(p3.max(), 1e-6)
    }
}

/// Matches `SwayUniforms` in Komorebi.metal.
struct SwayUniforms {
    static let maxGusts = 8
    var direction = SIMD4<Float>(1, 0, 1, 0)
    var strength = SIMD4<Float>(0, 0, 250, 0)
    var amplitude = SIMD4<Float>.zero
    var trunk = SIMD4<Float>.zero
    var branch = SIMD4<Float>.zero
    var flutter = SIMD4<Float>.zero
    var gusts = (SIMD4<Float>.zero, SIMD4<Float>.zero, SIMD4<Float>.zero, SIMD4<Float>.zero,
                 SIMD4<Float>.zero, SIMD4<Float>.zero, SIMD4<Float>.zero, SIMD4<Float>.zero)

    /// The same wind with a layer's amplitudes.
    func with(_ sway: LayerStyle.Sway) -> SwayUniforms {
        var copy = self
        copy.amplitude = SIMD4(Float(sway.trunk), Float(sway.branch), Float(sway.branchTurn * .pi / 180),
                               Float(sway.flutter * .pi / 180))
        return copy
    }
}

/// Matches `MaskUniforms` in Komorebi.metal.
struct MaskUniforms {
    var axes = SIMD4<Float>(1, 0, 0, 1)
    var originSize = SIMD4<Float>(0, 0, 1, 1)
    var strideOffset = SIMD4<Float>(1, 0, 0, 0)
}

/// Matches `CompositeUniforms` in Komorebi.metal.
struct CompositeUniforms {
    var display: SIMD4<Float>
    var output: SIMD4<Float>
    var colour: SIMD4<Float>
    var sky: SIMD4<Float>
    var layers: (MaskUniforms, MaskUniforms, MaskUniforms, MaskUniforms)
}

struct KomorebiError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
    let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
    return t * t * (3 - 2 * t)
}
