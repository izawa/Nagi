import NagiKit
import simd
import Testing
@testable import NagiCore

/// The shared wind (SPEC 3.6, DECISIONS D19).
struct WindTests {
    /// The wind at a time is the same however it was reached: renders and the live overlay agree.
    @Test func sameTimeSameWind() {
        let a = WindModel.wind(at: 1234.5, seed: 7), b = WindModel.wind(at: 1234.5, seed: 7)
        #expect(a.velocity == b.velocity)
        #expect(a.gusts == b.gusts)
        #expect(WindModel.wind(at: 1234.5, seed: 8).velocity != a.velocity)
    }

    /// The mean wind changes smoothly: no jump from one frame to the next, even across a knot.
    @Test func meanWindIsSmooth() {
        var previous = WindModel.wind(at: 0, seed: 3).velocity
        for step in 1...6000 {
            let velocity = WindModel.wind(at: Double(step) / 60, seed: 3).velocity
            #expect(simd_length(velocity - previous) < 0.01)
            previous = velocity
        }
    }

    /// A gust reaches points downwind later, at the front's speed, and its strength stays within 0…1.
    @Test func gustFrontTravels() throws {
        let seed: UInt64 = 5
        let gust = try #require((0..<50).lazy.compactMap { WindModel.gust(seed, interval: $0) }.first)
        let peak = gust.onset + gust.rise
        let wind = WindModel.wind(at: peak, seed: seed)
        let downwind = wind.frontDirection * 500  // 2 s later at 250 mm/s
        #expect(abs(wind.gust(at: .zero) - gust.strength) < 1e-9)
        let later = WindModel.wind(at: peak + 500 / Wind.frontSpeed, seed: seed)
        #expect(abs(later.gust(at: downwind) - gust.strength) < 1e-9)
        for step in 0..<400 {
            let value = WindModel.wind(at: gust.onset + Double(step) / 20, seed: seed).gust(at: .zero)
            #expect(value >= 0 && value <= 1)
        }
    }

    /// Gusts rise over 2–4 s and die away within 5–10 s (DECISIONS D19: gentler rises kept the
    /// sweeping disk edges under the flicker limit), with strength 0.4–1.
    @Test func gustShapes() {
        let gusts = (0..<500).compactMap { WindModel.gust(9, interval: $0) }
        #expect(gusts.count > 200 && gusts.count < 400)
        for gust in gusts {
            #expect((2...4).contains(gust.rise))
            #expect((5...10).contains(gust.duration))
            #expect((0.4...1).contains(gust.strength))
        }
    }

    /// A wind clock far outside any real run is held to the limit instead of trapping.
    @Test func extremeTimesAreHeld() {
        _ = WindModel.wind(at: 1e30, seed: 1)
        _ = WindModel.wind(at: -.infinity, seed: 1)
        _ = WindModel.wind(at: .nan, seed: 1)
    }
}
