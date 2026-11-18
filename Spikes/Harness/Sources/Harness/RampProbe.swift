import AppKit
import Metal
import QuartzCore
import SpikeLog

/// S2, drawn over the Fixture's panels (run `NagiFixture --scene panels` first).
/// - `ramp`: four horizontal strips, top to bottom: 8-bit, 8-bit with dither, float16,
///   float16 with dither. Each darkens from 0 at the left to `--max-alpha` at the right.
///   `--edr 0|1` sets whether the float16 strips request EDR (compare the banding both ways).
/// - `edr`: one patch on the white panel (the rightmost), alpha 0.3 with color `--gain` × white,
///   next to the plain white of the same panel.
@MainActor final class RampProbe {
    private let options: Options
    private let metal = SpikeMetal()
    private var window: NSWindow?
    private var draws: [() -> Void] = []

    init(options: Options) {
        self.options = options
        let panels = FixtureWindows.frames()
        // The panels scene has three windows: dark, mid and white, left to right.
        guard panels.count == 3, let first = panels.first, let white = panels.last,
              let screen = NSScreen.screens.first(where: { $0.frame.intersects(first) }) else {
            SpikeLog.emit("error", ["message": "run NagiFixture --scene panels first", "fixtureWindows": panels.count])
            AppDelegate.quit(reason: "error")
            return
        }
        let frame = panels.dropFirst().reduce(first) { $0.union($1) }
        let window = OverlayWindow.make(frame: frame, options: options)
        let container = NSView(frame: NSRect(origin: .zero, size: frame.size))
        container.wantsLayer = true
        window.contentView = container
        if options.run == "ramp" {
            addStrips(to: container, scale: screen.backingScaleFactor)
        } else {
            let patch = NSRect(x: white.minX - frame.minX + 20, y: white.minY - frame.minY + 60, width: 140, height: 100)
            addPatch(patch, to: container, scale: screen.backingScaleFactor)
        }
        window.orderFrontRegardless()
        self.window = window
        SpikeLog.emit("s2-config", [
            "mode": options.run, "edrRequested": options.run == "edr" || options.edr, "maxAlpha": options.maxAlpha, "gain": options.gain,
            "frame": "\(frame)", "screens": OverlayProbe.describeScreens(),
        ])
        // The content is static. Draw twice because the first frame after ordering in can be dropped (S1).
        drawAll()
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.drawAll() }
        }
        Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { _ in
            MainActor.assumeIsolated { SpikeLog.emit("s2-screens-after-3s", ["screens": OverlayProbe.describeScreens()]) }
        }
    }

    private func drawAll() { draws.forEach { $0() } }

    private func addStrips(to container: NSView, scale: CGFloat) {
        let strips: [(format: MTLPixelFormat, dither: Bool)] = [
            (.bgra8Unorm, false), (.bgra8Unorm, true), (.rgba16Float, false), (.rgba16Float, true),
        ]
        let size = container.bounds.size
        // A gap between strips, left undarkened, so the author can tell the strips apart.
        let gap: CGFloat = 8
        let height = ((size.height - gap * CGFloat(strips.count - 1)) / CGFloat(strips.count)).rounded(.down)
        for (index, strip) in strips.enumerated() {
            // Layer coordinates have a bottom-left origin here; index 0 is the top strip.
            let frame = NSRect(x: 0, y: size.height - CGFloat(index + 1) * height - CGFloat(index) * gap,
                               width: size.width, height: height)
            let layer = addLayer(frame, to: container, format: strip.format,
                                 edr: strip.format == .rgba16Float && options.edr, scale: scale)
            let pipeline = metal.pipeline(fragment: "rampFragment", format: strip.format)
            let uniforms = SIMD4<Float>(Float(frame.width * scale), Float(options.maxAlpha), strip.dither ? 1 : 0, 0)
            draws.append { [metal] in
                metal.draw(layer, pipeline: pipeline, uniforms: uniforms) { time in
                    SpikeLog.emit("s2-presented", ["strip": index, "presentedTime": time])
                }
            }
        }
    }

    private func addPatch(_ patch: NSRect, to container: NSView, scale: CGFloat) {
        let layer = addLayer(patch, to: container, format: .rgba16Float, edr: true, scale: scale)
        let pipeline = metal.pipeline(fragment: "markerFragment", format: .rgba16Float)
        let alpha: Float = 0.3
        let whole = SIMD4<Float>(0, 0, Float(patch.width * scale), Float(patch.height * scale))
        let uniforms = MarkerUniforms(rects: (whole, .zero), color: SIMD4(Float(options.gain) * alpha, Float(options.gain) * alpha,
                                                                          Float(options.gain) * alpha, alpha))
        draws.append { [metal] in
            metal.draw(layer, pipeline: pipeline, uniforms: uniforms) { SpikeLog.emit("s2-presented", ["patch": true, "presentedTime": $0]) }
        }
    }

    private func addLayer(_ frame: NSRect, to container: NSView, format: MTLPixelFormat, edr: Bool, scale: CGFloat) -> CAMetalLayer {
        let layer = CAMetalLayer()
        layer.frame = frame
        metal.configure(layer, format: format, edr: edr, pointSize: frame.size, scale: scale)
        container.layer?.addSublayer(layer)
        return layer
    }
}
