import CoreGraphics
import Foundation
import simd

/// The rain on the glass over time (SPEC 4.2 シミュレーション): drops arrive, run together,
/// and once heavy enough slide down, wandering a little, leaving small beads behind and
/// swallowing the drops in their way. Steps are fixed (1/60 s) and the randomness is seeded, so
/// the same inputs give the same rain.
struct RainSimulation {
    static let step = 1.0 / 60

    struct Settings: Equatable {
        var depth: Double
        var intensity: Double
        var size: Double
        /// Increase Contrast or Reduce Transparency: half the rain (SPEC 2.2), after the caps.
        var fewer = false
        /// False while nagi leaves: no new drops then, only the evaporation.
        var arriving = true
        /// The shared wind across the glass (points per second it pushes a running drop sideways).
        var drift = 0.0

        /// The glass's share to cover now (halved for `fewer` after the drop budget, by the
        /// placing itself: see Drops.scatter and `arrive`).
        var coverage: Double { Drops.coverage(depth: depth, intensity: intensity) }
    }

    private(set) var field = DropField()
    private let displays: [CGRect]
    private var random: SplitMix
    private var time = 0.0
    private var backlog = 0.0
    /// The time the latest `advance(by:)` that made steps started from: its steps are one frame's.
    private var frameStart = 0.0
    /// Water that has run off the bottom of the glass, for the books (tests).
    private(set) var drained = 0.0
    /// Water that has arrived, for the books.
    private(set) var arrived = 0.0
    /// The wet streaks runners leave: a thin film along the path that thins and dries within a
    /// few seconds (not water to count: the film is part of the runner's shed water, too thin to
    /// merge or run). Each with the time it was laid.
    private var trails: [(from: SIMD2<Double>, to: SIMD2<Double>, halfWidth: Double, laid: Double)] = []
    static let trailLife = 1.5

    /// One piece of a wet trail, in desktop points, with how much of it is left (1 … 0).
    struct TrailPiece: Equatable {
        var from: SIMD2<Double>
        var to: SIMD2<Double>
        var halfWidth: Double
        var left: Double
    }

    /// Starts from the drops the glass would hold at `settings.depth`. The heavy ones set off one
    /// by one over the first seconds, while nagi fades in (entry takes 4 s): all at once, their
    /// highlights crossed the same pixels in a burst (SPEC 2.2). Settling them first instead took
    /// 0.3 s of the main thread at the start of a showing.
    init(displays: [CGRect], settings: Settings, seed: UInt64) {
        self.displays = displays
        random = SplitMix(seed: seed ^ 0x5EED_0F2A_1B)
        for drop in Drops.scatter(displays: displays, coverage: settings.coverage, depth: settings.depth,
                                  size: settings.size, seed: seed, fewer: settings.fewer) {
            var drop = drop
            // The heavy ones set off one by one, as heavy drops do later on.
            if drop.size > Self.slideSize(settings) { drop.heldUntil = 8 * -log(1 - random.unit()) }
            field.add(drop, pull: 0)
            arrived += drop.area
        }
    }

    var drops: [Drop] { field.drops }

    /// Each drop on the glass, in turn, without copying the whole set (drawn every frame).
    func forEachDrop(_ body: (Drop) -> Void) {
        for case let drop? in field.slots { body(drop) }
    }

    /// Points per second `drop` went down the glass over the latest frame's steps (0 if it did not
    /// run in them). Often more than its speed: a runner put back in a slot the step has yet to
    /// reach is moved again in the same step, and what it takes in pulls it on. The motion blur
    /// follows this; with the speed it covered as little as half of a frame's travel, and the
    /// image in a runner jumped past sharp edges (a flicker, SPEC 2.2).
    func pace(of drop: Drop) -> Double {
        drop.movedAt > frameStart ? drop.moved / (time - frameStart) : 0
    }

