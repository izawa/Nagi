// Spike S3 (docs/M0-PLAN.md): idle time, power assertions, and screen-state
// notifications, all without any TCC permission. Throwaway code.
//
// Build: mkdir -p build && swiftc -O -o build/idle-probe Spikes/IdleProbe/main.swift
// Run:   build/idle-probe [seconds]   (default 30; prints a line every 0.5 s)

import AppKit
import CoreGraphics
import IOKit.pwr_mgt

let anyInput = CGEventType(rawValue: ~0)!  // kCGAnyInputEventType

func idle(_ state: CGEventSourceStateID) -> Double {
    CGEventSource.secondsSinceLastEventType(state, eventType: anyInput)
}

/// Assertion types that are currently held system-wide with level > 0.
func activeAssertionTypes() -> [String] {
    var status: Unmanaged<CFDictionary>?
    guard IOPMCopyAssertionsStatus(&status) == kIOReturnSuccess,
          let dict = status?.takeRetainedValue() as? [String: Int] else { return ["<error>"] }
    return dict.filter { $0.value > 0 }.map(\.key).sorted()
}

/// Per-process display-sleep assertions: "pid:type" (names are not printed; they can
/// contain media titles).
func displayAssertionsByProcess() -> [String] {
    var byProcess: Unmanaged<CFDictionary>?
    guard IOPMCopyAssertionsByProcess(&byProcess) == kIOReturnSuccess,
          let dict = byProcess?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return ["<error>"] }
    var result: [String] = []
    for (pid, assertions) in dict {
        for a in assertions {
            let type = a[kIOPMAssertionTypeKey] as? String ?? "?"
            if type.contains("Display") { result.append("\(pid):\(type)") }
        }
    }
    return result.sorted()
}

@MainActor func observeScreenState() {
    let ws = NSWorkspace.shared.notificationCenter
    for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification,
                 NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification,
                 NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification] {
        ws.addObserver(forName: name, object: nil, queue: .main) { n in print("EVENT workspace \(n.name.rawValue)") }
    }
    let dist = DistributedNotificationCenter.default()
    for name in ["com.apple.screenIsLocked", "com.apple.screenIsUnlocked",
                 "com.apple.screensaver.didstart", "com.apple.screensaver.didstop"] {
        dist.addObserver(forName: .init(name), object: nil, queue: .main) { _ in print("EVENT distributed \(name)") }
    }
}

let duration = Double(CommandLine.arguments.dropFirst().first ?? "") ?? 30
let start = Date()
MainActor.assumeIsolated { observeScreenState() }
setvbuf(stdout, nil, _IOLBF, 0)

let timer = Timer(timeInterval: 0.5, repeats: true) { _ in
    let t = Date().timeIntervalSince(start)
    print(String(format: "t=%5.1f hid=%7.2f session=%7.2f", t, idle(.hidSystemState), idle(.combinedSessionState)),
          "assert=\(activeAssertionTypes().joined(separator: ","))",
          "display=\(displayAssertionsByProcess().joined(separator: ","))")
    if t >= duration { exit(0) }
}
RunLoop.main.add(timer, forMode: .common)
RunLoop.main.run()
