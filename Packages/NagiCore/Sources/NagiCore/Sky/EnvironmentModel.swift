import Foundation
import NagiKit

/// Builds the shared environment every effect sees (SPEC 3.6). The engine and nagi-render both
/// use it, so a render at a given date and place matches the live overlay.
public enum EnvironmentModel {
    /// - Parameters:
    ///   - windTime: seconds on the wind clock (monotonic; the engine slows it for Reduce Motion).
    ///   - seed: the frame's seed, which also picks the wind.
    ///   - strongest: debug; the strongest wind the model gives (WindModel.strongest).
    public static func environment(at date: Date, location: GeoLocation, windTime: Double = 0,
                                   seed: UInt64 = 1, strongest: Bool = false) -> SharedEnvironment {
        let sun = Sun.position(at: date, location: location)
        let moon = Moon.position(at: date, location: location)
        var environment = SharedEnvironment()
        environment.sun = CelestialPosition(altitude: sun.altitude, azimuth: sun.azimuth)
        environment.moon = CelestialPosition(altitude: moon.altitude, azimuth: moon.azimuth)
        environment.moonPhase = Moon.phase(at: date)
        environment.sunColorTemperature = Sun.colorTemperature(altitude: sun.altitude)
        let wind = WindModel.wind(at: windTime, seed: seed)
        environment.wind = strongest ? WindModel.strongest(wind) : wind
        return environment
    }

    /// The default place: the time zone's representative city (no location services).
    public static func defaultLocation(at date: Date = Date()) -> GeoLocation {
        RepresentativeCity.location(for: .current, at: date)
    }
}
