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

    public init(time: TimeInterval, deltaTime: TimeInterval, date: Date, phase: NagiPhase, presence: Double,
                depth: Double, appearance: Appearance, quality: Quality = .standard,
                accessibility: AccessibilityAdjustments = .init(), parameters: [String: ParameterValue] = [:],
                seed: UInt64, environment: SharedEnvironment = .init()) {
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
    /// 0 clear … 1 overcast.
    public var cloudCover = 0.0
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

public struct Wind: Sendable {
    /// Mean wind, metres per second, in desktop coordinates (x right, y down).
    public var velocity = SIMD2<Double>(0, 0)
    /// Seed of the shared gust and turbulence field.
    public var fieldSeed: UInt64 = 0
    public init(velocity: SIMD2<Double> = .zero, fieldSeed: UInt64 = 0) {
        self.velocity = velocity
        self.fieldSeed = fieldSeed
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
