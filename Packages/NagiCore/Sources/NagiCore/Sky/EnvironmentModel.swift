import Foundation
import NagiKit

/// Builds the shared environment every effect sees (SPEC 3.6). The engine and nagi-render both
/// use it, so a render at a given date and place matches the live overlay.
public enum EnvironmentModel {
    /// What drives the sky besides the clock: the effects' weather hints, and debug overrides.
    public struct Weather: Sendable {
        public enum Sky: Sendable {
            /// Clouds come and go (the live default).
            case natural
            /// No clouds (nagi-render's default, so comparisons do not depend on the weather).
            case clear
            /// Debug: one cloud crossing the sun, starting at this time on the sky's clock.
            case cloudPass(start: Double)
        }
        public var sky = Sky.natural
        /// Debug: the strongest wind the model gives (WindModel.strongest).
        public var strongestWind = false
        /// The sum of the running effects' `WeatherHint.cloudBias`.
        public var cloudBias = 0.0
        public init(sky: Sky = .natural, strongestWind: Bool = false, cloudBias: Double = 0) {
            self.sky = sky
            self.strongestWind = strongestWind
            self.cloudBias = cloudBias
        }
    }

    /// - Parameters:
    ///   - windTime: seconds on the sky's clock (monotonic; the engine slows it for Reduce Motion).
    ///     The wind and the clouds both run on it.
    ///   - seed: the frame's seed, which also picks the wind and the clouds.
    public static func environment(at date: Date, location: GeoLocation, windTime: Double = 0,
                                   seed: UInt64 = 1, weather: Weather = Weather()) -> SharedEnvironment {
        let sun = Sun.position(at: date, location: location)
        let moon = Moon.position(at: date, location: location)
        var environment = SharedEnvironment()
        environment.sun = CelestialPosition(altitude: sun.altitude, azimuth: sun.azimuth)
        environment.moon = CelestialPosition(altitude: moon.altitude, azimuth: moon.azimuth)
        environment.moonPhase = Moon.phase(at: date)
        environment.sunColorTemperature = Sun.colorTemperature(altitude: sun.altitude)
        let wind = WindModel.wind(at: windTime, seed: seed)
        environment.wind = weather.strongestWind ? WindModel.strongest(wind) : wind
        switch weather.sky {
        case .natural:
            (environment.cloudCover, environment.sunOcclusion) = CloudModel.sky(at: windTime, seed: seed,
                                                                                bias: weather.cloudBias)
        case .clear:
            break
        case .cloudPass(let start):
            environment.sunOcclusion = CloudModel.pass(elapsed: windTime - start)
            environment.cloudCover = environment.sunOcclusion
        }
        return environment
    }

    /// The default place: the time zone's representative city (no location services).
    public static func defaultLocation(at date: Date = Date()) -> GeoLocation {
        RepresentativeCity.location(for: .current, at: date)
    }
}
