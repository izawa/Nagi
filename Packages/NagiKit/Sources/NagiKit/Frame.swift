import CoreGraphics
import Foundation
import Metal

/// Everything an effect needs to draw one frame (SPEC 3.4). Same seed and time, same picture.
public struct FrameState: Sendable {
    /// Monotonic seconds, and the step since the previous frame.
    public var time: TimeInterval
    public var deltaTime: TimeInterval
    /// Wall-clock date, for the sun and the moon.
    public var date: Date
    public var phase: NagiPhase
    /// 0…1. The core applies it again to the final output, whatever the effect draws.
    public var presence: Double
    /// Seconds of stillness, decaying while the user is active (SPEC 2.1).
    public var depth: Double
    public var appearance: Appearance
    public var quality: Quality
    public var accessibility: AccessibilityAdjustments
    /// Current values of the effect's own parameters, by key.
    public var parameters: [String: ParameterValue]
    public var seed: UInt64
    public var environment: SharedEnvironment
    /// The displays of the desktop, in points, top-left origin (DisplayView.frameInDesktop): a
    /// simulation spread over the desktop knows where it can be seen before any display draws.
    public var displays: [CGRect]
    /// Counts the times nagi has shown: a new value means a new showing, so an effect with state
    /// (rain's drops) can start over.
    public var showing: Int

    public init(time: TimeInterval, deltaTime: TimeInterval, date: Date, phase: NagiPhase, presence: Double,
                depth: Double, appearance: Appearance, quality: Quality = .standard,
                accessibility: AccessibilityAdjustments = .init(), parameters: [String: ParameterValue] = [:],
                seed: UInt64, environment: SharedEnvironment = .init(), displays: [CGRect] = [], showing: Int = 0) {
        self.time = time
        self.deltaTime = deltaTime
        self.date = date
        self.phase = phase
        self.presence = presence
        self.depth = depth
        self.appearance = appearance
        self.quality = quality
        self.accessibility = accessibility
        self.parameters = parameters
        self.seed = seed
        self.environment = environment
        self.displays = displays
        self.showing = showing
    }

    public func number(_ key: String, default value: Double) -> Double {
        if case let .number(number) = parameters[key] { number } else { value }
    }

    public func flag(_ key: String, default value: Bool) -> Bool {
        if case let .flag(flag) = parameters[key] { flag } else { value }
    }
}

public enum NagiPhase: Sendable {
    case entering, calm, leaving
}

public enum Appearance: Sendable {
    case light, dark
}

public enum Quality: Sendable {
    case standard, high
}

/// System settings an effect should honour (SPEC 2.2).
public struct AccessibilityAdjustments: Sendable {
    public var reduceMotion = false
    /// "Increase contrast" or "Reduce transparency".
    public var reduceStrength = false
    public init(reduceMotion: Bool = false, reduceStrength: Bool = false) {
        self.reduceMotion = reduceMotion
        self.reduceStrength = reduceStrength
    }
}

/// The sun, sky and wind every effect shares (SPEC 3.6). Filled in by the core.
public struct SharedEnvironment: Sendable {
    public var sun = CelestialPosition()
    public var moon = CelestialPosition()
    /// 0 (new) … 0.5 (full) … 1.
    public var moonPhase = 0.0
    /// Correlated colour temperature of direct sunlight, kelvin.
    public var sunColorTemperature = 5500.0
    /// 0 clear … 1 overcast: how cloudy the sky is, changing over minutes.
    public var cloudCover = 0.0
    /// 0 … 1: how much of the direct sun a cloud takes away now. Effects lose their direct light,
    /// not their brightness: the light that remains comes from the whole sky (DECISIONS D20).
    public var sunOcclusion = 0.0
    public var wind = Wind()
    public init() {}
}

public struct CelestialPosition: Sendable {
    /// Radians above the horizon; negative below.
    public var altitude = Double.pi / 2
    /// Radians clockwise from north.
    public var azimuth = 0.0
    public init(altitude: Double = .pi / 2, azimuth: Double = 0) {
        self.altitude = altitude
        self.azimuth = azimuth
    }
}

