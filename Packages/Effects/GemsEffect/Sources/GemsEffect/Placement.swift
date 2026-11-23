import CoreGraphics
import Foundation
import NagiKit

/// The stones a crystal can be (M5-PLAN 2): mostly clear quartz, some pale aquamarine and topaz.
enum Stone: Int, CaseIterable, Sendable {
    case quartz, aquamarine, topaz, morganite, prasiolite

    /// The share of clusters of each stone, in order: clear quartz most, then pale blue
    /// (aquamarine, topaz), pale pink (morganite) and pale green (prasiolite). The author asked to
    /// see pink and green as well (W1).
    static let shares: [(Stone, Double)] = [(.quartz, 0.64), (.aquamarine, 0.09), (.topaz, 0.09),
                                            (.morganite, 0.09), (.prasiolite, 0.09)]

    /// The stone for a sample 0 … 1.
    static func pick(_ sample: Double) -> Stone {
        var total = 0.0
        for (stone, share) in shares {
            total += share
            if sample < total { return stone }
        }
        return .quartz
    }
}

/// One crystal of a cluster, in desktop points (y grows downward, as in `WindowSnapshot`).
struct Crystal: Equatable, Sendable {
    /// Where it stands on the window's top edge.
    var root: CGPoint
    /// Its lean from straight up, radians (positive leans right).
    var angle: Double
    /// Its length now (grown) and when fully grown, points.
    var length: Double
    var fullLength: Double
    /// Across its body, points.
    var width: Double
    var stone: Stone
    /// 0 … 1: its turn about its own axis, which sets which faces face the viewer.
    var spin: Double
    var seed: UInt32
}

/// A cluster of crystals from one root on a window's top edge, with the windows in front that
/// cover any of it.
struct Cluster: Equatable, Sendable {
    var windowID: UInt32
    var crystals: [Crystal]
    /// The rectangle every crystal of the cluster fits in when fully grown, points.
    var bounds: CGRect
    var fronts: [CGRect]
    /// The deep light (M5-PLAN 2): a glowing point a little behind the cluster's root, seen through
    /// its crystals, and how far behind the screen it is, points. Fixed by the cluster's place and
    /// size, never by what covers it, so its images stay put as windows come and go.
    var light: CGPoint
    var lightDepth: Double
}

/// One edge of a window, walked clockwise from its upper-left corner, with the direction out of
/// the window (radians from straight up, clockwise, as a crystal's angle). Gems grow on every
/// edge, as crystals in a cave grow every way (the author at W1): most on the top, a few on the
/// sides and the bottom.
struct Edge {
    var start: CGPoint
    var direction: CGVector
    var length: Double
    var outward: Double
    /// Points left bare at the start and the end of the edge, past the corner radius (the window's
    /// buttons at the start of the top).
    var lead: Double
    var trail: Double
    /// The share of sections with a cluster.
    var share: Double

    func point(along distance: Double, inward: Double) -> CGPoint {
        // Inward is the direction 90° clockwise from walking the edge.
        CGPoint(x: start.x + direction.dx * distance - direction.dy * inward,
                y: start.y + direction.dy * distance + direction.dx * inward)
    }

    /// Top, right, bottom, left.
    static func all(of f: CGRect) -> [Edge] {
        [Edge(start: CGPoint(x: f.minX, y: f.minY), direction: CGVector(dx: 1, dy: 0), length: f.width,
              outward: 0, lead: 72, trail: 24, share: 0.6),
         Edge(start: CGPoint(x: f.maxX, y: f.minY), direction: CGVector(dx: 0, dy: 1), length: f.height,
              outward: .pi / 2, lead: 24, trail: 24, share: 0.25),
         Edge(start: CGPoint(x: f.maxX, y: f.maxY), direction: CGVector(dx: -1, dy: 0), length: f.width,
              outward: .pi, lead: 24, trail: 24, share: 0.25),
         Edge(start: CGPoint(x: f.minX, y: f.maxY), direction: CGVector(dx: 0, dy: -1), length: f.height,
              outward: -.pi / 2, lead: 24, trail: 24, share: 0.25)]
    }
}

