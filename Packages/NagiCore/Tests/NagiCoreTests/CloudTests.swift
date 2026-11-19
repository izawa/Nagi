import NagiKit
import Testing
@testable import NagiCore

/// The shared clouds (SPEC 3.6, DECISIONS D20).
struct CloudTests {
    /// The same instant gives the same sky, and the values stay in range.
    @Test func sameTimeSameSky() {
        for step in 0..<2000 {
            let time = Double(step) * 7.3
            let a = CloudModel.sky(at: time, seed: 4), b = CloudModel.sky(at: time, seed: 4)
            #expect(a == b)
            #expect((0...0.4).contains(a.cover))
            #expect((0...1).contains(a.occlusion))
        }
    }

    /// A fair sky: the sun is fully hidden only rarely, partly hidden sometimes (the author chose
    /// cover 0–0.4: about 1 % and 18 % in a simulation).
    @Test func fairSky() {
        let samples = (0..<200_000).map { CloudModel.sky(at: Double($0) * 3, seed: 2).occlusion }
        let hidden = Double(samples.filter { $0 > 0.95 }.count) / Double(samples.count)
        let partly = Double(samples.filter { $0 > 0.05 && $0 <= 0.95 }.count) / Double(samples.count)
        #expect(hidden < 0.05)
        #expect(partly > 0.05 && partly < 0.4)
    }

    /// The occlusion changes smoothly: no jump from one frame to the next.
    @Test func occlusionIsSmooth() {
        var previous = CloudModel.sky(at: 0, seed: 6).occlusion
        for step in 1...36_000 {
            let occlusion = CloudModel.sky(at: Double(step) / 60, seed: 6).occlusion
            #expect(abs(occlusion - previous) < 0.01)
            previous = occlusion
        }
    }

    /// The debug pass: clear, covering, hidden, clearing, clear.
    @Test func debugPass() {
        #expect(CloudModel.pass(elapsed: 0) == 0)
        #expect(CloudModel.pass(elapsed: 3) == 0)
        #expect(CloudModel.pass(elapsed: 15) == 1)
        #expect(CloudModel.pass(elapsed: 30) == 0)
        let environment = EnvironmentModel.environment(at: .now, location: GeoLocation(latitude: 35.7, longitude: 139.7),
                                                       windTime: 115, weather: .init(sky: .cloudPass(start: 100)))
        #expect(environment.sunOcclusion == 1)
        let clear = EnvironmentModel.environment(at: .now, location: GeoLocation(latitude: 35.7, longitude: 139.7),
                                                 windTime: 115, weather: .init(sky: .clear))
        #expect(clear.sunOcclusion == 0 && clear.cloudCover == 0)
    }
}
