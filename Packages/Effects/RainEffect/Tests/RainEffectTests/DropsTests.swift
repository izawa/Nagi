import CoreGraphics
import simd
import Testing
@testable import RainEffect

/// Where the still drops sit (SPEC 4.2 深まり方, M2-PLAN stage B).
struct DropsTests {
    let display = CGRect(x: 0, y: 0, width: 2560, height: 1440)

    func covered(_ drops: [Drop]) -> Double {
        drops.reduce(0) { $0 + $1.area } / Double(display.width * display.height)
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
}
