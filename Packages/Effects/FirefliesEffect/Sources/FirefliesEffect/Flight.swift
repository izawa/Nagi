import Foundation
import NagiKit
import simd

/// One firefly (M7-PLAN 3): it flies on whether lit or dark, so the next light comes on further
/// along its path. Its course, distance and pace follow from its seed and the time it was born;
/// the swarm moves it and advances its flash phase, so the flock can fall into step (M7-PLAN 9, 1).
struct Firefly: Equatable {
    var seed: UInt64
    var born: Double
    /// Seconds it flies; it starts no flash after that.
    var life: Double
    /// Where it is now, desktop points.
    var position: SIMD2<Double>
    /// The direction it set off in, radians (x right, y down); it wanders around it.
    var heading: Double
    /// Its own pace, times the speed its distance gives (0.85 … 1.15).
    var pace: Double
    /// Its own flash period, seconds.
    var period: Double
    /// 0 … 1 through its flash cycle; a flash starts each time it passes 1.
    var phase: Double
    /// The flashes it has started, when the last began, and whether it is lit (not before its
    /// first flash, nor if it began after its life).
    var flashes = 0
    var onset = -Double.infinity
    var lit = false
    /// How the wind carried it over its last step, desktop points a second (the inner orb trails
    /// the path it really flies).
    var carried = SIMD2<Double>.zero
    /// Where its distance swings around, in `distance(at:)`'s units (−∞ far … +∞ near).
    var depth: Double

    /// How far behind the glass fireflies fly, metres (M7-PLAN 3, 【仮】).
    static let distances = 0.3...4.0
    /// Apparent speed on the screen at the far and the near end of `distances`, mm/s (M7-PLAN 3).
    static let speeds = 5.0...16.0

    /// Seconds a flash takes to come up, stays, and dies away: about 2.2 s lit (the author found
    /// 0.3 + 0.8 s too short at W1).
    static let rise = 0.4
    static let hold = 0.6
    static let fall = 1.2
    /// Seconds a flash is lit.
    static var lit: Double { rise + hold + fall }

    /// 0 at the far end of `distances` … 1 at the near end (evenly in the logarithm of the
    /// distance) at `time`: it drifts nearer and further over 15 … 40 seconds, and eases into the
    /// ends instead of stopping at them.
    func nearness(at time: Double) -> Double {
        let t = max(time - born, 0)
        var swing = 0.0
        for wave in 0..<2 {
            let omega = 2 * Double.pi / (15 + 25 * Hash.unit(seed, 30 + wave))
            let phase = 2 * Double.pi * Hash.unit(seed, 40 + wave)
            swing += (wave == 0 ? 0.6 : 0.3) * (sin(omega * t + phase) - sin(phase))
        }
        return (1 + tanh(depth + swing)) / 2
    }

    /// Metres behind the glass for a nearness.
    static func distance(nearness: Double) -> Double {
        distances.upperBound * pow(distances.lowerBound / distances.upperBound, nearness)
    }

    /// Its velocity at `time`, desktop points a second. The direction wanders around its heading,
    /// turning every 2 … 6 seconds; the speed is the apparent speed of its distance now (nearer
    /// looks faster), times its pace and its pauses.
    func velocity(at time: Double) -> SIMD2<Double> {
        let t = max(time - born, 0)
        var angle = heading
        for wave in 0..<3 {
            let omega = 2 * Double.pi / (4 + 8 * Hash.unit(seed, 10 + wave))
            angle += 0.5 * sin(omega * t + 2 * Double.pi * Hash.unit(seed, 20 + wave))
        }
        let near = nearness(at: time)
        let millimetres = (Self.speeds.lowerBound + (Self.speeds.upperBound - Self.speeds.lowerBound) * near)
            * pace * slowing(at: time)
        return SIMD2(cos(angle), sin(angle)) * millimetres * Swarm.pointsPerMillimetre
    }

