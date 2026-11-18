import Foundation
import Metal
import Testing
@testable import KomorebiEffect

/// The pinhole physics of SPEC 4.1, checked by numbers (M1-PLAN 5).
struct PhysicsTests {
    let device = MTLCreateSystemDefaultDevice()!

    /// Runs the sun-image filter on a single-channel mask (row-major, top row first).
    func filter(_ mask: [Float], width: Int, height: Int, semiAxes: SIMD2<Float>) throws -> [Float] {
        let library = try device.makeDefaultLibrary(bundle: Bundle.module)
        let filter = try SunImageFilter(device: device, library: library)
        func texture(_ w: Int, _ format: MTLPixelFormat) -> any MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: w, height: height, mipmapped: false)
            d.usage = [.shaderRead, .shaderWrite]
            d.storageMode = .shared
            return device.makeTexture(descriptor: d)!
        }
        let input = texture(width, .rgba16Float), prefix = texture(width + 1, .rgba32Float), output = texture(width, .rgba16Float)
        var halves = [Float16]()
        halves.reserveCapacity(mask.count * 4)
        for value in mask { halves += [Float16(value), Float16(value), Float16(value), 1] }
        halves.withUnsafeBytes {
            input.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: width * 8)
        }
        let queue = device.makeCommandQueue()!, buffer = queue.makeCommandBuffer()!, compute = buffer.makeComputeCommandEncoder()!
        filter.encode(mask: input, prefix: prefix, filtered: output, image: SunImageFilter.Image(semiAxes: semiAxes),
                      into: compute)
        compute.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()
        #expect(buffer.error == nil)
        var out = [Float16](repeating: 0, count: width * height * 4)
        out.withUnsafeMutableBytes {
            output.getBytes($0.baseAddress!, bytesPerRow: width * 8, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        return stride(from: 0, to: out.count, by: 4).map { Float(out[$0]) }
    }

    /// A one-texel opening becomes the sun's image: an ellipse with the given semi-axes, flat inside,
    /// and the light through the opening is conserved.
    @Test func pinholeMakesAFlatEllipse() throws {
        let width = 161, height = 161, a: Float = 12, b: Float = 30
        var mask = [Float](repeating: 0, count: width * height)
        mask[80 * width + 80] = 1
        let image = try filter(mask, width: width, height: height, semiAxes: SIMD2(a, b))
        let peak = image.max()!
        let lit = image.enumerated().filter { $0.element > peak / 2 }.map { (x: $0.offset % width, y: $0.offset / width) }
        let spanX = lit.map(\.x).max()! - lit.map(\.x).min()! + 1
        let spanY = lit.map(\.y).max()! - lit.map(\.y).min()! + 1
        #expect(abs(Float(spanX) - 2 * a) <= 2, "across \(spanX)")
        #expect(abs(Float(spanY) - 2 * b) <= 2, "along \(spanY)")
        // Flat inside 75 % of the radius.
        let inner = (0..<(width * height)).filter {
            let dx = Float($0 % width - 80) / a, dy = Float($0 / width - 80) / b
            return dx * dx + dy * dy < 0.75 * 0.75
        }.map { image[$0] }
        #expect((inner.max()! - inner.min()!) / inner.max()! < 0.01, "inner spread \(inner.min()!) … \(inner.max()!)")
        // Conserved: the image sums to the opening (1 texel).
        #expect(abs(image.reduce(0, +) - 1) < 0.03, "sum \(image.reduce(0, +))")
    }

    /// A flat mask stays flat everywhere, edges included.
    @Test func flatStaysFlat() throws {
        let image = try filter([Float](repeating: 0.5, count: 40 * 40), width: 40, height: 40, semiAxes: SIMD2(5, 9))
        #expect(image.allSatisfy { abs($0 - 0.5) < 0.002 })
    }

    /// The mean transmission over the screen does not change with the blur.
    @Test func filterKeepsTheMean() throws {
        let width = 200, height = 200
        var random = SplitMix(seed: 7, layer: 0, cx: 0, cy: 0)
        let mask = (0..<(width * height)).map { _ in Float(random.unit() < 0.3 ? 1 : 0.1) }
        let image = try filter(mask, width: width, height: height, semiAxes: SIMD2(6, 9))
        func interiorMean(_ values: [Float]) -> Float {
            let inside = (0..<(width * height)).filter { ($0 % width) >= 20 && ($0 % width) < 180 && $0 / width >= 20 && $0 / width < 180 }
            return inside.map { values[$0] }.reduce(0, +) / Float(inside.count)
        }
        #expect(abs(interiorMean(image) - interiorMean(mask)) / interiorMean(mask) < 0.01)
    }

    /// Disk 0.0093·h/sin θ across, stretched by 1/sin θ along the azimuth (SPEC 4.1).
    @Test func sunImageSize() {
        let zenith = LayerGeometry(height: 10, altitude: .pi / 2, azimuth: 0, baseStride: 1, texelsAlong: 1000)
        #expect(abs(2 * zenith.semiAcross * zenith.stride - 93) < 0.01)
        #expect(abs(zenith.semiAlong / zenith.semiAcross - 1) < 1e-9)
        let low = LayerGeometry(height: 10, altitude: .pi / 6, azimuth: 1, baseStride: 1, texelsAlong: 1000)
        #expect(abs(2 * low.semiAcross * low.stride - 186) < 0.01)
        #expect(abs(low.semiAlong / low.semiAcross - 2) < 1e-9)
        // At 218 ppi the zenith disk of a 10 m gap is about 800 px.
        #expect(abs(93 / (25.4 / 218) - 798) < 1)
    }

    /// The shadow falls away from the sun: with the sun in the east, shadows shift west (−x).
    @Test func shadowFallsAwayFromTheSun() {
        let east = LayerGeometry(height: 4, altitude: .pi / 4, azimuth: .pi / 2, baseStride: 1)
        #expect(east.offset.x < 0 && abs(east.offset.y) < 1e-9)
        #expect(abs(east.offset.x + 4000) < 0.01)  // h·cot 45° = 4 m
    }

    /// The mask covers the layer region that lights the screen: every ground corner maps inside it.
    @Test func maskBoundsCoverTheGround() {
        let geometry = LayerGeometry(height: 10, altitude: 0.5, azimuth: 2.5, baseStride: 4)
        let ground = CGRect(x: 0, y: 0, width: 600, height: 340)
        let bounds = geometry.layerBounds(forGround: ground)
        for corner in [SIMD2(0.0, 0.0), SIMD2(600.0, 0.0), SIMD2(0.0, 340.0), SIMD2(600.0, 340.0)] {
            let layerPoint = corner - geometry.offset
            #expect(bounds.contains(CGPoint(x: layerPoint.x, y: layerPoint.y)))
        }
    }
}
