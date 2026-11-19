import AppKit
import NagiKit
import os
import QuartzCore

/// Ties the state machine, the OS signals, the overlays and the renderer together (SPEC 3.3, 3.8).
///
/// While the user is active nothing draws: one timer sleeps until the next moment nagi could
/// start. While nagi shows, every display-link frame reads the idle time, steps the state
/// machine and draws. A watchdog takes the overlays down at the leave deadline even if no frame
/// arrives (M1-PLAN 4.3).
@MainActor public final class NagiEngine {
    public var strength = 1.0
    /// Where the sun is computed for; nil uses the time zone's representative city for the frame's date.
    public var location: GeoLocation?
    /// A fixed wall-clock date for the sun (stop B looks at daylight in the evening).
    public var pinnedDate: Date?
    /// The weather hints of the effects, and debug overrides of the sky (EnvironmentModel.Weather).
    public var weather = EnvironmentModel.Weather()
    /// Debug: start a cloud crossing the sun each time nagi shows (CloudModel.pass).
    public var cloudPassEachShowing = false
    public var suppressDuringMedia = true
    /// Paused until this date; `.distantFuture` pauses until resumed.
    public var pausedUntil: Date? {
        didSet { if !configuring { sample() } }
    }
    private var configuring = false

    /// Changes several settings with one sample at the end, so nagi never shows under a half-applied
    /// set (a pause set after the timing, say). The first call can also be the start.
    public func configure(_ body: (NagiEngine) -> Void) {
        configuring = true
        body(self)
        configuring = false
        sample()
    }
    /// Reasons nagi is held off, e.g. an open gallery or settings preview (DECISIONS D24, D26).
    /// Independent of the user's pause; nagi shows again when the last one goes.
    private var holds: Set<String> = []
    public var heldOff: Bool { !holds.isEmpty }

    public func hold(_ reason: String, _ on: Bool) {
        if on { holds.insert(reason) } else { holds.remove(reason) }
        log("hold \(reason) \(on) holds=\(holds.sorted())")
        if !configuring { sample() }
    }

    /// The seconds until nagi shows and how fast it deepens, changed while running (SPEC 2.5).
    public func setTiming(onset: Double, depthGrowthRate: Double) {
        machine.setTiming(machine.timing.with(onset: onset, depthGrowthRate: depthGrowthRate), at: Self.now)
        if !configuring { sample() }
    }

    /// The highest frame rate, changed while running (Low Power Mode, D26).
    public var frameRateCap: Float {
        get { overlays.frameRateCap }
        set { overlays.frameRateCap = newValue }
    }
    public var sharingType: NSWindow.SharingType {
        get { overlays.sharingType }
        set { overlays.sharingType = newValue }
    }
    public let renderer: FrameRenderer

    private var machine: NagiStateMachine
    private let overlays: OverlayController
    private let signals = SystemSignals()
    private var output: NagiOutput?
    private var wakeTimer: Timer?
    private var watchdog: Timer?
    private var mediaActive = false
    private var mediaCheckedAt = -Double.infinity
    private var frame: FrameState?
    /// The wind clock (DECISIONS D19): starts at the uptime, so each launch meets different wind,
    /// keeps running while nagi is hidden, and runs at half speed while Reduce Motion is on,
    /// without jumping when it is switched.
    private var windClock = ProcessInfo.processInfo.systemUptime
    private var windClockRead = ProcessInfo.processInfo.systemUptime
    /// The depth effects see: held while nagi leaves, so the fading picture does not change as
    /// depth falls (a falling sway gain would slide the canopy back, DECISIONS D22).
    private var shownDepth = 0.0
    /// Set when the watchdog or the guard took nagi down: it stays down until the state
    /// machine has gone back to active, so a fade cannot bring it back.
    private var forcedDown = false
    private var framesThisShowing = 0
    /// GPU milliseconds of recent frames, logged every few seconds with `--trace` (M1-PLAN 7.3).
    private let gpuTimes = GPUTimes()
    /// Intervals between presented frames on the driver display (trace only).
    private var frameIntervals: [Double] = []
    private var lastPresentation: CFTimeInterval?
    private let withdrawalGuard: WithdrawalGuard
    private let trace: Logger?
    private var screenObserver: (any NSObjectProtocol)?