    /// 1 … 0.2: now and then (in seven of ten 10-second spans) it slows down for 1 … 2 seconds
    /// in all, easing down and back up over half a second each (M7-PLAN 3). A spell starts within
    /// the first 8 seconds of its span, so it ends within it.
    func slowing(at time: Double) -> Double {
        let t = max(time - born, 0)
        let span = (t / 10).rounded(.down)
        let key = 2000 + 3 * Int(span)
        guard Hash.unit(seed, key) < 0.7 else { return 1 }
        let start = span * 10 + 8 * Hash.unit(seed, key + 1)
        let end = start + 1 + Hash.unit(seed, key + 2)
        return 1 - 0.8 * Self.smooth((t - start) / 0.5) * (1 - Self.smooth((t - end + 0.5) / 0.5))
    }

    /// Apparent drift on the screen at full wind, mm/s, for the nearest firefly: the mean wind at
    /// its strongest and a gust at full strength, 6 mm/s together. Three times M7-PLAN 4's 2 mm/s:
    /// the author found that too little to see.
    static let breezeDrift = 1.2
    static let gustDrift = 4.8
    /// The strongest mean wind the core makes, m/s (WindModel.maximumSpeed in NagiCore).
    static let strongestWind = 3.5

    /// How the shared wind carries it at `time`, desktop points a second: the mean wind along its
    /// direction, and a gust where its front has reached along the front's travel. Nearer ones
    /// drift more, in the ratio their flight speeds have. Reduce Motion halves the breeze and
    /// stops the gusts (M7-PLAN 7).
    /// `scale` multiplies both (the gallery's "wind" parameter).
    func drift(in wind: Wind, at time: Double, reduceMotion: Bool, scale: Double = 1) -> SIMD2<Double> {
        let breeze = wind.velocity * (Self.breezeDrift / Self.strongestWind) * (reduceMotion ? 0.5 : 1)
        let gust = reduceMotion ? .zero
            : wind.frontDirection * Self.gustDrift * wind.gust(at: position / Swarm.pointsPerMillimetre)
        let parallax = (Self.speeds.lowerBound + (Self.speeds.upperBound - Self.speeds.lowerBound) * nearness(at: time))
            / Self.speeds.upperBound
        let drift = (breeze + gust) * parallax * scale * Swarm.pointsPerMillimetre
        return drift.x.isFinite && drift.y.isFinite ? drift : .zero
    }

    var point: CGPoint { CGPoint(x: position.x, y: position.y) }

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

    /// Moves it by `step` seconds ending at `now`: along its course (times `motion`) and with the
    /// wind's `drift`, and its phase at `rate` cycles a second. A flash starts the moment the phase
    /// passes 1, if that moment is within its life.
    mutating func advance(step: Double, now: Double, rate: Double, motion: Double, drift: SIMD2<Double> = .zero) {
        carried = drift
        position += (velocity(at: now - step / 2) * motion + drift) * step
        phase += step * rate
        guard phase >= 1 else { return }
        phase -= 1
        flashes += 1
        onset = now - phase / rate
        lit = onset < born + life
    }

    /// Its life is over and its last flash has died away.
    func isDone(at now: Double) -> Bool { now >= born + life && now - onset >= Self.lit }

    static func smooth(_ x: Double) -> Double {
        let c = min(max(x, 0), 1)
        return c * c * (3 - 2 * c)
    }
}