/// Where gems grow (M5-PLAN 4), in desktop points.
enum Placement {
    private static let cornerRadius = 16.0
    private static let sectionWidth = 240.0
    /// The most windows in front a cluster may meet: the shader tests no more.
    static let maxFronts = 16
    /// Points beyond a crystal's outline that its glow may reach (the shader's quad margin).
    static let halo = 24.0
    /// Sections looked at along one edge, at most (a made-up layout may hold a huge window).
    private static let maxSections = 64
    /// The amount past which the sections take more clusters (the setting's old most).
    private static let crowding = 2.0
    /// The setting's range: at the most, the edges are crusted (the author, 2026-11-23).
    static let amounts = 0.3...6.0

    /// Growth of the main crystal: a bud from 10 minutes, a small pillar (about a third) by 30,
    /// full by two hours (M5-PLAN 4). Quick at first and slowing, as a crystal fed from a solution.
    static func growth(age: Double) -> Double {
        easeOut(age, from: 600, to: 7200)
    }

    private static func easeOut(_ age: Double, from start: Double, to end: Double) -> Double {
        guard age.isFinite else { return age > 0 ? 1 : 0 }
        let t = min(max((age - start) / (end - start), 0), 1)
        return t * (2 - t)
    }

    // Mix a seed and an integer key so each section, crystal and trait is sampled independently.
    private static func hash(_ seed: UInt32, _ key: UInt32) -> UInt32 {
        var x = seed &+ (key &* 0x9e3779b9)
        x = (x ^ (x >> 16)) &* 0x7feb352d
        x = (x ^ (x >> 15)) &* 0x846ca68b
        return x ^ (x >> 16)
    }

    private static func sample(_ seed: UInt32, _ key: UInt32) -> Double {
        Double(hash(seed, key)) / Double(UInt32.max)
    }

    /// `amount` scales how many sections get a cluster (the setting; 1 is the shares in `Edge`).
    static func clusters(_ snapshot: WindowSnapshot, speed: Double = 1, heightScale: Double = 1,
                         amount: Double = 1) -> [Cluster] {
        // As in Moss, extend full-screen covers so rounding their corners still covers the display.
        let square = cornerRadius * (2.squareRoot() - 1) + 0.5
        let covers = snapshot.frontToBack.map { window in
            snapshot.usableAreas.contains { window.frame.contains($0) }
                ? window.frame.insetBy(dx: -square, dy: -square) : window.frame
        }
        var result: [Cluster] = []
        for (index, window) in snapshot.frontToBack.enumerated() where window.role == .surface {
            let frame = window.frame
            let age = window.stationarySeconds * speed
            guard age > 600 else { continue }
            func fits(_ bounds: CGRect, root: CGPoint) -> Bool {
                // The whole grown cluster must lie on the display under its root (below the menu
                // bar and above the Dock, which the usable area leaves out).
                guard let under = snapshot.usableAreas.first(where: { $0.contains(root) }) else { return snapshot.usableAreas.isEmpty }
                return under.contains(bounds)
            }
            for (edgeIndex, edge) in Edge.all(of: frame).enumerated() where edge.share > 0 {
                let available = edge.length - 2 * cornerRadius - edge.lead - edge.trail
                let count = available >= sectionWidth ? Int(min(available / sectionWidth, Double(maxSections))) : 0
                guard count > 0 else { continue }
                func sectionSeed(_ section: Int) -> UInt32 {
                    hash(window.id, UInt32(truncatingIfNeeded: edgeIndex * 1000 + section))
                }
                // In the order a growing amount would choose them, so a larger amount only adds
                // clusters. Every window with room on top has one there: the first that fits.
                let order = (0..<count).sorted { sample(sectionSeed($0), 0) < sample(sectionSeed($1), 0) }
                // The cluster this many sections along the edge, if it fits on the display.
                func place(_ seed: UInt32, at position: Double) -> Bool {
                    let along = cornerRadius + edge.lead + position * sectionWidth
                    let root = edge.point(along: along, inward: 1.5)
                    // Where clusters stand depends only on the window and the display: a window in
                    // front hides one, it never moves the top's cluster to another section.
                    let grown = cluster(windowID: window.id, seed: seed, root: root, edge: edge, age: age,
                                        heightScale: heightScale)
                    guard fits(grown.bounds, root: root) else { return false }
                    if let visible = cover(grown, with: covers.prefix(index)) { result.append(visible) }
                    return true
                }
                var placed = 0
                for section in order {
                    let seed = sectionSeed(section)
                    let chosen = sample(seed, 0) < edge.share * amount
                    guard chosen || (edgeIndex == 0 && placed == 0) else { break }
                    // Summed in this order so the clusters stay those of the old setting, to the bit.
                    if place(seed, at: Double(section) + 0.2 + 0.6 * sample(seed, 1)) { placed += 1 }
                }
                // Past `crowding`, two more slots per section fill in, as a crust: halfway across
                // the wider gap beside the first slot, then the section's start. Roots stay at
                // least a fifth of a section apart, and the clusters above only ever gain.
                guard amount > crowding else { continue }
                for section in 0..<count {
                    // The first slot's place in its section, as a fraction of it.
                    let first = 0.2 + 0.6 * sample(sectionSeed(section), 1)
                    let slots = [first <= 0.5 ? (first + 1) / 2 : first / 2, 0]
                    // The first section's start is too near the corner for a whole cluster.
                    for (slot, at) in slots.enumerated() where section > 0 || slot == 0 {
                        let seed = sectionSeed(section + maxSections * (slot + 1))
                        if Double(slot) + sample(seed, 0) < edge.share * (amount - crowding) {
                            _ = place(seed, at: Double(section) + at)
                        }
                    }
                }
            }
        }
        return result
    }