    private let measurement: MeasurementOptions

    public init(effects: [any Effect.Type], timing: NagiTiming = NagiTiming(), trace: Bool = false,
                measurement: MeasurementOptions = .init()) throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw NagiCoreError("no Metal device") }
        renderer = try FrameRenderer(device: device, effects: effects)
        weather.cloudBias = effects.compactMap { $0.descriptor.weatherHint?.cloudBias }.reduce(0, +)
        overlays = OverlayController(device: device, measurement: measurement)
        self.measurement = measurement
        machine = NagiStateMachine(timing: timing)
        let trace = trace ? Logger(subsystem: "org.izawa.Nagi", category: "trace") : nil
        self.trace = trace
        var cleanUp: (@MainActor @Sendable (Int) -> Void)?
        withdrawalGuard = WithdrawalGuard(budget: timing.leaveBudget - 0.3, idleOffset: timing.idleOffset,
                                          trace: trace) { cleanUp?($0) }
        overlays.onFrame = { [weak self] display, update in self?.drawFrame(display: display, update: update) }
        overlays.onRemove = { [weak self] display in self?.renderer.forget(display: display) }
        signals.onChange = { [weak self] in self?.sample() }
        cleanUp = { [weak self] generation in
            guard let self, self.overlays.isShown, self.withdrawalGuard.isCurrent(generation) else { return }
            self.forceDown(reason: "guard cleanup")
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.overlays.rebuild()
                if self.overlays.isShown { self.withdrawalGuard.replace(self.overlays.layers) }
            }
        }
    }

    isolated deinit {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    }

    public func start() {
        log("start")
        sample()
    }

    /// What the effects say about now (Effect.note): after sunset, komorebi shows nothing.
    public func notes() -> [LocalizedStringResource] {
        let date = pinnedDate ?? Date()
        let frame = FrameState(time: Self.now, deltaTime: 0, date: date, phase: .calm, presence: 1, depth: 0,
                               appearance: Self.appearance, seed: 1, environment: environment(at: date))
        return renderer.notes(frame)
    }

    private func environment(at date: Date) -> SharedEnvironment {
        EnvironmentModel.environment(at: date, location: location ?? EnvironmentModel.defaultLocation(at: date),
                                     windTime: windClock, seed: 1, weather: weather)
    }

    /// "See it now" (SPEC 2.4, M1-PLAN 4.5).
    public func preview() {
        // Take the reading first, so the click that asked for the preview is not new input.
        sample()
        machine.requestPreview(at: Self.now)
        log("preview holds=\(holds.sorted()) pausedUntil=\(String(describing: pausedUntil)) phase=\(String(describing: output?.phase))")
        sample()
    }

    // MARK: - Sampling

    private static var now: Double { ProcessInfo.processInfo.systemUptime }

    /// The system's accessibility settings (SPEC 2.2), read each frame.
    public static var accessibility: AccessibilityAdjustments {
        let workspace = NSWorkspace.shared
        return AccessibilityAdjustments(
            reduceMotion: workspace.accessibilityDisplayShouldReduceMotion,
            reduceStrength: workspace.accessibilityDisplayShouldIncreaseContrast
                || workspace.accessibilityDisplayShouldReduceTransparency)
    }

    /// Reads the signals and steps the state machine; shows or hides the overlays and schedules
    /// the next wake. Called by the wake timer, by every frame and by signal changes.
    @discardableResult private func sample() -> NagiOutput {
        let now = Self.now
        if now - mediaCheckedAt >= 1 {
            mediaActive = SystemSignals.mediaActive()
            mediaCheckedAt = now
        }
        let paused = heldOff || (pausedUntil.map { $0 > Date() } ?? false)
        let inputs = NagiInputs(now: now, idleReading: SystemSignals.idleReading(), paused: paused,
                                screenUnavailable: signals.screenUnavailable, mediaActive: mediaActive,
                                suppressDuringMedia: suppressDuringMedia)
        let previous = output
        let next = machine.step(inputs)
        output = next
        if previous?.phase != next.phase { log("phase \(String(describing: next.phase))") }

        if forcedDown, next.phase == .active { forcedDown = false }
        if next.showsOverlay, !overlays.isShown, !forcedDown {
            frame = nil
            withdrawalGuard.arm(overlays.layers, reading: inputs.idleReading, at: now)
            overlays.show()
            log("shown")
        } else if !next.showsOverlay, overlays.isShown {
            hide(reason: "hidden")
        }
        armWatchdog(next.leaveDeadline)
        scheduleWake(next, inputs: inputs)
        return next
    }

    private func hide(reason: String) {
        withdrawalGuard.disarm()
        overlays.hide()
        renderer.releaseResources()
        watchdog?.invalidate()
        watchdog = nil
        log("\(reason) frames=\(framesThisShowing)")
        framesThisShowing = 0
        lastPresentation = nil
        frameIntervals.removeAll()
    }

    /// Takes nagi down outside the state machine (watchdog, guard) and keeps it down until the
    /// machine is back to active; then samples to rearm the wake timer.
    private func forceDown(reason: String) {
        forcedDown = true
        hide(reason: reason)
        _ = sample()
    }

    /// While nothing shows, sleep until the next moment nagi could start (SPEC 3.8). Pauses and
    /// media assertions have no notification, so wake at least every few seconds.
    private func scheduleWake(_ output: NagiOutput, inputs: NagiInputs) {
        wakeTimer?.invalidate()
        wakeTimer = nil
        // While the overlay is up, its frames sample. Otherwise a timer must, even if the state
        // machine still shows (taken down by the watchdog or the guard mid-fade).
        guard !overlays.isShown else { return }
        let now = inputs.now
        let interval: Double
        if output.showsOverlay {
            interval = 0.1  // forced down: follow the fade to its end
        } else if inputs.screenUnavailable {
            return  // the screen-state notification wakes us
        } else if inputs.paused {
            // Releasing the gallery's hold, or resuming, samples again.
            guard !heldOff, let until = pausedUntil, until != .distantFuture else { return }
            interval = until.timeIntervalSinceNow
        } else if let wake = output.nextWake, wake > now {
            interval = wake - now
        } else {
            interval = 1  // a media assertion holds nagi back; it has no notification
        }
        let timer = Timer(timeInterval: max(interval, 0.1), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.log("wake")
                _ = self?.sample()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        wakeTimer = timer
    }

    /// Takes the overlays down at the leave deadline even if no frame came (SPEC 3.3).
    private func armWatchdog(_ deadline: Double?) {
        guard let deadline else { return }
        guard watchdog == nil else { return }
        let timer = Timer(timeInterval: max(deadline - Self.now, 0), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.overlays.isShown else { return }
                self.forceDown(reason: "watchdog")
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }

    // MARK: - Drawing

    private func drawFrame(display: UInt32, update: CAMetalDisplayLink.Update) {
        let wasShown = overlays.isShown
        let output = sample()
        guard overlays.isShown, let view = overlays.overlays[display]?.view else {
            // Hiding inside this very sample is normal; a frame that finds nagi already down is not.
            if !wasShown { log("frame while hidden") }
            return
        }
        framesThisShowing += 1
        // One simulation for the whole desktop (SPEC 3.4): the driver display advances it,
        // the others draw its latest frame with the current presence.
        let frame: FrameState
        if display == overlays.driverDisplay || self.frame == nil {
            let now = Self.now
            let date = pinnedDate ?? Date()
            let deltaTime = now - (self.frame?.time ?? now)
            let accessibility = Self.accessibility
            windClock += (now - windClockRead) * (accessibility.reduceMotion ? 0.5 : 1)
            windClockRead = now
            if cloudPassEachShowing, framesThisShowing == 1 { weather.sky = .cloudPass(start: windClock) }
            // A new showing starts from the current depth even if its first frame is already leaving.
            if output.phase != .leaving || framesThisShowing == 1 { shownDepth = output.depth }
            frame = FrameState(
                time: now, deltaTime: deltaTime, date: date, phase: output.phase.framePhase,
                presence: output.presence, depth: shownDepth, appearance: Self.appearance,
                accessibility: accessibility, seed: 1, environment: environment(at: date))
            renderer.update(frame)
            self.frame = frame
        } else {
            var latest = self.frame!
            latest.presence = output.presence
            latest.phase = output.phase.framePhase
            frame = latest
        }
        guard let commandBuffer = renderer.queue.makeCommandBuffer() else { return }
        if measurement.emptyFrames {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = update.drawable.texture
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            pass.colorAttachments[0].storeAction = .store
            commandBuffer.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
            commandBuffer.present(update.drawable)
            commandBuffer.commit()
            return
        }
        do {
            try renderer.encode(frame, view: view, strength: strength, into: update.drawable.texture,
                                commandBuffer: commandBuffer)
        } catch {
            log("encode failed: \(error.localizedDescription)")
            return
        }
        commandBuffer.present(update.drawable)
        if trace != nil {
            let times = gpuTimes
            commandBuffer.addCompletedHandler { buffer in times.add((buffer.gpuEndTime - buffer.gpuStartTime) * 1000) }
            if display == overlays.driverDisplay {
                let target = update.targetPresentationTimestamp
                if let last = lastPresentation { frameIntervals.append((target - last) * 1000) }
                lastPresentation = target
            }
            if framesThisShowing % 300 == 0 {
                if let summary = gpuTimes.drain() { log("gpu \(summary)") }
                if let summary = Self.intervalSummary(frameIntervals) { log("frames \(summary)") }
                frameIntervals.removeAll()
            }
        }
        commandBuffer.commit()
    }

    /// "n=… median=… p99=… max=… ms late=…": late frames came over 1.5 times the median
    /// interval after the previous one (a frame was missed).
    private static func intervalSummary(_ intervals: [Double]) -> String? {
        guard !intervals.isEmpty else { return nil }
        let sorted = intervals.sorted()
        let median = sorted[sorted.count / 2]
        let p99 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.99))]
        let late = sorted.filter { $0 > median * 1.5 }.count
        return String(format: "n=%d median=%.2f p99=%.2f max=%.2f ms late=%d", sorted.count, median, p99, sorted.last!, late)
    }

    private static var appearance: Appearance {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
    }

    /// Timestamps for measuring onset and withdrawal (M1-PLAN 7.2). `t` is `systemUptime`.
    private func log(_ event: String) {
        trace?.notice("\(event, privacy: .public) t=\(Self.now, format: .fixed(precision: 4), privacy: .public)")
    }
}

