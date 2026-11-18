import Foundation
import NagiCore
import Testing

private let tokyo = GeoLocation(latitude: 35.68, longitude: 139.69)
private func date(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }
private func deg(_ r: Double) -> Double { r * 180 / .pi }

@Test func morningEastAfternoonWest() {
    let morning = Sun.position(at: date("2026-06-21T07:00:00+09:00"), location: tokyo)
    let afternoon = Sun.position(at: date("2026-06-21T16:00:00+09:00"), location: tokyo)
    #expect((45...110).contains(deg(morning.azimuth)), "morning az \(deg(morning.azimuth))")
    #expect((250...315).contains(deg(afternoon.azimuth)), "afternoon az \(deg(afternoon.azimuth))")
    #expect(morning.altitude > 0 && afternoon.altitude > 0)
}

@Test func solsticeNoonAltitudes() {
    // Solar noon in Tokyo is about 11:40 JST.
    let summer = (0..<120).map { Sun.position(at: date("2026-06-21T10:40:00+09:00").addingTimeInterval(Double($0) * 60), location: tokyo).altitude }.max()!
    let winter = (0..<120).map { Sun.position(at: date("2025-12-21T10:40:00+09:00").addingTimeInterval(Double($0) * 60), location: tokyo).altitude }.max()!
    #expect(abs(deg(summer) - (90 - 35.68 + 23.44)) < 0.6, "summer \(deg(summer))")
    #expect(abs(deg(winter) - (90 - 35.68 - 23.44)) < 0.6, "winter \(deg(winter))")
}

@Test func tokyoEveningSunIsDown() {
    #expect(Sun.position(at: date("2026-11-18T20:20:00+09:00"), location: tokyo).altitude < 0)
    #expect(Sun.position(at: date("2026-11-18T12:00:00+09:00"), location: tokyo).altitude > 0)
}

@Test func southernHemisphereNoonSunIsNorth() {
    let sydney = GeoLocation(latitude: -33.87, longitude: 151.21)
    let noon = Sun.position(at: date("2026-06-21T12:00:00+10:00"), location: sydney)
    let az = deg(noon.azimuth)
    #expect(az < 30 || az > 330, "az \(az)")
}
