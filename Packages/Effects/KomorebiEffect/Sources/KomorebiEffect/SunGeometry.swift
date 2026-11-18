import Foundation
import simd

/// The pinhole geometry of one canopy layer under the current sun (SPEC 4.1).
///
/// The screen is treated as the ground, seen from above, with north at the top: x points east,
/// y south (DECISIONS). A layer's occlusion mask is drawn in a frame turned to the sun's
/// azimuth, `u` across it and `v` along it, so the image of the sun disk is an ellipse whose axes
/// lie along the mask's rows and columns.
struct LayerGeometry: Equatable {
    /// Unit vectors in screen millimetres: across the azimuth, and along it towards the sun.
    let across: SIMD2<Double>
    let along: SIMD2<Double>
    /// Where the layer's shadow falls relative to the layer, millimetres (away from the sun).
    let offset: SIMD2<Double>
    /// Millimetres per mask texel.
    let stride: Double
    /// Semi-axes of the sun's image, in mask texels: across and along the azimuth.
    let semiAcross: Double
    let semiAlong: Double

    static let sunAngularDiameter = 0.0093

    /// - Parameters:
    ///   - height: metres above the screen.
    ///   - altitude, azimuth: the sun, radians; altitude must be above the cutoff.
    ///   - baseStride: the finest mask texel for this layer, millimetres.
    ///   - texelsAlong: the sun's image is drawn at most this many texels long.
    init(height: Double, altitude: Double, azimuth: Double, baseStride: Double, texelsAlong: Double = 24) {
        let sinAltitude = sin(altitude)
        along = SIMD2(sin(azimuth), -cos(azimuth))
        across = SIMD2(cos(azimuth), sin(azimuth))
        offset = -along * (height * 1000 / tan(altitude))
        let diameterAcross = Self.sunAngularDiameter * height * 1000 / sinAltitude
        let diameterAlong = diameterAcross / sinAltitude
        stride = max(baseStride, diameterAlong / texelsAlong)
        semiAcross = diameterAcross / 2 / stride
        semiAlong = diameterAlong / 2 / stride
    }

    /// Mask texel coordinates of a ground point (millimetres) whose occluder sits above it.
    func maskCoordinates(ofGround point: SIMD2<Double>) -> SIMD2<Double> {
        let p = point - offset
        return SIMD2(simd_dot(p, across), simd_dot(p, along)) / stride
    }

    /// Mask texel coordinates of a point on the layer itself (millimetres).
    func maskCoordinates(ofLayer point: SIMD2<Double>) -> SIMD2<Double> {
        SIMD2(simd_dot(point, across), simd_dot(point, along)) / stride
    }

    /// The layer region (millimetres, axis-aligned) whose shadows reach the given ground rectangle,
    /// padded by the blur; `imageScale` is the largest scale the filter applies to the sun's image.
    func layerBounds(forGround rect: CGRect, imageScale: Double = 1) -> CGRect {
        let pad = (semiAlong * imageScale + 2) * stride
        // A ground point is lit through the layer point `ground − offset`.
        return rect.offsetBy(dx: -offset.x, dy: -offset.y).insetBy(dx: -pad, dy: -pad)
    }
}
