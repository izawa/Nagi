import NagiKit
import Testing
@testable import NagiCore

/// The preview helpers nagi-render and the gallery share (DECISIONS D24).
struct PreviewTests {
    /// Entry runs over the core's 4 s; the input is applied at its own time whatever the frame
    /// rate, and depth is held while leaving.
    @Test func replayEntersAndLeaves() {
        var replay = EnvelopeReplay(inputAt: 4.1)
        let start = replay.step(at: 0, depth: 10)
        #expect(start.phase == .entering)
        let calm = replay.step(at: 4, depth: 14)
        #expect(calm.phase == .calm && calm.presence == 1)
        // One frame a second: the 0.4 s fade from 4.1 s is over by 5 s.
        let after = replay.step(at: 5, depth: 15)
        #expect(after.presence == 0)
        var leaving = EnvelopeReplay(inputAt: 4.1)
        _ = leaving.step(at: 0, depth: 10)
        _ = leaving.step(at: 4, depth: 14)
        let fading = leaving.step(at: 4.3, depth: 14.3)
        #expect(fading.phase == .leaving)
        #expect(fading.depth == 14)
    }

    /// An input asked for later (the gallery's button) interrupts an entry.
    @Test func laterInputInterrupts() {
        var replay = EnvelopeReplay()
        _ = replay.step(at: 0, depth: 0)
        #expect(replay.step(at: 2, depth: 0).phase == .entering)
        replay.input(at: 2)
        #expect(replay.step(at: 2.5, depth: 0).presence == 0)
    }

    /// The gallery's input button on a calm picture: a fade from full, not a jump to nothing.
    @Test func inputFromCalmFades() {
        var replay = EnvelopeReplay(startingCalm: true, depth: 60)
        #expect(replay.step(at: 0, depth: 60).phase == .calm)
        replay.input(at: 0.5)
        let fading = replay.step(at: 0.6, depth: 60)
        #expect(fading.phase == .leaving && fading.presence > 0.5)
        // The gallery's order: the input before the first step keeps the depth on screen.
        var direct = EnvelopeReplay(startingCalm: true, depth: 60)
        direct.input(at: 0)
        let first = direct.step(at: 0.05, depth: 0)
        #expect(first.phase == .leaving && first.depth == 60)
    }
}
