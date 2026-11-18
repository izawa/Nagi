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

    /// Transmission of a closed crown (a little green comes through).
    static let crownTransmission = SIMD3<Float>(0.02, 0.035, 0.012)

    /// Two crowns, combined by `max` in the composite (one canopy whose gaps sit at two heights),
    /// then two leaf layers multiplied below them. The heights mix the sizes of the sun disks; the
    /// lower crown's gaps are clusters of two or three openings, so its disks keep some of their
    /// shape (stop B: the author asked for mixed sizes and shapes). Heights and counts are the values
    /// the author settled on at stop B (heights 0.6× and density 1.6× the first draft).
    static let all: [LayerStyle] = [
        LayerStyle(kind: .gaps, height: 6, baseStride: 2.4, clustersPerCell: 29, leavesPerCluster: 1,
                   clusterRadius: 0, leafLength: 12...40),
        LayerStyle(kind: .gaps, height: 3, baseStride: 1.2, clustersPerCell: 4.8, leavesPerCluster: 3,
                   clusterRadius: 14, leafLength: 12...28),
        LayerStyle(kind: .leaves, height: 1.8, baseStride: 1.2, clustersPerCell: 4.8, leavesPerCluster: 16,
                   clusterRadius: 110, leafLength: 60...120),
        // Low and loose, so single leaves read as sharp shapes (stop B: the author asked for sharper leaves).
        LayerStyle(kind: .leaves, height: 0.5, baseStride: 0.6, clustersPerCell: 4.8, leavesPerCluster: 6,
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
                        let length = (style.leafLength.lowerBound
                            + (style.leafLength.upperBound - style.leafLength.lowerBound) * random.unit()) * scale
                        let isGap = style.kind == .gaps
                        leaves.append(Leaf(
                            center: SIMD2<Float>(tip + spread),
                            halfLength: Float(length / 2),
                            halfWidth: Float(length * (isGap ? 0.3 + 0.2 * random.unit() : 0.22 + 0.12 * random.unit())),
                            angle: Float(random.unit() * 2 * .pi),
                            transmission: isGap ? LayerStyle.crownTransmission
                                : SIMD3<Float>(0.08, 0.14, 0.04) * Float(0.7 + 0.6 * random.unit())))
                    }
                }
            }
        }
        return leaves
    }

    /// Cells whose leaves can reach `bounds`: the spread is clamped to three standard deviations,
    /// plus the longest leaf.
    static func cellRange(_ bounds: CGRect, style: LayerStyle, scale: Double) -> (x: ClosedRange<Int>, y: ClosedRange<Int>) {
        let margin = (1.5 * style.clusterRadius + style.leafLength.upperBound) * scale
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
