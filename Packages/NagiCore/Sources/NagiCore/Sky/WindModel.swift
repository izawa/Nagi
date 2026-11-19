import Foundation
import NagiKit
import simd

/// The shared wind (SPEC 3.6, DECISIONS D19) as a pure function of the wind clock and the seed:
/// any instant can be computed directly, so a render at a given time matches the live overlay and
/// seeking needs no history. Knots and gust intervals are indexed by unwrapped integers, so the
/// wind never repeats.
public enum WindModel {
    /// Seconds between the knots the mean wind is interpolated through.
    static let knotSpacing = 20.0
    /// Each interval holds at most one gust.
    static let gustInterval = 12.0
    static let gustChance = 0.6
    /// The strongest mean wind, metres per second.
    static let maximumSpeed = 3.5
    /// A gust can be felt this long before or after it passes the desktop origin: the front's delay
    /// across the widest desktop expected (±3 m at `Wind.frontSpeed`).
    static let gustReach = 3000 / Wind.frontSpeed

    /// The wind clock is kept to ±10⁹ s (32 years), so its knot and interval indices fit an `Int`.
    static let timeLimit = 1e9

    public static func wind(at time: Double, seed: UInt64) -> Wind {
        let time = time.isFinite ? min(max(time, -timeLimit), timeLimit) : 0
        let prevailing = unit(seed, stream: 0, index: 0) * 2 * .pi
        let knot = time / knotSpacing
        let index = Int(knot.rounded(.down))
        let blend = smooth(knot - Double(index))
        func mix(_ stream: UInt64, _ low: Double, _ high: Double) -> Double {
            let a = unit(seed, stream: stream, index: index), b = unit(seed, stream: stream, index: index + 1)
            return low + (high - low) * (a + (b - a) * blend)
        }
        // A light breeze to moderate wind (never so calm the canopy stands still: the author found
        // the calm end too still), wandering ±35° around the prevailing direction.
        let speed = mix(1, 1.5, maximumSpeed)
        let heading = prevailing + mix(2, -35, 35) * .pi / 180
        var wind = Wind(velocity: SIMD2(sin(heading), -cos(heading)) * speed, time: time,
                        frontDirection: SIMD2(sin(prevailing), -cos(prevailing)))
        let current = Int((time / gustInterval).rounded(.down))
        let reach = Int((gustReach / gustInterval).rounded(.up)) + 1
        for interval in (current - reach - 1)...(current + reach) {
            guard let gust = gust(seed, interval: interval),
                  time > gust.onset - gustReach, time < gust.onset + gust.duration + gustReach else { continue }
            wind.gusts.append(gust)
        }
        return wind
    }

    /// A gust rises over 2–4 s and has died away 5–10 s after it began. Rises of 1–2 s swept the
    /// disk edges fast enough to pass the flicker limit (DECISIONS D19).
    static func gust(_ seed: UInt64, interval: Int) -> Wind.Gust? {
        guard unit(seed, stream: 3, index: interval) < gustChance else { return nil }
        let rise = 2 + 2 * unit(seed, stream: 4, index: interval)
        return Wind.Gust(onset: (Double(interval) + 0.6 * unit(seed, stream: 5, index: interval)) * gustInterval,
                         rise: rise, duration: rise + 3 + 3 * unit(seed, stream: 6, index: interval),
                         strength: 0.4 + 0.6 * unit(seed, stream: 7, index: interval))
    }

    /// Debug: the same wind at the top of its range, every gust at full strength.
    public static func strongest(_ wind: Wind) -> Wind {
        var strong = wind
        let speed = simd_length(wind.velocity)
        strong.velocity = speed > 0 ? wind.velocity / speed * maximumSpeed : wind.frontDirection * maximumSpeed
        strong.gusts = wind.gusts.map { var gust = $0; gust.strength = 1; return gust }
        return strong
    }

    static func smooth(_ x: Double) -> Double { x * x * (3 - 2 * x) }

    /// A uniform value in [0, 1) for a seed, a stream and an index (SplitMix64 finaliser).
    static func unit(_ seed: UInt64, stream: UInt64, index: Int) -> Double {
        var z = seed &+ stream &* 0x9E37_79B9_7F4A_7C15 &+ UInt64(bitPattern: Int64(index)) &* 0xD1B5_4A32_D192_ED03
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z >> 11) / Double(1 << 53)
    }
}