    /// The wet trails, piece by piece.
    var trailPieces: [TrailPiece] {
        trails.map { TrailPiece(from: $0.from, to: $0.to, halfWidth: $0.halfWidth,
                                left: max(1 - (time - $0.laid) / Self.trailLife, 0)) }
    }

    /// Puts given drops on the glass instead (tests).
    mutating func replaceField(_ field: DropField) {
        self.field = field
        arrived = field.drops.reduce(0) { $0 + $1.area }
        drained = 0
    }

    /// Moves the rain on by `seconds`, in fixed steps. More than five seconds at once (a stalled
    /// Mac) is cut to five, so catching up cannot stall it again. Timestamps that differ by a
    /// rounding error from a whole number of steps still make that number of steps.
    mutating func advance(by seconds: Double, _ settings: Settings) {
        backlog += min(max(seconds, 0), 5)
        if backlog >= Self.step * (1 - 1e-6) { frameStart = time }
        while backlog >= Self.step * (1 - 1e-6) {
            backlog = max(backlog - Self.step, 0)
            advance(settings)
        }
    }

    // MARK: - One step

    /// A drop this large (radius, points) slides; smaller ones are held by the glass.
    static func slideSize(_ settings: Settings) -> Double { 9 * settings.size }

    private mutating func advance(_ settings: Settings) {
        time += Self.step
        let dt = Self.step
        field.beginStep()
        defer { field.endStep() }
        // The slots this step starts with (drops moved in it land in new ones, DropField).
        for index in 0..<field.slots.count {
            guard let drop = field[index] else { continue }   // empty, or swallowed earlier in this step
            if drop.speed > 0 {
                slide(index, drop, dt: dt, settings)
            } else if drop.size > Self.slideSize(settings) {
                if drop.heldUntil < 0 {
                    // Newly heavy: the glass holds it for a while, eight seconds on average.
                    var held = drop
                    held.heldUntil = time + 8 * -log(1 - random.unit())
                    field.remove(index)
                    field.add(held, pull: 0)
                } else if time >= drop.heldUntil || drop.size > Self.slideSize(settings) * 1.8 {
                    // Its time came, or it grew too heavy to be held while it waited.
                    slide(index, drop, dt: dt, settings)
                }
            } else if drop.lobes.count > 1, (Int(time / Self.step) + index) % 8 == 0,
                      drop.lobes.contains(where: { simd_length($0.offset) > 0.05 }) {
                // Every eighth step, each drop in its turn: so slow a drawing-together moves a lobe
                // under 0.05 points at a time, too little to see (in jumps of 0.25 s, at τ = 6 s, the
                // image in the drop jumped and flickered), and it spares the CPU.
                relax(index, drop, dt: dt * 8)
            }
        }
        if settings.arriving { arrive(dt: dt, settings) }
        trails.removeAll { time - $0.laid > Self.trailLife }
        if Int(time / Self.step) % 120 == 0 { field.remeasure() }
    }

