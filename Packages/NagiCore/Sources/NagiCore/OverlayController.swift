import AppKit
import NagiKit
import QuartzCore

/// One click-through overlay window per display (SPEC 3.7, SPIKES S1 and S6).
/// Windows are rebuilt only when a display's position, size or scale changes: the screen
/// parameters notification also fires on every EDR headroom change.
@MainActor final class OverlayController {
    struct Overlay {
        let window: NSWindow
        let layer: CAMetalLayer
        let link: CAMetalDisplayLink
        let linkTarget: LinkTarget
        var view: DisplayView
    }

    /// Called from each display's link with a drawable to fill.
    var onFrame: ((_ display: UInt32, _ update: CAMetalDisplayLink.Update) -> Void)?
    /// Called when a display goes away.
    var onRemove: ((_ display: UInt32) -> Void)?
    private(set) var overlays: [UInt32: Overlay] = [:]
    private(set) var isShown = false
    private let device: any MTLDevice
    /// `.none` keeps nagi out of screenshots and screen sharing (SPEC 2.5, 3.7).
    var sharingType: NSWindow.SharingType = .none {
        didSet { for overlay in overlays.values { overlay.window.sharingType = sharingType } }
    }

    init(device: any MTLDevice) {
        self.device = device
        rebuild()
    }

    /// Adds, removes or rebuilds overlays to match the displays; refreshes EDR headroom.
    func rebuild() {
        var seen = Set<UInt32>()
        for screen in NSScreen.screens {
            guard let id = screen.displayID else { continue }
            seen.insert(id)
            let view = Self.displayView(screen, id: id)
            if let existing = overlays[id], existing.view.frameInDesktop == view.frameInDesktop,
               existing.view.scale == view.scale {
                overlays[id]?.view = view
                continue
            }
            remove(id)
            overlays[id] = makeOverlay(screen: screen, view: view)
        }
        for id in overlays.keys where !seen.contains(id) { remove(id) }
    }

    func show() {
        guard !isShown else { return }
        isShown = true
        for overlay in overlays.values {
            overlay.window.orderFrontRegardless()
            overlay.link.isPaused = false
        }
    }

    func hide() {
        guard isShown else { return }
        isShown = false
        for overlay in overlays.values {
            overlay.link.isPaused = true
            overlay.window.orderOut(nil)
        }
    }

    private func remove(_ id: UInt32) {
        guard let overlay = overlays.removeValue(forKey: id) else { return }
        overlay.link.invalidate()
        overlay.window.orderOut(nil)
        onRemove?(id)
    }

    var layers: [CALayer] { overlays.values.map(\.layer) }

    /// The display that advances the shared simulation (the others draw its latest frame).
    var driverDisplay: UInt32? { overlays.keys.min() }

    private func makeOverlay(screen: NSScreen, view: DisplayView) -> Overlay {
        let window = OverlayWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.setFrame(screen.frame, display: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.level = .popUpMenu
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.sharingType = sharingType
        window.animationBehavior = .none

        let layer = CAMetalLayer()
        layer.device = device
        layer.pixelFormat = FrameRenderer.workingFormat
        layer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
        layer.wantsExtendedDynamicRangeContent = true
        layer.isOpaque = false
        layer.framebufferOnly = true
        layer.contentsScale = view.scale
        layer.drawableSize = CGSize(width: view.pixelSize.x, height: view.pixelSize.y)
        let content = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        content.wantsLayer = true
        content.layer = layer
        window.contentView = content

        let target = LinkTarget(display: view.id) { [weak self] display, update in
            self?.onFrame?(display, update)
        }
        let link = CAMetalDisplayLink(metalLayer: layer)
        link.delegate = target
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 120)
        link.isPaused = !isShown
        // .common so frames keep coming while a menu is being tracked.
        link.add(to: .main, forMode: .common)
        if isShown { window.orderFrontRegardless() }
        return Overlay(window: window, layer: layer, link: link, linkTarget: target, view: view)
    }

    private static func displayView(_ screen: NSScreen, id: UInt32) -> DisplayView {
        let scale = screen.backingScaleFactor
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let frame = screen.frame
        let physical = CGDisplayScreenSize(id)
        return DisplayView(
            id: id,
            pixelSize: SIMD2(Int((frame.width * scale).rounded()), Int((frame.height * scale).rounded())),
            scale: scale,
            frameInDesktop: CGRect(x: frame.minX, y: primaryHeight - frame.maxY, width: frame.width, height: frame.height),
            physicalSize: physical.width > 0 ? SIMD2(physical.width, physical.height) : nil,
            edrHeadroom: screen.maximumExtendedDynamicRangeColorComponentValue,
            potentialEDRHeadroom: screen.maximumPotentialExtendedDynamicRangeColorComponentValue)
    }
}

/// Never key or main, so nagi never takes focus (SPIKES S1).
private final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The display link's delegate; forwards to the controller on the main thread.
/// Immutable, and `forward` only runs on the main actor, hence `@unchecked Sendable`.
final class LinkTarget: NSObject, CAMetalDisplayLinkDelegate, @unchecked Sendable {
    let display: UInt32
    let forward: @MainActor (UInt32, CAMetalDisplayLink.Update) -> Void

    init(display: UInt32, forward: @escaping @MainActor (UInt32, CAMetalDisplayLink.Update) -> Void) {
        self.display = display
        self.forward = forward
    }

    nonisolated func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
        // The link runs on the main run loop, so this is the main thread.
        nonisolated(unsafe) let update = update
        MainActor.assumeIsolated { forward(display, update) }
    }
}

extension NSScreen {
    var displayID: UInt32? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
