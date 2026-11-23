import CoreGraphics
import Metal
import NagiCore
import NagiKit
import Testing

@MainActor struct RendererTests {
    let device = MTLCreateSystemDefaultDevice()!
    let view = DisplayView(id: 1, pixelSize: SIMD2(8, 4), scale: 2, frameInDesktop: CGRect(x: 0, y: 0, width: 4, height: 2),
                           physicalSize: nil)

    func frame(presence: Double = 1) -> FrameState {
        FrameState(time: 0, deltaTime: 0, date: .distantPast, phase: .calm, presence: presence, depth: 0,
                   appearance: .light, seed: 1)
    }

    func pixel(_ pixels: [SIMD4<Float>], _ x: Int, _ y: Int) -> SIMD4<Float> { pixels[y * view.pixelSize.x + x] }

    @Test func zeroPresenceIsExactlyTransparent() throws {
        let renderer = try FrameRenderer(device: device, effects: [LightPatch.self])
        renderer.parameters = ["test.light": ["r": .number(0.9), "a": .number(1)]]
        let pixels = TextureReader.pixels(of: try renderer.renderOverlay(frame(presence: 0), view: view))
        #expect(pixels.allSatisfy { $0 == .zero })
    }

    @Test func presenceScalesColourAndAlpha() throws {
        let renderer = try FrameRenderer(device: device, effects: [LightPatch.self])
        renderer.parameters = ["test.light": ["r": .number(0.5), "a": .number(0.5)]]
        let p = pixel(TextureReader.pixels(of: try renderer.renderOverlay(frame(presence: 0.5), view: view)), 0, 0)
        #expect(abs(p.x - 0.25) < 1e-3 && abs(p.w - 0.25) < 1e-3)
    }

    /// Surface (black, α 0.5, left half) under light (red, premultiplied 0.25, α 0.25), stacked in
    /// encoded values (D40): red 0.25 · enc(1) over black gives encoded 0.25 at α 0.625, which is
    /// linear premultiplied 0.625 · dec(0.4) ≈ 0.0831. The other order would give encoded 0.125,
    /// 0.625 · dec(0.2) ≈ 0.0207, at the same α.
    @Test func layersCompositeBottomToTop() throws {
        let renderer = try FrameRenderer(device: device, effects: [LightPatch.self, SurfacePatch.self])
        renderer.parameters = [
            "test.surface": ["a": .number(0.5), "x1": .number(4)],
            "test.light": ["r": .number(0.25), "a": .number(0.25)],
        ]
        let pixels = TextureReader.pixels(of: try renderer.renderOverlay(frame(), view: view))
        let left = pixel(pixels, 0, 0), right = pixel(pixels, 7, 0)
        #expect(abs(left.x - 0.0831) < 1e-3 && abs(left.w - 0.625) < 1e-3)
        #expect(abs(right.x - 0.25) < 1e-3 && abs(right.w - 0.25) < 1e-3)
    }

    /// Effects share the rain they make (D32): the largest, clamped, and none from effects not
    /// running in the showing.
    @Test func precipitationIsSharedFromRunningEffects() throws {
        let renderer = try FrameRenderer(device: device, effects: [RainProbe.self, SurfacePatch.self])
        renderer.parameters = ["test.rain": ["rain": .number(0.4)]]
        #expect(renderer.update(frame()).environment.precipitation == 0.4)
        #expect(renderer.instance(of: RainProbe.self)?.seen == 0.4)
        renderer.parameters = ["test.rain": ["rain": .number(3)]]
        #expect(renderer.update(frame()).environment.precipitation == 1)
        renderer.parameters = ["test.rain": ["rain": .number(.nan)]]
        #expect(renderer.update(frame()).environment.precipitation == 0)
        renderer.disabledIDs = ["test.rain"]
        #expect(renderer.update(frame()).environment.precipitation == 0)
    }

    /// The measured WindowServer blend (SPEC 3.5): black at α 0.08 lowers the encoded value by 8 %,
    /// and colour at α 0 adds nothing.
    @Test func desktopBlendMatchesTheMeasuredModel() throws {
        let renderer = try FrameRenderer(device: device, effects: [SurfacePatch.self])
        renderer.parameters = ["test.surface": ["a": .number(0.08), "x1": .number(4)]]
        var pixels = TextureReader.pixels(of: try renderer.renderOffscreen(frame(), view: view, background: .gray(0.5)))
        #expect(abs(pixel(pixels, 0, 0).x - 0.46) < 2e-3)
        #expect(abs(pixel(pixels, 7, 0).x - 0.5) < 2e-3)

        renderer.parameters = ["test.surface": ["g": .number(0.3), "a": .number(0)]]
        pixels = TextureReader.pixels(of: try renderer.renderOffscreen(frame(), view: view, background: .gray(0.5)))
        #expect(abs(pixel(pixels, 0, 0).y - 0.5) < 2e-3)
    }

    /// A layer looks the same over a lower layer as over the desktop (D40): black at α 0.1 over
    /// white gives encoded 0.900 both over an opaque white surface (left half) and over the white
    /// desktop (right half). Stacked in linear values the left half was 0.955.
    @Test func aShadeIsTheSameOverALowerLayer() throws {
        let renderer = try FrameRenderer(device: device, effects: [LightPatch.self, SurfacePatch.self])
        renderer.parameters = [
            "test.surface": ["r": .number(1), "g": .number(1), "b": .number(1), "a": .number(1), "x1": .number(4)],
            "test.light": ["a": .number(0.1)],
        ]
        let pixels = TextureReader.pixels(of: try renderer.renderOffscreen(frame(), view: view, background: .gray(1)))
        #expect(abs(pixel(pixels, 0, 0).x - 0.9) < 2e-3)
        #expect(abs(pixel(pixels, 7, 0).x - 0.9) < 2e-3)
    }

    /// A `.backdrop` effect sees the screen with the lower layers blended in (SPEC 3.5).
    @Test func backdropIncludesLowerLayers() throws {
        let renderer = try FrameRenderer(device: device, effects: [BackdropProbe.self, SurfacePatch.self])
        renderer.parameters = ["test.surface": ["a": .number(0.5)], "test.backdrop": ["px": .number(2), "py": .number(1)]]
        var display = view
        display.backdrop = try Background.gray(0.5).makeTexture(size: view.pixelSize, renderer: renderer)
        _ = try renderer.renderOverlay(frame(), view: display)
        let probe = try #require(renderer.instance(of: BackdropProbe.self))
        #expect(probe.sawBackdrop)
        #expect(abs(probe.sampled.x - 0.25) < 2e-3)

        // A coloured lower layer counts too: white at α 0.5 (premultiplied 0.5) over grey 0.5 is
        // encoded 0.75.
        renderer.parameters["test.surface"] = ["r": .number(0.5), "g": .number(0.5), "b": .number(0.5), "a": .number(0.5)]
        _ = try renderer.renderOverlay(frame(), view: display)
        #expect(abs(probe.sampled.x - 0.75) < 2e-3)
    }

    @Test func noBackdropWithoutTheCapability() throws {
        let renderer = try FrameRenderer(device: device, effects: [PlainProbe.self])
        var display = view
        display.backdrop = try Background.gray(0.5).makeTexture(size: view.pixelSize, renderer: renderer)
        _ = try renderer.renderOverlay(frame(), view: display)
        #expect(renderer.instance(of: PlainProbe.self)?.sawBackdrop == false)
    }
}
