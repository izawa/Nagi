import CoreGraphics
import Foundation
import Metal
import NagiKit

/// A string from this package's catalog (Resources/Localizable.xcstrings).
func localized(_ key: String.LocalizationValue) -> LocalizedStringResource {
    LocalizedStringResource(key, bundle: .atURL(Bundle.module.bundleURL))
}

/// Moss on the windows left still (SPEC 4.3): along the top edge and the upper corners of each
/// window, and in the screen's bottom corners, growing from 10 minutes to 2 hours. Each patch is
/// drawn only where it is (an instanced quad); what windows in front cover is left out.
/// Moss grows in colonies that spread sideways from where they start, each one of three mosses
/// (M3-LOG stage B0); the shader works all of it out from the window's id and age.
public final class Moss: Effect {
    public static let descriptor = EffectDescriptor(
        id: "moss",
        displayName: localized("苔"),
        summary: localized("動かしていないウィンドウの縁に生える苔"),
        layer: .surface,
        capabilities: [.windows])

    /// Points: how far moss reaches out from an edge and in over a window (SPEC 4.3), the window's
    /// assumed corner radius (checkpoint H), and how far down the sides the upper corners wrap.
    static let outward = 20.0
    static let inward = 8.0
    static let cornerRadius = 16.0
    static let wrap = 28.0
    /// The screen's corners: how far moss spreads along the bottom and up the side.
    static let cornerSize = CGSize(width: 72, height: 72)
    /// Windows in front a patch is tested against; more are left out (16 windows over one band).
    static let frontCapacity = 16

