import NagiCore
import Testing

/// Which effects run in a showing (SPEC 2.3, M2-PLAN 4.2).
struct SelectionTests {
    /// Deterministic draws: always the first, or always the last, eligible effect.
    struct Pick: RandomNumberGenerator {
        var value: UInt64
        mutating func next() -> UInt64 { value }
    }

    let order = ["komorebi", "rain", "moss"]

    @Test func allRunsEveryEnabledAvailableEffect() {
        var selection = EffectSelection()
        selection.enabled = ["rain", "komorebi"]
        var random = Pick(value: 0)
        #expect(selection.resolve(order: order, unavailable: [], now: 0, using: &random) == ["komorebi", "rain"])
        #expect(selection.resolve(order: order, unavailable: ["rain"], now: 0, using: &random) == ["komorebi"])
        selection.enabled = []
        #expect(selection.resolve(order: order, unavailable: [], now: 0, using: &random).isEmpty)
    }

    @Test func randomKeepsItsDrawForThirtyMinutes() {
        var selection = EffectSelection()
        selection.mode = .random
        selection.enabled = ["komorebi", "rain"]
        var first = Pick(value: 0), last = Pick(value: .max)
        #expect(selection.resolve(order: order, unavailable: [], now: 100, using: &first) == ["komorebi"])
        // Within 30 minutes of the draw, the same effect, whatever the generator says.
        #expect(selection.resolve(order: order, unavailable: [], now: 100 + 1799, using: &last) == ["komorebi"])
        // From the draw, not from the last showing: at 30 minutes it draws again.
        #expect(selection.resolve(order: order, unavailable: [], now: 100 + 1800, using: &last) == ["rain"])
    }

    @Test func randomDrawsAgainWhenItsEffectCannotRun() {
        var selection = EffectSelection()
        selection.mode = .random
        selection.enabled = ["komorebi", "rain"]
        var last = Pick(value: .max), first = Pick(value: 0)
        #expect(selection.resolve(order: order, unavailable: [], now: 0, using: &last) == ["rain"])
        // Permission lost: rain is not drawn even within the 30 minutes.
        #expect(selection.resolve(order: order, unavailable: ["rain"], now: 60, using: &last) == ["komorebi"])
        selection.enabled = ["komorebi"]
        #expect(selection.resolve(order: order, unavailable: [], now: 120, using: &first) == ["komorebi"])
        selection.enabled = []
        #expect(selection.resolve(order: order, unavailable: [], now: 180, using: &first).isEmpty)
    }

    /// M7-PLAN 9 (question 4): by day, fireflies draw nothing; random mode draws another effect.
    @Test func randomLeavesOutSilentEffects() {
        var selection = EffectSelection()
        selection.mode = .random
        selection.enabled = ["komorebi", "rain"]
        var first = Pick(value: 0), last = Pick(value: .max)
        #expect(selection.resolve(order: order, unavailable: [], silent: ["komorebi"], now: 0, using: &first) == ["rain"])
        #expect(selection.upcoming(order: order, unavailable: [], silent: ["rain"], now: 60) == ["komorebi"])
        // A kept draw that has fallen silent is drawn again, within the 30 minutes.
        #expect(selection.resolve(order: order, unavailable: [], silent: ["rain"], now: 60, using: &last) == ["komorebi"])
        // When every eligible effect is silent, it draws as before (and keeps the draw).
        #expect(selection.resolve(order: order, unavailable: [], silent: ["komorebi", "rain"], now: 120,
                                  using: &last) == ["komorebi"])
        #expect(selection.upcoming(order: order, unavailable: [], silent: ["komorebi", "rain"], now: 180)
                == ["komorebi"])
    }

    @Test func allIgnoresSilentEffects() {
        var selection = EffectSelection()
        selection.enabled = ["komorebi", "rain"]
        var random = Pick(value: 0)
        #expect(selection.resolve(order: order, unavailable: [], silent: ["komorebi"], now: 0, using: &random)
                == ["komorebi", "rain"])
        #expect(selection.upcoming(order: order, unavailable: [], silent: ["komorebi"], now: 0) == ["komorebi", "rain"])
    }
}
