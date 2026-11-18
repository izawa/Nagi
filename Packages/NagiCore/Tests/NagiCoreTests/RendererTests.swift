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

    /// Surface (black, α 0.5, left half) under light (red, premultiplied 0.25, α 0.25).
    /// Light over surface gives red 0.25; the other order would give 0.125.
    @Test func layersCompositeBottomToTop() throws {
        let renderer = try FrameRenderer(device: device, effects: [LightPatch.self, SurfacePatch.self])
        renderer.parameters = [
            "test.surface": ["a": .number(0.5), "x1": .number(4)],
            "test.light": ["r": .number(0.25), "a": .number(0.25)],
        ]
        let pixels = TextureReader.pixels(of: try renderer.renderOverlay(frame(), view: view))
        let left = pixel(pixels, 0, 0), right = pixel(pixels, 7, 0)
        #expect(abs(left.x - 0.25) < 1e-3 && abs(left.w - 0.625) < 1e-3)
        #expect(abs(right.x - 0.25) < 1e-3 && abs(right.w - 0.25) < 1e-3)
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
    }

    @Test func noBackdropWithoutTheCapability() throws {
        let renderer = try FrameRenderer(device: device, effects: [PlainProbe.self])
        var display = view
        display.backdrop = try Background.gray(0.5).makeTexture(size: view.pixelSize, renderer: renderer)
        _ = try renderer.renderOverlay(frame(), view: display)
        #expect(renderer.instance(of: PlainProbe.self)?.sawBackdrop == false)
    }
}
