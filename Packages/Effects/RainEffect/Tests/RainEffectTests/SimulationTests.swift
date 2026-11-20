import CoreGraphics
import simd
import Testing
@testable import RainEffect

/// The rain over time (SPEC 4.2 シミュレーション, M2-PLAN stage C).
struct SimulationTests {
    let display = CGRect(x: 0, y: 0, width: 800, height: 600)
    let downpour = RainSimulation.Settings(depth: 150, intensity: 1, size: 1)

    func water(_ simulation: RainSimulation) -> Double { simulation.drops.reduce(0) { $0 + $1.area } }

    /// Same seed, same steps: the same drops (nagi-render and the flash check depend on it).
    @Test func sameSeedSameRain() {
        var a = RainSimulation(displays: [display], settings: downpour, seed: 3)
        var b = RainSimulation(displays: [display], settings: downpour, seed: 3)
        for _ in 0..<120 {
            a.advance(by: 1.0 / 60, downpour)
            b.advance(by: 1.0 / 60, downpour)
        }
        #expect(a.drops == b.drops)
    }

    /// No water appears or vanishes: what arrived is on the glass or ran off the bottom.
    @Test func waterIsKept() {
        var simulation = RainSimulation(displays: [display], settings: downpour, seed: 5)
        for _ in 0..<600 { simulation.advance(by: 1.0 / 60, downpour) }
        let books = simulation.arrived - simulation.drained
        #expect(abs(water(simulation) - books) / books < 0.01)
        #expect(simulation.drained > 0)                       // some ran off in ten seconds
    }

    /// A heavy drop slides down and leaves beads behind; a small one stays.
    @Test func heavyDropsSlide() {
        let calm = RainSimulation.Settings(depth: 0, intensity: 0.0001, size: 1)
        var simulation = RainSimulation(displays: [CGRect(x: 0, y: 0, width: 400, height: 1200)], settings: calm, seed: 1)
        var field = DropField()
        var heavy = Drop(center: SIMD2(100, 100), radius: 12, shape: 0)
        heavy.heldUntil = 0                                    // free to go at once
        field.add(heavy, pull: 0)
        field.add(Drop(center: SIMD2(300, 100), radius: 2, shape: 0), pull: 0)
        simulation.replaceField(field)
        for _ in 0..<60 { simulation.advance(by: 1.0 / 60, calm) }
        let big = simulation.drops.max { $0.area < $1.area }!
        #expect(big.center.y > 300)                            // it ran down, fast
        #expect(simulation.drops.contains { $0.center.y < big.center.y - 20 && $0.center.x < 200 })   // a bead behind
        #expect(simulation.drops.contains { simd_distance($0.center, SIMD2(300, 100)) < 1 })          // the small one stayed
    }

    /// The glass tends to the depth's coverage and stays alive at it.
    @Test func coverageHoldsAtDownpour() {
        var simulation = RainSimulation(displays: [display], settings: downpour, seed: 9)
        for _ in 0..<1200 { simulation.advance(by: 1.0 / 60, downpour) }
        let covered = water(simulation) / Double(display.width * display.height)
        #expect(covered > 0.02 && covered < 0.14)
    }

    /// A runner leaves only tiny beads, so it keeps its water and runs off the bottom.
    @Test func runnerRunsOff() {
        let calm = RainSimulation.Settings(depth: 0, intensity: 0.0001, size: 1)
        var simulation = RainSimulation(displays: [CGRect(x: 0, y: 0, width: 400, height: 1400)], settings: calm, seed: 1)
        var field = DropField()
        var runner = Drop(center: SIMD2(200, 50), radius: 11, shape: 0)
        runner.heldUntil = 0
        field.add(runner, pull: 0)
        simulation.replaceField(field)
        for _ in 0..<600 { simulation.advance(by: 1.0 / 60, calm) }
        #expect(simulation.drained > Double.pi * 11 * 11 * 0.7)   // most of it ran off
        #expect(simulation.drops.allSatisfy { $0.size < 2 })      // what stays behind is tiny
    }

