import simd
import Testing
@testable import KomorebiEffect

/// The canopy generator (DECISIONS D18).
struct CanopyTests {
    /// A split gap keeps its area and its centre of light, and its two openings do not overlap.
    @Test func splitKeepsAreaAndCentre() {
        let style = LayerStyle.all[0]
        let gap = Leaf(center: SIMD2(100, -40), halfLength: 12, halfWidth: 5, angle: 0.7,
                       transmission: LayerStyle.crownTransmission)
        var splits = 0
        for seed in 0..<200 {
            var random = SplitMix(seed: UInt64(seed), layer: 0, cx: 0, cy: 0)
            let parts = Canopy.split(gap, heading: 1.2, style: style, scale: 1, random: &random)
            guard parts.count == 2 else { continue }
            splits += 1
            let areas = parts.map { $0.halfLength * $0.halfWidth }
            #expect(abs(areas[0] + areas[1] - gap.halfLength * gap.halfWidth) < 1e-3)
            let centre = (parts[0].center * areas[0] + parts[1].center * areas[1]) / (areas[0] + areas[1])
            #expect(simd_distance(centre, gap.center) < 1e-3)
            #expect(simd_distance(parts[0].center, parts[1].center) >= parts[0].halfLength + parts[1].halfLength - 1e-3)
        }
        #expect(splits > 80 && splits < 140)  // splitChance 0.55 of 200
    }
}
