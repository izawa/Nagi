// The pure state machine of nagi (SPEC 2.1, 2.2; M1-PLAN 4.3-4.5). No clocks or OS calls: the
// engine feeds it timestamps and readings, so tests can drive it.

public struct NagiTiming: Sendable {
    public let onset: Double
    public let idleOffset: Double
    public let entryDuration: Double
    public let fadeOut: Double
    public let leaveBudget: Double
    /// How fast depth falls while the hands move (not while they rest before nagi shows again):
    /// a one-second scroll costs about five seconds of depth (DECISIONS D22).
    public let depthDecayPerActiveSecond: Double
    public let mediaGrace: Double
    public let previewDuration: Double
    /// Depth gained per second of stillness: 1 normally, 0.5 for "slow" (settings, D26).
    public let depthGrowthRate: Double

    public init(
        onset: Double = 3.0,
        idleOffset: Double = 0,
        entryDuration: Double = 4.0,
        fadeOut: Double = 0.4,
        leaveBudget: Double = 0.8,
        depthDecayPerActiveSecond: Double = 5,
        mediaGrace: Double = 3.0,
        previewDuration: Double = 30,
        depthGrowthRate: Double = 1
    ) {
        precondition((1...60).contains(onset), "Onset must be between 1 and 60 seconds")
        precondition(fadeOut < leaveBudget, "Fade-out must be shorter than the leave budget")
        precondition(
            [idleOffset, entryDuration, fadeOut, leaveBudget, depthDecayPerActiveSecond,
             mediaGrace, previewDuration, depthGrowthRate].allSatisfy { $0.isFinite && $0 >= 0 },
            "Timing values must be finite and nonnegative"
        )
        self.onset = onset
        self.idleOffset = idleOffset
        self.entryDuration = entryDuration
        self.fadeOut = fadeOut
        self.leaveBudget = leaveBudget
        self.depthDecayPerActiveSecond = depthDecayPerActiveSecond
        self.mediaGrace = mediaGrace
        self.previewDuration = previewDuration
        self.depthGrowthRate = depthGrowthRate
    }

    /// The same timing with the two values a user can set (SPEC 2.5).
    public func with(onset: Double, depthGrowthRate: Double) -> NagiTiming {
        NagiTiming(onset: min(max(onset, 1), 60), idleOffset: idleOffset, entryDuration: entryDuration,
                   fadeOut: fadeOut, leaveBudget: leaveBudget, depthDecayPerActiveSecond: depthDecayPerActiveSecond,
                   mediaGrace: mediaGrace, previewDuration: previewDuration,
                   depthGrowthRate: depthGrowthRate.isFinite ? max(depthGrowthRate, 0) : 1)
    }
}

public struct NagiInputs: Sendable {
    public let now: Double
    public let idleReading: Double
    public let paused: Bool
    public let screenUnavailable: Bool
    public let mediaActive: Bool
    public let suppressDuringMedia: Bool

    public init(
        now: Double,
        idleReading: Double,
        paused: Bool = false,
        screenUnavailable: Bool = false,
        mediaActive: Bool = false,
        suppressDuringMedia: Bool = true
    ) {
        self.now = now
        self.idleReading = idleReading
        self.paused = paused
        self.screenUnavailable = screenUnavailable
        self.mediaActive = mediaActive
        self.suppressDuringMedia = suppressDuringMedia
    }

    fileprivate var blocksOverlay: Bool { paused || screenUnavailable }
}

public enum NagiStatePhase: Equatable, Sendable {
    case active, entering, calm, leaving
}

public struct NagiOutput: Sendable {
    public let phase: NagiStatePhase
    public let presence: Double
    public let depth: Double
    public let nextWake: Double?
    public let leaveDeadline: Double?

    public var showsOverlay: Bool { presence > 0 || phase != .active }
}

/// Call `step` and `requestPreview` in timestamp order using the same monotonic clock.
public struct NagiStateMachine: Sendable {
    private enum State: Sendable {
        case active
        case entering(startedAt: Double)
        case calm
        case leaving(startedAt: Double, initialPresence: Double)

        var phase: NagiStatePhase {
            switch self {
            case .active: .active
            case .entering: .entering
            case .calm: .calm
            case .leaving: .leaving
            }
        }
    }

