import CoreGraphics
import NagiKit
import simd
import Testing
@testable import RainEffect

/// Where the still drops sit (SPEC 4.2 深まり方, M2-PLAN stage B).
struct DropsTests {
    let display = CGRect(x: 0, y: 0, width: 2560, height: 1440)

    func covered(_ drops: [Drop]) -> Double {
        drops.reduce(0) { $0 + $1.area } / Double(display.width * display.height)
    }

    /// What rain tells the core (D32): from a sprinkle at first to a downpour at two minutes.
    @Test func precipitationFollowsTheCoverage() {
        func rain(depth: Double, intensity: Double) -> Double {
            Rain.precipitation(FrameState(time: 0, deltaTime: 0, date: .distantPast, phase: .calm, presence: 1,
                                          depth: depth, appearance: .light, parameters: ["intensity": .number(intensity)],
                                          seed: 1))
        }
        #expect(rain(depth: 0, intensity: 1) < 0.05)
        #expect(abs(rain(depth: 120, intensity: 1) - 1) < 1e-9)
        #expect(rain(depth: 120, intensity: 0.5) < 0.6)
        #expect(rain(depth: 120, intensity: 1.5) == 1)
    }

    @Test func sameInputsSameDrops() {
        let a = Drops.scatter(displays: [display], depth: 60, intensity: 1, size: 1, seed: 1)
        #expect(a == Drops.scatter(displays: [display], depth: 60, intensity: 1, size: 1, seed: 1))
        #expect(a != Drops.scatter(displays: [display], depth: 60, intensity: 1, size: 1, seed: 2))
    }

    @Test func coverageFollowsDepth() {
        let early = covered(Drops.scatter(displays: [display], depth: 5, intensity: 1, size: 1, seed: 1))
        let full = covered(Drops.scatter(displays: [display], depth: 300, intensity: 1, size: 1, seed: 1))
        #expect(early < 0.01)                      // a few small drops while the hands may be reading
        #expect(full > 0.11 && full < 0.13)        // a downpour covers about 12 % (SPEC 4.2)
        let heavy = covered(Drops.scatter(displays: [display], depth: 300, intensity: 1.5, size: 1, seed: 1))
        #expect(heavy < 0.13)                      // and no more, whatever the intensity
        #expect(Drops.scatter(displays: [display], depth: 5, intensity: 1, size: 1, seed: 1)
            .allSatisfy { $0.reach < 8 })          // and they are small
    }

    /// Drops that land on one another run together: none touch, and no water is lost.
    @Test func touchingDropsRunTogether() {
        // A small display at downpour density, so every pair can be checked.
        let small = CGRect(x: 0, y: 0, width: 600, height: 400)
        let drops = Drops.scatter(displays: [small], depth: 150, intensity: 1, size: 1, seed: 1)
        let touching = drops.indices.contains { i in drops[(i + 1)...].contains { drops[i].touches($0) } }
        #expect(!touching)
        var field = DropField()
        field.add(Drop(center: SIMD2(100, 100), radius: 4, shape: 0), pull: 0)
        field.add(Drop(center: SIMD2(106, 100), radius: 3, shape: 0.5), pull: 0.5)
        #expect(field.drops.count == 1)
        let merged = field.drops[0]
        #expect(merged.lobes.count == 2)                           // the trace of both drops stays
        #expect(merged.center.x > 100 && merged.center.x < 103)   // nearer the larger drop
        let apart = simd_distance(merged.lobes[0].offset, merged.lobes[1].offset)
        #expect(apart > 2.9 && apart < 3.1)                        // drawn halfway together
        // Beyond four lobes, the nearest two become one.
        var many = Drop(center: .zero, radius: 3, shape: 0)
        for i in 1...4 { many = many.merged(with: Drop(center: SIMD2(Double(i) * 6, 0), radius: 3, shape: 0), pull: 0) }
        #expect(many.lobes.count == Drop.maxLobes)
    }

    /// However many drops a drop swallows, it stays the size of its water (no runaway growth).
    @Test func mergeChainsKeepTheirSize() {
        for seed in 1...8 {
            let drops = Drops.scatter(displays: [display], depth: 120, intensity: 1, size: 1, seed: UInt64(seed))
            for drop in drops {
                let disks = drop.lobes.reduce(0) { $0 + Double.pi * $1.radius * $1.radius }
                #expect(disks <= drop.area * Drop.lobeSpread * 1.0001)
            }
            #expect(drops.map(\.reach).max()! < 200)
        }
    }

    /// Fewer drops (Increase Contrast, Reduce Transparency) halves the rain even where the drop
    /// budget, not the coverage, ends the placing.
    @Test func fewerHalvesEvenAtTheBudget() {
        let huge = CGRect(x: 0, y: 0, width: 7680, height: 4320)
        let full = Drops.scatter(displays: [huge], coverage: 0.12, depth: 150, size: 0.5, seed: 1)
        let fewer = Drops.scatter(displays: [huge], coverage: 0.12, depth: 150, size: 0.5, seed: 1, fewer: true)
        let ratio = fewer.reduce(0) { $0 + $1.area } / full.reduce(0) { $0 + $1.area }
        #expect(ratio > 0.4 && ratio < 0.6)
    }

    /// Drops across the edge between two displays run together.
    @Test func dropsMergeAcrossDisplays() {
        var field = DropField()
        field.add(Drop(center: SIMD2(2558, 100), radius: 4, shape: 0), pull: 0.5)
        field.add(Drop(center: SIMD2(2563, 100), radius: 4, shape: 0), pull: 0.5)
        #expect(field.drops.count == 1)
    }

    @Test func dropsStayOnTheirDisplays() {
        let second = CGRect(x: 2560, y: -200, width: 1920, height: 1080)
        let drops = Drops.scatter(displays: [display, second], depth: 120, intensity: 1, size: 1, seed: 1)
        #expect(drops.allSatisfy { display.contains(CGPoint(x: $0.center.x, y: $0.center.y))
            || second.contains(CGPoint(x: $0.center.x, y: $0.center.y)) })
        #expect(drops.contains { second.contains(CGPoint(x: $0.center.x, y: $0.center.y)) })
    }

    /// A drop landing on a runner, even a larger one, leaves the runner's motion (for the blur).
    @Test func mergeKeepsTheLatestRun() {
        var runner = Drop(center: SIMD2(0, 0), radius: 5, shape: 0)
        (runner.moved, runner.movedAt) = (12, 1)
        let landed = Drop(center: SIMD2(6, 0), radius: 8, shape: 0)
        for merged in [runner.merged(with: landed, pull: 0.5), landed.merged(with: runner, pull: 0.5)] {
            #expect(merged.moved == 12 && merged.movedAt == 1)
        }
    }
}