    /// A heavy drop runs straight down, pulled by gravity, faster the heavier it is and where the
    /// glass holds it less. It leaves its line only where it runs into a drop that sits off to one
    /// side: it takes it in, moves towards it by as much as that drop weighs, and runs faster for
    /// the water, without growing (DropField.swallow). Those joins make a runner wander. Behind it, at uneven distances, it
    /// leaves tiny beads; it stops when it has lost enough water, which is seldom before the edge.
    private mutating func slide(_ index: Int, _ drop: Drop, dt: Double, _ settings: Settings) {
        var drop = drop
        field.remove(index)
        let slide = Self.slideSize(settings)
        let excess = (drop.size - slide * 0.8) / slide
        guard excess > 0 else {
            drop.speed = 0
            field.add(drop, pull: 0.5)
            return
        }
        // The glass's grip changes from place to place: the drop hesitates, then runs.
        let grip = Self.noise(drop.center / 40, seed: 1)
        // Heavier runs faster, so a big drop crosses the glass in a second or two. Once it runs
        // it does not crawl: a crawling lens over text flickers (SPEC 2.2).
        let target = max(700 * min(excess, 3) * (0.4 + 1.0 * grip), 300)
        // A drop lets go of the glass all at once: it starts at half its running speed (starting
        // from rest, it crept for a few frames and its highlight flickered, SPEC 2.2).
        if drop.speed == 0 { drop.speed = target / 2 }
        // Up to speed quickly; a boost from water taken in wears off over about a second.
        drop.speed += (target - drop.speed) * min(1, dt * (drop.speed < target ? 8 : 1.2))
        let move = SIMD2(0, drop.speed * dt) + SIMD2(settings.drift * dt, 0)
        let start = drop.center
        // In steps no longer than a quarter of the drop, taking in what it meets on the way: a
        // fast runner must not pass over a bead in one jump.
        let substeps = max(1, Int((simd_length(move) / max(drop.reach * 0.25, 0.5)).rounded(.up)))
        for _ in 0..<substeps {
            drop.center += move / Double(substeps)
            let taken = field.swallow(into: &drop)
            drop.speed += 600 * taken / drop.area
            drained += taken
        }
        drop.sinceBead += simd_length(move)
        // The lobes trail behind as a sliding drop draws itself into a teardrop.
        drop.lobes = drop.lobes.map { Drop.Lobe(offset: $0.offset * (1 - min(1, dt * 3)), radius: $0.radius) }
        // A tiny bead left behind now and then, a little of the water torn off the trailing edge.
        if drop.nextBead <= 0 { drop.nextBead = drop.size * (0.5 + 3 * -log(1 - random.unit())) }
        if drop.sinceBead > drop.nextBead, drop.size > slide * 0.8 {
            drop.sinceBead = 0
            drop.nextBead = 0
            let beadRadius = (0.5 + 0.8 * random.unit()) * settings.size
            // Just clear of the drop's trailing edge, where the water was torn off.
            let bead = Drop(center: drop.center - SIMD2(move.x, drop.reach + beadRadius + 0.5),
                            radius: beadRadius, shape: random.unit())
            drop = drop.losing(bead.area)
            // Within the drop budget, and on the glass; otherwise the water stays with the drop
            // (or, off the glass, runs off).
            // The budget counts the bead and the runner going back on the glass.
            if bead.touches(drop) || !hasRoom(for: 2, at: bead.center) { drop = drop.gaining(bead.area) }
            else if isOnGlass(bead) { field.add(bead, pull: 0.3) }
            else { drained += bead.area }
        }
        guard isOnGlass(drop) else {
            drained += drop.area
            return
        }
        // What it ran into did not swell it (above): the water carries it faster, and runs on with
        // it (counted as run off then; it leaves the glass with the runner).
        // The trail goes on from where it ended to where the runner is now, through any jump.
        layTrail(from: drop.trailEnd ?? drop.center - move, to: drop.center, size: drop.size)
        drop.trailEnd = drop.center
        if drop.movedAt <= frameStart { drop.moved = 0 }
        drop.movedAt = time
        drop.moved += abs(drop.center.y - start.y)
        field.add(drop, pull: 0.55)
    }

    /// A piece of wet trail along the step a runner just made, as wide as the runner is large (a
    /// runner keeps the size it set off with, so the trail keeps its width).
    private mutating func layTrail(from: SIMD2<Double>, to: SIMD2<Double>, size: Double) {
        guard simd_distance(from, to) > 0.01 else { return }
        trails.append((from, to, max(1.6, size * 0.3), time))
    }

    /// A drop at rest slowly draws its lobes together (surface tension). Its outline changes, so
    /// it goes back through `add`, which runs it together with anything it now touches.
    private mutating func relax(_ index: Int, _ drop: Drop, dt: Double) {
        guard drop.lobes.count > 1 else { return }
        var relaxed = drop
        // Slowly: the glass holds a drop's edge where it landed, so drops stay uneven a long while.
        let keep = exp(-dt / 25)
        relaxed.lobes = drop.lobes.map { Drop.Lobe(offset: $0.offset * keep, radius: $0.radius) }
        field.reshape(index, to: relaxed, pull: 0.3)
    }