    /// The cluster at this age, uncovered; its bounds are those of the grown cluster.
    private static func cluster(windowID: UInt32, seed: UInt32, root: CGPoint, edge: Edge, age: Double,
                                heightScale: Double) -> Cluster {
        // One main crystal, one to three middle ones leaning out, and six to nine small ones
        // filling the base side by side, their roots overlapping a little, as crystals from one
        // rock (a cluster, as quartz grows: the author at W1). One stone per cluster.
        let middles = 1 + Int(hash(seed, 2) % 3), smalls = 6 + Int(hash(seed, 6) % 4)
        let mainLength = (52 + 20 * sample(seed, 3)) * heightScale
        let stone = Stone.pick(sample(seed, 7))
        // The base runs this far to each side of the root.
        let reach = mainLength * 0.5
        var crystals: [Crystal] = []
        var bounds = CGRect.null
        var light = root
        for i in 0..<(1 + middles + smalls) {
            let crystalSeed = hash(seed, 8 + UInt32(i))
            let side = i.isMultiple(of: 2) ? -1.0 : 1.0
            let lean: Double, fullLength: Double, slender: Double, offset: Double, fraction: Double
            if i == 0 {
                // The main crystal need not stand in the middle, nor be the tallest.
                lean = (2 * sample(crystalSeed, 0) - 1) * 0.25
                fullLength = mainLength
                slender = 0.30 + 0.06 * sample(crystalSeed, 3)
                offset = (2 * sample(crystalSeed, 6) - 1) * mainLength * 0.15
                fraction = growth(age: age)
            } else {
                let small = i > middles
                fullLength = mainLength * (small ? 0.14 + 0.2 * sample(crystalSeed, 1) : 0.55 + 0.55 * sample(crystalSeed, 1))
                slender = small ? 0.5 + 0.1 * sample(crystalSeed, 3) : 0.30 + 0.06 * sample(crystalSeed, 3)
                if small {
                    // Side by side across the base, a little jittered: no gaps between the roots.
                    let k = Double(i - middles - 1), n = Double(smalls)
                    offset = reach * (2 * (k + 0.2 + 0.6 * sample(crystalSeed, 6)) / n - 1)
                    // Leaning out the more the farther from the middle.
                    lean = offset / reach * 1.0 + (2 * sample(crystalSeed, 0) - 1) * 0.25
                } else {
                    // Spread along the edge: the cluster runs sideways more than it stands up.
                    offset = side * reach * (0.2 + 0.7 * sample(crystalSeed, 6))
                    lean = side * (0.1 + 0.5 * sample(crystalSeed, 0))
                }
                fraction = easeOut(age, from: 1800 + 5400 * sample(crystalSeed, 2), to: 14400)
            }
            let width = fullLength * slender
            let base = CGPoint(x: root.x + edge.direction.dx * offset, y: root.y + edge.direction.dy * offset)
            let angle = edge.outward + lean
            // The deep light sits behind the main crystal's lower part, on its axis, so the faces
            // of that crystal split it (even before the crystal shows).
            if i == 0 {
                light = CGPoint(x: base.x + sin(angle) * fullLength * 0.22, y: base.y - cos(angle) * fullLength * 0.22)
            }
            // Include dormant crystals so the full-grown bounds stay fixed as the cluster grows.
            let dx = sin(angle) * fullLength, dy = -cos(angle) * fullLength
            let segment = CGRect(x: base.x + min(0, dx), y: base.y + min(0, dy), width: abs(dx), height: abs(dy))
            bounds = bounds.union(segment.insetBy(dx: -width / 2, dy: -width / 2))

            let length = fullLength * fraction
            guard length >= 0.5 else { continue }
            crystals.append(Crystal(root: base, angle: angle, length: length, fullLength: fullLength,
                                    width: width, stone: stone, spin: sample(crystalSeed, 5), seed: crystalSeed))
        }
        // Deep enough that the side faces move its images apart, shallow enough that they stay
        // inside the main crystal (half as wide as 0.12 of its length there).
        return Cluster(windowID: windowID, crystals: crystals, bounds: bounds.insetBy(dx: -4, dy: -4), fronts: [],
                       light: light, lightDepth: mainLength * 0.13)
    }