/// The fireflies of one showing: slots that fill one by one as the calm deepens; a firefly that
/// has flown its life or left the desktop gives its slot to a new one born elsewhere a few seconds
/// later. As the calm deepens their flashes are drawn into step, as a flock of Genji fireflies
/// falls into step (Kuramoto coupling, M7-PLAN 3): the depth shows as order, not only as more lights.
struct Swarm {
    /// Desktop points per millimetre of flight, for every display (komorebi's desktop pitch).
    static let pointsPerMillimetre = 109 / 25.4
    /// The depth at which slot `k` first fills: the first light by about 35 s, then one more every
    /// 20 s on a 27-inch display (the twelfth at 250 s), more slowly on a smaller desktop (`screen`,
    /// its share of a 27-inch), so it is no more crowded at any depth (M7-PLAN 6).
    static func threshold(_ slot: Int, screen: Double = 1) -> Double {
        30 + 20 * Double(slot) / min(max(screen.isFinite ? screen : 1, 0.01), 1)
    }
    /// How strongly the flashes pull together, radians a second, at full depth: well above the
    /// spread of their own rates (±5 % of 2π / 4 s ≈ 0.08), so they fall into step in tens of
    /// seconds and stay a little apart.
    static let coupling = 0.6
    /// 0 … 1: the coupling's share at `depth`, from none at 60 s to all at 300 s.
    static func pull(depth: Double) -> Double { Firefly.smooth((depth - 60) / 240) }
    /// How far past the desktop's edge a firefly is let go: its glow is gone well before.
    static let margin = 60.0
    /// The screen the set number is for: a 27-inch display (597 × 336 mm, M7-PLAN 6), and the same
    /// in points at `pointsPerMillimetre` (a 5K 27-inch's 2560 × 1440) for a display of unknown size.
    static let referenceMillimetres = 597.0 * 336
    static let referenceArea = 2560.0 * 1440

    /// A display's key: its rectangle.
    static func key(_ display: CGRect) -> [Double] { [display.minX, display.minY, display.width, display.height] }

    /// The displays to fly over: each once (a mirrored display reports the same rectangle), none
    /// empty, in one order.
    static func screens(_ displays: [CGRect]) -> [CGRect] {
        var seen = Set<[Double]>()
        return displays
            .filter { $0.width > 0 && $0.height > 0 && $0.width.isFinite && $0.height.isFinite }
            .filter { seen.insert(key($0)).inserted }
            .sorted { ($0.minX, $0.minY) < ($1.minX, $1.minY) }
    }

    /// The area the displays cover, points².
    static func area(_ displays: [CGRect]) -> Double {
        screens(displays).reduce(0) { $0 + $1.width * $1.height }
    }

    /// Each of `screens(displays)`'s area against a 27-inch display: by its physical size where it
    /// is known (a preview says how large a screen it shows), else by its points.
    static func shares(_ displays: [CGRect], millimetres: [[Double]: Double]) -> [Double] {
        screens(displays).map { millimetres[key($0)].map { $0 / referenceMillimetres } ?? $0.width * $0.height / referenceArea }
    }

    /// The whole desktop's area against a 27-inch display.
    static func share(_ displays: [CGRect], millimetres: [[Double]: Double]) -> Double {
        shares(displays, millimetres: millimetres).reduce(0, +)
    }

    let seed: UInt64
    /// The displays the fireflies are born over, and the rectangle around them, points.
    let displays: [CGRect]
    /// Each display's share of the births: its area against a 27-inch display (`shares`). The sizes
    /// may become known after the swarm is made (`reweigh`).
    private(set) var weights: [Double]
    /// The desktop's share of a 27-inch display, which paces the slots.
    var screen: Double { weights.reduce(0, +) }
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
    init(seed: UInt64, displays: [CGRect], millimetres: [[Double]: Double] = [:], count: Int, period: Double,
         depth: Double, now: Double) {
        self.seed = seed
        self.displays = Self.screens(displays)
        weights = Self.shares(displays, millimetres: millimetres)
        bounds = self.displays.reduce(CGRect.null) { $0.union($1) }
        self.period = period
        fireflies = Array(repeating: nil, count: count)
        nextBirth = Array(repeating: .infinity, count: count)
        births = Array(repeating: 0, count: count)
        time = now
        // The first slot's first flash soon, so a deep start shows a light in a second or two; the
        // others no sooner, and spread over a period as little as the depth would have drawn them
        // together.
        let first = 0.6 + 1.2 * Hash.unit(seed, 600)
        let scatter = 1 - Self.pull(depth: depth)
        for slot in 0..<count where depth >= Self.threshold(slot, screen: screen) {
            let age = min(depth - Self.threshold(slot, screen: screen), 40 * Hash.unit(seed, 500 + slot))
            var firefly = make(slot: slot, born: now - age, phase: 0)
            let wait = first + (slot == 0 ? 0 : scatter * (firefly.period - first) * Hash.unit(seed, 600 + slot))
            firefly.phase = max(1 - wait / firefly.period, 0)
            fireflies[slot] = firefly
        }
    }

