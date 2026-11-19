import CoreGraphics
import Foundation
import NagiKit
import Testing
@testable import KomorebiEffect

/// The tree's number (DECISIONS D28): it picks the canopy and nothing else.
struct TreeTests {
    func frame(tree: Double?) -> FrameState {
        FrameState(time: 0, deltaTime: 0, date: Date(), phase: .calm, presence: 1, depth: 60, appearance: .light,
                   parameters: tree.map { ["tree": .number($0)] } ?? [:], seed: 7)
    }

    @Test func treeIsTheCanopySeed() {
        #expect(Komorebi.tree(frame(tree: nil)) == 1)       // the author's tree, whatever the shared seed
        #expect(Komorebi.tree(frame(tree: 42)) == 42)
        #expect(Komorebi.tree(frame(tree: 900)) == 255)
        #expect(Komorebi.tree(frame(tree: .nan)) == 1)
    }

    @Test func sameTreeSameLeaves() {
        let bounds = CGRect(x: -2000, y: -2000, width: 4000, height: 4000)
        let style = LayerStyle.all[0]
        func leaves(_ seed: UInt64) -> [SIMD2<Float>] {
            Canopy.leaves(in: bounds, layer: 0, style: style, seed: seed, density: 1, scale: 1).map(\.center)
        }
        #expect(leaves(1) == leaves(1))
        #expect(leaves(1) != leaves(2))
    }

    @Test func userValues() {
        let spec = Komorebi.descriptor.parameters.first { $0.key == "tree" }!
        #expect(spec.validated(.number(3.6), forUser: true) == .number(4))
        #expect(spec.validated(.number(0), forUser: true) == .number(1))
        #expect(spec.validated(.number(300), forUser: true) == .number(255))
        #expect(spec.validated(.flag(true), forUser: true) == .number(1))
        // The trees that failed the flash check are not offered (D28).
        #expect(spec.validated(.number(35), forUser: true) == .number(36))
        #expect(spec.validated(.number(143), forUser: true) == .number(144))
        #expect(spec.validated(.number(252), forUser: true) == .number(253))
        #expect(spec.user?.keepsOnReset == true)
    }
}