    public private(set) var timing: NagiTiming
    private var state: State = .active
    private var depth: Double = 0
    private var updatedAt: Double?
    private var previousInputs: NagiInputs?
    private var lastMediaActiveAt: Double?
    private var previewEndsAt: Double?
    /// "See it now" was asked for and waits for the hands to rest (2026-11-18, author).
    private var previewRequestedAt: Double?
    /// Active time not yet charged against depth; `step` charges the part the hands were moving.
    private var unchargedActive: Double = 0
    /// Input within this many seconds counts as the hands moving.
    private static let movingWindow = 1.0
    private static let previewStillness = 0.5
    private static let previewPatience = 10.0
    /// The last input as known when nagi showed (or a preview was asked for); nil while active
    /// or leaving. Any later input withdraws nagi.
    private var inputAtEntry: Double?

    public init(timing: NagiTiming = NagiTiming()) {
        self.timing = timing
    }

    /// New timing from `now` on: time so far runs under the old one, and depth, phase and any
    /// preview carry over.
    public mutating func setTiming(_ timing: NagiTiming, at now: Double) {
        advance(to: now)
        self.timing = timing
    }

    /// "See it now": nagi shows as soon as the hands have rested for 0.5 s (not T_onset), media
    /// or not, and stays 30 s unless there is input. The click that asked for it, and the hand
    /// still moving after it, do not cancel it; it gives up after 10 s of continued input.
    /// While nagi already shows, the 30 s start again.
    public mutating func requestPreview(at now: Double) {
        advance(to: now)
        guard previousInputs?.blocksOverlay != true, timing.previewDuration > 0 else { return }
        switch state {
        case .entering, .calm: previewEndsAt = now + timing.previewDuration
        case .active, .leaving: previewRequestedAt = now
        }
    }

    public mutating func step(_ inputs: NagiInputs) -> NagiOutput {
        let now = inputs.now
        // A sample that completes a departure reports the overlay hidden.
        let wasActive = state.phase == .active
        advance(to: now)

        let idle = trueIdle(inputs.idleReading)
        depth = max(0, depth - movingTime(idle: idle, now: now) * timing.depthDecayPerActiveSecond)
        unchargedActive = 0
        // Input shows as a drop in the reading, or as a last input later than the one known when
        // nagi showed. The second also catches input that holds the reading at its floor, and a
        // single key right after "see it now". The reading grows in ~12 ms steps (M1-LOG), so
        // a 0.1 s tolerance is enough.
        let dropped = previousInputs.map { previous in
            inputs.idleReading < previous.idleReading - 0.05 || idle < trueIdle(previous.idleReading)
        } ?? false
        let inputSinceShown = inputAtEntry.map { lastInput(inputs) > $0 + Self.inputTolerance } ?? false
        let inputDetected = dropped || inputSinceShown
        previousInputs = inputs

        if inputs.mediaActive { lastMediaActiveAt = now }
        let mediaInGrace = lastMediaActiveAt.map { now < $0 + timing.mediaGrace } ?? false
        let mediaSuppresses = inputs.suppressDuringMedia && (inputs.mediaActive || mediaInGrace)

        if let requested = previewRequestedAt, now - requested > Self.previewPatience { previewRequestedAt = nil }
        if inputs.blocksOverlay {
            state = .active
            inputAtEntry = nil
            previewEndsAt = nil
            previewRequestedAt = nil
        } else {
            if inputDetected { previewEndsAt = nil }

            switch state {
            case .active where wasActive:
                if previewRequestedAt != nil, idle >= Self.previewStillness {
                    previewRequestedAt = nil
                    previewEndsAt = now + timing.previewDuration
                    enter(at: now)
                } else if idle >= timing.onset && !mediaSuppresses {
                    enter(at: now)
                }
            case .entering, .calm:
                if inputDetected || (mediaSuppresses && previewEndsAt == nil) { leave(at: now) }
            case .active, .leaving:
                break
            }
        }

        let phase = state.phase
        let waitForOnset = previewRequestedAt != nil
            ? max(0, Self.previewStillness - idle) : max(0, timing.onset - idle)
        let nextWake = phase == .active ? now + waitForOnset : nil
        let leaveDeadline: Double?
        if case let .leaving(startedAt, _) = state {
            leaveDeadline = startedAt + timing.leaveBudget
        } else {
            leaveDeadline = nil
        }
        return NagiOutput(
            phase: phase, presence: presence(at: now), depth: depth,
            nextWake: nextWake, leaveDeadline: leaveDeadline
        )
    }