    /// A runner leaves its line only where it joins a drop that sits off to one side, and by as
    /// much as that drop weighs; with nothing in the way it runs straight.
    @Test func runnerTurnsWhereItJoinsADrop() {
        let calm = RainSimulation.Settings(depth: 0, intensity: 0.0001, size: 1)
        var simulation = RainSimulation(displays: [CGRect(x: 0, y: 0, width: 400, height: 1400)], settings: calm, seed: 1)
        var field = DropField()
        var runner = Drop(center: SIMD2(200, 50), radius: 11, shape: 0)
        runner.heldUntil = 0
        field.add(runner, pull: 0)
        // On its way, overlapping its right edge; and far to the left, out of its way.
        field.add(Drop(center: SIMD2(212, 140), radius: 5, shape: 0), pull: 0)
        field.add(Drop(center: SIMD2(150, 140), radius: 5, shape: 0), pull: 0)
        simulation.replaceField(field)
        for _ in 0..<30 { simulation.advance(by: 1.0 / 60, calm) }
        let moved = simulation.drops.max { $0.area < $1.area }!
        let shift = 12 * 25 / (121.0 + 25)                        // the joined drop's weight, times its offset
        #expect(abs(moved.center.x - (200 + shift)) < 1.5)        // moved right by about that
        #expect(simulation.drops.contains { abs($0.center.x - 150) < 0.01 })   // the far one untouched
        #expect(moved.area <= Double.pi * 121)                     // it did not swell with the water
    }

    /// The motion blur spans how far a runner went in the step, which can be more than its
    /// speed: put back in a free slot further on, it is moved again in the same step.
    @Test func paceIsTheDistanceGone() {
        let calm = RainSimulation.Settings(depth: 0, intensity: 0.0001, size: 1)
        var simulation = RainSimulation(displays: [CGRect(x: 0, y: 0, width: 400, height: 1400)], settings: calm, seed: 1)
        var field = DropField()
        var runner = Drop(center: SIMD2(200, 50), radius: 11, shape: 0)
        runner.heldUntil = 0
        field.add(runner, pull: 0)
        field.add(Drop(center: SIMD2(50, 1000), radius: 2, shape: 0), pull: 0)
        field.remove(field.add(Drop(center: SIMD2(350, 1000), radius: 2, shape: 0), pull: 0))   // free, after the runner
        simulation.replaceField(field)
        func runnerNow() -> Drop { simulation.drops.max { $0.area < $1.area }! }
        let before = runnerNow()
        #expect(simulation.pace(of: before) == 0)                 // not run yet
        simulation.advance(by: 1.0 / 60, calm)
        let after = runnerNow()
        let gone = after.center.y - before.center.y
        #expect(abs(simulation.pace(of: after) * RainSimulation.step - gone) < 1e-9)
        #expect(gone > after.speed * RainSimulation.step * 1.5)  // moved twice
        // A frame of two steps (30 fps): the pace is over both.
        simulation.advance(by: 2.0 / 60, calm)
        let later = runnerNow()
        #expect(abs(simulation.pace(of: later) * 2 * RainSimulation.step - (later.center.y - after.center.y)) < 1e-9)
    }

    /// While nagi leaves no new drops land; with fewer drops asked for, the glass holds about half.
    @Test func arrivalsFollowSettings() {
        var leaving = downpour
        leaving.arriving = false
        var simulation = RainSimulation(displays: [display], settings: downpour, seed: 2)
        let before = simulation.arrived
        for _ in 0..<60 { simulation.advance(by: 1.0 / 60, leaving) }
        #expect(simulation.arrived == before)
        var fewer = downpour
        fewer.fewer = true
        let full = water(RainSimulation(displays: [display], settings: downpour, seed: 2))
        let half = water(RainSimulation(displays: [display], settings: fewer, seed: 2))
        #expect(half / full > 0.4 && half / full < 0.6)
    }

    /// Frames timed as start + index / fps step once each, even where the subtraction rounds a
    /// hair below one step (nagi-render's clock at --time 2719).
    @Test func roundedTimestampsStepEvenly() {
        var simulation = RainSimulation(displays: [display], settings: downpour, seed: 4)
        var reference = RainSimulation(displays: [display], settings: downpour, seed: 4)
        var previous = 2719.0
        for index in 1...30 {
            let now = 2719.0 + Double(index) / 60
            simulation.advance(by: now - previous, downpour)
            reference.advance(by: 1.0 / 60, downpour)
            previous = now
            #expect(simulation.drops == reference.drops)
        }
    }
}
