import AppKit
import CoreGraphics
import Metal
import QuartzCore
import SpikeLog

/// S1: one transparent, click-through overlay window per screen. Draws two faint markers,
/// one across the menu bar and one across the Dock, so the author can see whether the
/// overlay sits above both. Logs focus, idle time and the first presented frame.
@MainActor final class OverlayProbe {
    private let options: Options
    private let metal = SpikeMetal()
    private let pipeline: any MTLRenderPipelineState
    private var windows: [NSWindow] = []
    private var geometry = OverlayProbe.screenGeometry()
    private var shown = false

    init(options: Options) {
        self.options = options
        pipeline = metal.pipeline(fragment: "markerFragment", format: .rgba16Float)
        // This notification also fires on every EDR headroom step (once per frame while the
        // headroom ramps), so rebuild only when the screens' frames or scales change.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let current = Self.screenGeometry()
                let geometryChanged = current != self.geometry
                self.geometry = current
                SpikeLog.emit("screens-changed", ["geometryChanged": geometryChanged, "screens": Self.describeScreens()])
                if geometryChanged, self.shown { self.rebuild() }
            }
        }
        // Any activation while the probe runs, not only the 1-second snapshot below.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            SpikeLog.emit("app-activated", ["pid": Int(app?.processIdentifier ?? -1)])
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in SpikeLog.emit("harness-became-active") }
        SpikeLog.emit("overlay-config", [
            "level": options.level, "levelValue": OverlayLevels.level(options.level).rawValue,
            "behaviors": options.behaviors, "screens": Self.describeScreens(),
        ])
        Timer.scheduledTimer(withTimeInterval: options.showAfter, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.show() }
        }
    }

    private func show() {
        let frontBefore = Self.frontmostPID()
        let idleBefore = Self.idleSeconds()
        let shownAt = CACurrentMediaTime()
        shown = true
        rebuild()
        SpikeLog.emit("overlay-shown", [
            "frontmostPIDBefore": frontBefore, "idleBefore": idleBefore, "windowNumbers": windows.map(\.windowNumber),
        ])
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { _ in
            MainActor.assumeIsolated {
                SpikeLog.emit("overlay-after-1s", [
                    "frontmostPIDAfter": Self.frontmostPID(), "harnessActive": NSApp.isActive,
                    "idleAfter": Self.idleSeconds(), "idleExpectedIfNoInput": idleBefore + CACurrentMediaTime() - shownAt,
                    "harnessHasKeyWindow": NSApp.keyWindow != nil,
                ])
            }
        }
    }

    private func rebuild() {
        windows.forEach { $0.orderOut(nil) }
        windows = NSScreen.screens.map(makeWindow)
        for window in windows {
            let orderedAt = CACurrentMediaTime()
            window.orderFrontRegardless()
            render(window, orderedAt: orderedAt, attempt: 1)
        }
    }

    private func makeWindow(for screen: NSScreen) -> NSWindow {
        let window = OverlayWindow.make(frame: screen.frame, options: options)
        let view = MetalView(frame: NSRect(origin: .zero, size: screen.frame.size))
        metal.configure(view.metalLayer, format: .rgba16Float, edr: options.edr,
                        pointSize: screen.frame.size, scale: screen.backingScaleFactor)
        window.contentView = view
        return window
    }

    private func render(_ window: NSWindow, orderedAt: CFTimeInterval, attempt: Int) {
        guard let layer = (window.contentView as? MetalView)?.metalLayer, let screen = window.screen else { return }
        let scale = Float(screen.backingScaleFactor)
        let width = Float(screen.frame.width) * scale, height = Float(screen.frame.height) * scale
        let side = 160 * scale
        // Top marker spans the menu bar; bottom marker spans the Dock area.
        let marker = MarkerUniforms(
            rects: (SIMD4(width * 0.3, 0, side, side), SIMD4(width * 0.5 - side / 2, height - side, side, side)),
            color: SIMD4(0.25, 0.6, 1.0, 1.0) * Float(options.alpha)
        )
        let number = window.windowNumber
        metal.draw(layer, pipeline: pipeline, uniforms: marker) { [weak self] presentedTime in
            Task { @MainActor in
                SpikeLog.emit("overlay-presented", [
                    "windowNumber": number, "attempt": attempt, "presentedTime": presentedTime,
                    "msFromOrderFront": presentedTime > 0 ? (presentedTime - orderedAt) * 1000 : -1,
                ])
                // A dropped frame (presentedTime 0) would leave the overlay blank for the visual checks.
                if presentedTime == 0, attempt < 3,
                   let window = self?.windows.first(where: { $0.windowNumber == number }) {
                    self?.render(window, orderedAt: orderedAt, attempt: attempt + 1)
                }
            }
        }
    }

    static func describeScreens() -> [[String: any Sendable]] {
        NSScreen.screens.map { screen in
            [
                "name": screen.localizedName, "frame": "\(screen.frame)", "scale": Double(screen.backingScaleFactor),
                "maxEDR": Double(screen.maximumExtendedDynamicRangeColorComponentValue),
                "maxPotentialEDR": Double(screen.maximumPotentialExtendedDynamicRangeColorComponentValue),
            ]
        }
    }

    static func screenGeometry() -> [String] {
        NSScreen.screens.map { "\($0.frame) @\($0.backingScaleFactor)" }
    }

    static func frontmostPID() -> Int { Int(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1) }

    static func idleSeconds() -> Double {
        CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: ~0)!)
    }
}

/// Matches `struct Marker` in Overlay.metal. Also used by the EDR patch (S2).
struct MarkerUniforms {
    var rects: (SIMD4<Float>, SIMD4<Float>)
    var color: SIMD4<Float>
}
