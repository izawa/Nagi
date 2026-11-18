import AppKit
import CoreGraphics
import Metal
import QuartzCore

/// A borderless, transparent, click-through window that never becomes key or main.
/// Shared by the overlay (S1), ramp and EDR (S2) and glass (S8) probes.
final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    static func make(frame: NSRect, options: Options) -> OverlayWindow {
        let window = OverlayWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.setFrame(frame, display: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.level = OverlayLevels.level(options.level)
        window.collectionBehavior = OverlayLevels.behavior(options.behaviors)
        return window
    }
}

enum OverlayLevels {
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
}

/// An NSView backed by a CAMetalLayer.
final class MetalView: NSView {
    let metalLayer = CAMetalLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override func makeBackingLayer() -> CALayer { metalLayer }
}

/// Metal objects shared by the probes, and one full-screen-triangle draw.
@MainActor final class SpikeMetal {
    let device = MTLCreateSystemDefaultDevice()!
    let queue: any MTLCommandQueue
    private let library: any MTLLibrary

    init() {
        queue = device.makeCommandQueue()!
        library = try! device.makeDefaultLibrary(bundle: Bundle.module)
    }

    func pipeline(fragment: String, format: MTLPixelFormat) -> any MTLRenderPipelineState {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "fullScreenVertex")
        descriptor.fragmentFunction = library.makeFunction(name: fragment)
        descriptor.colorAttachments[0].pixelFormat = format
        return try! device.makeRenderPipelineState(descriptor: descriptor)
    }

    /// Configures a layer for this device. `edr` selects rgba16Float in extended linear Display P3
    /// with EDR requested; otherwise the given format in sRGB.
    func configure(_ layer: CAMetalLayer, format: MTLPixelFormat, edr: Bool, pointSize: CGSize, scale: CGFloat) {
        layer.device = device
        layer.pixelFormat = format
        layer.colorspace = CGColorSpace(name: format == .rgba16Float ? CGColorSpace.extendedLinearDisplayP3 : CGColorSpace.sRGB)
        layer.wantsExtendedDynamicRangeContent = edr
        layer.isOpaque = false
        layer.contentsScale = scale
        layer.drawableSize = CGSize(width: pointSize.width * scale, height: pointSize.height * scale)
    }

    /// Clears the drawable, draws one full-screen triangle with `uniforms` at fragment buffer 0,
    /// and presents it. Calls `presented` with the presented time (0 when the frame was dropped).
    func draw<U: BitwiseCopyable>(_ layer: CAMetalLayer, pipeline: any MTLRenderPipelineState, uniforms: U,
                 presented: @escaping @Sendable (CFTimeInterval) -> Void) {
        guard let drawable = layer.nextDrawable() else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        guard let commands = queue.makeCommandBuffer(),
              let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(pipeline)
        withUnsafeBytes(of: uniforms) { encoder.setFragmentBytes($0.baseAddress!, length: $0.count, index: 0) }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        drawable.addPresentedHandler { presented($0.presentedTime) }
        commands.present(drawable)
        commands.commit()
    }
}

/// The Fixture's on-screen windows, read without the screen recording permission (S5).
enum FixtureWindows {
    static let bundleID = "org.izawa.nagi.spike.fixture"

    /// The Fixture's window frames in Cocoa screen coordinates, left to right; empty if it isn't running.
    @MainActor static func frames() -> [NSRect] {
        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.processIdentifier,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]],
              let primaryHeight = NSScreen.screens.first?.frame.height else { return [] }
        return list.compactMap { entry -> NSRect? in
            guard entry[kCGWindowOwnerPID as String] as? Int32 == pid,
                  let dict = entry[kCGWindowBounds as String] as? NSDictionary,
                  let cg = CGRect(dictionaryRepresentation: dict) else { return nil }
            // CG window bounds have a top-left origin on the primary display; Cocoa's is bottom-left.
            return NSRect(x: cg.minX, y: primaryHeight - cg.maxY, width: cg.width, height: cg.height)
        }.sorted { $0.minX < $1.minX }
    }
}
