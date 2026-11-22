import Foundation

/// What lights a scene: the sun by day; at night, if moonlight is on, the moon (DECISIONS D21).
/// Shared by the effects lit from the sky (komorebi, the light under water, gems).
public struct SkyLight: Sendable {
    /// Below this the sun or moon lights nothing; it fades in up to `fadeAltitude` (radians).
    public static let cutoffAltitude = 5 * Double.pi / 180
    public static let fadeAltitude = 10 * Double.pi / 180

    public var position: CelestialPosition
    /// 0 … 1.
    public var weight: Double
    public var isMoon: Bool

    /// The sun while it is above 5°. Otherwise the moon, weighted by how dark the sky is (it comes
    /// in through civil twilight), how high the moon is (the same 5–10° fade as the sun) and how
    /// much of it is lit. Nil when nothing lights.
    public init?(_ environment: SharedEnvironment, moonlight: Bool) {
        let day = Self.smooth(Self.cutoffAltitude, Self.fadeAltitude, environment.sun.altitude)
        if day > 0 {
            self.init(position: environment.sun, weight: day, isMoon: false)
            return
        }
        guard moonlight else { return nil }
        let darkness = 1 - Self.smooth(-6 * .pi / 180, 0, environment.sun.altitude)
        let lit = (1 - cos(2 * .pi * environment.moonPhase)) / 2
        // Clear around new moon: under 1 % lit counts as dark, without a step.
        let phase = max(0, (lit - 0.01) / 0.99)
        let weight = darkness * Self.smooth(Self.cutoffAltitude, Self.fadeAltitude, environment.moon.altitude) * phase
        guard weight > 0 else { return nil }
        self.init(position: environment.moon, weight: weight, isMoon: true)
    }

    public init(position: CelestialPosition, weight: Double, isMoon: Bool) {
        self.position = position
        self.weight = weight
        self.isMoon = isMoon
    }

    static func smooth(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = min(max((x - a) / (b - a), 0), 1)
        return t * t * (3 - 2 * t)
    }
}
