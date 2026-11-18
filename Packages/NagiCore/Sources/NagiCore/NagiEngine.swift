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
    public var suppressDuringMedia = true
    /// Paused until this date; `.distantFuture` pauses until resumed.
    public var pausedUntil: Date? {
        didSet { sample() }
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
    /// Set when the watchdog or the guard took nagi down: it stays down until the state
    /// machine has gone back to active, so a fade cannot bring it back.
    private var forcedDown = false
    private var framesThisShowing = 0
    /// GPU milliseconds of recent frames, logged every few seconds with `--trace` (M1-PLAN 7.3).
    private let gpuTimes = GPUTimes()
    private let withdrawalGuard: WithdrawalGuard
    private let trace: Logger?
    private var screenObserver: (any NSObjectProtocol)?

    private let measurement: MeasurementOptions

    public init(effects: [any Effect.Type], timing: NagiTiming = NagiTiming(), trace: Bool = false,
                measurement: MeasurementOptions = .init()) throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw NagiCoreError("no Metal device") }
        renderer = try FrameRenderer(device: device, effects: effects)
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

    /// "See it now" (SPEC 2.4, M1-PLAN 4.5).
    public func preview() {
        // Take the reading first, so the click that asked for the preview is not new input.
        sample()
        machine.requestPreview(at: Self.now)
        log("preview")
        sample()
    }

    // MARK: - Sampling

    private static var now: Double { ProcessInfo.processInfo.systemUptime }

    /// Reads the signals and steps the state machine; shows or hides the overlays and schedules
    /// the next wake. Called by the wake timer, by every frame and by signal changes.
    @discardableResult private func sample() -> NagiOutput {
        let now = Self.now
        if now - mediaCheckedAt >= 1 {
            mediaActive = SystemSignals.mediaActive()
            mediaCheckedAt = now
        }
        let paused = pausedUntil.map { $0 > Date() } ?? false
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
            guard let until = pausedUntil, until != .distantFuture else { return }  // resume wakes us
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
            frame = FrameState(
                time: now, deltaTime: now - (self.frame?.time ?? now), date: date, phase: phase(output.phase),
                presence: output.presence, depth: output.depth, appearance: Self.appearance, seed: 1,
                environment: EnvironmentModel.environment(
                    at: date, location: location ?? EnvironmentModel.defaultLocation(at: date)))
            renderer.update(frame)
            self.frame = frame
        } else {
            var latest = self.frame!
            latest.presence = output.presence
            latest.phase = phase(output.phase)
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
            if framesThisShowing % 300 == 0, let summary = gpuTimes.drain() { log("gpu \(summary)") }
        }
        commandBuffer.commit()
    }

    private func phase(_ phase: NagiStatePhase) -> NagiPhase {
        switch phase {
        case .entering: .entering
        case .leaving: .leaving
        case .active, .calm: .calm
        }
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
    /// Highest frame rate asked of the display link.
    public var maxFrameRate: Float = 120
    /// An 8-bit sRGB drawable instead of 16-bit float (empty frames only: the effects draw float).
    public var eightBit = false
    public init(emptyFrames: Bool = false, edr: Bool = true, drawableScale: Double = 1, maxFrameRate: Float = 120,
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