    /// The cluster as seen behind the windows in front, or nil if nothing of it shows.
    private static func cover(_ cluster: Cluster, with covers: ArraySlice<CGRect>) -> Cluster? {
        var crystals = cluster.crystals
        let bounds = cluster.bounds
        // The windows in front that may cover anything drawn, the glow included.
        let fronts = covers.filter { $0.intersects(bounds.insetBy(dx: -halo, dy: -halo)) }
        // A crystal covered at its root is left out (its tip would float over the window in
        // front); so is a cluster wholly covered, or met by more windows than the shader tests.
        crystals.removeAll { crystal in
            let base = CGRect(origin: crystal.root, size: .zero)
            return fronts.contains { roundedContains($0, base) }
        }
        guard !crystals.isEmpty, fronts.count <= maxFronts,
              !fronts.contains(where: { roundedContains($0, bounds) }) else { return nil }
        var visible = cluster
        visible.crystals = crystals
        visible.fronts = fronts
        return visible
    }

    private static func roundedContains(_ window: CGRect, _ rect: CGRect) -> Bool {
        // A small panel's corners can be no rounder than half its size.
        let r = min(cornerRadius, window.width / 2, window.height / 2)
        func inside(_ x: CGFloat, _ y: CGFloat) -> Bool {
            let cx = min(max(x, window.minX + r), window.maxX - r)
            let cy = min(max(y, window.minY + r), window.maxY - r)
            return window.contains(CGPoint(x: x, y: y)) && hypot(x - cx, y - cy) <= r
        }
        return inside(rect.minX, rect.minY) && inside(rect.maxX, rect.minY)
            && inside(rect.minX, rect.maxY) && inside(rect.maxX, rect.maxY)
    }
}
