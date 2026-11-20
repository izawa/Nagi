import CoreGraphics
import NagiKit
import Testing
@testable import MossEffect

/// Where moss may grow (SPEC 4.3, M3-PLAN 4).
struct MossTests {
    let display = CGRect(x: 0, y: 0, width: 1280, height: 720)

    func window(_ id: UInt32, _ frame: CGRect, role: WindowInfo.Role = .surface, age: Double = 7200) -> WindowInfo {
        WindowInfo(id: id, frame: frame, role: role, stationarySeconds: age)
    }

    func snapshot(_ windows: [WindowInfo]) -> WindowSnapshot {
        WindowSnapshot(frontToBack: windows, layoutRevision: 1, usableAreas: [display], desktopSeconds: 7200)
    }

    @Test func growthStartsAtTenMinutesAndEndsAtTwoHours() {
        #expect(Moss.growth(age: 0) == 0)
        #expect(Moss.growth(age: 600) == 0)
        #expect(Moss.growth(age: 601) > 0)
        #expect(Moss.growth(age: 7200) == 1)
        #expect(Moss.growth(age: .infinity) == 1)
        #expect(Moss.growth(age: .nan) == 0)
    }

    @Test func onePatchPerWindowAndTwoCorners() {
        let patches = Moss.patches(snapshot([window(1, CGRect(x: 100, y: 100, width: 600, height: 400))]))
        #expect(patches.filter { $0.kind == .window }.count == 1)
        #expect(patches.filter { $0.kind != .window }.count == 2)
        let band = patches[0]
        // Out 20 points above the top, and down the sides as far as the corners wrap.
        #expect(band.quad == CGRect(x: 80, y: 80, width: 640, height: 48))
        #expect(band.seed == 1)
    }

    @Test func occludersGrowNothingButCover() {
        let panel = window(2, CGRect(x: 300, y: 60, width: 200, height: 120), role: .occluder)
        let patches = Moss.patches(snapshot([panel, window(1, CGRect(x: 100, y: 100, width: 600, height: 400))]))
        #expect(patches.allSatisfy { $0.seed != 2 })
        #expect(patches.first { $0.seed == 1 }?.fronts == [panel.frame])
    }

    @Test func aBandWhollyCoveredIsLeftOut() {
        let front = window(2, CGRect(x: 0, y: 0, width: 1280, height: 720), role: .occluder)
        let patches = Moss.patches(snapshot([front, window(1, CGRect(x: 100, y: 100, width: 600, height: 400))]))
        #expect(patches.isEmpty)
    }

    /// Dew on a still morning (M3-PLAN 5.3): low in the east only, and less under rain.
    @Test func dewOnlyOnStillMornings() {
        let east = CelestialPosition(altitude: 10 * .pi / 180, azimuth: .pi / 2)
        let west = CelestialPosition(altitude: 10 * .pi / 180, azimuth: 3 * .pi / 2)
        let high = CelestialPosition(altitude: 40 * .pi / 180, azimuth: .pi / 2)
        #expect(Moss.dew(sun: east, depth: 150, precipitation: 0) > 0.9)
        #expect(Moss.dew(sun: west, depth: 150, precipitation: 0) == 0)
        #expect(Moss.dew(sun: high, depth: 150, precipitation: 0) == 0)
        #expect(Moss.dew(sun: east, depth: 10, precipitation: 0) == 0)
        #expect(Moss.dew(sun: east, depth: 150, precipitation: 1) < 0.25)
    }

    @Test func windLeansWithinBounds() {
        let gust = Wind.Gust(onset: 0, rise: 2, duration: 10, strength: 1)
        let wind = Wind(velocity: SIMD2(10, 0), time: 2, frontDirection: SIMD2(1, 0), gusts: [gust])
        let lean = Moss.lean(wind, at: CGRect(x: 0, y: 0, width: 100, height: 40))
        #expect(lean > 0 && lean <= 1)
        #expect(Moss.lean(Wind(), at: CGRect(x: 0, y: 0, width: 100, height: 40)) == 0)
    }
}
