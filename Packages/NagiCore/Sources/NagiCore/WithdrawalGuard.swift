import Foundation
import os
import QuartzCore

/// The last line of the safety rule "input makes nagi disappear within T_leave" (SPEC 1.1, 3.3).
///
/// The engine detects input and fades the overlay on the main thread. If the main thread is
/// stuck, neither happens. This guard reads the idle time on its own thread while nagi shows;
/// when it sees input and the overlay is still armed at the deadline, it hides the layers through
/// Core Animation, which does not need the main thread (M1-PLAN 4.3).
///
/// `@unchecked Sendable`: all mutable state is behind `lock`; the layers are only touched
/// inside a Core Animation transaction.
final class WithdrawalGuard: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "org.izawa.Nagi.withdrawal", qos: .userInteractive)
    private let budget: Double
    private var timer: (any DispatchSourceTimer)?
    private var armed = false
    private var layers: [CALayer] = []
    private var previousReading: Double?
    private var inputAt: Double?
    private let idleOffset: Double
    /// The last input as known when nagi showed (same rule as the state machine).
    private var inputAtArm: Double?
    private let trace: Logger?
    private let onHide: @MainActor @Sendable (_ generation: Int) -> Void
    /// Counts arms, so a late cleanup cannot touch a later showing.
    private(set) var generation = 0

    /// - Parameters:
    ///   - budget: seconds from seeing input to hiding. T_leave minus the input source's own lag
    ///     (HIDIdleTime shows a scroll about 0.2 s late) and the compositor's (M1-LOG).
    ///   - idleOffset: the idle reading's floor (NagiTiming.idleOffset).
    ///   - trace: where to log "guard" when it hides the layers.
    ///   - onHide: runs on the main thread once it is free again, to finish the cleanup.
    init(budget: Double, idleOffset: Double, trace: Logger?,
         onHide: @escaping @MainActor @Sendable (_ generation: Int) -> Void) {
        self.budget = budget
        self.idleOffset = idleOffset
        self.trace = trace
        self.onHide = onHide
    }

    /// The overlays changed while shown (a display came or went): guard the new set and keep
    /// any pending deadline.
    @MainActor func replace(_ layers: [CALayer]) {
        lock.withLock { if armed { self.layers = layers } }
    }

    /// Call on the main thread right before the overlay windows come on screen.
    /// - Parameters:
    ///   - reading, at: the idle reading that let nagi show, and when it was taken. Input after
    ///     that moment withdraws nagi, even if the guard's first own reading comes later.
    @MainActor func arm(_ layers: [CALayer], reading: Double, at time: Double) {
        start(layers, inputAtArm: time - (reading - idleOffset))
    }

    /// Whether `generation` is the current arm.
    func isCurrent(_ generation: Int) -> Bool { lock.withLock { self.generation == generation } }



    /// Not main-actor isolated: the timer's handler must not inherit the main actor.
    private func start(_ layers: [CALayer], inputAtArm: Double) {
        lock.withLock {
            // Unhide inside the lock: a hide from the previous arm cannot slip in after it.
            for layer in layers { layer.isHidden = false }
            generation += 1
            self.layers = layers
            armed = true
            previousReading = nil
            inputAt = nil
            self.inputAtArm = inputAtArm
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(8))
        timer.setEventHandler { [weak self] in self?.tick() }
        lock.withLock {
            self.timer?.cancel()
            self.timer = timer
        }
        timer.resume()
    }

    /// Call when the overlay has been taken down normally.
    func disarm() {
        lock.withLock {
            timer?.cancel()
            timer = nil
            layers = []
            armed = false
        }
    }

    private func tick() {
        let reading = SystemSignals.idleReading()
        let now = ProcessInfo.processInfo.systemUptime
        let hidden: Int? = lock.withLock {
            defer { previousReading = reading }
            // Same two signs of input as the state machine: a drop in the reading, or a last input
            // later than the one known when the guard was armed.
            let lastInput = now - (reading - idleOffset)
            let dropped = previousReading.map { reading < $0 - 0.05 } ?? false
            let later = inputAtArm.map { lastInput > $0 + 0.1 } ?? false
            if inputAt == nil, dropped || later { inputAt = now }
            guard let inputAt, now >= inputAt + budget, !layers.isEmpty else { return nil }
            // Hide inside the lock, so a new arm cannot unhide in between.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for layer in layers { layer.isHidden = true }
            CATransaction.commit()
            CATransaction.flush()
            layers = []
            armed = false
            timer?.cancel()
            timer = nil
            return generation
        }
        guard let hidden else { return }
        trace?.notice("guard t=\(now, format: .fixed(precision: 4), privacy: .public)")
        let onHide = onHide
        DispatchQueue.main.async { MainActor.assumeIsolated { onHide(hidden) } }
    }
}
