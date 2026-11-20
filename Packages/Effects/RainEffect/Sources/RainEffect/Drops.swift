import CoreGraphics
import Foundation
import simd

/// One raindrop on the glass, in desktop points (top-left origin). A drop is up to `maxLobes`
/// round lobes drawn as one smooth surface: two drops that run together keep a trace of where
/// each was (water draws together but does not snap into a ball, as mercury would).
struct Drop: Equatable {
    struct Lobe: Equatable {
        /// From the drop's centre.
        var offset: SIMD2<Double>
        var radius: Double
    }

    static let maxLobes = 4

    var center: SIMD2<Double>
    var lobes: [Lobe]
    /// Picks the outline's small irregularity (0…1).
    var shape: Double
    /// The water in the drop, as the area of the drops it came from (kept when drops merge; the
    /// lobes are drawn a little wider).
    var area: Double
    /// Sliding: points per second down the glass (0: held by the glass).
    var speed = 0.0
    /// Points slid since the drop last left a bead behind, and how far to slide before the next
    /// (drawn at random, so the beads do not line up evenly).
    var sinceBead = 0.0
    var nextBead = 0.0
    /// Held by the glass until this simulation time, however heavy: a heavy drop waits a while
    /// before it gives way, so the glass sees a runner now and then, not many at once. Negative:
    /// not yet heavy enough to have a time.
    var heldUntil = -1.0
    /// Where this runner's wet trail ends so far: the next piece starts there, so the trail stays
    /// one line even where the runner jumps aside to take in a drop.
    var trailEnd: SIMD2<Double>?
    /// Points a runner went down the glass over the steps of the latest frame, up to simulation
    /// time `movedAt`: its run plus the jumps towards what it took in, over every time it was moved
    /// (it can be moved more than once a step: see RainSimulation.travel). The motion blur spans
    /// this, not its speed.
    var moved = 0.0
    var movedAt = -1.0

    /// A drop that lands as a few lobes of different sizes, not a perfect circle: water hits the
    /// glass unevenly. `random` picks how many (1–3), where, and how large; the water is `radius`'s.
    static func landing(at center: SIMD2<Double>, radius: Double, random: inout SplitMix) -> Drop {
        let count = 1 + Int(random.unit() * random.unit() * 3)
        let weights = (0..<count).map { _ in 0.4 + random.unit() }
        let total = weights.reduce(0, +)
        let lobes = weights.map { weight in
            let r = radius * (weight / total).squareRoot() * Drop.lobeSpread.squareRoot()
            let angle = random.unit() * 2 * Double.pi
            let distance = count == 1 ? 0 : radius * (0.25 + 0.35 * random.unit())
            return Lobe(offset: SIMD2(cos(angle), sin(angle)) * distance, radius: r)
        }
        return Drop(center: center, lobes: lobes, shape: random.unit(), area: Double.pi * radius * radius)
    }

    /// The radius of a round drop holding this much water.
    var size: Double { (area / Double.pi).squareRoot() }

    init(center: SIMD2<Double>, radius: Double, shape: Double) {
        self.init(center: center, lobes: [Lobe(offset: .zero, radius: radius)], shape: shape,
                  area: Double.pi * radius * radius)
    }

    init(center: SIMD2<Double>, lobes: [Lobe], shape: Double, area: Double) {
        self.center = center
        self.lobes = lobes
        self.shape = shape
        self.area = area
    }

    /// How far the drop reaches from its centre.
    var reach: Double {
        var reach = 0.0
        for lobe in lobes { reach = max(reach, simd_length(lobe.offset) + lobe.radius) }
        return reach
    }

    /// Some lobe of one touches some lobe of the other: water does not stay as two drops there.
    func touches(_ other: Drop) -> Bool {
        guard simd_distance(center, other.center) < reach + other.reach else { return false }
        for a in lobes {
            for b in other.lobes where simd_distance(center + a.offset, other.center + b.offset) < a.radius + b.radius {
                return true
            }
        }
        return false
    }

    /// Drawn together, lobes overlap: their disks add up to this much more than the water.
    static let lobeSpread = 1.15

