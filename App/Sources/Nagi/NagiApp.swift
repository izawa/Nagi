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
/// - `--debug-lens`: also draw a few drifting lenses that magnify the captured screen (needs
///   Screen Recording; M2-PLAN stage A).
/// - `--debug-windows`: also offer the window check, which draws what the window service sees
///   (M3-PLAN stage A1). `--debug-window-age-scale n` makes every window age n times as fast.
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
/// - `--debug-strongest-wind`: hold the mean wind at its strongest, every gust at full strength.
/// - `--debug-clear-sky`: no clouds. `--debug-cloud-pass`: each time nagi shows, one cloud crosses
///   the sun (clear 3 s, covering 10 s, hidden 5 s, clearing 10 s, then clear).
/// - `--first-launch`: start from the default settings and show the first-launch guide, as on a
///   new Mac (the saved settings are replaced at the first change).
/// - `--debug-preview`: "see it now" one second after launch (checks without waiting for onset).
/// - `--debug-gallery`: offer the gallery in the menu (always offered in Debug builds).
/// - `--debug-fake-input s`: the idle reading behaves as if input came every `s` seconds,
///   0.5 s after each stall would start (logged as "fakeinput" with the scheduled time).
@main struct NagiApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    init() {
        if CommandLine.arguments.contains("--self-test") { SelfTest.run() }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(delegate: delegate)
        } label: {
            MenuIcon(store: delegate.settings)
        }
        // A small panel, not a menu: switching several effects should not close it each time
        // (a menu item always closes the menu; SwiftUI cannot keep a macOS menu open).
        .menuBarExtraStyle(.window)
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var engine: NagiEngine?
    /// The user's settings (DECISIONS D26).
    let settings = SettingsStore(effects: EffectCatalog.all, fresh: CommandLine.arguments.contains("--first-launch"))
    private(set) lazy var notes = EffectNotes { [weak self] in self?.noteLines() ?? [] }
    private(set) lazy var screenRecording: ScreenRecording = {
        let permission = ScreenRecording(store: settings)
        permission.onChange = { [weak self] in
            self?.engine?.recheckPermissions()
            self?.notes.refresh()
        }
        return permission
    }()
    /// The settings window's tab, so the menu can open it on Permissions.
    let settingsTab = SettingsTab()

    /// The effects' notes, then a line per enabled effect that lacks its permission.
    private func noteLines() -> [String] {
        var lines = engine?.notes().map { String(localized: $0) } ?? []
        // What the engine found (it reads the permission, and hears when capture is refused).
        let unavailable = engine?.unavailableEffects ?? []
        for descriptor in settings.descriptors where unavailable.contains(descriptor.id)
            && settings.settings.isEnabled(descriptor.id, among: settings.effects) {
                lines.append(String(format: String(localized: "画面収録を許可していないため、%@は出ません", bundle: .module),
                                    String(localized: descriptor.displayName)))
        }
        return lines
    }
    private var gallery: GalleryWindowController?

    func applicationWillTerminate(_ notification: Notification) {
        settings.flush()
    }

    /// Debug builds always offer the gallery; Release builds when launched with --debug-gallery.
    static let galleryAllowed: Bool = {
        #if DEBUG
        true
        #else
        CommandLine.arguments.contains("--debug-gallery")
        #endif
    }()

    let login = LoginItem()

    /// The settings window (SPEC 2.5).
    func showSettings(tab: SettingsTab.Tab? = nil) {
        if let tab { settingsTab.selection = tab }
        settingsWindow.show()
    }

    private lazy var settingsWindow: HoldingWindowController = {
        let window = HoldingWindowController(
            reason: "settings", title: { String(localized: "設定", bundle: .module) }, size: NSSize(width: 640, height: 600),
            engine: { [weak self] in self?.engine }
        ) { [unowned self] in
            AnyView(SettingsView(store: settings, login: login, screenRecording: screenRecording, tab: settingsTab,
                                 device: engine?.renderer.device))
        }
        window.onClose = { [settings] in settings.flush() }
        return window
    }()

    /// The first-launch guide; done when it closes, however it closes.
    private lazy var onboardingWindow: HoldingWindowController = {
        let window = HoldingWindowController(
            reason: "onboarding", title: { String(localized: "凪", bundle: .module) }, size: NSSize(width: 480, height: 520),
            engine: { [weak self] in self?.engine }
        ) { [unowned self] in
            AnyView(OnboardingView(store: settings, login: login, screenRecording: screenRecording,
                                   explainPermission: { [weak self] in self?.showSettings(tab: .permissions) }) { [weak self] in self?.onboardingWindow.close() })
        }
        window.onClose = { [settings] in
            settings.update { $0.onboarded = true }
            settings.flush()
        }
        return window
    }()

    /// A window holds nagi off, so "see it now" would do nothing.
    var windowsHoldOff: Bool { settingsWindow.holdsOff || onboardingWindow.holdsOff }

    func showGallery() {
        guard let engine else { return }
        if gallery == nil { gallery = GalleryWindowController(engine: engine) }
        gallery?.show()
    }

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
        // The lens checks the screen capture (M2-PLAN stage A), over the effects the user has on.
        if arguments.contains("--debug-lens") { effects.append(LensEffect.self) }
        // The window check shows what the window service sees (M3-PLAN stage A1, checkpoint H).
        if arguments.contains("--debug-windows") { effects.append(WindowCheckEffect.self) }
        do {
            let measurement = MeasurementOptions(
                emptyFrames: arguments.contains("--debug-empty-frame"),
                edr: !arguments.contains("--debug-no-edr"),
                drawableScale: Self.value(after: "--debug-drawable-scale", in: arguments).flatMap(Double.init)
                    .flatMap { (0.1...2).contains($0) ? $0 : nil } ?? 1,
                maxFrameRate: Self.value(after: "--debug-max-fps", in: arguments).flatMap(Float.init) ?? 60,
                eightBit: arguments.contains("--debug-eight-bit"))
            let engine = try NagiEngine(effects: effects, trace: arguments.contains("--trace"), measurement: measurement)
            if let patch {
                engine.renderer.parameters[PatchEffect.descriptor.id] = patch
                // Calibration output must not depend on the saved strength.
                settings.overrides.strength = 1
            }
            if arguments.contains("--sharing-readonly") { settings.overrides.sharing = .readOnly }
            if arguments.contains("--debug-ignore-media") { settings.overrides.holdForMedia = false }
            if arguments.contains("--debug-strongest-wind") { engine.weather.strongestWind = true }
            if arguments.contains("--debug-clear-sky") { engine.weather.sky = .clear }
            if arguments.contains("--debug-cloud-pass") { engine.cloudPassEachShowing = true }
            if let scale = Self.value(after: "--debug-window-age-scale", in: arguments).flatMap(Double.init), scale.isFinite, scale > 0 {
                engine.windowAgeScale = scale
            }
            if let date = Self.value(after: "--debug-date", in: arguments).flatMap(ISO8601DateFormatter().date(from:)) {
                engine.pinnedDate = date
            }
            for (index, argument) in arguments.enumerated() where argument == "--effect-param" && index + 1 < arguments.count {
                let parts = arguments[index + 1].split(separator: "=", maxSplits: 1).map(String.init)
                let path = parts.first?.split(separator: ".", maxSplits: 1).map(String.init) ?? []
                guard parts.count == 2, path.count == 2 else { continue }
                settings.overrides.parameters[path[0], default: [:]][path[1]] = ParameterValue(parsing: parts[1])
            }
            settings.overrides.frameRateCap = Self.value(after: "--debug-max-fps", in: arguments).flatMap(Float.init)
            self.engine = engine
            // The settings go in before the first sample, so nagi starts with the saved onset and pause.
            settings.attach(engine)
            engine.start()
            settings.didApply = { [weak self] in self?.notes.refresh() }
            notes.start()
            // Debug launches (measurements, checks) run unattended: no guide, and it stays unseen.
            let debugLaunch = arguments.contains { $0.hasPrefix("--debug-") }
            if !settings.settings.onboarded, !debugLaunch { onboardingWindow.show() }
            // Low Power Mode switches the frame rate (SPEC 2.2).
            NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil,
                                                   queue: .main) { [settings] _ in
                MainActor.assumeIsolated { settings.apply() }
            }
            // A timed pause is a wall-clock deadline: check it when the clock jumps or the Mac wakes.
            NotificationCenter.default.addObserver(forName: .NSSystemClockDidChange, object: nil,
                                                   queue: .main) { [settings] _ in
                MainActor.assumeIsolated { settings.recheckPause() }
            }
            NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil,
                                                              queue: .main) { [settings] _ in
                MainActor.assumeIsolated { settings.recheckPause() }
            }
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