/// Switches for finding where the cost of a shown overlay goes (M1-LOG). Not for users.
public struct MeasurementOptions: Sendable {
    /// Present a cleared drawable instead of running the effects and the final pass.
    public var emptyFrames = false
    /// Ask for EDR on the overlay layer.
    public var edr = true
    /// The overlay's pixel size relative to the display's.
    public var drawableScale = 1.0
    /// Highest frame rate asked of the display link: 60, the author's choice at stop C (D25).
    public var maxFrameRate: Float = 60
    /// An 8-bit sRGB drawable instead of 16-bit float (empty frames only: the effects draw float).
    public var eightBit = false
    public init(emptyFrames: Bool = false, edr: Bool = true, drawableScale: Double = 1, maxFrameRate: Float = 60,
                eightBit: Bool = false) {
        self.emptyFrames = emptyFrames
        self.edr = edr
        self.drawableScale = drawableScale
        self.maxFrameRate = maxFrameRate
        self.eightBit = eightBit
    }
}

/// Collects per-frame GPU times from completion handlers (any thread).
final class GPUTimes: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double] = []

    func add(_ milliseconds: Double) { lock.withLock { values.append(milliseconds) } }

    /// "n=… mean=… p95=… max=… ms", and starts over; nil if empty.
    func drain() -> String? {
        let sorted = lock.withLock { () -> [Double] in
            defer { values.removeAll() }
            return values.sorted()
        }
        guard let max = sorted.last else { return nil }
        let mean = sorted.reduce(0, +) / Double(sorted.count)
        let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
        return String(format: "n=%d mean=%.2f p95=%.2f max=%.2f ms", sorted.count, mean, p95, max)
    }
}

extension NagiStatePhase {
    /// The phase effects see (they are not drawn while active). The engine and nagi-render use it.
    public var framePhase: NagiPhase {
        switch self {
        case .entering: .entering
        case .leaving: .leaving
        case .active, .calm: .calm
        }
    }
}
