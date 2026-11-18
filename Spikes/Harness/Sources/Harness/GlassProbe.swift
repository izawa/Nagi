import AppKit
import SpikeLog

/// S8: NSGlassEffectView in an inactive, click-through overlay over the Fixture's panels
/// (run `NagiFixture --scene panels` first). Circles of 12, 24, 48 and 96 pt and a capsule,
/// `.regular` on the left and `.clear` on the right, both across the panels' paragraph. The question is whether the glass
/// distorts the other app's text beneath it like a raindrop, or only blurs or tints it.
@MainActor final class GlassProbe {
    private var window: NSWindow?

    init(options: Options) {
        let panels = FixtureWindows.frames()
        guard let first = panels.first else {
            SpikeLog.emit("error", ["message": "the Fixture's panels are not on screen"])
            AppDelegate.quit(reason: "error")
            return
        }
        let frame = panels.dropFirst().reduce(first) { $0.union($1) }
        let window = OverlayWindow.make(frame: frame, options: options)
        let container = NSView(frame: NSRect(origin: .zero, size: frame.size))
        // The paragraph sits about 52-132 pt below the top of each panel window (title bar and inset).
        let textMidY = frame.height - 92
        for (style, startX) in [(NSGlassEffectView.Style.regular, 20.0), (.clear, frame.width / 2 + 10)] {
            var x = startX
            // Circles, then a capsule.
            for (width, height) in [(12.0, 12.0), (24, 24), (48, 48), (96, 96), (160, 48)] as [(CGFloat, CGFloat)] {
                container.addSubview(Self.glass(NSRect(x: x, y: textMidY - height / 2, width: width, height: height), style: style))
                x += width + 30
            }
        }
        window.contentView = container
        window.orderFrontRegardless()
        self.window = window
        SpikeLog.emit("s8-config", ["frame": "\(frame)", "views": container.subviews.count])
    }

    private static func glass(_ frame: NSRect, style: NSGlassEffectView.Style) -> NSGlassEffectView {
        let view = NSGlassEffectView(frame: frame)
        view.style = style
        view.cornerRadius = min(frame.width, frame.height) / 2
        return view
    }
}
