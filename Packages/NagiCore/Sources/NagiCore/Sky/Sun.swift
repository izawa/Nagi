import Foundation

public enum Sun {
    public static func position(at date: Date, location: GeoLocation) -> SkyPosition {
        let days = Astronomy.daysSinceJ2000(date)
        return Astronomy.horizontalPosition(
            longitude: eclipticLongitude(days: days), latitude: 0, days: days, location: location
        )
    }

    /// Approximate correlated colour temperature of direct sunlight at the ground, in kelvin.
    public static func colorTemperature(altitude: Double) -> Double {
        let fraction = min(max(altitude / (.pi / 3), 0), 1)
        return 2_000 + 3_500 * fraction * fraction * (3 - 2 * fraction)
    }

    static func meanAnomaly(days: Double) -> Double {
        (357.52911 + 0.98560028 * days) * Astronomy.radiansPerDegree
    }

    // Low-precision solar longitude from the NOAA/Meeus mean longitude and equation of centre.
    static func eclipticLongitude(days: Double) -> Double {
        let anomaly = meanAnomaly(days: days)
        let meanLongitude = 280.46646 + 0.98564736 * days
        let correction = 1.9146 * sin(anomaly) + 0.0200 * sin(2 * anomaly)
        return (meanLongitude + correction - 0.00569) * Astronomy.radiansPerDegree
    }
}
