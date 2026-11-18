import Foundation

public enum Moon {
    public static func position(at date: Date, location: GeoLocation) -> SkyPosition {
        let days = Astronomy.daysSinceJ2000(date)
        let orbit = LunarOrbit(days: days)
        return Astronomy.horizontalPosition(
            longitude: orbit.longitude, latitude: orbit.latitude, days: days, location: location,
            parallaxOffset: 6_378 / orbit.distanceInKilometres
        )
    }

    /// Lunar phase in `0..<1`, with new moon at 0, first quarter at 0.25,
    /// full moon at 0.5, and last quarter at 0.75.
    public static func phase(at date: Date) -> Double {
        let days = Astronomy.daysSinceJ2000(date)
        let elongation = LunarOrbit(days: days).longitude - Sun.eclipticLongitude(days: days)
        return Astronomy.wrapAngle(elongation) / Astronomy.fullTurn
    }
}

// Dominant terms from Meeus, Astronomical Algorithms, 2nd ed., chapter 47.
private struct LunarOrbit {
    let meanLongitude: Double
    let elongation: Double
    let anomaly: Double
    let solarAnomaly: Double
    let argumentOfLatitude: Double

    init(days: Double) {
        let radians = Astronomy.radiansPerDegree
        meanLongitude = (218.316448 + 13.17639648 * days) * radians
        elongation = (297.850192 + 12.19074912 * days) * radians
        anomaly = (134.963396 + 13.06499295 * days) * radians
        solarAnomaly = Sun.meanAnomaly(days: days)
        argumentOfLatitude = (93.272095 + 13.22935024 * days) * radians
    }

    var longitude: Double {
        let twiceElongation = 2 * elongation
        let principal = 6.289 * sin(anomaly)
            + 1.274 * sin(twiceElongation - anomaly)
            + 0.658 * sin(twiceElongation)
            + 0.214 * sin(2 * anomaly)
            - 0.185 * sin(solarAnomaly)
            - 0.114 * sin(2 * argumentOfLatitude)
        let correction = 0.059 * sin(twiceElongation - 2 * anomaly)
            + 0.057 * sin(twiceElongation - solarAnomaly - anomaly)
            + 0.053 * sin(twiceElongation + anomaly)
            + 0.046 * sin(twiceElongation - solarAnomaly)
            + 0.041 * sin(anomaly - solarAnomaly)
            - 0.035 * sin(elongation)
            - 0.030 * sin(anomaly + solarAnomaly)
        return meanLongitude + (principal + correction) * Astronomy.radiansPerDegree
    }

    var latitude: Double {
        let latitude = 5.128 * sin(argumentOfLatitude)
            + 0.281 * sin(anomaly + argumentOfLatitude)
            + 0.278 * sin(anomaly - argumentOfLatitude)
            + 0.173 * sin(2 * elongation - argumentOfLatitude)
            + 0.055 * sin(2 * elongation - anomaly + argumentOfLatitude)
            + 0.046 * sin(2 * elongation - anomaly - argumentOfLatitude)
            + 0.033 * sin(2 * elongation + argumentOfLatitude)
            + 0.017 * sin(2 * anomaly + argumentOfLatitude)
        return latitude * Astronomy.radiansPerDegree
    }

    var distanceInKilometres: Double {
        385_001 - 20_905 * cos(anomaly)
    }
}