    /// New drops land so the glass tends to the coverage for this depth, and a few more keep
    /// arriving so the rain stays alive once it is reached.
    private mutating func arrive(dt: Double, _ settings: Settings) {
        let grown = Drops.smoothstep(20, 120, settings.depth)
        for display in displays {
            let area = Double(display.width * display.height)
            // `fewer`: half the water and at most half the drops (the budget binds too).
            let target = settings.coverage * area * (settings.fewer ? 0.5 : 1)
            let budget = Drops.maxPerDisplay / (settings.fewer ? 2 : 1)
            var (covered, drops) = water(on: display)
            // Drops per second: refill the shortfall over a few seconds, plus a steady drizzle.
            let meanDrop = Double.pi * pow(3 * settings.size, 2)
            let rate = max(target - covered, 0) / meanDrop / 60 + target / meanDrop / 1500
            var count = rate * dt
            while count > 0, drops < budget {
                if count < 1, random.unit() >= count { break }
                count -= 1
                let u = random.unit()
                let radius = (1.5 + (3 + 6 * grown) * u * u * u) * settings.size
                let drop = Drop.landing(at: SIMD2(Double(display.minX) + random.unit() * Double(display.width),
                                                  Double(display.minY) + random.unit() * Double(display.height)),
                                        radius: radius, random: &random)
                arrived += drop.area
                covered += drop.area
                drops += 1
                field.add(drop, pull: 0.2 + 0.3 * random.unit())
            }
        }
    }

    /// Whether the display under `point` can take `count` more drops within its budget.
    private func hasRoom(for count: Int, at point: SIMD2<Double>) -> Bool {
        guard let display = displays.first(where: { $0.contains(CGPoint(x: point.x, y: point.y)) }) else { return false }
        return water(on: display).count + count <= Drops.maxPerDisplay
    }

    /// The water and the drops on one display (drops are assigned by their centre).
    private func water(on display: CGRect) -> (area: Double, count: Int) {
        field.slots.reduce((0, 0)) { sum, drop in
            guard let drop, display.contains(CGPoint(x: drop.center.x, y: drop.center.y)) else { return sum }
            return (sum.0 + drop.area, sum.1 + 1)
        }
    }

    private func isOnGlass(_ drop: Drop) -> Bool {
        displays.contains { $0.insetBy(dx: -drop.reach, dy: -drop.reach).contains(CGPoint(x: drop.center.x, y: drop.center.y)) }
    }

    /// Smooth value noise in 0…1 (bilinear between hashed corners), the same on every Mac.
    static func noise(_ p: SIMD2<Double>, seed: UInt64) -> Double {
        let cell = SIMD2((p.x).rounded(.down), (p.y).rounded(.down))
        let f = p - cell
        func corner(_ dx: Double, _ dy: Double) -> Double {
            var mix = SplitMix(seed: seed &+ UInt64(bitPattern: Int64(cell.x + dx)) &* 0x9E37_79B9
                                 &+ UInt64(bitPattern: Int64(cell.y + dy)) &* 0x85EB_CA6B)
            return mix.unit()
        }
        let s = f * f * (3 - 2 * f)
        let top = corner(0, 0) + (corner(1, 0) - corner(0, 0)) * s.x
        let bottom = corner(0, 1) + (corner(1, 1) - corner(0, 1)) * s.x
        return top + (bottom - top) * s.y
    }
}

extension Drop {
    /// The same drop with `water` less, its lobes shrunk to match.
    func losing(_ water: Double) -> Drop { resized(to: max(area - water, 1)) }
    func gaining(_ water: Double) -> Drop { resized(to: area + water) }

    private func resized(to water: Double) -> Drop {
        var drop = self
        let scale = (water / area).squareRoot()
        drop.lobes = lobes.map { Lobe(offset: $0.offset, radius: $0.radius * scale) }
        drop.area = water
        return drop
    }
}
