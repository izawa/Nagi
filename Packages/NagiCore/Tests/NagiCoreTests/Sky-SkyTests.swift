import Foundation
import NagiCore
import Testing

private let radiansPerDegree = Double.pi / 180
private let tokyo = GeoLocation(latitude: 35.69, longitude: 139.69)

@Test(arguments: [("2026-06-21T02:43:00Z", 23.44), ("2026-12-21T02:39:00Z", -23.44)])
func tokyoSolsticeNoon(time: String, declination: Double) throws {
    let date = try Date(time, strategy: .iso8601)
    let sun = Sun.position(at: date, location: tokyo)
    let expectedAltitude = (90 - tokyo.latitude + declination) * radiansPerDegree
    #expect(abs(sun.altitude - expectedAltitude) < 0.5 * radiansPerDegree)
    #expect(abs(sun.azimuth - .pi) < 2 * radiansPerDegree)
}

@Test func equatorialSunOnTheMarchEquinox() throws {
    let location = GeoLocation(latitude: 0, longitude: 0)
    let sunrise = try Date("2026-03-20T06:07:00Z", strategy: .iso8601)
    let noon = try Date("2026-03-20T12:07:00Z", strategy: .iso8601)
    let sunset = try Date("2026-03-20T18:07:00Z", strategy: .iso8601)
    let rising = Sun.position(at: sunrise, location: location)
    let transiting = Sun.position(at: noon, location: location)
    let setting = Sun.position(at: sunset, location: location)

    let tolerance = 0.5 * radiansPerDegree
    #expect(abs(rising.altitude) < tolerance)
    #expect(abs(rising.azimuth - .pi / 2) < tolerance)
    #expect(abs(transiting.altitude - .pi / 2) < tolerance)
    #expect(abs(setting.altitude) < tolerance)
    #expect(abs(setting.azimuth - 3 * .pi / 2) < tolerance)
}

@Test func sunlightTemperatureIncreasesWithAltitude() {
    let temperatures = [-10.0, 0, 5, 15, 30, 45, 60, 90].map {
        Sun.colorTemperature(altitude: $0 * radiansPerDegree)
    }
    #expect(temperatures == temperatures.sorted())
    #expect(abs(Sun.colorTemperature(altitude: 0) - 2_000) < 50)
    #expect(abs(Sun.colorTemperature(altitude: .pi / 2) - 5_500) < 50)
}

// U.S. Naval Observatory, Dates of Primary Phases of the Moon, 2026.
@Test(arguments: [
    ("2026-01-03T10:03:00Z", 0.5),
    ("2026-01-10T15:48:00Z", 0.75),
    ("2026-01-18T19:52:00Z", 0.0),
    ("2026-01-26T04:47:00Z", 0.25),
])
func lunarPhase(time: String, expectedPhase: Double) throws {
    let date = try Date(time, strategy: .iso8601)
    let phase = Moon.phase(at: date)
    let difference = abs(phase - expectedPhase)
    #expect((0..<1).contains(phase))
    #expect(min(difference, 1 - difference) < 0.05)
}

@Test func fullMoonAltitudeInTokyo() throws {
    let midday = try Date("2026-01-03T03:00:00Z", strategy: .iso8601)
    let midnight = try Date("2026-01-03T15:00:00Z", strategy: .iso8601)
    let below = Moon.position(at: midday, location: tokyo)
    let above = Moon.position(at: midnight, location: tokyo)
    #expect(below.altitude < 0)
    #expect(above.altitude > 0)
    #expect((0..<(2 * .pi)).contains(below.azimuth))
    #expect((0..<(2 * .pi)).contains(above.azimuth))
}

@Test(arguments: [
    ("Asia/Tokyo", GeoLocation(latitude: 35.69, longitude: 139.69)),
    ("Europe/London", GeoLocation(latitude: 51.51, longitude: -0.13)),
    ("America/New_York", GeoLocation(latitude: 40.71, longitude: -74.01)),
    ("America/Los_Angeles", GeoLocation(latitude: 34.05, longitude: -118.24)),
    ("Australia/Sydney", GeoLocation(latitude: -33.87, longitude: 151.21)),
])
func representativeCity(identifier: String, expectedLocation: GeoLocation) throws {
    let date = try Date("2026-07-01T00:00:00Z", strategy: .iso8601)
    let zone = try #require(TimeZone(identifier: identifier))
    #expect(RepresentativeCity.location(for: zone, at: date) == expectedLocation)
}

@Test func fallbackUsesTheDatesFractionalUTCOffset() throws {
    let winter = try Date("2026-01-01T00:00:00Z", strategy: .iso8601)
    let summer = try Date("2026-07-01T00:00:00Z", strategy: .iso8601)
    let newfoundland = try #require(TimeZone(identifier: "America/St_Johns"))
    let fixed = try #require(TimeZone(secondsFromGMT: 20_700))

    #expect(RepresentativeCity.location(for: newfoundland, at: winter) == GeoLocation(latitude: 35, longitude: -52.5))
    #expect(RepresentativeCity.location(for: newfoundland, at: summer) == GeoLocation(latitude: 35, longitude: -37.5))
    #expect(RepresentativeCity.location(for: fixed, at: summer) == GeoLocation(latitude: 35, longitude: 86.25))
}
