import CoreGraphics
import Foundation
import NagiKit

/// One frame's inputs for previews: nagi-render and the gallery build frames the same way
/// (SPEC 3.12, DECISIONS D24).
public struct PreviewScene: Sendable {
    /// The wall-clock date at the start (the sun and the moon move on from it).
    public var date: Date
    public var location: GeoLocation
    /// Seconds on the sky's clock at the start (the wind and the clouds).
    public var windTime: Double
    public var seed: UInt64
    public var weather: EnvironmentModel.Weather
    public var appearance: Appearance

    public init(date: Date, location: GeoLocation? = nil, windTime: Double = 0, seed: UInt64 = 1,
                weather: EnvironmentModel.Weather = .init(sky: .clear), appearance: Appearance = .light) {
        self.date = date
        self.location = location ?? EnvironmentModel.defaultLocation(at: date)
        self.windTime = windTime
        self.seed = seed
        self.weather = weather
        self.appearance = appearance
    }

    /// The frame `elapsed` seconds after the start. Date, wind and clouds advance together.
    public func frame(elapsed: Double, deltaTime: Double, phase: NagiPhase = .calm, presence: Double = 1,
                      depth: Double) -> FrameState {
        let date = date.addingTimeInterval(elapsed)
        let time = windTime + elapsed
        return FrameState(time: time, deltaTime: deltaTime, date: date, phase: phase, presence: presence,
                          depth: depth, appearance: appearance, seed: seed,
                          environment: EnvironmentModel.environment(at: date, location: location, windTime: time,
                                                                    seed: seed, weather: weather))
    }

    /// The display a preview draws on, at 2× (a Retina display), of a given physical size; the
    /// canopy keeps its size whatever the preview window does.
    public static func display(pixels: SIMD2<Int>, physicalSize: SIMD2<Double>?) -> DisplayView {
        let points = CGSize(width: Double(pixels.x) / 2, height: Double(pixels.y) / 2)
        return DisplayView(id: 1, pixelSize: pixels, scale: 2, frameInDesktop: CGRect(origin: .zero, size: points),
                           physicalSize: physicalSize, edrHeadroom: 1, potentialEDRHeadroom: 1)
    }
}

/// Entry and exit replayed through the real state machine (DECISIONS D23): the hands have rested
/// for the onset at time 0, so nagi enters then (or, `startingCalm`, it is already calm), and
/// they move once at `inputAt`. Depth is held while nagi leaves, as the engine holds it
/// (DECISIONS D22).
public struct EnvelopeReplay: Sendable {
    private var machine = NagiStateMachine()
    private var inputAt: Double?
    private var previous = -Double.infinity
    private var heldDepth = 0.0
    /// When the hands came to rest, less the onset (nagi enters then).
    private let restStart: Double

    /// - Parameter depth: the depth shown before the first step (held if that step is leaving).
    public init(inputAt: Double? = nil, startingCalm: Bool = false, depth: Double = 0) {
        self.inputAt = inputAt
        heldDepth = depth
        restStart = startingCalm ? -NagiTiming().entryDuration : 0
        if startingCalm { _ = machine.step(NagiInputs(now: restStart, idleReading: NagiTiming().onset)) }
    }

    /// The hands move at `time` (seconds since the replay began), once.
    public mutating func input(at time: Double) {
        inputAt = time
    }

    /// The state machine's phase (effects see `phase.framePhase`), the presence and the depth
    /// `elapsed` seconds after the replay began. The input is stepped at its own time, whatever
    /// the frame rate.
    public mutating func step(at elapsed: Double, depth: Double) -> (phase: NagiStatePhase, presence: Double, depth: Double) {
        let onset = NagiTiming().onset
        let inputAt = inputAt, restStart = restStart
        func inputs(_ now: Double) -> NagiInputs {
            let rested = onset + now - restStart
            let idle = inputAt.map { now >= $0 ? now - $0 : rested } ?? rested
            return NagiInputs(now: now, idleReading: idle)
        }
        if let inputAt, previous <= inputAt, elapsed > inputAt { _ = machine.step(inputs(inputAt)) }
        let output = machine.step(inputs(elapsed))
        previous = elapsed
        if output.phase != .leaving { heldDepth = depth }
        return (output.phase, output.presence, heldDepth)
    }
}
