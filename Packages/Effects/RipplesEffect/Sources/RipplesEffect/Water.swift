import Foundation

/// The water a drop falls into (M6-PLAN 2): real water, linear capillary-gravity waves. Lengths in
/// metres, times in seconds.
struct Water: Equatable {
    static let gravity = 9.81
    /// Surface tension over density (0.072 N/m / 1000 kg/m³).
    static let tensionOverDensity = 0.072 / 1000
    /// Kinematic viscosity.
    static let viscosity = 1e-6
    static let refractiveIndex = 1.333

    /// The water's depth, which sets how the long waves travel.
    var depth = 0.020
    /// The width (standard deviation) of the downward push a drop gives the surface.
    var impulseWidth = 0.003
    /// How much of the short waves (3 cm down to 1.6 cm and shorter) to keep: 1 is real water.
    var shortWaves = 1.0
    /// The surface film: 0 is perfectly clean water (only the bulk's viscosity damps the waves), 1
    /// a surface that does not stretch, as a little dust or oil makes ordinary water. The film
    /// damps a wave at k √(νω/8) per second, several times the bulk's 2νk² for ripples.
    var film = 0.0

    /// Angular frequency of a wave of wavenumber k: ω² = (g k + σ/ρ k³) tanh(k H).
    func omega(_ k: Double) -> Double {
        ((Self.gravity * k + Self.tensionOverDensity * k * k * k) * tanh(k * depth)).squareRoot()
    }

    /// The drop's push in wavenumbers (Hankel transform of the initial vertical speed): a Gaussian
    /// dent with a shallow skirt twice as wide, so the water's volume does not change (W(0) = 0).
    func impulse(_ k: Double) -> Double {
        let s = impulseWidth
        return s * s * (-exp(-k * k * s * s / 2) + exp(-2 * k * k * s * s))
    }

    /// Wavenumbers beyond this carry nothing of the push (its spectrum is down to e^-10 there).
    var largestWavenumber: Double { 4.5 / impulseWidth }

    /// The integrand of `radialSlope` without J1(kr), for a drop of this age: what the shader sums
    /// against J1 at each radius, k = (i + 0.5) dk. Fine enough in k that J1(kr) is sampled well
    /// out to `reach`.
    func slopeCoefficients(age t: Double, reach: Double, push: Double) -> (dk: Double, values: [Float]) {
        let dk = min(1, Double.pi / (2 * reach))
        let steps = Int((largestWavenumber / dk).rounded(.up))
        let values = (0..<steps).map { i -> Float in
            let k = (Double(i) + 0.5) * dk
            let w = omega(k)
            return Float(-push * dk * impulse(k) * shortWeight(k) * sin(w * t) / w * decay(k, omega: w, age: t) * k * k)
        }
        return (dk, values)
    }

    /// How much of a wave of wavenumber k is left after `age` seconds: the bulk's viscosity and the film.
    func decay(_ k: Double, omega w: Double, age t: Double) -> Double {
        exp(-(2 * Self.viscosity * k * k + film * k * (Self.viscosity * w / 8).squareRoot()) * t)
    }

    /// 1 for long waves, `shortWaves` for waves of 1.6 cm and shorter, smooth between 3 and 1.6 cm.
    func shortWeight(_ k: Double) -> Double {
        let t = min(max((k - 2 * .pi / 0.03) / (2 * .pi / 0.016 - 2 * .pi / 0.03), 0), 1)
        return 1 - (1 - shortWaves) * t * t * (3 - 2 * t)
    }

    /// Height at the centre at time t for a unit push: ∫ W(k) sin(ωt)/ω e^(−2νk²t) k dk.
    func centreHeight(at t: Double, steps: Int = 4000) -> Double {
        let dk = largestWavenumber / Double(steps)
        var sum = 0.0
        for i in 0..<steps {
            let k = (Double(i) + 0.5) * dk
            let w = omega(k)
            sum += impulse(k) * sin(w * t) / w * decay(k, omega: w, age: t) * k
        }
        return sum * dk
    }

    /// The push that makes a dent this deep at the centre (the deepest point within 0.1 s).
    func pushScale(forDent dent: Double) -> Double {
        let deepest = stride(from: 0.002, through: 0.1, by: 0.002).map { abs(centreHeight(at: $0)) }.max() ?? 0
        return deepest > 0 ? dent / deepest : 0
    }

    /// The radial slope ∂h/∂r at r and t for a unit push: −∫ W(k) sin(ωt)/ω e^(−2νk²t) J1(kr) k² dk,
    /// from the same coefficients the shader sums.
    func radialSlope(at r: Double, time t: Double) -> Double {
        let (dk, values) = slopeCoefficients(age: t, reach: max(r, 0.05), push: 1)
        return values.enumerated().reduce(0) { $0 + Double($1.element) * j1((Double($1.offset) + 0.5) * dk * r) }
    }

    /// How far out a drop's waves matter at this age: past this the waves left are faint.
    static func reach(age: Double) -> Double { 0.3 * age + 0.05 }
}
