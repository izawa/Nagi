import Foundation

/// One drop on a display's pool: where (millimetres from the display's top-left), when it fell
/// (seconds on the frame clock) and how hard (a multiple of the dent).
struct Drop: Equatable {
    var x: Double
    var y: Double
    var time: Double
    var strength: Double
}

/// A source of waves seen by the pool: a drop or one of its mirror images across the walls.
struct WaveSource: Equatable {
    var x: Double
    var y: Double
    /// The wall's reflectance to the power of the reflections it took.
    var gain: Double
    /// Which drop it comes from.
    var drop: Int
}

/// Each display is its own rectangular pool (M6-PLAN 2). A wall reflects a wave like the side of
/// a real pool: mirror images of each drop across the walls, with the same sign, make the slope
/// across every wall zero.
struct Pool {
    /// Size in millimetres.
    var width: Double
    var height: Double

    /// The drop and its mirror images whose waves can reach the pool within `reach` mm.
    func sources(of drop: Drop, index: Int, reach: Double, reflectance: Double) -> [WaveSource] {
        let xs = Self.mirrors(drop.x, length: width, reach: reach)
        let ys = Self.mirrors(drop.y, length: height, reach: reach)
        var result: [WaveSource] = []
        for (x, bouncesX) in xs {
            for (y, bouncesY) in ys {
                // Skip images farther than `reach` from every point of the pool.
                let dx = max(0, -x, x - width), dy = max(0, -y, y - height)
                guard dx * dx + dy * dy < reach * reach else { continue }
                let bounces = bouncesX + bouncesY
                let gain = bounces == 0 ? 1 : pow(reflectance, Double(bounces))
                guard gain > 1e-3 else { continue }
                result.append(WaveSource(x: x, y: y, gain: gain, drop: index))
            }
        }
        return result
    }

    /// Positions of a point and its mirror images along one axis of a segment [0, length], with
    /// the number of reflections each took, within `reach` of the segment.
    static func mirrors(_ p: Double, length: Double, reach: Double) -> [(Double, Int)] {
        let period = 2 * length
        let lowest = Int(((-reach - p) / period).rounded(.down)) - 1
        let highest = Int(((length + reach + p) / period).rounded(.up)) + 1
        var result: [(Double, Int)] = []
        for m in lowest...highest {
            // p + 2mL took 2|m| reflections; −p + 2mL took |2m − 1|.
            for (position, bounces) in [(p + Double(m) * period, 2 * abs(m)), (-p + Double(m) * period, abs(2 * m - 1))]
            where position > -reach && position < length + reach {
                result.append((position, bounces))
            }
        }
        return result
    }
}

/// When and where drops fall on one display (M6-PLAN 4): none until 20 s of depth, then more as
/// nagi deepens. Seeded, so the same seed, showing and display give the same drops.
struct DropSchedule {
    /// Drops a minute on a 27-inch display (597 × 336 mm) at each depth node (M6-PLAN 4).
    static let nodes: [(depth: Double, perMinute: Double)] = [(20, 0), (35, 4), (60, 10), (90, 20), (120, 30)]
    static let referenceArea = 597.0 * 336.0
    /// Alive at once on one display, and the least time between two drops.
    static let capacity = 6
    static let spacing = 0.5

    static func perMinute(depth: Double) -> Double {
        guard depth.isFinite, depth > nodes[0].depth else { return 0 }
        for (a, b) in zip(nodes, nodes.dropFirst()) where depth < b.depth {
            let t = (depth - a.depth) / (b.depth - a.depth)
            return a.perMinute + (b.perMinute - a.perMinute) * t * t * (3 - 2 * t)
        }
        return nodes[nodes.count - 1].perMinute
    }

    private var random: SplitMix
    private var credit = 0.0
    private var threshold: Double
    private(set) var drops: [Drop] = []

    init(seed: UInt64) {
        random = SplitMix(state: seed)
        threshold = 0
        threshold = nextThreshold()
    }

    private mutating func nextThreshold() -> Double { -log(max(random.unit(), 1e-12)) }

    /// Advances to `time`, `dt` seconds after the previous step, and lets drops fall at the rate
    /// for `depth`. `rate` scales it (the area of the display, the user's amount, Reduce Motion).
    /// Each drop falls at the moment its turn came within the step, so the same drops fall at the
    /// same times whatever the frame rate. Drops older than `lifetime` are forgotten.
    mutating func step(time: Double, dt: Double, depth: Double, rate: Double, pool: Pool,
                       lifetime: Double, strength: ClosedRange<Double>) {
        // Keep the drops still alive at the start of the step: one that dies within it still
        // counts against an arrival before its end, whatever the frame rate.
        drops.removeAll { time - max(dt, 0) - $0.time >= lifetime }
        defer { drops.removeAll { time - $0.time >= lifetime } }
        let perSecond = Self.perMinute(depth: depth) / 60 * rate
        guard perSecond > 0, dt > 0 else { return }
        credit += perSecond * dt
        while credit >= threshold {
            credit -= threshold
            threshold = nextThreshold()
            let arrival = time - credit / perSecond
            let x = random.unit() * pool.width, y = random.unit() * pool.height
            let s = strength.lowerBound + random.unit() * (strength.upperBound - strength.lowerBound)
            // Too soon after another drop, or too many alive: this one does not fall.
            let alive = drops.filter { arrival - $0.time < lifetime }
            if alive.count < Self.capacity, alive.allSatisfy({ abs(arrival - $0.time) >= Self.spacing }) {
                drops.append(Drop(x: x, y: y, time: arrival, strength: s))
            }
        }
    }

    /// A drop placed by hand (the first drop of a deep showing, or a test drop).
    mutating func place(_ drop: Drop) {
        if drops.count < Self.capacity { drops.append(drop) }
    }
}

/// A small seeded generator (SplitMix64).
struct SplitMix {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9e3779b97f4a7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9
        z = (z ^ (z >> 27)) &* 0x94d049bb133111eb
        return z ^ (z >> 31)
    }
    /// 0 ..< 1.
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}
