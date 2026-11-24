import Foundation
import simd

/// One firefly (M7-PLAN 3): it flies on whether lit or dark, so the next light comes on further
/// along its path. Its flight follows from its seed and the time it was born, in desktop points;
/// its flashes from a phase the swarm advances, so the flock can fall into step (M7-PLAN 9, 1).
struct Firefly: Equatable {
    var seed: UInt64
    var born: Double
    /// Seconds it flies; it starts no flash after that.
    var life: Double
    /// Where it was born, desktop points.
    var origin: SIMD2<Double>
    /// Its own flash period, seconds.
    var period: Double
    /// 0 … 1 through its flash cycle; a flash starts each time it passes 1.
    var phase: Double
    /// The flashes it has started, when the last began, and whether it is lit (not before its
    /// first flash, nor if it began after its life).
    var flashes = 0
    var onset = -Double.infinity
    var lit = false
    /// Where its distance swings around, in `distance(at:)`'s units (−∞ far … +∞ near).
    var depth: Double
    /// Mean flight speed, desktop points per second.
    var speed: Double
    /// Unit vector of its slow drift.
    var heading: SIMD2<Double>

    /// How far behind the glass fireflies fly, metres (M7-PLAN 3, 【仮】).
    static let distances = 0.3...4.0

    /// Metres behind the glass at `time`: it drifts nearer and further over 15 … 40 seconds, and
    /// eases into the ends of `distances` instead of stopping at them.
    func distance(at time: Double) -> Double {
        let t = max(time - born, 0)
        var swing = 0.0
        for wave in 0..<2 {
            let omega = 2 * Double.pi / (15 + 25 * Hash.unit(seed, 30 + wave))
            let phase = 2 * Double.pi * Hash.unit(seed, 40 + wave)
            swing += (wave == 0 ? 0.6 : 0.3) * (sin(omega * t + phase) - sin(phase))
        }
        let near = log(Self.distances.lowerBound), far = log(Self.distances.upperBound)
        return exp((near + far) / 2 + (near - far) / 2 * tanh(depth + swing))
    }

    /// 0 at the far end of `distances` … 1 at the near end, evenly in the logarithm.
    static func nearness(distance: Double) -> Double {
        log(distances.upperBound / distance) / log(distances.upperBound / distances.lowerBound)
    }

    /// Seconds a flash takes to come up, stays, and dies away: about 2.2 s lit (the author found
    /// 0.3 + 0.8 s too short at W1).
    static let rise = 0.4
    static let hold = 0.6
    static let fall = 1.2

    /// Where it is at `time`: a slow drift plus a smooth wander (two waves per axis whose
    /// frequencies do not divide, so the path does not repeat within a life). `motion` scales the
    /// distance flown (Reduce Motion halves it, SPEC 2.2).
    func position(at time: Double, motion: Double = 1) -> SIMD2<Double> {
        let t = max(time - born, 0)
        var wander = SIMD2<Double>.zero
        for wave in 0..<4 {
            // Turns every 2 … 6 seconds (M7-PLAN 3).
            let omega = 2 * Double.pi / (4 + 8 * Hash.unit(seed, 10 + wave))
            let phase = 2 * Double.pi * Hash.unit(seed, 20 + wave)
            // Each wave alone moves at a third of the mean speed: with the drift, the fastest
            // moments stay under about 1.5 times the mean.
            let amplitude = 0.33 * speed / omega
            let value = amplitude * (sin(omega * t + phase) - sin(phase))
            if wave < 2 { wander.x += value } else { wander.y += value }
        }
        return origin + motion * (heading * speed * 0.55 * t + wander)
    }

    func point(at time: Double, motion: Double = 1) -> CGPoint {
        let p = position(at: time, motion: motion)
        return CGPoint(x: p.x, y: p.y)
    }

    /// 0 … 1: how lit it is at `time`, by the seconds since its last flash began.
    func brightness(at time: Double) -> Double {
        guard lit else { return 0 }
        let local = time - onset
        // A flash a little stronger or weaker than the last.
        let level = 0.8 + 0.2 * Hash.unit(seed, 1000 + flashes)
        guard local >= 0 else { return 0 }
        if local < Self.rise { return level * Self.smooth(local / Self.rise) }
        return level * (1 - Self.smooth((local - Self.rise - Self.hold) / Self.fall))
    }