    /// One drop holding both. The lobes move part of the way towards the shared centre (`pull`:
    /// 0 stays put, 1 meets in the middle); beyond `maxLobes`, the two nearest lobes become one.
    /// The lobes are then sized from the water, so merging again and again never inflates them.
    func merged(with other: Drop, pull: Double) -> Drop {
        let a = area, b = other.area
        let center = (center * a + other.center * b) / (a + b)
        var lobes = (self.lobes.map { Lobe(offset: self.center + $0.offset - center, radius: $0.radius) }
            + other.lobes.map { Lobe(offset: other.center + $0.offset - center, radius: $0.radius) })
            .map { Lobe(offset: $0.offset * (1 - pull), radius: $0.radius) }
        while lobes.count > Self.maxLobes { lobes = Self.joinNearest(lobes) }
        let disks = lobes.reduce(0) { $0 + Double.pi * $1.radius * $1.radius }
        let scale = ((a + b) * Self.lobeSpread / disks).squareRoot()
        lobes = lobes.map { Lobe(offset: $0.offset, radius: $0.radius * scale) }
        var drop = Drop(center: center, lobes: lobes, shape: a >= b ? shape : other.shape, area: a + b)
        // A sliding drop that swallows another keeps going, a little faster (momentum, more weight).
        drop.speed = (speed * a + other.speed * b) / (a + b)
        drop.sinceBead = a >= b ? sinceBead : other.sinceBead
        drop.heldUntil = max(heldUntil, other.heldUntil)
        drop.trailEnd = a >= b ? trailEnd : other.trailEnd
        drop.nextBead = a >= b ? nextBead : other.nextBead
        // The more recent run: a drop landing on a runner must not take its motion away.
        // The merge moves it on too, by its share of the way to the other's centre.
        let ours = movedAt != other.movedAt ? movedAt > other.movedAt : a >= b
        let runner = ours ? self : other
        (drop.moved, drop.movedAt) = (runner.moved + abs(center.y - runner.center.y), runner.movedAt)
        return drop
    }

    /// The two nearest lobes as one, holding both's water at their weighted middle.
    private static func joinNearest(_ lobes: [Lobe]) -> [Lobe] {
        var best = (i: 0, j: 1, distance: Double.infinity)
        for i in lobes.indices {
            for j in lobes.indices where j > i {
                let distance = simd_distance(lobes[i].offset, lobes[j].offset)
                if distance < best.distance { best = (i, j, distance) }
            }
        }
        let a = lobes[best.i].radius * lobes[best.i].radius, b = lobes[best.j].radius * lobes[best.j].radius
        let joined = Lobe(offset: (lobes[best.i].offset * a + lobes[best.j].offset * b) / (a + b),
                          radius: (a + b).squareRoot())
        return lobes.indices.filter { $0 != best.i && $0 != best.j }.map { lobes[$0] } + [joined]
    }
}

/// Where drops sit for a given depth (SPEC 4.2 深まり方), the same for the same inputs. Stage B
/// places still drops; the simulation that moves them comes in stage C (M2-PLAN 2).
enum Drops {
    /// The share of the glass the drops cover: a few small drops at first, growing towards a
    /// downpour at two minutes (SPEC 4.2: up to 12 %).
    static func coverage(depth: Double, intensity: Double) -> Double {
        let t = smoothstep(20, 120, depth)
        return min((0.004 + 0.116 * t) * intensity, maximumCoverage)
    }

    /// The most of the glass a downpour covers, whatever the intensity (SPEC 4.2).
    static let maximumCoverage = 0.12

    /// Enough for a downpour on a 5K display at the largest drop size (SPEC 4.2: thousands).
    static let maxPerDisplay = 8000

    /// Drops over `displays` (desktop points). `size` scales every radius. Drops that land on
    /// one another run together into one (DropField).
    static func scatter(displays: [CGRect], depth: Double, intensity: Double, size: Double, seed: UInt64) -> [Drop] {
        scatter(displays: displays, coverage: coverage(depth: depth, intensity: intensity), depth: depth, size: size, seed: seed)
    }

    /// Drops over `displays` covering `coverage` of each (the share already settled).
    /// `fewer` keeps every other drop placed, so the rain halves even where the drop count, not
    /// the coverage, ends the placing (Increase Contrast, Reduce Transparency).
    static func scatter(displays: [CGRect], coverage share: Double, depth: Double, size: Double, seed: UInt64,
                        fewer: Bool = false) -> [Drop] {
        let grown = smoothstep(20, 120, depth)
        // One field for the desktop: drops across a display's edge run together too.
        var field = DropField()
        for (index, display) in displays.enumerated() {
            var random = SplitMix(seed: seed &+ UInt64(index) &* 0x9E37_79B9_7F4A_7C15)
            let area = Double(display.width * display.height)
            var covered = 0.0, count = 0
            let target = share * area
            while covered < target, count < maxPerDisplay {
                count += 1
                // Mostly small drops, a few large; larger ones only as the rain grows.
                let u = random.unit()
                let radius = (1.5 + (3 + 9 * grown) * u * u * u) * size
                let drop = Drop.landing(at: SIMD2(Double(display.minX) + random.unit() * Double(display.width),
                                                  Double(display.minY) + random.unit() * Double(display.height)),
                                        radius: radius, random: &random)
                // How far the two have drawn together since they met (stage C lets it grow).
                let pull = 0.3 + 0.4 * random.unit()
                covered += drop.area
                if fewer, count % 2 == 0 { continue }
                field.add(drop, pull: pull)
            }
        }
        return field.drops
    }

