import NagiCore
import Testing

// These tests use a 0.9 s reading floor (the CGEventSource reading); the default is 0 (HIDIdleTime).

@Test func onsetUsesCorrectedIdleAndProjectsNextWake() {
    var machine = NagiStateMachine(timing: NagiTiming(idleOffset: 0.9))
    let active = machine.step(.init(now: 10, idleReading: 1.9))
    #expect(active.phase == .active)
    #expect(!active.showsOverlay)
    #expect(active.nextWake == 12)

    #expect(machine.step(.init(now: 11.9, idleReading: 3.8)).phase == .active)
    let entry = machine.step(.init(now: 12, idleReading: 3.9))
    #expect(entry.phase == .entering)
    #expect(entry.showsOverlay)
    #expect(entry.presence == 0)
    #expect(entry.nextWake == nil)

    var initiallyIdle = NagiStateMachine(timing: .init(onset: 2, idleOffset: 1.5))
    #expect(initiallyIdle.step(.init(now: 10, idleReading: 3.5)).phase == .entering)
}

@Test func entrySmoothsPresenceAndGrowsDepthThroughCalm() {
    var machine = NagiStateMachine(timing: NagiTiming(idleOffset: 0.9))
    _ = machine.step(.init(now: 0, idleReading: 3.9))

    let quarter = machine.step(.init(now: 1, idleReading: 4.9))
    #expect(quarter.phase == .entering)
    #expect(quarter.presence == 0.15625)
    #expect(quarter.depth == 1)

    let calm = machine.step(.init(now: 4, idleReading: 7.9))
    #expect(calm.phase == .calm)
    #expect(calm.presence == 1)
    #expect(calm.depth == 4)
    #expect(machine.step(.init(now: 6, idleReading: 9.9)).depth == 6)
}

@Test func inputInterruptsEntryAndFadeMeetsTheOriginalDeadline() throws {
    var machine = NagiStateMachine(timing: NagiTiming(idleOffset: 0.9))
    _ = machine.step(.init(now: 0, idleReading: 3.9))
    _ = machine.step(.init(now: 1, idleReading: 4.9))

    let leaving = machine.step(.init(now: 2, idleReading: 0.9))
    #expect(leaving.phase == .leaving)
    #expect(leaving.presence == 0.5)
    #expect(leaving.depth == 2)
    #expect(leaving.nextWake == nil)
    let deadline = try #require(leaving.leaveDeadline)
    #expect(deadline == 2.8)

    let repeatedInput = machine.step(.init(now: 2.05, idleReading: 0.8))
    #expect(repeatedInput.phase == .leaving)
    #expect(repeatedInput.leaveDeadline == deadline)
    #expect(abs(repeatedInput.presence - 0.4375) < 1e-10)
    #expect(abs(repeatedInput.depth - 1) < 1e-10)

    let goneAt = 2.4
    let active = machine.step(.init(now: goneAt, idleReading: 0.8))
    #expect(goneAt < deadline)
    #expect(active.phase == .active)
    #expect(active.presence == 0)
    #expect(active.depth == 0)
    #expect(!active.showsOverlay)
    #expect(active.leaveDeadline == nil)
}

@Test func inputUsesBothRawAndCorrectedDrops() {
    // Without input the reading grows with time (here from the preview click at 0).
    var machine = NagiStateMachine(timing: NagiTiming(idleOffset: 0.9))
    machine.requestPreview(at: 0)
    _ = machine.step(.init(now: 1, idleReading: 1.9))
    #expect(machine.step(.init(now: 2, idleReading: 2.9)).phase == .entering)
    #expect(machine.step(.init(now: 3, idleReading: 0.9)).phase == .leaving)
    #expect(machine.step(.init(now: 3.4, idleReading: 1.3)).phase == .active)
    #expect(machine.step(.init(now: 4, idleReading: 1.9)).phase == .active)

    var corrected = NagiStateMachine(timing: NagiTiming(idleOffset: 0.9))
    _ = corrected.step(.init(now: 0, idleReading: 5))
    let smallTrueIdleDrop = corrected.step(.init(now: 4, idleReading: 4.98))
    #expect(smallTrueIdleDrop.phase == .leaving)
    #expect(smallTrueIdleDrop.presence == 1)
}

@Test func activeDepthKeepsDecayingAfterDeparture() {
    var machine = NagiStateMachine(timing: NagiTiming(idleOffset: 0.9))
    _ = machine.step(.init(now: 0, idleReading: 3.9))
    #expect(machine.step(.init(now: 20, idleReading: 0.9)).depth == 20)
    #expect(machine.step(.init(now: 20.5, idleReading: 0.9)).depth == 10)
    #expect(machine.step(.init(now: 20.75, idleReading: 0.9)).depth == 5)
    #expect(machine.step(.init(now: 21.5, idleReading: 0.9)).depth == 0)
}

