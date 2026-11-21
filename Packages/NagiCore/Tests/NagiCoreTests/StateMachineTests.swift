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
    #expect(abs(repeatedInput.depth - 1.75) < 1e-10)  // 0.05 s of moving at 5 per second

    let goneAt = 2.4
    let active = machine.step(.init(now: goneAt, idleReading: 0.8))
    #expect(goneAt < deadline)
    #expect(active.phase == .active)
    #expect(active.presence == 0)
    #expect(abs(active.depth) < 1e-10)
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

/// Depth falls while the hands move and for a second after, not while they rest before nagi
/// shows again (DECISIONS D22): a short scroll does not start the stillness over.
@Test func depthFallsOnlyWhileTheHandsMove() {
    var machine = NagiStateMachine(timing: NagiTiming(idleOffset: 0.9))
    _ = machine.step(.init(now: 0, idleReading: 3.9))
    #expect(machine.step(.init(now: 20, idleReading: 0.9)).depth == 20)
    #expect(machine.step(.init(now: 20.5, idleReading: 0.9)).depth == 17.5)
    // Resting 3 s after the last input: only the first second of it counts.
    #expect(machine.step(.init(now: 23.5, idleReading: 3.9)).depth == 12.5)
    // nagi showed again at 23.5 with the depth it kept, and it grows from there.
    let back = machine.step(.init(now: 24, idleReading: 4.4))
    #expect(back.depth == 13)
    #expect(back.phase == .entering)
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

/// Samples are sparse while nagi is hidden: a single key after a long rest must not count the
/// rest as movement, while steady typing across samples counts throughout (Codex's review).
@Test func sparseSamplesCountOnlyTheMoving() {
    var machine = NagiStateMachine(timing: NagiTiming(idleOffset: 0.9))
    _ = machine.step(.init(now: 0, idleReading: 3.9))
    _ = machine.step(.init(now: 100, idleReading: 103.9))   // calm, depth 100
    #expect(machine.step(.init(now: 100.2, idleReading: 0.9)).phase == .leaving)  // a key
    // Hidden and resting; the next sample a while later, a single key just before it.
    let late = machine.step(.init(now: 130, idleReading: 0.95))
    // depth 100.2, less the key at 100.2 (its second) and the key at 129.95 (0.05 s), at 5 per s.
    #expect(abs(late.depth - (100.2 - 1.05 * 5)) < 1e-9)
    // Typing steadily, sampled every 3 s: each interval counts in full.
    let typing1 = machine.step(.init(now: 133, idleReading: 0.9))
    let typing2 = machine.step(.init(now: 136, idleReading: 0.9))
    #expect(abs((typing1.depth - typing2.depth) - 15) < 1e-9)
    // A wake a little late (timer slack) is still steady typing.
    let typing3 = machine.step(.init(now: 139.2, idleReading: 0.9))
    #expect(abs((typing2.depth - typing3.depth) - 16) < 1e-9)
}


/// "See it now" starts deepened, carries on as an ordinary calm after its 30 s while the hands
/// rest, and its showing is marked (for the clear sky) until nagi is fully gone; the showing
/// after that, and one that started on its own, are not.
@Test func previewShowingIsMarkedUntilGone() {
    var machine = NagiStateMachine(timing: NagiTiming(idleOffset: 0.9))
    machine.requestPreview(at: 0)
    let opening = machine.step(.init(now: 0.6, idleReading: 1.5))
    #expect(opening.startedByPreview)
    #expect(opening.depth == 120)
    #expect(machine.step(.init(now: 4.7, idleReading: 5.6)).startedByPreview)
    // The 30 s ended at 30.6: the hands still rest, so nagi stays.
    let after = machine.step(.init(now: 31, idleReading: 31.9))
    #expect(after.phase == .calm)
    #expect(after.startedByPreview)
    let moved = machine.step(.init(now: 40, idleReading: 0.9))
    #expect(moved.phase == .leaving)
    #expect(moved.startedByPreview)
    let gone = machine.step(.init(now: 40.5, idleReading: 1.4))
    #expect(gone.phase == .active)
    #expect(!gone.startedByPreview)
    let back = machine.step(.init(now: 43, idleReading: 3.9))
    #expect(back.phase == .entering)
    #expect(!back.startedByPreview)

    var ordinary = NagiStateMachine(timing: NagiTiming(idleOffset: 0.9))
    let shown = ordinary.step(.init(now: 0, idleReading: 1000))
    #expect(shown.phase == .entering)
    #expect(!shown.startedByPreview)
}

/// A preview cut short leaves the stillness gathered as it was, so the next ordinary showing
/// opens shallow; and with a long onset the preview does not outlast it as a calm.
@Test func previewDepthAndOnsetStayThePreviews() {
    var machine = NagiStateMachine(timing: NagiTiming(idleOffset: 0.9))
    machine.requestPreview(at: 0)
    #expect(machine.step(.init(now: 0.6, idleReading: 1.5)).depth == 120)
    #expect(machine.step(.init(now: 1.6, idleReading: 0.9)).phase == .leaving)
    _ = machine.step(.init(now: 2.1, idleReading: 1.4))
    let next = machine.step(.init(now: 5.1, idleReading: 4.4))
    #expect(next.phase == .entering)
    #expect(next.depth < 5)

    var patient = NagiStateMachine(timing: NagiTiming(onset: 60, idleOffset: 0.9))
    patient.requestPreview(at: 0)
    #expect(patient.step(.init(now: 0.6, idleReading: 1.5)).phase == .entering)
    #expect(patient.step(.init(now: 30, idleReading: 30.9)).phase == .calm)
    #expect(patient.step(.init(now: 31, idleReading: 31.9)).phase == .active)  // left at 30.6, faded by 31
}

/// A sample that comes late, past the preview's end and its whole fade, finds nagi already gone
/// when it may not stay (media plays): the fade started at the end, not at the late sample.
@Test func previewEndsOnTimeWhenSamplesAreLate() {
    var machine = NagiStateMachine(timing: NagiTiming(idleOffset: 0.9))
    machine.requestPreview(at: 0)
    _ = machine.step(.init(now: 0.6, idleReading: 1.5, mediaActive: true))
    #expect(machine.step(.init(now: 20, idleReading: 20.9, mediaActive: true)).phase == .calm)
    let late = machine.step(.init(now: 32, idleReading: 32.9, mediaActive: true))
    #expect(late.phase == .active)
    #expect(!late.showsOverlay)
    #expect(late.depth < 30.7)  // the stillness up to the end at 30.6, not to the late sample
}
