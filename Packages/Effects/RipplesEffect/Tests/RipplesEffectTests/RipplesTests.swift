import Foundation
import Testing
@testable import RipplesEffect

@Suite struct WaterTests {
    let water = Water()

    @Test func theWavesHaveRealWaterFrequencies() {
        // 1.6, 3 and 5 cm waves on 20 mm of water: about 14.4, 8.3 and 5.9 Hz (M6-PLAN 2).
        let hertz = [0.016, 0.03, 0.05].map { water.omega(2 * .pi / $0) / (2 * .pi) }
        #expect(abs(hertz[0] - 14.4) < 0.2)
        #expect(abs(hertz[1] - 8.3) < 0.2)
        #expect(abs(hertz[2] - 5.9) < 0.2)
    }

    @Test func aDropMovesNoWater() {
        #expect(abs(water.impulse(0)) < 1e-15)
    }

    @Test func aDropDentsTheCentreThenTheRingsMoveOut() {
        let push = water.pushScale(forDent: 0.003)
        // The centre goes down first.
        #expect(water.centreHeight(at: 0.02) * push < 0)
        // Where the slope is steepest moves out at about 20 cm a second (the numbers of M6-PLAN 2).
        func steepest(at t: Double) -> Double {
            stride(from: 0.005, through: 0.4, by: 0.0025).max { abs(water.radialSlope(at: $0, time: t))
                < abs(water.radialSlope(at: $1, time: t)) }!
        }
        #expect(abs(steepest(at: 0.5) - 0.11) < 0.02)
        #expect(steepest(at: 1.0) > steepest(at: 0.5))
    }
}

@Suite struct PoolTests {
    let pool = Pool(width: 597, height: 336)

    @Test func mirrorsTakeTheRightNumberOfBounces() {
        let xs = Pool.mirrors(100, length: 597, reach: 700)
        #expect(xs.contains { $0.0 == 100 && $0.1 == 0 })
        #expect(xs.contains { $0.0 == -100 && $0.1 == 1 })
        #expect(xs.contains { $0.0 == 2 * 597 - 100 && $0.1 == 1 })
        #expect(xs.contains { $0.0 == 2 * 597 + 100 && $0.1 == 2 })
    }

    /// The walls reflect: across each wall the slope from all sources is zero.
    @Test func noSlopeCrossesAWall() {
        let drop = Drop(x: 120, y: 90, time: 0, strength: 1)
        let sources = pool.sources(of: drop, index: 0, reach: 1500, reflectance: 1)
        func slope(_ p: SIMD2<Double>) -> SIMD2<Double> {
            // Any radial profile will do for the symmetry.
            sources.reduce(.zero) { sum, s in
                let d = p - SIMD2(s.x, s.y), r = (d * d).sum().squareRoot()
                guard r < 1500, r > 0 else { return sum }
                return sum + s.gain * sin(r / 13) * exp(-r / 400) * d / r
            }
        }
        for y in stride(from: 10.0, to: 336, by: 37) {
            #expect(abs(slope(SIMD2(0, y)).x) < 1e-9)
            #expect(abs(slope(SIMD2(597, y)).x) < 1e-9)
        }
        for x in stride(from: 10.0, to: 597, by: 53) {
            #expect(abs(slope(SIMD2(x, 0)).y) < 1e-9)
            #expect(abs(slope(SIMD2(x, 336)).y) < 1e-9)
        }
    }

    @Test func aWeakWallReturnsLess() {
        let drop = Drop(x: 120, y: 90, time: 0, strength: 1)
        let sources = pool.sources(of: drop, index: 0, reach: 800, reflectance: 0.5)
        #expect(sources.contains { $0.x == -120 && $0.y == 90 && $0.gain == 0.5 })
        #expect(sources.contains { $0.x == -120 && $0.y == -90 && $0.gain == 0.25 })
    }
}

@Suite struct DropScheduleTests {
    let pool = Pool(width: 597, height: 336)

    func run(seed: UInt64, depthAt: (Double) -> Double, seconds: Double) -> [Drop] {
        var schedule = DropSchedule(seed: seed)
        var seen: [Drop] = []
        for i in 0...Int(seconds * 60) {
            let t = Double(i) / 60
            schedule.step(time: t, dt: 1.0 / 60, depth: depthAt(t), rate: 1, pool: pool, lifetime: 5, strength: 0.7...1.3)
            for drop in schedule.drops where !seen.contains(drop) { seen.append(drop) }
        }
        return seen
    }

    @Test func noDropFallsInTheFirstTwentySeconds() {
        #expect(run(seed: 7, depthAt: { $0 }, seconds: 20).isEmpty)
    }

    @Test func theSameSeedGivesTheSameDrops() {
        #expect(run(seed: 7, depthAt: { $0 + 100 }, seconds: 30) == run(seed: 7, depthAt: { $0 + 100 }, seconds: 30))
        #expect(run(seed: 7, depthAt: { $0 + 100 }, seconds: 30) != run(seed: 1, depthAt: { $0 + 100 }, seconds: 30))
    }

    /// Drops fall at the moment their turn comes, so 30 and 60 frames a second see the same water.
    @Test func theFrameRateDoesNotChangeTheDrops() {
        func drops(fps: Double) -> [Drop] {
            var schedule = DropSchedule(seed: 3)
            var seen: [Drop] = []
            for i in 0...Int(60 * fps) {
                schedule.step(time: Double(i) / fps, dt: i == 0 ? 0 : 1 / fps, depth: 150, rate: 1, pool: pool, lifetime: 5, strength: 0.7...1.3)
                for drop in schedule.drops where !seen.contains(where: { abs($0.time - drop.time) < 1e-9 }) { seen.append(drop) }
            }
            return seen
        }
        let a = drops(fps: 30), b = drops(fps: 60)
        #expect(a.count == b.count && !a.isEmpty)
        for (x, y) in zip(a, b) { #expect(abs(x.time - y.time) < 1e-6 && x.x == y.x && x.y == y.y) }
    }

    @Test func deepCalmGetsAboutThirtyAMinuteAndKeepsTheirDistance() {
        let drops = run(seed: 1, depthAt: { _ in 150 }, seconds: 120)
        #expect(drops.count > 40 && drops.count < 75)
        for (a, b) in zip(drops, drops.dropFirst()) { #expect(b.time - a.time >= DropSchedule.spacing - 1e-9) }
        #expect(drops.allSatisfy { $0.x >= 0 && $0.x <= 597 && $0.y >= 0 && $0.y <= 336 })
    }
}

@Suite struct DescriptorTests {
    /// Ripples flash beyond the rule, so they carry the notice that keeps them off by default, and
    /// the waves' shadow stays at the strength that keeps blank areas within it (SPEC 2.2, M6-LOG).
    @Test func ripplesCarryTheNoticeAndAMildShadow() throws {
        #expect(Ripples.descriptor.photosensitivityNotice != nil)
        let shadow = try #require(Ripples.descriptor.parameters.first { $0.key == "shadow" })
        #expect(shadow.defaultValue == .number(0.4))
    }
}