@Test func mediaSuppressesThroughGraceAndCanInterruptEntry() {
    var machine = NagiStateMachine(timing: NagiTiming(idleOffset: 0.9))
    #expect(machine.step(.init(now: 0, idleReading: 10, mediaActive: true)).phase == .active)
    #expect(machine.step(.init(now: 2, idleReading: 12, mediaActive: true)).phase == .active)
    #expect(machine.step(.init(now: 4.9, idleReading: 14.9)).phase == .active)
    #expect(machine.step(.init(now: 5, idleReading: 15)).phase == .entering)
    let leaving = machine.step(.init(now: 7, idleReading: 17, mediaActive: true))
    #expect(leaving.phase == .leaving)
    #expect(leaving.presence == 0.5)
    #expect(leaving.leaveDeadline == 7.8)

    var allowed = NagiStateMachine(timing: NagiTiming(idleOffset: 0.9))
    let unsuppressed = allowed.step(.init(now: 0, idleReading: 10, mediaActive: true, suppressDuringMedia: false))
    #expect(unsuppressed.phase == .entering)
    #expect(allowed.step(.init(now: 4, idleReading: 14, mediaActive: true, suppressDuringMedia: false)).phase == .calm)
}

@Test(arguments: [true, false]) func pauseAndScreenUnavailabilityHideAndBlockPreview(paused: Bool) {
    var machine = NagiStateMachine(timing: NagiTiming(idleOffset: 0.9))
    machine.requestPreview(at: 0)
    #expect(machine.step(.init(now: 0.6, idleReading: 1.5)).phase == .entering)
    #expect(machine.step(.init(now: 4.7, idleReading: 5.6)).phase == .calm)

    let hidden = machine.step(.init(now: 5, idleReading: 5.9, paused: paused, screenUnavailable: !paused))
    #expect(hidden.phase == .active)
    #expect(!hidden.showsOverlay)
    #expect(hidden.presence == 0)
    #expect(hidden.leaveDeadline == nil)

    machine.requestPreview(at: 6)
    #expect(machine.step(.init(now: 7, idleReading: 1.5)).phase == .active)  // below onset; the preview was refused
}

@Test func previewWaitsForStillnessIgnoresMediaAndCanBeExtended() {
    var machine = NagiStateMachine(timing: NagiTiming(idleOffset: 0.9))
    _ = machine.step(.init(now: 0, idleReading: 0.9, mediaActive: true))
    // The engine samples right before asking, so the click at 1 is known.
    _ = machine.step(.init(now: 1, idleReading: 0.9, mediaActive: true))
    machine.requestPreview(at: 1)
    let waiting = machine.step(.init(now: 1.2, idleReading: 1.1, mediaActive: true))
    #expect(waiting.phase == .active)
    #expect(waiting.nextWake == 1.5)
    #expect(machine.step(.init(now: 1.5, idleReading: 1.45, mediaActive: true)).phase == .entering)
    #expect(machine.step(.init(now: 2.5, idleReading: 2.4, mediaActive: true)).presence == 0.15625)

    machine.requestPreview(at: 3)  // already showing: 30 s from now
    #expect(machine.step(.init(now: 5.5, idleReading: 5.4, mediaActive: true)).phase == .calm)
    #expect(machine.step(.init(now: 32, idleReading: 31.9, mediaActive: true)).phase == .calm)
    let expired = machine.step(.init(now: 33, idleReading: 32.9, mediaActive: true))
    #expect(expired.phase == .leaving)
    #expect(expired.leaveDeadline == 33.8)
    #expect(machine.step(.init(now: 33.4, idleReading: 33.3, mediaActive: true)).phase == .active)
}

/// Hands that keep moving after "see it now" keep it waiting; it gives up after 10 s.
@Test func previewWaitsWhileInputContinuesAndGivesUp() {
    var machine = NagiStateMachine(timing: NagiTiming(idleOffset: 0.9))
    _ = machine.step(.init(now: 0, idleReading: 0.9))
    machine.requestPreview(at: 0)
    #expect(machine.step(.init(now: 5, idleReading: 0.9)).phase == .active)
    #expect(machine.step(.init(now: 10.5, idleReading: 0.9)).phase == .active)
    #expect(machine.step(.init(now: 11.2, idleReading: 1.6)).phase == .active)  // gave up; onset not reached
}

/// Input after the preview has shown withdraws it as usual.
@Test func inputAfterAPreviewShowsEndsIt() {
    var machine = NagiStateMachine(timing: NagiTiming(idleOffset: 0.9))
    _ = machine.step(.init(now: 0, idleReading: 0.9))
    machine.requestPreview(at: 0)
    #expect(machine.step(.init(now: 0.3, idleReading: 1.2)).phase == .active)
    #expect(machine.step(.init(now: 0.6, idleReading: 1.5)).phase == .entering)
    #expect(machine.step(.init(now: 1.2, idleReading: 1.1)).phase == .leaving)  // a key at 1.0
}

@Test func aPreviewDuringTheFadeWaitsForTheFadeAndStillness() {
    var machine = NagiStateMachine(timing: NagiTiming(idleOffset: 0.9))
    _ = machine.step(.init(now: 0, idleReading: 3.9))       // enters
    _ = machine.step(.init(now: 5, idleReading: 8.9))       // calm
    #expect(machine.step(.init(now: 6, idleReading: 0.9)).phase == .leaving)
    machine.requestPreview(at: 6.1)
    #expect(machine.step(.init(now: 6.5, idleReading: 1.4)).phase == .active)
    #expect(machine.step(.init(now: 6.6, idleReading: 1.5)).phase == .entering)
}
