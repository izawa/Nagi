import AppKit
import CoreGraphics
import IOKit
import IOKit.pwr_mgt

/// What the OS tells the core, without any permission (SPEC 3.8, SPIKES S3).
@MainActor public final class SystemSignals {
    /// Locked, screensaver running or displays asleep.
    public private(set) var screenUnavailable = false
    /// Called when `screenUnavailable` changes.
    public var onChange: (() -> Void)?

    private var locked = false
    private var screensaver = false
    private var displaysAsleep = false
    private var observers: [(NotificationCenter, any NSObjectProtocol)] = []

    public init() {
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.screensDidSleepNotification) { $0.displaysAsleep = true }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { $0.displaysAsleep = false }
        let distributed = DistributedNotificationCenter.default()
        observe(distributed, .init("com.apple.screenIsLocked")) { $0.locked = true }
        observe(distributed, .init("com.apple.screenIsUnlocked")) { $0.locked = false }
        observe(distributed, .init("com.apple.screensaver.didstart")) { $0.screensaver = true }
        observe(distributed, .init("com.apple.screensaver.didstop")) { $0.screensaver = false }
    }

    isolated deinit {
        for (center, observer) in observers { center.removeObserver(observer) }
    }

    /// Seconds since the last keyboard, mouse or trackpad event.
    public nonisolated static func idleReading() -> Double { idleSource() }

    /// The OS reading: IOHIDSystem's `HIDIdleTime`, which drops to 0 within a few ms of a key or
    /// click. `CGEventSource` lagged real input by 0.1–0.4 s and bottomed out at 0.5 s
    /// (M1-LOG, stop A). Falls back to `CGEventSource` if the property is missing.
    /// Replaceable once at launch, before the engine starts, for measurements that simulate
    /// input (the app's `--debug-fake-input`); the engine and the guard both read it.
    nonisolated(unsafe) public static var idleSource: @Sendable () -> Double = {
        hidIdleTime() ?? CGEventSource.secondsSinceLastEventType(.combinedSessionState,
                                                                  eventType: CGEventType(rawValue: ~0)!)
    }

    private nonisolated static let hidSystem = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))

    /// `HIDIdleTime` in seconds (the property is in nanoseconds); nil if unavailable.
    public nonisolated static func hidIdleTime() -> Double? {
        guard hidSystem != IO_OBJECT_NULL,
              let value = IORegistryEntryCreateCFProperty(hidSystem, "HIDIdleTime" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? NSNumber else { return nil }
        return value.doubleValue / 1_000_000_000
    }

    /// Whether another process asks the display to stay awake: `PreventUserIdleDisplaySleep` or
    /// `NoDisplaySleepAssertion` (video, meetings). `Internal…` types and system-sleep assertions
    /// do not count (SPEC 3.8).
    public nonisolated static func mediaActive() -> Bool {
        var byProcess: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&byProcess) == kIOReturnSuccess,
              let processes = byProcess?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return false }
        let me = getpid()
        return processes.contains { pid, assertions in
            pid.int32Value != me && assertions.contains {
                guard let type = $0[kIOPMAssertionTypeKey] as? String else { return false }
                return type == kIOPMAssertPreventUserIdleDisplaySleep || type == "NoDisplaySleepAssertion"
            }
        }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ update: @escaping @MainActor @Sendable (SystemSignals) -> Void) {
        let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                update(self)
                let unavailable = self.locked || self.screensaver || self.displaysAsleep
                if unavailable != self.screenUnavailable {
                    self.screenUnavailable = unavailable
                    self.onChange?()
                }
            }
        }
        observers.append((center, observer))
    }
}
