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
    private let device = MTLCreateSystemDefaultDevice()!
    private let pipeline: any MTLRenderPipelineState
    private let queue: any MTLCommandQueue
    private var windows: [NSWindow] = []
    private var geometry = OverlayProbe.screenGeometry()
    private var shown = false

    init(options: Options) {
        self.options = options
        queue = device.makeCommandQueue()!
        pipeline = Self.makePipeline(device: device)
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
            "level": options.level, "levelValue": Self.level(options.level).rawValue,
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
        let window = OverlayWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.setFrame(screen.frame, display: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.level = Self.level(options.level)
        window.collectionBehavior = Self.behavior(options.behaviors)
        let view = MetalView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.metalLayer.device = device
        view.metalLayer.pixelFormat = .rgba16Float
        view.metalLayer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
        view.metalLayer.wantsExtendedDynamicRangeContent = true
        view.metalLayer.isOpaque = false
        view.metalLayer.contentsScale = screen.backingScaleFactor
        view.metalLayer.drawableSize = CGSize(
            width: screen.frame.width * screen.backingScaleFactor, height: screen.frame.height * screen.backingScaleFactor
        )
        window.contentView = view
        return window
    }

    private func render(_ window: NSWindow, orderedAt: CFTimeInterval, attempt: Int) {
        guard let layer = (window.contentView as? MetalView)?.metalLayer, let drawable = layer.nextDrawable(),
              let screen = window.screen else { return }
        let scale = Float(screen.backingScaleFactor)
        let width = Float(screen.frame.width) * scale, height = Float(screen.frame.height) * scale
        let side = 160 * scale
        // Top marker spans the menu bar; bottom marker spans the Dock area.
        var marker = MarkerUniforms(
            rects: (SIMD4(width * 0.3, 0, side, side), SIMD4(width * 0.5 - side / 2, height - side, side, side)),
            color: SIMD4(0.25, 0.6, 1.0, 1.0) * Float(options.alpha)
        )
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        guard let commands = queue.makeCommandBuffer(),
              let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&marker, length: MemoryLayout<MarkerUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        let number = window.windowNumber
        drawable.addPresentedHandler { [weak self] presented in
            let presentedTime = presented.presentedTime
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
        commands.present(drawable)
        commands.commit()
    }

    private static func makePipeline(device: any MTLDevice) -> any MTLRenderPipelineState {
        let library = try! device.makeDefaultLibrary(bundle: Bundle.module)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "fullScreenVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "markerFragment")
        descriptor.colorAttachments[0].pixelFormat = .rgba16Float
        return try! device.makeRenderPipelineState(descriptor: descriptor)
    }

    static func level(_ name: String) -> NSWindow.Level {
        switch name {
        case "normal": .normal
        case "floating": .floating
        case "statusBar": .statusBar
        case "popUpMenu": .popUpMenu
        case "screenSaver": .screenSaver
        case "assistiveTechHigh": NSWindow.Level(Int(CGWindowLevelForKey(.assistiveTechHighWindow)))
        default: .statusBar
        }
    }

    static func behavior(_ names: [String]) -> NSWindow.CollectionBehavior {
        let table: [String: NSWindow.CollectionBehavior] = [
            "canJoinAllSpaces": .canJoinAllSpaces, "moveToActiveSpace": .moveToActiveSpace,
            "stationary": .stationary, "ignoresCycle": .ignoresCycle,
            "fullScreenAuxiliary": .fullScreenAuxiliary, "fullScreenNone": .fullScreenNone,
            "canJoinAllApplications": .canJoinAllApplications, "auxiliary": .auxiliary,
            "transient": .transient,
        ]
        return names.reduce(into: []) { $0.formUnion(table[$1] ?? []) }
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

private struct MarkerUniforms {
    var rects: (SIMD4<Float>, SIMD4<Float>)
    var color: SIMD4<Float>
}

private final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class MetalView: NSView {
    let metalLayer = CAMetalLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override func makeBackingLayer() -> CALayer { metalLayer }
}