    static func smoothstep(_ low: Double, _ high: Double, _ x: Double) -> Double {
        let t = min(max((x - low) / (high - low), 0), 1)
        return t * t * (3 - 2 * t)
    }
}

/// The drops on the glass, kept apart: a drop that touches another runs together with it, again
/// and again while it grows. A grid of cells finds the neighbours; freed slots are reused.
struct DropField {
    private(set) var slots: [Drop?] = []
    private var free: [Int] = []
    /// Slots freed during a step, reused only after it: a drop moved in the step lands in a new
    /// slot, so the step's walk over the slots it started with never meets it twice.
    private var freedThisStep: [Int] = []
    private var stepping = false
    /// How many drops are on the glass.
    var count: Int { slots.count - free.count - freedThisStep.count }
    private var grid: [SIMD2<Int>: [Int]] = [:]
    private var largest = 0.0
    static let cell = 24.0

    var drops: [Drop] { slots.compactMap { $0 } }

    subscript(index: Int) -> Drop? { slots[index] }

    /// Puts `drop` on the glass, running it together with whatever it touches. Returns its slot.
    @discardableResult mutating func add(_ drop: Drop, pull: Double) -> Int {
        var drop = drop
        while let index = touching(drop) {
            drop = drop.merged(with: slots[index]!, pull: pull)
            remove(index)
        }
        let index: Int
        if let reused = free.popLast() {
            index = reused
            slots[index] = drop
        } else {
            index = slots.count
            slots.append(drop)
        }
        grid[Self.key(drop.center), default: []].append(index)
        largest = max(largest, drop.reach)
        return index
    }

    /// A runner takes in every drop it touches, without growing: each one moves it towards
    /// itself by its share of the water (the path bends), and its water goes into the runner's
    /// speed. Returns the water taken in.
    mutating func swallow(into drop: inout Drop) -> Double {
        var taken = 0.0
        while let index = touching(drop) {
            let other = slots[index]!
            remove(index)
            drop.center += (other.center - drop.center) * (other.area / (drop.area + other.area))
            taken += other.area
        }
        return taken
    }

    /// Takes a drop off the glass.
    mutating func remove(_ index: Int) {
        guard let drop = slots[index] else { return }
        grid[Self.key(drop.center)]?.removeAll { $0 == index }
        slots[index] = nil
        if stepping { freedThisStep.append(index) } else { free.append(index) }
    }

    /// Between these, freed slots wait (see `freedThisStep`).
    mutating func beginStep() { stepping = true }
    mutating func endStep() {
        stepping = false
        free += freedThisStep
        freedThisStep.removeAll()
    }

    /// The largest reach, measured again (it only grows as drops are added).
    mutating func remeasure() {
        largest = slots.compactMap { $0?.reach }.max() ?? 0
    }

    /// Changes a drop's shape where it is (its lobes drawing together), running it together
    /// with anything it now touches.
    mutating func reshape(_ index: Int, to drop: Drop, pull: Double) {
        slots[index] = drop
        guard touching(drop, except: index) != nil else { return }
        remove(index)
        add(drop, pull: pull)
    }

    private func touching(_ drop: Drop, except skipped: Int? = nil) -> Int? {
        let reach = drop.reach + largest
        let low = Self.key(drop.center - reach), high = Self.key(drop.center + reach)
        // Cells in order, and indices in order within a cell: the same drops merge on every Mac.
        for y in low.y...high.y {
            for x in low.x...high.x {
                for index in grid[SIMD2(x, y)] ?? [] where index != skipped && slots[index].map(drop.touches) == true {
                    return index
                }
            }
        }
        return nil
    }

    private static func key(_ point: SIMD2<Double>) -> SIMD2<Int> {
        SIMD2(Int((point.x / cell).rounded(.down)), Int((point.y / cell).rounded(.down)))
    }
}

/// A small, fast, seeded generator: the same seed gives the same drops on every Mac.
struct SplitMix {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// 0 ..< 1.
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}
