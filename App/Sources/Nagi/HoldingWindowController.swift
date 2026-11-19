import AppKit
import NagiCore
import Observation
import SwiftUI

/// A window that holds nagi off while it is on screen (open and not in the Dock): the settings and
/// the first-launch guide (DECISIONS D26). The user is at the keyboard, and the settings show
/// their own preview. The view is made on each opening and dropped on closing.
@MainActor @Observable final class HoldingWindowController: NSObject, NSWindowDelegate {
    @ObservationIgnored private let reason: String
    @ObservationIgnored private let title: () -> String
    @ObservationIgnored private let size: NSSize
    @ObservationIgnored private let content: () -> AnyView
    @ObservationIgnored private let engine: () -> NagiEngine?
    @ObservationIgnored var onClose: () -> Void = {}
    @ObservationIgnored private var window: NSWindow?
    private(set) var holdsOff = false {
        didSet { engine()?.hold(reason, holdsOff) }
    }

    /// `engine` is looked up when needed: the menu can read `holdsOff` before the engine exists.
    init(reason: String, title: @escaping () -> String, size: NSSize, engine: @escaping () -> NagiEngine?,
         content: @escaping () -> AnyView) {
        self.reason = reason
        self.title = title
        self.size = size
        self.engine = engine
        self.content = content
    }

    func show() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                                  styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = title()
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: content())
            window.delegate = self
            window.center()
            self.window = window
        }
        holdsOff = true
        // A menu-bar app is not active when its menu is used: activate first, then bring the
        // window up even if the activation is declined, so it never opens behind other apps.
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }

    func close() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
        // Drop the view (and any preview) now, not when the window is reused.
        window?.contentView = nil
        window = nil
        holdsOff = false
    }

    func windowDidMiniaturize(_ notification: Notification) { holdsOff = false }
    func windowDidDeminiaturize(_ notification: Notification) { holdsOff = true }
}
