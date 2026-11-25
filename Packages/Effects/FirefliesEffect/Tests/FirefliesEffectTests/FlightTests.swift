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

    /// Most in early summer, half in winter, smoothly through the year (M7-PLAN 4).
    @Test func seasonScalesTheNumber() throws {
        let tokyo = try #require(TimeZone(identifier: "Asia/Tokyo"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = tokyo
        func day(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0) throws -> Date {
            try #require(calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour)))
        }
        #expect(abs(Fireflies.season(try day(2026, 6, 15)) - 1) < 1e-9)
        #expect(abs(Fireflies.season(try day(2027, 6, 15)) - 1) < 1e-4)
        #expect(abs(Fireflies.season(try day(2026, 12, 14, 12)) - 0.5) < 1e-4)
        let spring = Fireflies.season(try day(2027, 3, 15))
        #expect(spring > 0.7 && spring < 0.8)
        // No step at the turn of the year.
        #expect(abs(Fireflies.season(try day(2026, 12, 31, 23)) - Fireflies.season(try day(2027, 1, 1, 1))) < 1e-3)
        let winter = try day(2026, 12, 15)
        #expect([1, 2, 12, 15].map { Fireflies.count($0, on: winter) } == [1, 1, 6, 8])
        #expect(Fireflies.count(12, on: try day(2026, 6, 15)) == 12)
        #expect(Fireflies.count(12, on: Date(timeIntervalSince1970: .nan)) == 12)
    }

    /// A desktop too big to leave, for following one firefly through its life.
    let wide = CGRect(x: -1e6, y: -1e6, width: 2e6, height: 2e6)

    /// It flies on while dark, without a jump: never faster than the near speed allows, and it
    /// gets somewhere.
    @Test func flightIsSmooth() {
        var swarm = Swarm(seed: 7, displays: [wide], count: 1, period: 4, depth: 60, now: 0)
        let start = swarm.fireflies[0]!.position
        var last = start, fastest = 0.0
        for step in 1...(60 * 40) {
            swarm.advance(to: Double(step) / 60, depth: 60)
            let p = swarm.fireflies[0]!.position
            fastest = max(fastest, simd_length(p - last) * 60)
            last = p
        }
        #expect(fastest <= Firefly.speeds.upperBound * 1.15 * Swarm.pointsPerMillimetre + 1e-9)
        #expect(simd_length(last - start) > 20 * Swarm.pointsPerMillimetre)
    }

    /// The speed follows the distance it is at now (nearer looks faster), times its pace and
    /// its pauses.
    @Test func speedFollowsTheDistanceNow() {
        let firefly = Firefly(seed: 1, born: 0, life: 60, position: .zero, heading: 0, pace: 0.9, period: 4, phase: 0,
                              depth: 0)
        for time in [3.0, 17.0, 41.0] {
            let near = firefly.nearness(at: time)
            let expected = (Firefly.speeds.lowerBound + (Firefly.speeds.upperBound - Firefly.speeds.lowerBound) * near)
                * 0.9 * firefly.slowing(at: time) * Swarm.pointsPerMillimetre
            #expect(abs(simd_length(firefly.velocity(at: time)) - expected) < 1e-9)
        }
        let nearness = stride(from: 0.0, to: 60, by: 1).map { firefly.nearness(at: $0) }
        #expect(nearness.max()! - nearness.min()! > 0.1)
    }

    /// Reduce Motion: half the distance flown, the flashes as they were.
    @Test func reduceMotionHalvesTheFlight() {
        var full = Swarm(seed: 3, displays: [wide], count: 1, period: 4, depth: 60, now: 0), half = full
        let start = full.fireflies[0]!.position
        for step in 1...200 {
            full.advance(to: Double(step) / 20, depth: 60)
            half.advance(to: Double(step) / 20, depth: 60, motion: 0.5)
        }
        let ratio = simd_length(half.fireflies[0]!.position - start) / simd_length(full.fireflies[0]!.position - start)
        #expect(abs(ratio - 0.5) < 1e-9)
        #expect(full.fireflies[0]!.phase == half.fireflies[0]!.phase)
    }

    /// Now and then it slows to a fifth for a second or two, easing in and out.
    @Test func itSlowsNowAndThen() {
        let firefly = Firefly(seed: 4, born: 0, life: 90, position: .zero, heading: 0, pace: 1, period: 4, phase: 0,
                              depth: 0)
        let samples = stride(from: 0.0, to: 90, by: 0.05).map { firefly.slowing(at: $0) }
        let slowSpells = zip(samples, samples.dropFirst()).filter { $0 >= 0.25 && $1 < 0.25 }.count
        #expect(slowSpells >= 4 && slowSpells <= 9)
        // Each spell, from leaving full speed to regaining it, lasts 1 … 2 s.
        var spell = 0.0
        for value in samples {
            if value < 1 { spell += 0.05 } else if spell > 0 { #expect(spell > 0.9 && spell < 2.05); spell = 0 }
        }
        #expect(samples.min()! >= 0.2 - 1e-9)
        #expect(zip(samples, samples.dropFirst()).allSatisfy { abs($1 - $0) < 0.25 })
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
        var swarm = Swarm(seed: 13, displays: [wide], count: 10,
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
        #expect(waits[0] < 2 && waits.dropFirst().allSatisfy { $0 >= waits[0] - 1e-9 })
        for firefly in deep.fireflies { #expect(bounds.contains(firefly!.point)) }
    }

    /// A firefly that has flown its life gives its slot to a new one after some dark.
    @Test func aSlotIsRefilled() {
        var swarm = Swarm(seed: 9, displays: [wide], count: 1,
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
        let small = CGRect(x: 0, y: 0, width: 200, height: 200)
        let field = small.insetBy(dx: -Swarm.margin, dy: -Swarm.margin)
        // Born at 30 s of calm: newly born, its life (45 s or more) is far from over.
        var swarm = Swarm(seed: 9, displays: [small], count: 1, period: 4, depth: 30, now: 0)
        var now = 0.0
        while let firefly = swarm.fireflies[0], field.contains(firefly.point), now < 30 {
            now += 0.05
            swarm.advance(to: now, depth: 30)
        }
        #expect(now < 30)
        #expect(swarm.fireflies[0] == nil)
    }

    /// Born heading into its display: nearly always still on it a period later (one born in a
    /// corner may turn along the edge and leave).
    @Test func bornHeadingIn() {
        let left = (UInt64(1)...200).filter { seed in
            var swarm = Swarm(seed: seed, displays: [bounds], count: 1, period: 4, depth: 30, now: 0)
            for step in 1...80 { swarm.advance(to: Double(step) / 20, depth: 30) }
            return swarm.fireflies[0].map { !bounds.contains($0.point) } ?? true
        }
        #expect(left.count <= 4)
    }

    /// It drifts nearer and further, within 0.3 … 4 m, without a jump.
    @Test func distanceSwingsSmoothly() {
        let swarm = Swarm(seed: 21, displays: [bounds], count: 1, period: 4, depth: 60, now: 0)
        let firefly = try! #require(swarm.fireflies[0])
        let samples = stride(from: 0.0, through: 60, by: 1.0 / 30).map { Firefly.distance(nearness: firefly.nearness(at: $0)) }
        #expect(samples.allSatisfy { Firefly.distances.contains($0) })
        #expect(samples.max()! / samples.min()! > 1.3)
        #expect(zip(samples, samples.dropFirst()).allSatisfy { abs(log($1 / $0)) < 0.02 })
    }

    @Test func sameSeedSameSwarm() {
        let a = Swarm(seed: 11, displays: [bounds], count: 4, period: 4, depth: 200, now: 10)
        let b = Swarm(seed: 11, displays: [bounds], count: 4, period: 4, depth: 200, now: 10)
        #expect(a.fireflies == b.fireflies)
    }

    /// The wind carries them a little (M7-PLAN 4): the breeze along its direction, a gust along its
    /// front where the front has reached; 2 mm/s at most, less for far ones.
    @Test func windCarriesThemALittle() {
        let firefly = Swarm(seed: 3, displays: [wide], count: 1, period: 4, depth: 60, now: 0).fireflies[0]!
        let perMillimetre = Swarm.pointsPerMillimetre
        func mm(_ v: SIMD2<Double>) -> SIMD2<Double> { v / perMillimetre }
        // Its share by its distance: its flight speed against the nearest's.
        let parallax = (5 + 11 * firefly.nearness(at: 0)) / 16
        #expect(abs(mm(firefly.drift(in: Wind(velocity: SIMD2(3.5, 0)), at: 0, reduceMotion: false)).x
            - Firefly.breezeDrift * parallax) < 1e-9)
        // The breeze along its own direction, scaled with its speed.
        let breeze = mm(firefly.drift(in: Wind(velocity: SIMD2(0, -1.75)), at: 0, reduceMotion: false))
        #expect(abs(breeze.x) < 1e-12 && abs(breeze.y + 0.2 * parallax) < 1e-9)
        // A full gust whose front is at the firefly now, along the front, with the strongest breeze
        // across it: 2 mm/s together at most.
        let local = (firefly.position / perMillimetre).x / Wind.frontSpeed
        let gust = Wind.Gust(onset: -2, rise: 2, duration: 8, strength: 1)
        let gusty = Wind(velocity: SIMD2(3.5, 0), time: local, frontDirection: SIMD2(1, 0), gusts: [gust])
        let carried = mm(firefly.drift(in: gusty, at: 0, reduceMotion: false))
        #expect(abs(carried.x - 2 * parallax) < 1e-9)
        // Before the front reaches it, the breeze only.
        let early = Wind(velocity: SIMD2(3.5, 0), time: local - 3, frontDirection: SIMD2(1, 0), gusts: [gust])
        #expect(abs(mm(firefly.drift(in: early, at: 0, reduceMotion: false)).x - 0.4 * parallax) < 1e-9)
        // Reduce Motion: half the breeze, no gust.
        #expect(abs(mm(firefly.drift(in: gusty, at: 0, reduceMotion: true)).x - 0.2 * parallax) < 1e-9)
        // No wind, no drift; a broken wind, none either.
        #expect(firefly.drift(in: Wind(), at: 0, reduceMotion: false) == .zero)
        #expect(firefly.drift(in: Wind(velocity: SIMD2(.nan, 0)), at: 0, reduceMotion: false) == .zero)
    }

    /// The swarm moves with the wind and flashes as before.
    @Test func theSwarmDriftsDownwind() {
        var still = Swarm(seed: 3, displays: [wide], count: 1, period: 4, depth: 60, now: 0), carried = still
        let wind = Wind(velocity: SIMD2(3.5, 0))
        for step in 1...200 {
            still.advance(to: Double(step) / 20, depth: 60)
            carried.advance(to: Double(step) / 20, depth: 60, wind: wind)
        }
        let shift = (carried.fireflies[0]!.position - still.fireflies[0]!.position) / Swarm.pointsPerMillimetre
        // 10 s at 0.4 mm/s times its parallax.
        #expect(shift.x > 10 * 0.4 * 5 / 16 - 1e-6 && shift.x < 10 * 0.4 + 1e-6)
        #expect(abs(shift.y) < 1e-9)
        #expect(still.fireflies[0]!.phase == carried.fireflies[0]!.phase)
    }

    /// A late frame reads each gust at its own moment: one update of a second carries a firefly as
    /// twenty of a twentieth do.
    @Test func aLateFrameReadsGustsInTime() {
        var smooth = Swarm(seed: 3, displays: [wide], count: 1, period: 4, depth: 60, now: 0), late = smooth
        // The front reaches it half a second in, wherever it is.
        let reach = (smooth.fireflies[0]!.position / Swarm.pointsPerMillimetre).x / Wind.frontSpeed
        let gust = Wind.Gust(onset: 0.5 - reach, rise: 0.5, duration: 1, strength: 1)
        func wind(_ t: Double) -> Wind { Wind(velocity: .zero, time: t, frontDirection: SIMD2(1, 0), gusts: [gust]) }
        for step in 1...20 { smooth.advance(to: Double(step) / 20, depth: 60, wind: wind(Double(step) / 20)) }
        late.advance(to: 1, depth: 60, wind: wind(1))
        let gap = simd_length(smooth.fireflies[0]!.position - late.fireflies[0]!.position)
        #expect(gap < 1e-6)
    }
}
