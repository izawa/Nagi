import Foundation
import simd

/// One leaf as drawn into a layer's mask: a pointed ellipse in layer millimetres.
struct Leaf: Equatable {
    var center: SIMD2<Float>
    var halfLength: Float
    var halfWidth: Float
    var angle: Float
    /// Light let through, per channel (leaves pass a little green).
    var transmission: SIMD3<Float>
}

/// How one canopy layer grows (SPEC 4.1: high gaps make soft circles, low leaves sharp shapes).
///
/// A `.gaps` layer is a closed crown with small openings: the mask starts at the crown's own
/// transmission and each opening lets the sky through. That is what makes the distinct sun
/// disks; scattered leaves over open sky would average out under a 9 cm disk. A `.leaves` layer
/// is leaves over open sky.
struct LayerStyle {
    enum Kind { case gaps, leaves }

    var kind: Kind
    var height: Double          // metres
    var baseStride: Double      // finest mask texel, millimetres
    var clustersPerCell: Double // gaps or branch tips per cell, before density
    var leavesPerCluster: Int   // 1 for gaps
    var clusterRadius: Double   // millimetres
    var leafLength: ClosedRange<Double> // gap or leaf length, millimetres
    /// Twigs per cell, before density: gaps in a line, each a little turned from the last, so their
    /// sun disks overlap in chains (2026-11-19, after a photo the author showed).
    var chainsPerCell = 0.0
    var chainLinks = 1...1                  // gaps per twig
    var chainSpacing = 0.0...0.0            // between neighbouring gaps, millimetres
    static let chainTurn = 15.0 * .pi / 180 // the most a twig turns per gap
    /// Chance that a twig's gap is two smaller openings (2026-11-19): under a high summer sun their
    /// disks overlap; under a low sun the larger disk blurs the pair back into one patch of light.
    var splitChance = 0.0
    var splitSeparation = 0.0...0.0         // between the two openings' centres, millimetres
    static let splitTurn = 25.0 * .pi / 180 // the pair's axis, off the twig's heading
    static let splitShare = 0.3...0.5       // the smaller opening's share of the area

    /// How far a twig reaches from its first gap, plus how far a split opening's centre can move
    /// (at most the separation, which is at least the two openings' half-lengths).
    var chainReach: Double {
        guard chainsPerCell > 0 else { return 0 }
        return Double(chainLinks.upperBound - 1) * chainSpacing.upperBound
            + max(splitSeparation.upperBound, leafLength.upperBound)
    }

    /// Transmission of a closed crown (a little green comes through). A fifth of stop B's, so the
    /// shade between the sun disks stays dark and the disks read against it (2026-11-19).
    static let crownTransmission = SIMD3<Float>(0.004, 0.007, 0.0024)

    /// Two crowns, combined by `max` in the composite (one canopy whose gaps sit at two heights),
    /// then two leaf layers multiplied below them. The heights mix the sizes of the sun disks. Leaf
    /// counts are the values the author settled on at stop B (1.6× the first draft); the heights are
    /// half of stop B's, so that under a low winter sun the disks stay small enough on a display to
    /// read as overlapping disks rather than a pool's caustics (2026-11-19). The mask strides stay at
    /// stop B's: halving them with the heights changed a 1:1 render on a 5K display by at most 10/255
    /// while quadrupling the texels filtered each frame. The crowns' gaps
    /// are twigs of 3–5 openings, plus single openings in the high crown. A twig's openings are about
    /// 1.1–1.5 disks apart under a summer noon sun and overlap as the sun drops and the disks grow.
    /// Both crowns' openings are about the same fraction of their sun disk, so neither crown
    /// outshines the other (2026-11-19).
    static let all: [LayerStyle] = [
        LayerStyle(kind: .gaps, height: 3, baseStride: 2.4, clustersPerCell: 12, leavesPerCluster: 1,
                   clusterRadius: 0, leafLength: 16...30,
                   chainsPerCell: 4, chainLinks: 3...5, chainSpacing: 32...44,
                   splitChance: 0.55, splitSeparation: 15...22),
        LayerStyle(kind: .gaps, height: 1.5, baseStride: 1.2, clustersPerCell: 0, leavesPerCluster: 1,
                   clusterRadius: 0, leafLength: 10...16,
                   chainsPerCell: 16, chainLinks: 3...5, chainSpacing: 16...22,
                   splitChance: 0.55, splitSeparation: 7.5...11),
        LayerStyle(kind: .leaves, height: 0.9, baseStride: 1.2, clustersPerCell: 4.8, leavesPerCluster: 16,
                   clusterRadius: 110, leafLength: 60...120),
        // Low and loose, so single leaves read as sharp shapes (stop B: the author asked for sharper leaves).
        LayerStyle(kind: .leaves, height: 0.25, baseStride: 0.6, clustersPerCell: 4.8, leavesPerCluster: 6,
                   clusterRadius: 160, leafLength: 50...110),
    ]
}

/// The canopy is unbounded: each 0.5 m cell grows its own leaves from a hash of the seed, the layer
/// and the cell, so any region of any display can be drawn without storing the whole canopy.
enum Canopy {
    static let cellSize = 500.0

