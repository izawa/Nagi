import Foundation
import NagiKit
import Testing
@testable import KomorebiEffect

/// The menu's note (Effect.note): nothing by day, a line after sunset (DECISIONS D26).
struct NoteTests {
    func frame(sun: Double, moon: Double = -0.5, phase: Double = 0.5, moonlight: Bool = true) -> FrameState {
        var environment = SharedEnvironment()
        environment.sun = CelestialPosition(altitude: sun)
        environment.moon = CelestialPosition(altitude: moon)
        environment.moonPhase = phase
        return FrameState(time: 0, deltaTime: 0, date: Date(), phase: .calm, presence: 1, depth: 0,
                          appearance: .light, parameters: ["moonlight": .flag(moonlight)], seed: 1,
                          environment: environment)
    }

    @Test func notes() {
        #expect(Komorebi.note(frame(sun: 0.8)) == nil)
        // Above the horizon but below the 5° cutoff: not "set".
        #expect(Komorebi.note(frame(sun: 0.03))?.key == "日が低いので、木漏れ日は現れません")
        // After sunset with the moon below the horizon, or moonlight off: nothing shows.
        let none = Komorebi.note(frame(sun: -0.3))
        #expect(none?.key == "日が沈んでいるので、木漏れ日は現れません")
        #expect(Komorebi.note(frame(sun: -0.3, moon: 0.8, moonlight: false))?.key == none?.key)
        // A full moon high in a dark sky: faint moonlight.
        #expect(Komorebi.note(frame(sun: -0.3, moon: 0.8))?.key == "日が沈んでいます。木漏れ日は月明かりで薄く現れます")
    }

    /// Silent (left out of random mode's draw) only when nothing shows; faint moonlight draws.
    @Test func silence() {
        #expect(!Komorebi.isSilent(frame(sun: 0.8)))
        #expect(Komorebi.isSilent(frame(sun: 0.03)))
        #expect(Komorebi.isSilent(frame(sun: -0.3)))
        #expect(Komorebi.isSilent(frame(sun: -0.3, moon: 0.8, moonlight: false)))
        #expect(!Komorebi.isSilent(frame(sun: -0.3, moon: 0.8)))
        var zero = frame(sun: 0.8)
        zero.parameters["strength"] = .number(0)
        #expect(Komorebi.isSilent(zero))
        #expect(Komorebi.note(zero) == nil)
        var unknown = frame(sun: 0.8)
        unknown.parameters["strength"] = .number(.nan)
        #expect(Komorebi.isSilent(unknown))
        // A visible moon that reduced strength makes too faint to see.
        var reduced = frame(sun: -0.3, moon: 0.8)
        reduced.parameters["strength"] = .number(0.1)
        #expect(Komorebi.isSilent(reduced))
    }
}
