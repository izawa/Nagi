import CoreGraphics
import Foundation
import Metal
import NagiKit
import Testing
@testable import CausticsEffect

/// The light-carrying splats (M4-PLAN 5): light is neither lost nor gained where it lands, flat
/// water is flat, and a spread-out patch shows no grain of separate points.
@MainActor struct CausticsTests {
    let device = MTLCreateSystemDefaultDevice()!

    final class Encoder: EffectEncoder {
        let commandBuffer: any MTLCommandBuffer
        let output: any MTLTexture
        init(commandBuffer: any MTLCommandBuffer, output: any MTLTexture) {
            self.commandBuffer = commandBuffer
            self.output = output
        }
        var outputSize: SIMD2<Int> { SIMD2(output.width, output.height) }
        func renderToOutput(_ body: (any MTLRenderCommandEncoder) throws -> Void) rethrows {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = output
            pass.colorAttachments[0].loadAction = .load
            pass.colorAttachments[0].storeAction = .store
            try render(to: pass, body)
        }
        func render(to pass: MTLRenderPassDescriptor, _ body: (any MTLRenderCommandEncoder) throws -> Void) rethrows {
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
            defer { encoder.endEncoding() }
            try body(encoder)
        }
        func compute(_ body: (any MTLComputeCommandEncoder) throws -> Void) rethrows {
            guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
            defer { encoder.endEncoding() }
            try body(encoder)
        }
    }