    static func leaves(in bounds: CGRect, layer: Int, style: LayerStyle, seed: UInt64, density: Double,
                       scale: Double) -> [Leaf] {
        let cells = cellRange(bounds, style: style, scale: scale)
        var leaves: [Leaf] = []
        for cy in cells.y {
            for cx in cells.x {
                var random = SplitMix(seed: seed, layer: layer, cx: cx, cy: cy)
                let clusters = Int((style.clustersPerCell * density + random.unit()).rounded(.down))
                for _ in 0..<clusters {
                    let tip = SIMD2(Double(cx) + random.unit(), Double(cy) + random.unit()) * cellSize
                    for _ in 0..<style.leavesPerCluster {
                        let spread = SIMD2(min(max(random.gaussian(), -3), 3), min(max(random.gaussian(), -3), 3))
                            * style.clusterRadius * scale / 2
                        leaves.append(leaf(at: tip + spread, style: style, scale: scale, random: &random))
                    }
                }
                guard style.chainsPerCell > 0 else { continue }
                // Twigs draw from their own stream, so a change in the single gaps (density) does
                // not move the twigs already there; splits from a third, so they leave the twigs as they are.
                var twig = SplitMix(seed: seed, layer: layer + LayerStyle.all.count, cx: cx, cy: cy)
                var split = SplitMix(seed: seed, layer: layer + 2 * LayerStyle.all.count, cx: cx, cy: cy)
                let chains = Int((style.chainsPerCell * density + twig.unit()).rounded(.down))
                for _ in 0..<chains {
                    var point = SIMD2(Double(cx) + twig.unit(), Double(cy) + twig.unit()) * cellSize
                    var heading = twig.unit() * 2 * .pi
                    let links = style.chainLinks.lowerBound + Int(twig.unit() * Double(style.chainLinks.count))
                    for link in 0..<links {
                        if link > 0 {
                            heading += (twig.unit() * 2 - 1) * LayerStyle.chainTurn
                            let spacing = style.chainSpacing.lowerBound
                                + (style.chainSpacing.upperBound - style.chainSpacing.lowerBound) * twig.unit()
                            point += SIMD2(cos(heading), sin(heading)) * spacing * scale
                        }
                        let gap = leaf(at: point, style: style, scale: scale, random: &twig)
                        leaves += Self.split(gap, heading: heading, style: style, scale: scale, random: &split)
                    }
                }
            }
        }
        return leaves
    }

    /// One gap or leaf centred at `center`, with a random length, width, angle and transmission.
    private static func leaf(at center: SIMD2<Double>, style: LayerStyle, scale: Double,
                             random: inout SplitMix) -> Leaf {
        let length = (style.leafLength.lowerBound
            + (style.leafLength.upperBound - style.leafLength.lowerBound) * random.unit()) * scale
        let isGap = style.kind == .gaps
        return Leaf(
            center: SIMD2<Float>(center),
            halfLength: Float(length / 2),
            halfWidth: Float(length * (isGap ? 0.3 + 0.2 * random.unit() : 0.22 + 0.12 * random.unit())),
            angle: Float(random.unit() * 2 * .pi),
            transmission: isGap ? LayerStyle.crownTransmission
                : SIMD3<Float>(0.08, 0.14, 0.04) * Float(0.7 + 0.6 * random.unit()))
    }

    /// The gap as is, or two smaller openings with the same total area and the same centre of light,
    /// `splitSeparation` apart along the twig (± `splitTurn`), but never overlapping.
    static func split(_ gap: Leaf, heading: Double, style: LayerStyle, scale: Double,
                      random: inout SplitMix) -> [Leaf] {
        guard random.unit() < style.splitChance else { return [gap] }
        let small = LayerStyle.splitShare.lowerBound
            + (LayerStyle.splitShare.upperBound - LayerStyle.splitShare.lowerBound) * random.unit()
        let shares = random.unit() < 0.5 ? (small, 1 - small) : (1 - small, small)
        let angle = heading + (random.unit() * 2 - 1) * LayerStyle.splitTurn
        let wanted = (style.splitSeparation.lowerBound
            + (style.splitSeparation.upperBound - style.splitSeparation.lowerBound) * random.unit()) * scale
        func part(_ share: Double) -> Leaf {
            var part = gap
            part.halfLength *= Float(share.squareRoot())
            part.halfWidth *= Float(share.squareRoot())
            return part
        }
        var first = part(shares.0), second = part(shares.1)
        let separation = max(wanted, Double(first.halfLength + second.halfLength))
        let axis = SIMD2<Float>(Float(cos(angle)), Float(sin(angle))) * Float(separation)
        // Area-weighted: shares.0 · first + shares.1 · second = the original centre.
        first.center -= axis * Float(shares.1)
        second.center += axis * Float(shares.0)
        return [first, second]
    }

    /// Cells whose leaves can reach `bounds`: the spread is clamped to three standard deviations,
    /// plus a twig's reach and the longest leaf.
    static func cellRange(_ bounds: CGRect, style: LayerStyle, scale: Double) -> (x: ClosedRange<Int>, y: ClosedRange<Int>) {
        let margin = (1.5 * style.clusterRadius + style.chainReach + style.leafLength.upperBound) * scale
        func range(_ low: Double, _ high: Double) -> ClosedRange<Int> {
            Int(((low - margin) / cellSize).rounded(.down))...Int(((high + margin) / cellSize).rounded(.down))
        }
        return (range(bounds.minX, bounds.maxX), range(bounds.minY, bounds.maxY))
    }
}

/// A small deterministic generator (SplitMix64) seeded per cell.
struct SplitMix {
    private var state: UInt64

    init(seed: UInt64, layer: Int, cx: Int, cy: Int) {
        var mixer = seed ^ 0x9E37_79B9_7F4A_7C15
        for value in [UInt64(bitPattern: Int64(layer)), UInt64(bitPattern: Int64(cx)), UInt64(bitPattern: Int64(cy))] {
            mixer = (mixer ^ value) &* 0xBF58_476D_1CE4_E5B9
            mixer ^= mixer >> 31
        }
        state = mixer
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in [0, 1).
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }

    /// Standard normal (Box–Muller).
    mutating func gaussian() -> Double {
        let u1 = max(unit(), 1e-12), u2 = unit()
        return sqrt(-2 * log(u1)) * cos(2 * .pi * u2)
    }
}
