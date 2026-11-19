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
    private let filter: SunImageFilter
    private let sampler: any MTLSamplerState
    private let white: any MTLTexture
    private var layers: [LayerKey: LayerResources] = [:]

    public init(context: EffectContext) throws {
        device = context.device
        let library = try device.makeDefaultLibrary(bundle: Bundle.module)
        let leaf = MTLRenderPipelineDescriptor()
        leaf.vertexFunction = library.makeFunction(name: "leafVertex")
        leaf.fragmentFunction = library.makeFunction(name: "leafFragment")
        leaf.colorAttachments[0].pixelFormat = .rgba16Float
        // Multiply: the mask starts at 1 (open sky) and each leaf multiplies in its transmission.
        leaf.colorAttachments[0].isBlendingEnabled = true
        leaf.colorAttachments[0].sourceRGBBlendFactor = .destinationColor
        leaf.colorAttachments[0].destinationRGBBlendFactor = .zero
        leaf.colorAttachments[0].sourceAlphaBlendFactor = .zero
        leaf.colorAttachments[0].destinationAlphaBlendFactor = .one
        leafPipeline = try device.makeRenderPipelineState(descriptor: leaf)
        let gap = MTLRenderPipelineDescriptor()
        gap.vertexFunction = library.makeFunction(name: "leafVertex")
        gap.fragmentFunction = library.makeFunction(name: "gapFragment")
        gap.colorAttachments[0].pixelFormat = .rgba16Float
        // Max: an opening raises the crown's transmission towards open sky.
        gap.colorAttachments[0].isBlendingEnabled = true
        gap.colorAttachments[0].rgbBlendOperation = .max
        gap.colorAttachments[0].alphaBlendOperation = .max
        gapPipeline = try device.makeRenderPipelineState(descriptor: gap)
        let composite = MTLRenderPipelineDescriptor()
        composite.vertexFunction = library.makeFunction(name: "komorebiFullscreen")
        composite.fragmentFunction = library.makeFunction(name: "komorebiComposite")
        composite.colorAttachments[0].pixelFormat = context.pixelFormat
        composite.colorAttachments[0].usePremultipliedSourceOver()
        compositePipeline = try device.makeRenderPipelineState(descriptor: composite)
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
        let sun = frame.environment.sun
        guard sun.altitude > Self.cutoffAltitude else { return }
        let clearSky = smoothstep(Self.cutoffAltitude, Self.fadeAltitude, sun.altitude) * (1 - frame.environment.cloudCover)
        let strength = frame.number("strength", default: 1) * (frame.accessibility.reduceStrength ? 0.6 : 1)
        guard clearSky * strength > 0 else { return }

        // Display origins use one desktop-wide scale so neighbouring displays meet in the canopy;
        // positions inside a display use its own pitch (SPEC 3.4).
        let millimetresPerPoint = view.millimetresPerPixel * view.scale
        let origin = SIMD2(view.frameInDesktop.minX, view.frameInDesktop.minY) * Self.desktopMillimetresPerPoint
        let ground = CGRect(x: origin.x, y: origin.y, width: view.frameInDesktop.width * millimetresPerPoint,
                            height: view.frameInDesktop.height * millimetresPerPoint)
        let weights = Self.layerWeights(depth: frame.depth)
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
            encodeMask(resources, style: style, encoder: encoder)
            var uniforms = resources.uniforms
            uniforms.strideOffset.w = Float(weights[index])
            masks.append(uniforms)
            textures.append(resources.filtered)
        }

        let dark = frame.appearance == .dark
        let edr = Self.descriptor.capabilities.contains(.extendedRange) && view.edrHeadroom > 1
        let sunColour = Self.sunColour(kelvin: frame.environment.sunColorTemperature)
        let colour: SIMD3<Float> = dark
            ? sunColour * Float(edr ? min(view.edrHeadroom, frame.number("edrGain", default: 2)) : 1)
            : SIMD3(0.0, 0.006, 0.014)  // near-black, a little green-blue (SPEC 4.1)
        var composite = CompositeUniforms(
            display: SIMD4(Float(origin.x), Float(origin.y), Float(1 / view.scale), Float(millimetresPerPoint)),
            output: SIMD4(Float(frame.number(dark ? "darkAlpha" : "lightAlpha", default: 0.2) * strength),
                          Float(clearSky), dark ? 1 : 0, Float(Self.clamped(frame.number("exposure", default: 12), 1...40, default: 12))),
            colour: SIMD4(colour, Float(frame.number("shadowCurve", default: 0.7))),
            layers: (masks[0], masks[1], masks[2], masks[3]))
        encoder.renderToOutput { pass in
            pass.setRenderPipelineState(compositePipeline)
            for (index, texture) in textures.enumerated() { pass.setFragmentTexture(texture, index: index) }
            pass.setFragmentSamplerState(sampler, index: 0)
            pass.setFragmentBytes(&composite, length: MemoryLayout<CompositeUniforms>.stride, index: 0)
            pass.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
    }

    public func releaseResources() {
        layers.removeAll()
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

    private func encodeMask(_ resources: LayerResources, style: LayerStyle, encoder: any EffectEncoder) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = resources.mask
        pass.colorAttachments[0].loadAction = .clear
        let crown = LayerStyle.crownTransmission
        pass.colorAttachments[0].clearColor = style.kind == .gaps
            ? MTLClearColor(red: Double(crown.x), green: Double(crown.y), blue: Double(crown.z), alpha: 1)
            : MTLClearColor(red: 1, green: 1, blue: 1, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        var uniforms = resources.uniforms
        encoder.render(to: pass) { render in
            guard let leaves = resources.leaves, resources.leafCount > 0 else { return }
            render.setRenderPipelineState(style.kind == .gaps ? gapPipeline : leafPipeline)
            render.setVertexBuffer(leaves, offset: 0, index: 0)
            render.setVertexBytes(&uniforms, length: MemoryLayout<MaskUniforms>.stride, index: 1)
            render.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: resources.leafCount)
        }
        encoder.compute { compute in
            filter.encode(mask: resources.mask, prefix: resources.prefix, filtered: resources.filtered,
                          image: resources.image, into: compute)
        }
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
