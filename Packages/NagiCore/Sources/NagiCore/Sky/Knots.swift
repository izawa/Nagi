import Foundation

/// Seeded random values on an unwrapped time grid, smoothly joined (SPEC 3.6). The wind and the
/// clouds both use it, so any instant can be computed directly and nothing ever repeats.
enum Knots {
    /// The sky's clock is kept to ±10⁹ s (32 years), so knot indices fit an `Int`.
    static let timeLimit = 1e9

    static func clamped(_ time: Double) -> Double {
        time.isFinite ? min(max(time, -timeLimit), timeLimit) : 0
    }

    /// A value between `low` and `high` that moves smoothly through a random knot every `spacing`
    /// seconds.
    static func value(at time: Double, spacing: Double, seed: UInt64, stream: UInt64,
                      _ low: Double, _ high: Double) -> Double {
        let knot = clamped(time) / spacing
        let index = Int(knot.rounded(.down))
        let a = unit(seed, stream: stream, index: index), b = unit(seed, stream: stream, index: index + 1)
        return low + (high - low) * (a + (b - a) * smooth(knot - Double(index)))
    }

    static func smooth(_ x: Double) -> Double {
        let c = min(max(x, 0), 1)
        return c * c * (3 - 2 * c)
    }

    /// A uniform value in [0, 1) for a seed, a stream and an index (SplitMix64 finaliser).
    static func unit(_ seed: UInt64, stream: UInt64, index: Int) -> Double {
        var z = seed &+ stream &* 0x9E37_79B9_7F4A_7C15 &+ UInt64(bitPattern: Int64(index)) &* 0xD1B5_4A32_D192_ED03
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z >> 11) / Double(1 << 53)
    }
}
