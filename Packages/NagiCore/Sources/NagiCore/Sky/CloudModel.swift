import Foundation

/// The shared clouds (SPEC 3.6, DECISIONS D20) as a pure function of the sky's clock and the seed,
/// like the wind. Two values: how cloudy the sky is (slow, minutes) and how much of the direct sun
/// a cloud takes away now (tens of seconds). Under a fair sky a single thick cloud can still
/// cross the sun.
public enum CloudModel {
    /// The cover moves through a knot every five minutes, within a fair sky (the author's choice:
    /// the sun is fully hidden about 1 % of the time, at most about two minutes at once).
    static let coverSpacing = 300.0
    static let coverRange = 0.0...0.4
    /// A threshold the cover is compared with moves through a knot every 45 s: where the cover
    /// passes it, a cloud is crossing the sun. `edge` softens the crossing.
    static let thresholdSpacing = 45.0
    static let thresholdRange = 0.15...0.85
    static let edge = 0.15

    public static func sky(at time: Double, seed: UInt64, bias: Double = 0) -> (cover: Double, occlusion: Double) {
        let cover = min(max(Knots.value(at: time, spacing: coverSpacing, seed: seed, stream: 10,
                                        coverRange.lowerBound, coverRange.upperBound) + bias, 0), 1)
        let threshold = Knots.value(at: time, spacing: thresholdSpacing, seed: seed, stream: 11,
                                    thresholdRange.lowerBound, thresholdRange.upperBound)
        return (cover, Knots.smooth((cover - threshold + edge) / (2 * edge)))
    }

    /// Debug: one cloud crossing the sun, `elapsed` seconds after it was asked for: clear for 3 s,
    /// covering over 10 s, hidden for 5 s, clearing over 10 s, then clear.
    public static func pass(elapsed: Double) -> Double {
        Knots.smooth((elapsed - 3) / 10) * (1 - Knots.smooth((elapsed - 18) / 10))
    }
}
