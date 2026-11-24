import CoreGraphics
import Foundation
import NagiKit
import Testing
import simd
@testable import FirefliesEffect

/// The flight and the flashes (M7-PLAN 3, 6), and when fireflies show (M7-PLAN 4, 9).
struct FlightTests {
    let bounds = CGRect(x: 0, y: 0, width: 1512, height: 982)

    func frame(sun: Double, strength: Double? = nil, depth: Double = 0) -> FrameState {
        var environment = SharedEnvironment()
        environment.sun = CelestialPosition(altitude: sun)
        return FrameState(time: 0, deltaTime: 0, date: Date(), phase: .calm, presence: 1, depth: depth,
                          appearance: .dark, parameters: strength.map { ["strength": .number($0)] } ?? [:],
                          seed: 1, environment: environment)
    }

    /// Random mode asks at the start of a calm (depth 0): at night fireflies are not silent then,
    /// though none flies yet.
    @Test func silentOnlyByDayOrAtNoStrength() {
        #expect(!Fireflies.isSilent(frame(sun: -0.3, depth: 0)))
        #expect(Fireflies.note(frame(sun: -0.3)) == nil)
        #expect(Fireflies.isSilent(frame(sun: 0.3)))
        #expect(Fireflies.isSilent(frame(sun: 0)))
        #expect(Fireflies.note(frame(sun: 0.3))?.key == "蛍は日が沈むと現れます")
        #expect(Fireflies.isSilent(frame(sun: -0.3, strength: 0)))
        #expect(Fireflies.isSilent(frame(sun: -0.3, strength: .nan)))
        // Twilight: coming in between 0° and −6°.
        let dusk = Fireflies.visibility(frame(sun: -3 * .pi / 180))
        #expect(dusk > 0 && dusk < 1)
    }

    /// It flies on while dark: no jump from frame to frame, and it gets somewhere.
    @Test func flightIsSmooth() {
        let swarm = Swarm(seed: 7, displays: [bounds], count: 1, period: 4, depth: 60, now: 100)
        let firefly = try! #require(swarm.fireflies[0])
        var last = firefly.position(at: 100)
        var fastest = 0.0
        for step in 1...(60 * 60) {
            let p = firefly.position(at: 100 + Double(step) / 60)
            fastest = max(fastest, simd_length(p - last) * 60)
            last = p
        }
        // Points per second: under 1.6 times the mean speed.
        #expect(fastest < 1.6 * firefly.speed)
        #expect(simd_length(last - firefly.position(at: 100)) > 5 * Swarm.pointsPerMillimetre)
    }

    /// One flash per period, each up and down well within it: no pixel flashes more than once in
    /// three seconds. Alone, it keeps its own rate.
    @Test func oneFlashPerPeriod() {
        var swarm = Swarm(seed: 3, displays: [bounds], count: 1, period: 4, depth: 30, now: 0)
        var starts: [Double] = [], previous = 0.0, longest = 0.0, litSince = 0.0
        for step in 1...(60 * 40) {
            let now = Double(step) / 60
            swarm.advance(to: now, depth: 400)
            let value = swarm.fireflies[0]?.brightness(at: now) ?? 0
            if previous == 0, value > 0 { starts.append(now); litSince = now }
            if value > 0 { longest = max(longest, now - litSince) }
            previous = value
        }
        let gaps = zip(starts, starts.dropFirst()).map { $1 - $0 }
        #expect(starts.count >= 8)
        #expect(gaps.allSatisfy { $0 > 3 })
        #expect(longest < Firefly.lit + 0.05)
        // The first light within two seconds of the start.
        #expect(starts[0] < 2)
    }

    /// As the calm deepens the flock falls into step: newcomers come in out of step, and within a
    /// minute of full pull they flash together. No pull before 60 s of calm.
    @Test func flashesFallIntoStep() {
        #expect(Swarm.pull(depth: 60) == 0 && Swarm.pull(depth: 300) == 1)
        var swarm = Swarm(seed: 13, displays: [CGRect(x: -1e6, y: -1e6, width: 2e6, height: 2e6)], count: 10,
                          period: 4, depth: 60, now: 0)
        swarm.advance(to: 0.05, depth: 400)
        let before = swarm.order
        for step in 2...(20 * 60) { swarm.advance(to: Double(step) / 20, depth: 400) }
        #expect(swarm.fireflies.compactMap { $0 }.count >= 6)  // some have flown their life and been replaced
        #expect(before < 0.8)
        #expect(swarm.order > 0.9)
    }

