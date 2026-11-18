import AppKit
import CoreGraphics
import SpikeLog

/// S5: what CGWindowListCopyWindowInfo returns without the screen recording permission.
/// Logs key names (never the values of name keys), the Fixture's windows when they change,
/// and the call time. Correlate with the Fixture's own log by `t`.
@MainActor final class WindowListProbe {
    private var timer: Timer?
    private var durations: [Double] = []
    private var lastFixtureWindows: [[String: Double]]?  // nil until the Fixture is first seen
    private var loggedKeys = false

    init(hz: Double) {
        timer = Timer.scheduledTimer(withTimeInterval: 1 / hz, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.summarize() } }
    }

    private func sample() {
        let start = ProcessInfo.processInfo.systemUptime
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        durations.append((ProcessInfo.processInfo.systemUptime - start) * 1000)

        if !loggedKeys {
            loggedKeys = true
            let keys = Set(list.flatMap(\.keys)).sorted()
            SpikeLog.emit("s5-keys", [
                "keys": keys, "windowCount": list.count,
                "nameKeyPresent": list.contains { $0[kCGWindowName as String] != nil },
                "ownerNameKeyPresent": list.contains { $0[kCGWindowOwnerName as String] != nil },
            ])
        }

        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: FixtureWindows.bundleID)
            .first?.processIdentifier else { return }
        // Front-to-back order of the whole on-screen list is the array order.
        let windows: [[String: Double]] = list.enumerated().compactMap { index, entry in
            guard entry[kCGWindowOwnerPID as String] as? Int32 == pid,
                  let bounds = entry[kCGWindowBounds as String] as? [String: Double] else { return nil }
            return [
                "number": Double(entry[kCGWindowNumber as String] as? Int ?? -1),
                "layer": Double(entry[kCGWindowLayer as String] as? Int ?? -1),
                "zIndex": Double(index),
                "x": bounds["X"] ?? .nan, "y": bounds["Y"] ?? .nan,
                "w": bounds["Width"] ?? .nan, "h": bounds["Height"] ?? .nan,
            ]
        }
        if windows != lastFixtureWindows {
            lastFixtureWindows = windows
            SpikeLog.emit("s5-sample", ["fixturePID": Int(pid), "windows": windows])
        }
    }

    private func summarize() {
        let sorted = durations.sorted()
        guard !sorted.isEmpty else { return }
        func percentile(_ p: Double) -> Double { sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))] }
        SpikeLog.emit("s5-timing", [
            "samples": sorted.count, "p50ms": percentile(0.5), "p95ms": percentile(0.95), "maxMs": sorted.last!,
        ])
    }
}