/// The shared wind (SPEC 3.6) at one instant of the wind clock. The core fills it in; effects read
/// the mean wind and evaluate gusts where they need them (DECISIONS D19).
public struct Wind: Sendable {
    /// Mean wind, metres per second, in desktop coordinates (x right, y down).
    public var velocity = SIMD2<Double>(0, 0)
    /// Seconds on the wind clock: monotonic, and slowed while Reduce Motion is on.
    public var time = 0.0
    /// The direction gust fronts travel, a unit vector in desktop coordinates.
    public var frontDirection = SIMD2<Double>(1, 0)
    /// The gusts that can be felt somewhere on the desktop around now.
    public var gusts: [Gust] = []

    /// How fast a gust front crosses the ground, millimetres per second. Real gusts cross a display
    /// in a fifth of a second; this is slow enough to watch one cross (the author's choice, D19).
    public static let frontSpeed = 250.0

    public init(velocity: SIMD2<Double> = .zero, time: Double = 0, frontDirection: SIMD2<Double> = SIMD2(1, 0),
                gusts: [Gust] = []) {
        self.velocity = velocity
        self.time = time
        self.frontDirection = frontDirection
        self.gusts = gusts
    }

    /// Gust strength, 0…1, at a ground point (desktop millimetres): the front reaches points
    /// downwind later.
    public func gust(at point: SIMD2<Double>) -> Double {
        let local = time - (point.x * frontDirection.x + point.y * frontDirection.y) / Self.frontSpeed
        return gusts.reduce(0) { max($0, $1.envelope(at: local)) }
    }

    public struct Gust: Sendable, Equatable {
        /// Wind-clock seconds when the front passes the desktop origin.
        public var onset: Double
        /// Seconds to full strength, and from onset until it has died away.
        public var rise: Double
        public var duration: Double
        /// 0…1.
        public var strength: Double

        public init(onset: Double, rise: Double, duration: Double, strength: Double) {
            self.onset = onset
            self.rise = rise
            self.duration = duration
            self.strength = strength
        }

        /// A smooth rise, then a slower release. Komorebi.metal evaluates the same curve.
        public func envelope(at time: Double) -> Double {
            let s = time - onset
            guard s > 0, s < duration else { return 0 }
            func smooth(_ x: Double) -> Double { let c = min(max(x, 0), 1); return c * c * (3 - 2 * c) }
            return strength * smooth(s / rise) * (1 - smooth((s - rise) / (duration - rise)))
        }
    }
}

/// One display as the effect sees it (SPEC 3.4).
public struct DisplayView {
    public var id: UInt32
    public var pixelSize: SIMD2<Int>
    /// Pixels per point.
    public var scale: Double
    /// The display within the whole desktop, in points, top-left origin.
    public var frameInDesktop: CGRect
    /// Physical size in millimetres, when the display reports it.
    public var physicalSize: SIMD2<Double>?
    /// Current and potential headroom above SDR white (1 = none).
    public var edrHeadroom: Double
    public var potentialEDRHeadroom: Double
    /// The screen under this effect's layer, for `.backdrop` effects (M2): encoded Display P3.
    public var backdrop: (any MTLTexture)?

    public init(id: UInt32, pixelSize: SIMD2<Int>, scale: Double, frameInDesktop: CGRect,
                physicalSize: SIMD2<Double>?, edrHeadroom: Double = 1, potentialEDRHeadroom: Double = 1,
                backdrop: (any MTLTexture)? = nil) {
        self.id = id
        self.pixelSize = pixelSize
        self.scale = scale
        self.frameInDesktop = frameInDesktop
        self.physicalSize = physicalSize
        self.edrHeadroom = edrHeadroom
        self.potentialEDRHeadroom = potentialEDRHeadroom
        self.backdrop = backdrop
    }

    /// Millimetres per pixel; falls back to 218 ppi (Studio Display) when the size is unknown.
    public var millimetresPerPixel: Double {
        guard let physicalSize, physicalSize.x > 0 else { return 25.4 / 218 }
        return physicalSize.x / Double(pixelSize.x)
    }
}