    /// The first light by about 35 s of calm, one more slot every 20 s; a deep start finds them
    /// flying, on the desktop.
    @Test func slotsFillAsTheCalmDeepens() {
        var swarm = Swarm(seed: 5, displays: [bounds], count: 3, period: 4, depth: 0, now: 0)
        #expect(swarm.fireflies.allSatisfy { $0 == nil })
        swarm.advance(to: 29, depth: 29)
        #expect(swarm.fireflies[0] == nil)
        swarm.advance(to: 31, depth: 31)
        #expect(swarm.fireflies[0] != nil && swarm.fireflies[1] == nil)
        let deep = Swarm(seed: 5, displays: [bounds], count: 3, period: 4, depth: 120, now: 500)
        #expect(deep.fireflies.allSatisfy { $0 != nil })
        // The first slot lights first.
        let waits = deep.fireflies.map { (1 - $0!.phase) * $0!.period }
        #expect(waits[0] < 2 && waits.dropFirst().allSatisfy { $0 >= waits[0] * 0.9 })
        for firefly in deep.fireflies { #expect(bounds.contains(firefly!.point(at: 500))) }
    }

    /// A firefly that has flown its life gives its slot to a new one after some dark.
    @Test func aSlotIsRefilled() {
        var swarm = Swarm(seed: 9, displays: [CGRect(x: -1e6, y: -1e6, width: 2e6, height: 2e6)], count: 1,
                          period: 4, depth: 60, now: 0)
        let first = try! #require(swarm.fireflies[0])
        var now = 0.0
        while swarm.fireflies[0]?.seed == first.seed, now < 200 { now += 0.05; swarm.advance(to: now, depth: 600) }
        #expect(now >= first.life + first.born)
        while swarm.fireflies[0] == nil, now < 220 { now += 0.05; swarm.advance(to: now, depth: 600) }
        #expect(swarm.fireflies[0] != nil)
    }

    /// One that has flown off the desktop gives its slot up at once, not at the end of its life.
    @Test func aFireflyThatLeavesIsReplaced() {
        var swarm = Swarm(seed: 9, displays: [CGRect(x: 0, y: 0, width: 200, height: 200)], count: 1, period: 4,
                          depth: 60, now: 0)
        let first = try! #require(swarm.fireflies[0])
        // Find when it is past the edge (a 200-point desktop is crossed in well under its life).
        let out = stride(from: 0.0, to: first.life, by: 0.5).first {
            let p = first.position(at: $0)
            return !CGRect(x: -Swarm.margin, y: -Swarm.margin, width: 200 + 2 * Swarm.margin,
                           height: 200 + 2 * Swarm.margin).contains(CGPoint(x: p.x, y: p.y))
        }
        let time = try! #require(out)
        swarm.advance(to: time, depth: 600)
        #expect(swarm.fireflies[0] == nil)
    }

    /// Born heading into its display: nearly always still on it a period later (one born in a
    /// corner may turn along the edge and leave).
    @Test func bornHeadingIn() {
        let left = (UInt64(1)...200).filter { seed in
            let swarm = Swarm(seed: seed, displays: [bounds], count: 1, period: 4, depth: 60, now: 0)
            return !bounds.contains(swarm.fireflies[0]!.point(at: 4))
        }
        #expect(left.count <= 4)
    }

    /// It drifts nearer and further, within 0.3 … 4 m, without a jump.
    @Test func distanceSwingsSmoothly() {
        let swarm = Swarm(seed: 21, displays: [bounds], count: 1, period: 4, depth: 60, now: 0)
        let firefly = try! #require(swarm.fireflies[0])
        let samples = stride(from: 0.0, through: 60, by: 1.0 / 30).map { firefly.distance(at: $0) }
        #expect(samples.allSatisfy { Firefly.distances.contains($0) })
        #expect(samples.max()! / samples.min()! > 1.3)
        #expect(zip(samples, samples.dropFirst()).allSatisfy { abs(log($1 / $0)) < 0.02 })
    }

    @Test func sameSeedSameSwarm() {
        let a = Swarm(seed: 11, displays: [bounds], count: 4, period: 4, depth: 200, now: 10)
        let b = Swarm(seed: 11, displays: [bounds], count: 4, period: 4, depth: 200, now: 10)
        #expect(a.fireflies == b.fireflies)
    }
}
