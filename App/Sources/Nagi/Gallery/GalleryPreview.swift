import AppKit
import NagiCore
import NagiKit
import QuartzCore
import SwiftUI

/// The gallery's picture: its own renderer on the engine's device, drawing what the screen would
/// show (the overlay over a sample background) straight into a CAMetalLayer (DECISIONS D24).
/// The display is fixed at 2560 × 1440, scaled to fit the window, so the canopy keeps its size.
@MainActor final class GalleryPreviewView: NSView {
    private let model: GalleryModel
    private let renderer: FrameRenderer
    private let metalLayer = CAMetalLayer()
    private var link: CAMetalDisplayLink?
    private var linkTarget: LinkTarget?
    private var backgrounds: [GalleryModel.Fixture: any MTLTexture] = [:]
    private var lastTimestamp: CFTimeInterval?
    private var lastDrawn: CFTimeInterval = -.infinity
    private static let pixels = SIMD2(2560, 1440)

    init(model: GalleryModel, device: any MTLDevice) throws {
        self.model = model
        renderer = try FrameRenderer(device: device, effects: [model.effect])
        super.init(frame: .zero)
        metalLayer.device = device
        metalLayer.pixelFormat = FrameRenderer.workingFormat
        // The blend writes encoded Display P3, as WindowServer shows it (SPEC 3.5).
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.displayP3)
        metalLayer.isOpaque = true
        metalLayer.framebufferOnly = false
        metalLayer.drawableSize = CGSize(width: Self.pixels.x, height: Self.pixels.y)
        metalLayer.contentsGravity = .resizeAspect
        metalLayer.backgroundColor = NSColor.black.cgColor
        layer = metalLayer
        wantsLayer = true
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func start() {
        guard link == nil else { return }
        // Decode the sample backgrounds now, not in the middle of a frame.
        for fixture in GalleryModel.Fixture.allCases { _ = try? background(for: fixture) }
        let target = LinkTarget(display: 0) { [weak self] _, update in self?.draw(update) }
        let link = CAMetalDisplayLink(metalLayer: metalLayer)
        link.delegate = target
        applyFrameRate(to: link)
        link.add(to: .main, forMode: .common)
        self.link = link
        linkTarget = target
    }

    /// Stops drawing and frees the textures (the window closed).
    func stop() {
        link?.invalidate()
        link = nil
        linkTarget = nil
        backgrounds.removeAll()
        renderer.releaseResources()
        lastTimestamp = nil
    }

    private func applyFrameRate(to link: CAMetalDisplayLink) {
        let rate = Float(model.framesPerSecond)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: rate, maximum: rate, preferred: rate)
    }

    private func draw(_ update: CAMetalDisplayLink.Update) {
        if let link, link.preferredFrameRateRange.preferred != Float(model.framesPerSecond) { applyFrameRate(to: link) }
        let timestamp = update.targetPresentationTimestamp
        let seconds = lastTimestamp.map { max(0, min(timestamp - $0, 0.25)) } ?? 0
        lastTimestamp = timestamp
        // Paused, a still picture: redraw a few times a second to follow the controls, not 60.
        if !model.playing, timestamp - lastDrawn < 0.2 { return }
        lastDrawn = timestamp
        renderer.parameters[model.effect.descriptor.id] = model.parameters
        let width = model.widthMillimetres
        let view = PreviewScene.display(pixels: Self.pixels,
                                        physicalSize: SIMD2(width, width * Double(Self.pixels.y) / Double(Self.pixels.x)))
        var frame = model.advance(by: seconds)
        frame.displays = [view.frameInDesktop]
        frame.showing = model.showings
        do {
            let background = try background(for: model.fixture)
            guard let commandBuffer = renderer.queue.makeCommandBuffer() else { return }
            renderer.update(frame)
            try renderer.encodeScreen(frame, view: view, strength: model.strength, background: background, into: update.drawable.texture,
                                      commandBuffer: commandBuffer)
            commandBuffer.present(update.drawable)
            commandBuffer.commit()
        } catch {
            NSLog("Gallery could not draw: %@", error.localizedDescription)
        }
    }

    private func background(for fixture: GalleryModel.Fixture) throws -> any MTLTexture {
        if let texture = backgrounds[fixture] { return texture }
        guard let url = Bundle.module.url(forResource: fixture.rawValue, withExtension: "png") else {
            throw NagiCoreError("no sample background \(fixture.rawValue)")
        }
        let texture = try Background.image(url).makeTexture(size: Self.pixels, renderer: renderer)
        backgrounds[fixture] = texture
        return texture
    }
}

struct GalleryPreview: NSViewRepresentable {
    let view: GalleryPreviewView
    func makeNSView(context: Context) -> GalleryPreviewView { view }
    func updateNSView(_ nsView: GalleryPreviewView, context: Context) {}
}