    /// Illuminance under noon sun for a display at `origin` (points), `size` points at 2×.
    func illuminance(slope: Double, depth: Double = 28, origin: CGPoint = .zero,
                     size: CGSize = CGSize(width: 400, height: 240)) throws -> [Float] {
        let effect = try Caustics(context: EffectContext(device: device, pixelFormat: .rgba16Float))
        var environment = SharedEnvironment()
        environment.sun = CelestialPosition(altitude: 60 * .pi / 180, azimuth: .pi)
        let frame = FrameState(time: 0, deltaTime: 0, date: .distantPast, phase: .calm, presence: 1, depth: 150,
                               appearance: .dark, parameters: ["slope": .number(slope), "waterDepth": .number(depth)],
                               seed: 3, environment: environment)
        let pixels = SIMD2(Int(size.width) * 2, Int(size.height) * 2)
        let view = DisplayView(id: 1, pixelSize: pixels, scale: 2, frameInDesktop: CGRect(origin: origin, size: size), physicalSize: nil)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: pixels.x, height: pixels.y, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        let output = device.makeTexture(descriptor: descriptor)!
        let queue = device.makeCommandQueue()!
        let buffer = queue.makeCommandBuffer()!
        try effect.render(frame, view: view, encoder: Encoder(commandBuffer: buffer, output: output))
        buffer.commit()
        buffer.waitUntilCompleted()
        let texture = effect.lastIlluminance(display: 1)!
        var values = [Float](repeating: 0, count: texture.width * texture.height)
        texture.getBytes(&values, bytesPerRow: texture.width * 4, from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        return values
    }

    /// Texels away from the display's edges (light from outside the patch drawn may be missing there).
    func interior(_ values: [Float], width: Int = 200, height: Int = 120, border: Int = 12) -> [Float] {
        (border..<(height - border)).flatMap { y in (border..<(width - border)).map { values[y * width + $0] } }
    }

    @Test func flatWaterIsFlat() throws {
        let inside = interior(try illuminance(slope: 0))
        #expect(inside.allSatisfy { abs($0 - 1) < 0.02 })
    }

    /// Splats crossing texel boundaries keep the light: the same flat water, the display moved by
    /// fractions of a texel, gives the same total.
    @Test func lightIsKeptAcrossTexels() throws {
        let totals = try [0, 0.37, 0.81].map { offset in
            interior(try illuminance(slope: 0, origin: CGPoint(x: offset, y: offset * 0.5))).reduce(0, +)
        }
        for total in totals { #expect(abs(total / totals[0] - 1) < 0.002) }
    }

    /// With ripples, light moves but the average over many cells stays that of flat water.
    @Test func ripplesMoveLightWithoutLosingIt() throws {
        let inside = interior(try illuminance(slope: 0.07, size: CGSize(width: 1600, height: 1000)), width: 800, height: 500)
        let mean = inside.reduce(0, +) / Float(inside.count)
        #expect(abs(mean - 1) < 0.05)
        #expect(inside.max()! > 1.5)   // some light gathers
    }

    /// Shallow water spreads light without focusing it: smooth, no grain of separate points.
    @Test func spreadLightHasNoGrain() throws {
        let values = try illuminance(slope: 0.07, depth: 10)
        let width = 200
        var roughest: Float = 0
        for y in 13..<107 {
            for x in 13..<187 {
                let centre = values[y * width + x]
                let around = (values[y * width + x - 1] + values[y * width + x + 1] + values[(y - 1) * width + x] + values[(y + 1) * width + x]) / 4
                roughest = max(roughest, abs(centre - around))
            }
        }
        #expect(roughest < 0.05)
    }

    @Test func wavesComeFromTheSeed() {
        let a = WaveField.waves(count: 12, slope: 0.07, seed: 5)
        #expect(a == WaveField.waves(count: 12, slope: 0.07, seed: 5))
        #expect(a != WaveField.waves(count: 12, slope: 0.07, seed: 6))
        #expect(abs(WaveField.rmsSlope(a) - 0.07) < 1e-9)
        #expect(a.allSatisfy { $0.wavelength >= 40 && $0.wavelength <= 240 })
    }

    /// The water's speed wanders between the slowest flow and full speed, smoothly, for any seed
    /// and however long the clock has run.
    @Test func flowWanders() {
        for seed: UInt64 in [1, 7, 42] {
            var slowest = 1.0, fastest = 0.0, previous: Double?
            for step in 0..<20_000 {
                let time = 1e6 + Double(step) * 0.05
                let speed = (WaveField.flow(time: time + 0.01, seed: seed) - WaveField.flow(time: time, seed: seed)) / 0.01
                slowest = min(slowest, speed)
                fastest = max(fastest, speed)
                if let previous { #expect(abs(speed - previous) < 0.01) }
                previous = speed
            }
            #expect(slowest >= WaveField.slowestFlow - 1e-3 && fastest <= 1 + 1e-3)
            #expect(fastest - slowest > 0.4)
        }
        #expect(WaveField.flow(time: 0, seed: 3) == 0)
    }

    /// Long-running clocks: phases stay within one cycle and match the direct sum.
    @Test func phasesWrap() {
        let waves = WaveField.waves(count: 5, slope: 0.07, seed: 1)
        let late = WaveField.phases(waves, time: 1e7)
        #expect(late.allSatisfy { $0 >= 0 && $0 < 2 * .pi })
        for (wave, phase) in zip(waves, late) {
            let direct = wave.phase - wave.angularFrequency * 1e7
            #expect(abs(sin(direct) - sin(phase)) < 1e-6)
        }
    }

    @Test func downwindWavesGrow() {
        let waves = WaveField.waves(count: 12, slope: 0.07, seed: 2)
        let calm = WaveField.windy(waves, wind: .zero), breezy = WaveField.windy(waves, wind: SIMD2(4, 0))
        #expect(WaveField.rmsSlope(breezy) > WaveField.rmsSlope(calm))
    }

    /// At first only the long swell; the shorter waves come as nagi deepens.
    @Test func shortWavesComeWithDepth() {
        let waves = WaveField.waves(count: 12, slope: 0.07, seed: 4)
        let shallow = WaveField.deepened(waves, depth: 0), deep = WaveField.deepened(waves, depth: 60)
        for (a, (b, c)) in zip(waves, zip(shallow, deep)) {
            #expect(abs(c.amplitude - a.amplitude) < 1e-12)
            // The long and middle waves are there from the opening; the short ones come later.
            if WaveField.shortness(a) > 0.5 { #expect(b.amplitude < a.amplitude) }
            if WaveField.shortness(a) <= 0.5 { #expect(abs(b.amplitude - a.amplitude) < 1e-12) }
        }
    }

    /// Even when every wave is short (3 waves, seed 5), the longest stays as the opening's swell.
    @Test func theOpeningAlwaysHasASwell() {
        let waves = WaveField.waves(count: 3, slope: 0.07, seed: 5)
        #expect(waves.allSatisfy { WaveField.shortness($0) > 0.5 })
        let longest = waves.indices.max { waves[$0].wavelength < waves[$1].wavelength }!
        #expect(WaveField.deepened(waves, depth: 0)[longest].amplitude == waves[longest].amplitude)
    }

    /// The light bends further at a low sun: the surface patch drawn must reach further out.
    @Test func lowSunBendsFurther() {
        let noon = Caustics.incidentDirection(CelestialPosition(altitude: 60 * .pi / 180, azimuth: .pi))
        let evening = Caustics.incidentDirection(CelestialPosition(altitude: 8 * .pi / 180, azimuth: 1.5 * .pi))
        #expect(Caustics.deflection(incident: evening, slope: 0.3, depth: 280)
                > Caustics.deflection(incident: noon, slope: 0.3, depth: 280))
        #expect(Caustics.deflection(incident: noon, slope: 0, depth: 280) < 1e-9)
    }
}

