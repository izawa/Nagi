import Metal
import Testing
@testable import KomorebiEffect

/// The wind moves openings by less than a mask texel (DECISIONS D19). The light through them must
/// not depend on where they sit within a texel, or every sun disk would shimmer as it sways.
struct MotionTests {
    let device = MTLCreateSystemDefaultDevice()!
    let size = 64
    let stride: Float = 10  // millimetres per texel, as coarse as an evening sun

    /// The light the openings add over a closed crown, or the shade leaves take from open sky,
    /// summed over the mask (texels × transmission, green channel).
    func light(_ gaps: [Leaf], kind: LayerStyle.Kind = .gaps) throws -> Float {
        let library = try device.makeDefaultLibrary(bundle: Bundle.module)
        let pipeline = try Komorebi.maskPipeline(kind, device: device, library: library)
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: size, height: size, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .shared
        let mask = device.makeTexture(descriptor: d)!
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = mask
        pass.colorAttachments[0].loadAction = .clear
        let floor = kind == .gaps ? LayerStyle.crownTransmission : SIMD3<Float>(1, 1, 1)
        pass.colorAttachments[0].clearColor = MTLClearColor(red: Double(floor.x), green: Double(floor.y),
                                                            blue: Double(floor.z), alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        var uniforms = MaskUniforms(axes: SIMD4(1, 0, 0, 1), originSize: SIMD4(0, 0, Float(size), Float(size)),
                                    strideOffset: SIMD4(stride, 0, 0, 1))
        var sway = SwayUniforms()
        let queue = device.makeCommandQueue()!, buffer = queue.makeCommandBuffer()!
        let render = buffer.makeRenderCommandEncoder(descriptor: pass)!
        render.setRenderPipelineState(pipeline)
        render.setVertexBytes(gaps, length: MemoryLayout<Leaf>.stride * gaps.count, index: 0)
        render.setVertexBytes(&uniforms, length: MemoryLayout<MaskUniforms>.stride, index: 1)
        render.setVertexBytes(&sway, length: MemoryLayout<SwayUniforms>.stride, index: 2)
        render.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: gaps.count)
        render.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()
        var texels = [Float16](repeating: 0, count: size * size * 4)
        texels.withUnsafeMutableBytes {
            mask.getBytes($0.baseAddress!, bytesPerRow: size * 8, from: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0)
        }
        return Swift.stride(from: 1, to: texels.count, by: 4).reduce(0) { $0 + abs(Float(texels[$1]) - floor.y) }
    }

    /// Slides the openings across one texel in eighths and returns the spread of their light
    /// relative to its mean.
    func spread(_ gaps: [Leaf], kind: LayerStyle.Kind = .gaps) throws -> Float {
        let lights = try (0..<8).map { step in
            try light(gaps.map {
                var moved = $0
                moved.center += SIMD2(Float(step) / 8, Float(step) / 16) * stride
                return moved
            }, kind: kind)
        }
        let mean = lights.reduce(0, +) / Float(lights.count)
        return (lights.max()! - lights.min()!) / mean
    }

    func gap(at x: Float, _ y: Float, half: Float) -> Leaf {
        Leaf(center: SIMD2(x, y) * stride, halfLength: half * stride, halfWidth: 0.8 * half * stride, angle: 0.3,
             transmission: LayerStyle.crownTransmission)
    }

    @Test func subTexelOpeningKeepsItsLight() throws {
        #expect(try spread([gap(at: 32, 32, half: 0.3)]) < 0.01)
    }

    @Test func resolvedOpeningKeepsItsLight() throws {
        #expect(try spread([gap(at: 32, 32, half: 2)]) < 0.01)
    }

    /// Narrow and turned openings near the blob-to-edge change (Codex's review): a 1.8 × 1.1 texel
    /// opening drawn with an edge varied 3.9 %.
    @Test func narrowOpeningsKeepTheirLight() throws {
        for (length, width, angle) in [(1.8, 1.1, 0.0), (2.4, 1.2, 0.0), (3.0, 1.5, 0.7), (4.0, 2.2, 1.2), (6.0, 3.0, 0.3)] {
            let opening = Leaf(center: SIMD2(32, 32) * stride, halfLength: Float(length) * stride,
                               halfWidth: Float(width) * stride, angle: Float(angle),
                               transmission: LayerStyle.crownTransmission)
            #expect(try spread([opening]) < 0.01, "\(length) × \(width)")
        }
    }

    /// Leaves are looser: their pointed tips, and the mask's half floats near 1 (steps of 1/2048,
    /// a few of which make a small leaf's whole shade), leave about 2 %.
    @Test func movingLeavesKeepTheirShade() throws {
        var leaf = gap(at: 32, 32, half: 3)
        leaf.transmission = SIMD3(0.1, 0.1, 0.1)
        #expect(try spread([leaf], kind: .leaves) < 0.025)
        leaf.halfLength = 0.4 * stride
        leaf.halfWidth = 0.15 * stride
        #expect(try spread([leaf], kind: .leaves) < 0.025)
    }

    /// As the sun changes the texel, a shape crosses from a blob to an edge; its light must follow
    /// its area without a step.
    @Test func lightFollowsAreaAcrossSizes() throws {
        // The narrow half-axis is 0.8 of `half`, so this crosses the whole 1.8–2.6 texel blend.
        let ratios = try Swift.stride(from: Float(0.8), through: 3.6, by: 0.1).map { half in
            try light([gap(at: 32, 32, half: half)]) / (Float.pi * half * 0.8 * half * (1 - LayerStyle.crownTransmission.y))
        }
        #expect(ratios.allSatisfy { abs($0 - 1) < 0.03 }, "\(ratios)")
    }

    @Test func splitPairInOneTexelKeepsItsLight() throws {
        let original = gap(at: 32, 32, half: 0.5)
        var random = SplitMix(seed: 3, layer: 0, cx: 0, cy: 0)
        var style = LayerStyle.all[0]
        style.splitChance = 1
        style.splitSeparation = Double(stride) * 0.6...Double(stride) * 0.6
        let pair = Canopy.split(original, heading: 0.4, style: style, scale: 1, random: &random)
        #expect(pair.count == 2)
        #expect(try spread(pair) < 0.01)
        // Openings that share texels keep all their light.
        #expect(abs(try light(pair) / light([original]) - 1) < 0.01)
    }
}
