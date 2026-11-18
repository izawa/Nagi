// Harness: the M0 spike app (docs/M0-PLAN.md section 2). Throwaway code.
//
// One probe per launch, results as JSON Lines on stdout:
//   open -n -g -W --stdout <file> build/spikes/NagiSpike-plain.app --args --run <probe> [options]
// Probes: header, s9, s3, s5, s10 (with --action), launch (S10: no arguments at all), overlay, ramp, edr (S2), glass (S8), markers (S6),
// capture and permission (S4, granted only), composite (S2 numeric, granted only). Every run exits by itself after --duration seconds
// (default 20, max 600); the status item's menu can also quit it.
//
// Rule for the .plain variants: never call CGRequestScreenCaptureAccess, SCShareableContent
// or any capture API. A prompt with nobody to click it would change the TCC state.

import AppKit
import CoreGraphics
import Metal
import os
import ProbeShaders
import SpikeLog

struct Options {
    var run = "header"         // "launch" when there are no arguments at all (S10: macOS opens the app at login)
    var action = "status"      // s10: status, register, unregister or settings
    var duration = 20.0
    var step = 6.0             // s3: seconds per input step
    var hz = 15.0              // s5 sampling rate
    var showAfter = 3.0        // overlay: delay before ordering the windows in
    var level = "statusBar"    // overlay: see OverlayLevel
    var behaviors = ["canJoinAllSpaces", "fullScreenAuxiliary", "stationary", "ignoresCycle"]
    var alpha = 0.35           // overlay: marker opacity (keep it faint on the author's display)
    var edr = true             // overlay, ramp: request EDR on the rgba16Float layers
    var maxAlpha = 0.08        // ramp: darkening at the right edge
    var gain = 2.0             // edr: patch color relative to SDR white
    var filter = "self"        // capture: "self" excludes this app's windows, "none" captures everything
    var trials = 0             // capture: number of start/stop trials; 0 runs one stream until --duration
    var captureScale = 1.0     // capture: output size relative to the display's pixels (load comparison)
    var watch: CGPoint?        // capture: an extra point to sample, "x,y" in Cocoa points (M1 stage 2)

