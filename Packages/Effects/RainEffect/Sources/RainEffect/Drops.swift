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
    var reach: Double { lobes.map { simd_length($0.offset) + $0.radius }.max() ?? 0 }

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
        return Drop(center: center, lobes: lobes, shape: a >= b ? shape : other.shape, area: a + b)
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
        let grown = smoothstep(20, 120, depth)
        // One field for the desktop: drops across a display's edge run together too.
        var field = DropField()
        for (index, display) in displays.enumerated() {
            var random = SplitMix(seed: seed &+ UInt64(index) &* 0x9E37_79B9_7F4A_7C15)
            let area = Double(display.width * display.height)
            var covered = 0.0, count = 0
            let target = coverage(depth: depth, intensity: intensity) * area
            while covered < target, count < maxPerDisplay {
                count += 1
                // Mostly small drops, a few large; larger ones only as the rain grows.
                let u = random.unit()
                let radius = (1.5 + (3 + 9 * grown) * u * u * u) * size
                let drop = Drop(center: SIMD2(Double(display.minX) + random.unit() * Double(display.width),
                                              Double(display.minY) + random.unit() * Double(display.height)),
                                radius: radius, shape: random.unit())
                // How far the two have drawn together since they met (stage C lets it grow).
                field.add(drop, pull: 0.3 + 0.4 * random.unit())
                covered += drop.area
            }
        }
        return field.drops
    }

    static func smoothstep(_ low: Double, _ high: Double, _ x: Double) -> Double {
        let t = min(max((x - low) / (high - low), 0), 1)
        return t * t * (3 - 2 * t)
    }
}

/// The drops on one display, kept apart: a drop that touches another runs together with it, again
/// and again while it grows. A grid of cells finds the neighbours.
struct DropField {
    private(set) var slots: [Drop?] = []
    private var grid: [SIMD2<Int>: [Int]] = [:]
    private var largest = 0.0
    static let cell = 24.0

    var drops: [Drop] { slots.compactMap { $0 } }

    mutating func add(_ drop: Drop, pull: Double) {
        var drop = drop
        while let index = touching(drop) {
            drop = drop.merged(with: slots[index]!, pull: pull)
            remove(index)
        }
        let index = slots.count
        slots.append(drop)
        grid[Self.key(drop.center), default: []].append(index)
        largest = max(largest, drop.reach)
    }

    private func touching(_ drop: Drop) -> Int? {
        let reach = drop.reach + largest
        let low = Self.key(drop.center - reach), high = Self.key(drop.center + reach)
        // Cells in order, and indices in order within a cell: the same drops merge on every Mac.
        for y in low.y...high.y {
            for x in low.x...high.x {
                for index in grid[SIMD2(x, y)] ?? [] where slots[index].map(drop.touches) == true {
                    return index
                }
            }
        }
        return nil
    }

    private mutating func remove(_ index: Int) {
        guard let drop = slots[index] else { return }
        grid[Self.key(drop.center)]?.removeAll { $0 == index }
        slots[index] = nil
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