    /// Moves its phase on by `step` seconds, ending at `now`, at `rate` cycles a second. A flash
    /// starts the moment it passes 1, if that moment is within its life.
    mutating func flash(step: Double, rate: Double, now: Double) {
        phase += step * rate
        guard phase >= 1 else { return }
        phase -= 1
        flashes += 1
        onset = now - phase / rate
        lit = onset < born + life
    }

    /// Seconds a flash is lit.
    static var lit: Double { rise + hold + fall }

    /// Its life is over and its last flash has died away.
    func isDone(at now: Double) -> Bool { now >= born + life && now - onset >= Self.lit }

    static func smooth(_ x: Double) -> Double {
        let c = min(max(x, 0), 1)
        return c * c * (3 - 2 * c)
    }
}

/// The fireflies of one showing: slots that fill one by one as the calm deepens; a firefly that
/// has flown its life gives its slot to a new one born elsewhere a few seconds later. As the calm
/// deepens their flashes are drawn into step, as a flock of Genji fireflies falls into step
/// (Kuramoto coupling, M7-PLAN 3): the depth shows as order, not only as more lights.
struct Swarm {
    /// Desktop points per millimetre of flight, for every display (komorebi's desktop pitch).
    static let pointsPerMillimetre = 109 / 25.4
    /// The depth at which slot `k` first fills: the first light by about 35 s, one more every
    /// 20 s (the twelfth at 250 s).
    static func threshold(_ slot: Int) -> Double { 30 + 20 * Double(slot) }
    /// How strongly the flashes pull together, radians a second, at full depth: well above the
    /// spread of their own rates (±5 % of 2π / 4 s ≈ 0.08), so they fall into step in tens of
    /// seconds and stay a little apart.
    static let coupling = 0.6
    /// 0 … 1: the coupling's share at `depth`, from none at 60 s to all at 300 s.
    static func pull(depth: Double) -> Double { Firefly.smooth((depth - 60) / 240) }

    let seed: UInt64
    /// The displays the fireflies are born over, and the rectangle around them, points.
    let displays: [CGRect]
    let bounds: CGRect
    let period: Double
    private(set) var fireflies: [Firefly?]
    private var nextBirth: [Double]
    private var births: [Int]
    /// The time the swarm was last advanced to: leaving, it is not advanced, and the lights are
    /// drawn as they were then.
    private(set) var time: Double

    /// The slots that should be filled at `depth` and `now`, as if the calm had deepened to it
    /// (a showing that starts deep, "see it now", finds fireflies already flying).
    init(seed: UInt64, displays: [CGRect], count: Int, period: Double, depth: Double, now: Double, motion: Double = 1) {
        self.seed = seed
        self.displays = displays.sorted { ($0.minX, $0.minY) < ($1.minX, $1.minY) }
        bounds = displays.reduce(CGRect.null) { $0.union($1) }
        self.period = period
        fireflies = Array(repeating: nil, count: count)
        nextBirth = Array(repeating: .infinity, count: count)
        births = Array(repeating: 0, count: count)
        time = now
        // The first slot's next flash soon, so a deep start shows a light in a second or two; the
        // others as far into step as the depth would have drawn them.
        let first = 1 - (0.6 + 1.2 * Hash.unit(seed, 600)) / period
        let scatter = 1 - Self.pull(depth: depth)
        for slot in 0..<count where depth >= Self.threshold(slot) {
            let age = min(depth - Self.threshold(slot), 40 * Hash.unit(seed, 500 + slot))
            // The others between the first and a period behind it: none lights before the first.
            let phase = first * (1 - (slot == 0 ? 0 : scatter * Hash.unit(seed, 600 + slot)))
            var firefly = make(slot: slot, born: now - age, phase: phase)
            // Where it is now is the random point drawn, not where it was born: a deep start does
            // not begin with fireflies already off the desktop.
            firefly.origin -= firefly.position(at: now, motion: motion) - firefly.origin
            fireflies[slot] = firefly
        }
    }

    /// How far past the desktop's edge a firefly is let go: its glow is gone well before.
    static let margin = 60.0

