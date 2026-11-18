import Foundation

public struct GeoLocation: Sendable, Equatable {
    /// Latitude in degrees, positive north.
    public let latitude: Double
    /// Longitude in degrees, positive east.
    public let longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}

public struct SkyPosition: Sendable {
    /// Geometric altitude in radians, positive above the horizon.
    public let altitude: Double
    /// Azimuth in radians clockwise from north, in `0..<2π`.
    public let azimuth: Double
}

enum Astronomy {
    static let radiansPerDegree = Double.pi / 180
    static let fullTurn = 2 * Double.pi

    static func daysSinceJ2000(_ date: Date) -> Double {
        // J2000.0 is 2000-01-01 at 12:00 UTC for this approximation.
        (date.timeIntervalSince1970 - 946_728_000) / 86_400
    }

    static func wrapAngle(_ angle: Double) -> Double {
        let remainder = angle.truncatingRemainder(dividingBy: fullTurn)
        let wrapped = remainder < 0 ? remainder + fullTurn : remainder
        return wrapped == fullTurn ? 0 : wrapped
    }

    static func horizontalPosition(
        longitude: Double, latitude: Double, days: Double, location: GeoLocation,
        parallaxOffset: Double = 0
    ) -> SkyPosition {
        // Rotate the ecliptic unit vector into equatorial coordinates.
        let obliquity = (23.4393 - 0.0000003563 * days) * radiansPerDegree
        let eclipticX = cos(latitude) * cos(longitude)
        let eclipticY = cos(latitude) * sin(longitude)
        let eclipticZ = sin(latitude)
        let x = eclipticX
        let y = eclipticY * cos(obliquity) - eclipticZ * sin(obliquity)
        let z = eclipticY * sin(obliquity) + eclipticZ * cos(obliquity)

        // Rotate by local sidereal time and observer latitude into east, north, and up.
        let sidereal = (280.46061837 + 360.98564736629 * days + location.longitude) * radiansPerDegree
        let observerLatitude = location.latitude * radiansPerDegree
        let meridian = x * cos(sidereal) + y * sin(sidereal)
        let east = y * cos(sidereal) - x * sin(sidereal)
        let north = z * cos(observerLatitude) - meridian * sin(observerLatitude)
        // On a spherical Earth, the observer is offset upwards by one Earth radius.
        let up = meridian * cos(observerLatitude) + z * sin(observerLatitude) - parallaxOffset

        return SkyPosition(altitude: atan2(up, hypot(east, north)), azimuth: wrapAngle(atan2(east, north)))
    }
}
