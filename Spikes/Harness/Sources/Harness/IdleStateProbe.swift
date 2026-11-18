import AppKit
import CoreGraphics
import IOKit.pwr_mgt
import SpikeLog

/// S3: idle time, power assertions, and screen-state notifications.
@MainActor final class IdleStateProbe {
    private let anyInput = CGEventType(rawValue: ~0)!  // kCGAnyInputEventType
    private let steps = ["wait", "key", "modifier", "move", "click", "drag", "scroll"]
    private let statusItem: NSStatusItem?
    private var stepIndex = 0

    init(statusItem: NSStatusItem?, step: Double) {
        self.statusItem = statusItem
        showStep()
        observeScreenState()
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        Timer.scheduledTimer(withTimeInterval: step, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.advanceStep() }
        }
    }

    private func showStep() {
        let step = steps[stepIndex]
        statusItem?.button?.title = "凪 s3: \(step)"
        SpikeLog.emit("s3-step", ["step": step])
    }

    private func advanceStep() {
        stepIndex = (stepIndex + 1) % steps.count
        showStep()
    }

    private func sample() {
        var fields: [String: any Sendable] = [
            "hidIdleSeconds": CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: anyInput),
            "combinedSessionIdleSeconds": CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput),
        ]
        readAssertionStatus(into: &fields)
        readDisplayAssertions(into: &fields)
        SpikeLog.emit("s3-sample", fields)
    }

    private func readAssertionStatus(into fields: inout [String: any Sendable]) {
        var status: Unmanaged<CFDictionary>?
        let result = IOPMCopyAssertionsStatus(&status)
        guard result == kIOReturnSuccess else {
            fields["assertionsStatusIOReturn"] = result
            return
        }
        let levels = status?.takeRetainedValue() as? [String: Int] ?? [:]
        fields["activeAssertionTypes"] = levels.filter { $0.value > 0 }.map(\.key).sorted()
    }

    private func readDisplayAssertions(into fields: inout [String: any Sendable]) {
        var byProcess: Unmanaged<CFDictionary>?
        let result = IOPMCopyAssertionsByProcess(&byProcess)
        guard result == kIOReturnSuccess else {
            fields["assertionsByProcessIOReturn"] = result
            return
        }
        let processes = byProcess?.takeRetainedValue() as? [NSNumber: [[String: Any]]] ?? [:]
        // Assertion names can contain media titles. Log only the PID and type.
        fields["displayAssertionsByProcess"] = processes.flatMap { pid, assertions in
            assertions.compactMap { assertion -> String? in
                guard let type = assertion[kIOPMAssertionTypeKey] as? String,
                      type.contains("Display") else { return nil }
                return "\(pid):\(type)"
            }
        }.sorted()
    }

    private func observeScreenState() {
        let logEvent: @Sendable (Notification) -> Void = { notification in
            SpikeLog.emit("s3-event", ["name": notification.name.rawValue])
        }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification,
                     NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification] {
            _ = workspace.addObserver(forName: name, object: nil, queue: .main, using: logEvent)
        }
        let distributed = DistributedNotificationCenter.default()
        for name in ["com.apple.screenIsLocked", "com.apple.screenIsUnlocked",
                     "com.apple.screensaver.didstart", "com.apple.screensaver.didstop"] {
            _ = distributed.addObserver(forName: .init(name), object: nil, queue: .main, using: logEvent)
        }
    }
}
