import Foundation

public enum RepresentativeCity {
    /// Representative city for the time zone, or 35° north and 15° east per hour of UTC offset.
    public static func location(for timeZone: TimeZone, at date: Date) -> GeoLocation {
        cities[timeZone.identifier] ?? GeoLocation(
            latitude: 35, longitude: Double(timeZone.secondsFromGMT(for: date)) / 240
        )
    }

    private static let cities: [String: GeoLocation] = [
        "Africa/Cairo": .init(latitude: 30.04, longitude: 31.24),
        "Africa/Johannesburg": .init(latitude: -26.20, longitude: 28.04),
        "Africa/Lagos": .init(latitude: 6.52, longitude: 3.38),
        "America/Anchorage": .init(latitude: 61.22, longitude: -149.90),
        "America/Argentina/Buenos_Aires": .init(latitude: -34.60, longitude: -58.38),
        "America/Chicago": .init(latitude: 41.88, longitude: -87.63),
        "America/Denver": .init(latitude: 39.74, longitude: -104.99),
        "America/Halifax": .init(latitude: 44.65, longitude: -63.58),
        "America/Los_Angeles": .init(latitude: 34.05, longitude: -118.24),
        "America/Mexico_City": .init(latitude: 19.43, longitude: -99.13),
        "America/New_York": .init(latitude: 40.71, longitude: -74.01),
        "America/Phoenix": .init(latitude: 33.45, longitude: -112.07),
        "America/Sao_Paulo": .init(latitude: -23.55, longitude: -46.63),
        "America/Toronto": .init(latitude: 43.65, longitude: -79.38),
        "America/Vancouver": .init(latitude: 49.28, longitude: -123.12),
        "Asia/Bangkok": .init(latitude: 13.76, longitude: 100.50),
        "Asia/Dubai": .init(latitude: 25.20, longitude: 55.27),
        "Asia/Hong_Kong": .init(latitude: 22.32, longitude: 114.17),
        "Asia/Jakarta": .init(latitude: -6.21, longitude: 106.85),
        "Asia/Jerusalem": .init(latitude: 31.77, longitude: 35.21),
        "Asia/Karachi": .init(latitude: 24.86, longitude: 67.01),
        "Asia/Kolkata": .init(latitude: 22.57, longitude: 88.36),
        "Asia/Manila": .init(latitude: 14.60, longitude: 120.98),
        "Asia/Seoul": .init(latitude: 37.57, longitude: 126.98),
        "Asia/Shanghai": .init(latitude: 31.23, longitude: 121.47),
        "Asia/Singapore": .init(latitude: 1.35, longitude: 103.82),
        "Asia/Taipei": .init(latitude: 25.03, longitude: 121.57),
        "Asia/Tokyo": .init(latitude: 35.69, longitude: 139.69),
        "Australia/Adelaide": .init(latitude: -34.93, longitude: 138.60),
        "Australia/Brisbane": .init(latitude: -27.47, longitude: 153.03),
        "Australia/Melbourne": .init(latitude: -37.81, longitude: 144.96),
        "Australia/Perth": .init(latitude: -31.95, longitude: 115.86),
        "Australia/Sydney": .init(latitude: -33.87, longitude: 151.21),
        "Europe/Amsterdam": .init(latitude: 52.37, longitude: 4.90),
        "Europe/Athens": .init(latitude: 37.98, longitude: 23.73),
        "Europe/Berlin": .init(latitude: 52.52, longitude: 13.41),
        "Europe/Istanbul": .init(latitude: 41.01, longitude: 28.98),
        "Europe/London": .init(latitude: 51.51, longitude: -0.13),
        "Europe/Madrid": .init(latitude: 40.42, longitude: -3.70),
        "Europe/Moscow": .init(latitude: 55.76, longitude: 37.62),
        "Europe/Paris": .init(latitude: 48.86, longitude: 2.35),
        "Europe/Rome": .init(latitude: 41.90, longitude: 12.50),
        "Pacific/Auckland": .init(latitude: -36.85, longitude: 174.76),
        "Pacific/Honolulu": .init(latitude: 21.31, longitude: -157.86),
    ]
}