    /// One patch for the shader, in the display's pixels: the quad to draw, the window (or the
    /// screen corner's area) it grows from, then seed, growth, kind (0 window, 1 bottom-left
    /// corner, 2 bottom-right corner) and the number of front rectangles that follow, and the age.
    struct Instance {
        var quad: SIMD4<Float>
        var base: SIMD4<Float>
        var info: SIMD4<Float>
        /// The window's age in seconds (sporophytes come with age past full growth).
        var extra: SIMD4<Float>
        var fronts: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>,
                     SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>,
                     SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>,
                     SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)
    }

    struct Uniforms {
        var scale: Float
        var cornerRadius: Float
        var inward: Float
        var precipitation: Float
        var depth: Float
    }

    /// Where moss may grow, in desktop points: a band along a window's top or a screen corner,
    /// with the rectangles in front that cover it.
    struct Patch: Equatable {
        enum Kind: Int { case window = 0, bottomLeft = 1, bottomRight = 2 }
        var kind: Kind
        var quad: CGRect
        var base: CGRect
        var seed: UInt32
        var age: Double
        var fronts: [CGRect]
    }

    /// Growth from 10 minutes to 2 hours (SPEC 4.3, M3-PLAN 5.1).
    static func growth(age: Double) -> Double {
        guard age.isFinite else { return age > 0 ? 1 : 0 }
        let t = min(max((age - 600) / (7200 - 600), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// The patches seen in `snapshot`: one per ordinary window whose band is not wholly covered,
    /// and the bottom corners of each display's usable area.
    static func patches(_ snapshot: WindowSnapshot) -> [Patch] {
        // A window over a whole display (full screen) has square corners; the shader rounds every
        // window, so such a window grows by enough for its rounded shape to cover its corners.
        let square = cornerRadius * (2.squareRoot() - 1) + 0.5
        let covers = snapshot.frontToBack.map { window in
            snapshot.usableAreas.contains { window.frame.contains($0) }
                ? window.frame.insetBy(dx: -square, dy: -square) : window.frame
        }
        let windows = snapshot.frontToBack
        func fronts(of quad: CGRect, before index: Int) -> [CGRect] {
            covers.prefix(index).filter { $0.intersects(quad) }
        }
        var patches: [Patch] = []
        for (index, window) in windows.enumerated() where window.role == .surface {
            let f = window.frame
            let quad = CGRect(x: f.minX - outward, y: f.minY - outward, width: f.width + 2 * outward,
                              height: outward + wrap)
            let covering = fronts(of: quad, before: index)
            if covering.contains(where: { Self.roundedContains($0, quad) }) { continue }
            patches.append(Patch(kind: .window, quad: quad, base: f, seed: window.id, age: window.stationarySeconds,
                                 fronts: covering))
        }
        for (number, area) in snapshot.usableAreas.enumerated() {
            for kind in [Patch.Kind.bottomLeft, .bottomRight] {
                let x = kind == .bottomLeft ? area.minX : area.maxX - cornerSize.width
                let quad = CGRect(x: x, y: area.maxY - cornerSize.height, width: cornerSize.width, height: cornerSize.height)
                let covering = fronts(of: quad, before: windows.count)
                if covering.contains(where: { Self.roundedContains($0, quad) }) { continue }
                patches.append(Patch(kind: kind, quad: quad, base: area, seed: UInt32(number * 2 + kind.rawValue) &+ 0x9E37,
                                     age: snapshot.desktopSeconds, fronts: covering))
            }
        }
        return patches
    }

    /// Whether a window, with the corner radius the shader gives it, covers all of `rect`: its
    /// four corners inside the rounded rectangle (it is convex).
    static func roundedContains(_ window: CGRect, _ rect: CGRect) -> Bool {
        let r = cornerRadius
        func inside(_ p: CGPoint) -> Bool {
            let cx = min(max(p.x, window.minX + r), window.maxX - r), cy = min(max(p.y, window.minY + r), window.maxY - r)
            return window.contains(p) && hypot(p.x - cx, p.y - cy) <= r
        }
        return [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)].allSatisfy(inside)
    }

    private let pipeline: any MTLRenderPipelineState
    private let device: any MTLDevice

    public init(context: EffectContext) throws {
        device = context.device
        let library = try context.device.makeDefaultLibrary(bundle: Bundle.module)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "mossVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "mossFragment")
        descriptor.colorAttachments[0].pixelFormat = context.pixelFormat
        descriptor.colorAttachments[0].usePremultipliedSourceOver()
        pipeline = try context.device.makeRenderPipelineState(descriptor: descriptor)
    }

    public func update(_ frame: FrameState) {}

    public func render(_ frame: FrameState, view: DisplayView, encoder: any EffectEncoder) throws {
        guard let snapshot = frame.windows else { return }
        let origin = view.frameInDesktop.origin, scale = view.scale
        func pixels(_ rect: CGRect) -> SIMD4<Float> {
            SIMD4(Float(rect.minX - origin.x), Float(rect.minY - origin.y),
                  Float(rect.maxX - origin.x), Float(rect.maxY - origin.y)) * Float(scale)
        }
        // Back to front, so where two windows' moss meet outside both, the front one's lies on top.
        let visible = Self.patches(snapshot).reversed().filter { $0.quad.intersects(view.frameInDesktop) && Self.growth(age: $0.age) > 0 }
        guard !visible.isEmpty else { return }
        var instances = visible.map { patch -> Instance in
            var fronts = [SIMD4<Float>](repeating: .zero, count: Self.frontCapacity)
            for (slot, rect) in patch.fronts.prefix(Self.frontCapacity).enumerated() { fronts[slot] = pixels(rect) }
            return Instance(quad: pixels(patch.quad), base: pixels(patch.base),
                            info: SIMD4(Float(patch.seed % 65536), Float(Self.growth(age: patch.age)),
                                        Float(patch.kind.rawValue), Float(min(patch.fronts.count, Self.frontCapacity))),
                            extra: SIMD4(Float(patch.age.isFinite ? min(patch.age, 1e7) : 0), 0, 0, 0),
                            fronts: (fronts[0], fronts[1], fronts[2], fronts[3], fronts[4], fronts[5], fronts[6], fronts[7],
                                     fronts[8], fronts[9], fronts[10], fronts[11], fronts[12], fronts[13], fronts[14], fronts[15]))
        }
        guard let buffer = device.makeBuffer(bytes: &instances, length: MemoryLayout<Instance>.stride * instances.count,
                                             options: .storageModeShared) else { return }
        var uniforms = Uniforms(scale: Float(scale), cornerRadius: Float(Self.cornerRadius), inward: Float(Self.inward),
                                precipitation: Float(frame.environment.precipitation),
                                depth: Float(frame.depth.isFinite ? frame.depth : 0))
        var size = SIMD2<Float>(Float(encoder.outputSize.x), Float(encoder.outputSize.y))
        encoder.renderToOutput { pass in
            pass.setRenderPipelineState(pipeline)
            pass.setVertexBuffer(buffer, offset: 0, index: 0)
            pass.setVertexBytes(&size, length: MemoryLayout<SIMD2<Float>>.size, index: 1)
            pass.setFragmentBuffer(buffer, offset: 0, index: 0)
            pass.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            pass.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: instances.count)
        }
    }

    public func releaseResources() {}
}