    /// Moves the fireflies on to `now`, fills the slots `depth` has reached, and replaces those
    /// that have flown their life or left the desktop (they fly on and away, not back: M7-PLAN 3).
    /// `motion` scales the distance flown (Reduce Motion halves it, SPEC 2.2); `wind` carries them.
    mutating func advance(to now: Double, depth: Double, motion: Double = 1, wind: Wind? = nil, drift: Double = 1) {
        step(to: now, depth: depth, motion: motion, wind: wind, drift: drift)
        let field = bounds.insetBy(dx: -Self.margin, dy: -Self.margin)
        for slot in fireflies.indices {
            if let firefly = fireflies[slot], firefly.isDone(at: now) || !field.contains(firefly.point) {
                fireflies[slot] = nil
                // Some seconds of dark before the next one.
                nextBirth[slot] = now + 2 + 6 * Hash.unit(seed &+ UInt64(births[slot]), 700 + slot)
            }
            guard fireflies[slot] == nil, depth >= Self.threshold(slot, screen: screen) else { continue }
            if nextBirth[slot] == .infinity { nextBirth[slot] = now }
            guard now >= nextBirth[slot] else { continue }
            // A newcomer flashes first in 0.5 … 2 s, out of step; the flock draws it in.
            let wait = 0.5 + 1.5 * Hash.unit(seed &+ UInt64(births[slot]), 800 + slot)
            fireflies[slot] = make(slot: slot, born: now, phase: max(1 - wait / period, 0))
        }
    }

    /// New shares for the same displays (their physical sizes now known): births and slots follow
    /// them; those flying stay where they are.
    mutating func reweigh(millimetres: [[Double]: Double]) {
        let shares = Self.shares(displays, millimetres: millimetres)
        if shares.count == weights.count { weights = shares }
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

    /// Moves every firefly to `now` in steps of at most 1/20 s: along its course, and its phase at
    /// its own rate, pulled towards the flock's mean phase as hard as the depth allows. `wind` is
    /// the one at `now`; each step reads its gusts at the step's own moment on the wind clock.
    private mutating func step(to now: Double, depth: Double, motion: Double, wind: Wind?, drift scale: Double) {
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
                let drift = wind.map { now in
                    var then = now
                    then.time -= remaining + step / 2
                    return firefly.drift(in: then, at: at - step / 2, reduceMotion: motion < 1, scale: scale)
                } ?? .zero
                firefly.advance(step: step, now: at, rate: 1 / firefly.period + pull * towards / (2 * .pi), motion: motion,
                                drift: drift)
                fireflies[slot] = firefly
            }
        }
        time = now
    }

    private mutating func make(slot: Int, born: Double, phase: Double) -> Firefly {
        births[slot] += 1
        let key = seed &+ UInt64(slot) &* 0x9E37_79B9 &+ UInt64(births[slot]) &* 0x85EB_CA6B
        // A display by its share of the area, so they are as many to the square millimetre on each.
        var pick = Hash.unit(key, 8) * weights.reduce(0, +)
        let index = weights.indices.first { pick -= weights[$0]; return pick < 0 } ?? displays.count - 1
        let display = displays[index]
        let position = SIMD2(display.minX + display.width * Hash.unit(key, 5),
                             display.minY + display.height * Hash.unit(key, 6))
        // Towards the middle of its display, give or take 70°: one born near an edge crosses the
        // screen instead of leaving it at once.
        let inward = SIMD2(display.midX, display.midY) - position
        let heading = atan2(inward.y, inward.x) + (Hash.unit(key, 3) - 0.5) * 140 * Double.pi / 180
        return Firefly(seed: key, born: born, life: 45 + 45 * Hash.unit(key, 4), position: position,
                       heading: heading, pace: 0.85 + 0.3 * Hash.unit(key, 2),
                       period: period * (0.95 + 0.1 * Hash.unit(key, 7)), phase: phase,
                       // Evenly over the logarithm of the distance, a little less often at the ends.
                       depth: 2.4 * (Hash.unit(key, 1) - 0.5))
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
