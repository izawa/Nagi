import AppKit
import SpikeLog

/// S6: two identical click-through markers side by side on the main display, the left one
/// `.readOnly` (the default) and the right one `.none`. The author takes screenshots and shares
/// the screen in a meeting; a granted `--run capture` in another process samples both centres.
@MainActor final class MarkerPairProbe {
    static let size: CGFloat = 200
    private var windows: [NSWindow] = []

    /// The two markers' frames in Cocoa screen coordinates: `.readOnly` left of centre, `.none` right.
    static func frames(on screen: NSScreen) -> (readOnly: NSRect, none: NSRect) {
        let y = screen.frame.midY - size / 2
        return (NSRect(x: screen.frame.midX - size - 20, y: y, width: size, height: size),
                NSRect(x: screen.frame.midX + 20, y: y, width: size, height: size))
    }

    init(options: Options) {
        guard let screen = NSScreen.main else { return }
        let frames = Self.frames(on: screen)
        windows = [(frames.readOnly, NSWindow.SharingType.readOnly), (frames.none, .none)].map { frame, sharing in
            let window = MarkerWindow.make(frame: frame, options: options, color: MarkerWindow.orange)
            window.sharingType = sharing
            window.orderFrontRegardless()
            return window
        }
        SpikeLog.emit("s6-markers", [
            "readOnly": "\(frames.readOnly)", "none": "\(frames.none)",
            "sharingTypes": windows.map { Int($0.sharingType.rawValue) },
            "windowNumbers": windows.map(\.windowNumber),
        ])
    }
}

/// A solid, opaque square overlay window used as a capture target (S4 and S6).
@MainActor enum MarkerWindow {
    /// Fixed sRGB colours (not appearance-dependent system colours), so capture checks can match them.
    nonisolated static let orange = SIMD3<Float>(1.0, 0.5, 0.0)
    nonisolated static let purple = SIMD3<Float>(0.6, 0.2, 0.8)

    static func make(frame: NSRect, options: Options, color: SIMD3<Float>) -> NSWindow {
        let window = OverlayWindow.make(frame: frame, options: options)
        let view = NSView(frame: NSRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        view.layer?.backgroundColor = CGColor(srgbRed: CGFloat(color.x), green: CGFloat(color.y), blue: CGFloat(color.z), alpha: 1)
        window.contentView = view
        return window
    }
}
