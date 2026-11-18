import AppKit
import DebugEffects
import EffectCatalog
import Metal
import NagiCore
import NagiKit
import os
import SwiftUI

/// The menu-bar app (SPEC 2.4).
///
/// Launch arguments for development and measurement (M1-PLAN 7.2):
/// - `--self-test`: print what loaded as JSON and quit.
/// - `--trace`: log nagi's transitions to the unified log (subsystem org.izawa.Nagi).
/// - `--debug-patch r,g,b,a,x0,y0,x1,y1`: also draw a flat premultiplied colour (pixels; the
///   rectangle may be omitted for the whole display).
/// - `--sharing-readonly`: let screenshots and capture see the overlay.
/// - `--debug-stall`: block the main thread for 1.5 s every 10 s, to test withdrawal while the
///   main thread is stuck (M1-PLAN 4.3). Logged as "stall"/"unstall" with `--trace`.
/// - `--debug-pin-idle`: the idle reading never drops (nagi stays; no withdrawal). Load runs only.
/// - `--debug-empty-frame`, `--debug-no-edr`, `--debug-drawable-scale s`: see MeasurementOptions.
/// - `--debug-date ISO8601`: compute the sun for this wall-clock date (stop B in the evening).
/// - `--effect-param id.key=value` (repeatable): set an effect parameter, e.g. komorebi.lightAlpha=0.06.
/// - `--debug-ignore-media`: do not hold back for video or meetings (measurements).
/// - `--debug-preview`: "see it now" one second after launch (checks without waiting for onset).
/// - `--debug-fake-input s`: the idle reading behaves as if input came every `s` seconds,
///   0.5 s after each stall would start (logged as "fakeinput" with the scheduled time).
@main struct NagiApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    init() {
        if CommandLine.arguments.contains("--self-test") { SelfTest.run() }
    }

    var body: some Scene {
        MenuBarExtra(String(localized: "凪", bundle: .module), systemImage: "leaf") {
            Button(String(localized: "今すぐ見る", bundle: .module)) { delegate.engine?.preview() }
            Divider()
            Button(String(localized: "凪を終了", bundle: .module)) { NSApplication.shared.terminate(nil) }
        }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var engine: NagiEngine?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let arguments = CommandLine.arguments
        if let period = Self.value(after: "--debug-fake-input", in: arguments).flatMap(Double.init) {
            fakeInput(every: period)
        }
        if arguments.contains("--debug-pin-idle") {
            // Grows with time like a real reading without input (a constant reads as ongoing input).
            SystemSignals.idleSource = { 1000 + ProcessInfo.processInfo.systemUptime }
        }
        var effects = EffectCatalog.all
        let patch = Self.value(after: "--debug-patch", in: arguments).map(Self.patchParameters)
        // The patch is for calibration and measurement: alone, so nothing else draws with it.
        if patch != nil { effects = [PatchEffect.self] }
        do {
            let measurement = MeasurementOptions(
                emptyFrames: arguments.contains("--debug-empty-frame"),
                edr: !arguments.contains("--debug-no-edr"),
                drawableScale: Self.value(after: "--debug-drawable-scale", in: arguments).flatMap(Double.init)
                    .flatMap { (0.1...2).contains($0) ? $0 : nil } ?? 1,
                maxFrameRate: Self.value(after: "--debug-max-fps", in: arguments).flatMap(Float.init) ?? 120,
                eightBit: arguments.contains("--debug-eight-bit"))
            let engine = try NagiEngine(effects: effects, trace: arguments.contains("--trace"), measurement: measurement)
            if let patch { engine.renderer.parameters[PatchEffect.descriptor.id] = patch }
            if arguments.contains("--sharing-readonly") { engine.sharingType = .readOnly }
            if arguments.contains("--debug-ignore-media") { engine.suppressDuringMedia = false }
            if let date = Self.value(after: "--debug-date", in: arguments).flatMap(ISO8601DateFormatter().date(from:)) {
                engine.pinnedDate = date
            }
            for (index, argument) in arguments.enumerated() where argument == "--effect-param" && index + 1 < arguments.count {
                let parts = arguments[index + 1].split(separator: "=", maxSplits: 1).map(String.init)
                let path = parts.first?.split(separator: ".", maxSplits: 1).map(String.init) ?? []
                guard parts.count == 2, path.count == 2, let value = Double(parts[1]) else { continue }
                engine.renderer.parameters[path[0], default: [:]][path[1]] = .number(value)
            }
            engine.start()
            self.engine = engine
            if arguments.contains("--debug-stall") { startStalling() }
            if arguments.contains("--debug-preview") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { engine.preview() }
            }
        } catch {
            NSLog("Nagi could not start: %@", error.localizedDescription)
        }
    }

    private func fakeInput(every period: Double) {
        let start = ProcessInfo.processInfo.systemUptime + 0.5
        let real = SystemSignals.idleSource
        SystemSignals.idleSource = {
            let now = ProcessInfo.processInfo.systemUptime
            let sinceFake = (now - start).truncatingRemainder(dividingBy: period)
            guard now >= start + period else { return real() }
            return min(real(), sinceFake)
        }
        let trace = Logger(subsystem: "org.izawa.Nagi", category: "trace")
        let timer = Timer(timeInterval: period, repeats: true) { _ in
            // The scheduled time, not the (possibly stalled) time this timer ran.
            let k = ((ProcessInfo.processInfo.systemUptime - start) / period).rounded(.down)
            trace.notice("fakeinput t=\(start + k * period, format: .fixed(precision: 4), privacy: .public)")
        }
        timer.fireDate = Date(timeIntervalSinceNow: 0.5 + period)
        RunLoop.main.add(timer, forMode: .common)
    }

    private func startStalling() {
        let trace = Logger(subsystem: "org.izawa.Nagi", category: "trace")
        let timer = Timer(timeInterval: 10, repeats: true) { _ in
            let now = { ProcessInfo.processInfo.systemUptime }
            trace.notice("stall t=\(now(), format: .fixed(precision: 4), privacy: .public)")
            Thread.sleep(forTimeInterval: 1.5)
            trace.notice("unstall t=\(now(), format: .fixed(precision: 4), privacy: .public)")
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    private static func patchParameters(_ text: String) -> [String: ParameterValue] {
        let keys = ["r", "g", "b", "a", "x0", "y0", "x1", "y1"]
        let values = text.split(separator: ",").compactMap { Double($0) }
        return Dictionary(uniqueKeysWithValues: zip(keys, values.map { ParameterValue.number($0) }))
    }
}

@MainActor enum SelfTest {
    static func run() {
        var report: [String: Any] = [
            "bundleID": Bundle.main.bundleIdentifier ?? "",
            "sandboxed": ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil,
            "preferredLanguages": Locale.preferredLanguages,
            "quit": String(localized: "凪を終了", bundle: .module),
            "effects": EffectCatalog.all.map { $0.descriptor.id },
            "hidIdleTime": SystemSignals.hidIdleTime() ?? -1,
        ]
        if let device = MTLCreateSystemDefaultDevice() {
            report["renderer"] = (try? FrameRenderer(device: device, effects: EffectCatalog.all)) != nil
        }
        let data = try! JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
        exit(0)
    }
}