    init(_ arguments: [String]) {
        var values: [String: String] = [:]
        var index = 0
        while index + 1 < arguments.count {
            if arguments[index].hasPrefix("--") { values[String(arguments[index].dropFirst(2))] = arguments[index + 1] }
            index += 1
        }
        run = values["run"] ?? (arguments.isEmpty ? "launch" : run)
        action = values["action"] ?? action
        duration = min(Double(values["duration"] ?? "") ?? duration, 600)
        if let seconds = Double(values["step"] ?? ""), seconds.isFinite, seconds > 0 { step = seconds }
        if let rate = Double(values["hz"] ?? ""), rate.isFinite, rate > 0 { hz = rate }
        showAfter = Double(values["show-after"] ?? "") ?? showAfter
        level = values["level"] ?? level
        behaviors = values["behaviors"].map { $0.split(separator: ",").map(String.init) } ?? behaviors
        alpha = Double(values["alpha"] ?? "") ?? alpha
        edr = values["edr"].map { $0 != "0" } ?? edr
        maxAlpha = Double(values["max-alpha"] ?? "") ?? maxAlpha
        gain = Double(values["gain"] ?? "") ?? gain
        if let value = values["filter"], ["self", "none"].contains(value) { filter = value }
        trials = max(Int(values["trials"] ?? "") ?? trials, 0)
        if let scale = Double(values["capture-scale"] ?? ""), scale.isFinite { captureScale = min(max(scale, 0.1), 1) }
        if let text = values["watch"] {
            let parts = text.split(separator: ",", omittingEmptySubsequences: false).map { Double($0) }
            if parts.count == 2, let x = parts[0], let y = parts[1], x.isFinite, y.isFinite, x >= 0, y >= 0 {
                watch = CGPoint(x: x, y: y)
            }
        }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    let options = Options(Array(CommandLine.arguments.dropFirst()))
    var statusItem: NSStatusItem?
    var probe: AnyObject?  // keeps the running probe alive

    func applicationDidFinishLaunching(_ notification: Notification) {
        if ["launch", "s10"].contains(options.run) {
            SpikeLog.systemLog = Logger(subsystem: "org.izawa.nagi.spike", category: options.run)
        }
        SpikeLog.header(["screenCapturePreflight": CGPreflightScreenCaptureAccess(), "options": "\(options)"])
        installStatusItem()
        Timer.scheduledTimer(withTimeInterval: options.duration, repeats: false) { _ in
            MainActor.assumeIsolated { Self.quit(reason: "duration") }
        }
        switch options.run {
        case "header":
            Self.quit(reason: "done")
        case "launch":
            LoginProbe.recordLaunch()
            Self.quit(reason: "done")
        case "s10":
            LoginProbe.run(action: options.action)
            Self.quit(reason: "done")
        case "s9":
            runS9()
            Self.quit(reason: "done")
        case "s3":
            probe = IdleStateProbe(statusItem: statusItem, step: options.step)
        case "s5":
            // S5 is about what is returned WITHOUT the permission; a granted run proves nothing.
            guard !CGPreflightScreenCaptureAccess() else {
                SpikeLog.emit("error", ["message": "s5 must run without screen recording permission"])
                Self.quit(reason: "error")
                return
            }
            probe = WindowListProbe(hz: options.hz)
        case "overlay":
            probe = OverlayProbe(options: options)
        case "ramp", "edr":
            probe = RampProbe(options: options)
        case "glass":
            probe = GlassProbe(options: options)
        case "markers":
            probe = MarkerPairProbe(options: options)
        case "capture", "composite", "permission":
            // Capture APIs only in the .granted variants (see the rule at the top of this file).
            guard Bundle.main.bundleIdentifier?.contains(".granted") == true else {
                SpikeLog.emit("error", ["message": "\(options.run) runs only in the .granted variants"])
                Self.quit(reason: "error")
                return
            }
            switch options.run {
            case "capture": probe = CaptureProbe(options: options)
            case "composite": probe = CompositeProbe(options: options)
            default:
                // S4: the permission dialog. Deny, allow and revoke each leave this record.
                let before = CGPreflightScreenCaptureAccess()
                let granted = CGRequestScreenCaptureAccess()
                SpikeLog.emit("s4-permission", ["preflightBefore": before, "requestResult": granted,
                                                "preflightAfter": CGPreflightScreenCaptureAccess()])
                Self.quit(reason: "done")
            }
        default:
            SpikeLog.emit("error", ["message": "unknown --run \(options.run)"])
            Self.quit(reason: "error")
        }
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "凪 \(options.run)"
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Quit Harness", action: #selector(quitFromMenu), keyEquivalent: ""))
        menu.items.forEach { $0.target = self }
        item.menu = menu
        statusItem = item
    }

    @objc private func quitFromMenu() { Self.quit(reason: "menu") }

    static func quit(reason: String) {
        SpikeLog.emit("exit", ["reason": reason])
        NSApp.terminate(nil)
    }

    /// S9 inside the .app: the metallib must come from this app's Contents/Resources.
    private func runS9() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            SpikeLog.emit("s9", ["passed": false, "error": "no Metal device"])
            return
        }
        do {
            let result = try runProbe(device: device)
            let inside = result.metallibPath.hasPrefix(Bundle.main.bundlePath + "/Contents/Resources/")
            SpikeLog.emit("s9", [
                "passed": result.passed && inside, "kernelPassed": result.passed,
                "metallibInsideApp": inside, "metallibPath": result.metallibPath,
                "pixels": result.pixels.map { $0.map(Double.init) },
            ])
        } catch {
            SpikeLog.emit("s9", ["passed": false, "error": error.localizedDescription])
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
