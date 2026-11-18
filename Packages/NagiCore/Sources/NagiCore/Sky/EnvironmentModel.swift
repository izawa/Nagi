import Foundation
import NagiKit

/// Builds the shared environment every effect sees (SPEC 3.6). The engine and nagi-render both
/// use it, so a render at a given date and place matches the live overlay.
public enum EnvironmentModel {
    public static func environment(at date: Date, location: GeoLocation) -> SharedEnvironment {
        let sun = Sun.position(at: date, location: location)
        let moon = Moon.position(at: date, location: location)
        var environment = SharedEnvironment()
        environment.sun = CelestialPosition(altitude: sun.altitude, azimuth: sun.azimuth)
        environment.moon = CelestialPosition(altitude: moon.altitude, azimuth: moon.azimuth)
        environment.moonPhase = Moon.phase(at: date)
        environment.sunColorTemperature = Sun.colorTemperature(altitude: sun.altitude)
        return environment
    }

    /// The default place: the time zone's representative city (no location services).
    public static func defaultLocation(at date: Date = Date()) -> GeoLocation {
        RepresentativeCity.location(for: .current, at: date)
    }
}