    private static let inputTolerance = 0.1

    /// How much of the active time since the previous sample the hands were moving (DECISIONS
    /// D22). Samples are sparse while nagi is hidden (every few seconds), so this is inferred: the
    /// hands count as moving up to a second after the last input; if they were moving at the
    /// previous sample and input kept coming, they moved throughout, otherwise only from the
    /// latest input on. Resting before nagi shows again costs nothing.
    private func movingTime(idle: Double, now: Double) -> Double {
        guard unchargedActive > 0 else { return 0 }
        let start = now - unchargedActive
        let lastInput = now - idle
        let previousIdle = previousInputs.map { trueIdle($0.idleReading) } ?? .infinity
        let previousLastInput = previousInputs.map { $0.now - previousIdle } ?? -.infinity
        // The previous input's last second, then the new input's: their union within the interval.
        func clipped(_ from: Double, _ to: Double) -> (Double, Double) { (max(from, start), min(to, now)) }
        let tail = clipped(previousLastInput, previousLastInput + Self.movingWindow)
        guard lastInput > start else { return max(0, tail.1 - tail.0) }
        // While hidden the engine samples about once per onset, so input that keeps coming has its
        // last inputs within an onset (and some timer slack) of each other; a longer gap was a rest.
        let continuous = previousIdle < Self.movingWindow && lastInput - previousLastInput <= timing.onset + 0.5
        let latest = clipped(continuous ? start : lastInput, lastInput + Self.movingWindow)
        let union = max(0, tail.1 - tail.0) + max(0, latest.1 - latest.0)
            - max(0, min(tail.1, latest.1) - max(tail.0, latest.0))
        return min(unchargedActive, union)
    }

    /// When the last input happened, from a reading (unclamped, so it moves smoothly).
    private func lastInput(_ inputs: NagiInputs) -> Double {
        inputs.now - (inputs.idleReading - timing.idleOffset)
    }

    private func trueIdle(_ reading: Double) -> Double {
        max(0, reading - timing.idleOffset)
    }

    private mutating func enter(at now: Double) {
        state = timing.entryDuration == 0 ? .calm : .entering(startedAt: now)
        inputAtEntry = previousInputs.map(lastInput) ?? now
    }

    private mutating func leave(at now: Double) {
        inputAtEntry = nil
        let initialPresence = presence(at: now)
        state = initialPresence > 0 && timing.fadeOut > 0
            ? .leaving(startedAt: now, initialPresence: initialPresence)
            : .active
    }

    private func presence(at now: Double) -> Double {
        switch state {
        case .active:
            return 0
        case let .entering(startedAt):
            let progress = min(1, (now - startedAt) / timing.entryDuration)
            return progress * progress * (3 - 2 * progress)
        case .calm:
            return 1
        case let .leaving(startedAt, initialPresence):
            let progress = min(1, (now - startedAt) / timing.fadeOut)
            return initialPresence * (1 - progress)
        }
    }

    private mutating func advance(to now: Double) {
        let previousTime = updatedAt ?? now
        updatedAt = now
        var decayFrom = previousTime

        switch state {
        case .entering, .calm:
            if let expiry = previewEndsAt, now >= expiry {
                depth += (expiry - previousTime) * timing.depthGrowthRate
                leave(at: expiry)
                decayFrom = expiry
            } else {
                depth += (now - previousTime) * timing.depthGrowthRate
                if case let .entering(startedAt) = state, now >= startedAt + timing.entryDuration {
                    state = .calm
                }
                return
            }
        case .active, .leaving:
            break
        }

        unchargedActive += now - decayFrom
        if case let .leaving(startedAt, _) = state, now >= startedAt + timing.fadeOut {
            state = .active
        }
        if let expiry = previewEndsAt, now >= expiry { previewEndsAt = nil }
    }
}