    /// Fills the slots `depth` has reached, and replaces fireflies that have flown their life or
    /// left the desktop (they fly on and away, not back: M7-PLAN 3). `motion` as for
    /// `Firefly.position`.
    mutating func advance(to now: Double, depth: Double, motion: Double = 1) {
        stepFlashes(to: now, depth: depth)
        let field = bounds.insetBy(dx: -Self.margin, dy: -Self.margin)
        for slot in fireflies.indices {
            if let firefly = fireflies[slot], firefly.isDone(at: now) || !field.contains(firefly.point(at: now, motion: motion)) {
                fireflies[slot] = nil
                // Some seconds of dark before the next one.
                nextBirth[slot] = now + 2 + 6 * Hash.unit(seed &+ UInt64(births[slot]), 700 + slot)
            }
            guard fireflies[slot] == nil, depth >= Self.threshold(slot) else { continue }
            if nextBirth[slot] == .infinity { nextBirth[slot] = now }
            guard now >= nextBirth[slot] else { continue }
            // A newcomer flashes first in 0.5 … 2 s, out of step; the flock draws it in.
            let wait = 0.5 + 1.5 * Hash.unit(seed &+ UInt64(births[slot]), 800 + slot)
            fireflies[slot] = make(slot: slot, born: now, phase: max(1 - wait / period, 0))
        }
    }

    /// The flock's order, 0 (scattered) … 1 (in step): the length of the mean of their phases.
    var order: Double { simd_length(meanPhase) }

    /// The mean of the flying fireflies' phases as unit vectors (zero with none flying).
    private var meanPhase: SIMD2<Double> {
        let flying = fireflies.compactMap { $0 }
        guard !flying.isEmpty else { return .zero }
        let sum = flying.reduce(SIMD2<Double>.zero) { $0 + SIMD2(cos(2 * .pi * $1.phase), sin(2 * .pi * $1.phase)) }
        return sum / Double(flying.count)
    }

    /// Advances every phase to `now` in steps of at most 1/20 s: each at its own rate, pulled
    /// towards the flock's mean phase as hard as the depth allows.
    private mutating func stepFlashes(to now: Double, depth: Double) {
        let pull = Self.coupling * Self.pull(depth: depth)
        var remaining = max(now - time, 0)
        while remaining > 0 {
            let step = min(remaining, 0.05)
            remaining -= step
            let at = now - remaining
            let mean = meanPhase
            for slot in fireflies.indices {
                guard var firefly = fireflies[slot] else { continue }
                // dθ/dt = ω + K · R · sin(ψ − θ), in cycles a second.
                let angle = 2 * Double.pi * firefly.phase
                let towards = mean.y * cos(angle) - mean.x * sin(angle)  // R · sin(ψ − θ)
                firefly.flash(step: step, rate: 1 / firefly.period + pull * towards / (2 * .pi), now: at)
                fireflies[slot] = firefly
            }
        }
        time = now
    }

    private mutating func make(slot: Int, born: Double, phase: Double) -> Firefly {
        births[slot] += 1
        let key = seed &+ UInt64(slot) &* 0x9E37_79B9 &+ UInt64(births[slot]) &* 0x85EB_CA6B
        // Evenly over the logarithm of the distance, a little less often at the very ends.
        let depth = 2.4 * (Hash.unit(key, 1) - 0.5)
        let nearness = (tanh(depth) + 1) / 2
        // Apparent speed on the screen: 5 … 9 mm/s far, 10 … 16 mm/s near (M7-PLAN 3).
        let millimetres = (5 + 5 * nearness) + (4 + 3 * nearness) * Hash.unit(key, 2)
        let display = displays[min(Int(Hash.unit(key, 8) * Double(displays.count)), displays.count - 1)]
        let origin = SIMD2(display.minX + display.width * Hash.unit(key, 5), display.minY + display.height * Hash.unit(key, 6))
        // Towards the middle of its display, give or take 70°: one born near an edge crosses the
        // screen instead of leaving it at once.
        let inward = SIMD2(display.midX, display.midY) - origin
        let angle = atan2(inward.y, inward.x) + (Hash.unit(key, 3) - 0.5) * 140 * Double.pi / 180
        return Firefly(seed: key, born: born, life: 45 + 45 * Hash.unit(key, 4),
                       origin: origin,
                       period: period * (0.95 + 0.1 * Hash.unit(key, 7)), phase: phase,
                       depth: depth, speed: millimetres * Self.pointsPerMillimetre,
                       heading: SIMD2(cos(angle), sin(angle)))
    }
}

/// Stateless random numbers from a seed and a key (SplitMix64).
enum Hash {
    static func unit(_ seed: UInt64, _ key: Int) -> Double {
        var z = seed &+ UInt64(bitPattern: Int64(key)) &* 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z >> 11) / Double(1 << 53)
    }
}
