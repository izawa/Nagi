import Foundation
import NagiKit

/// The rippled water surface (M4-PLAN 4): a few plane waves of different directions and
/// wavelengths, summed. Everything is decided by the seed, so any moment can be drawn directly.
///
/// The waves move far slower than real water: at its true speed (ω = √(g k)) one 8 cm wave alone
/// would sweep a caustic line across a pixel about four times a second, over the flash limit
/// (SPEC 2.2). Their periods are chosen for the eye instead, like the slowed gust fronts (D19).
struct Wave: Equatable {
    /// Unit direction of travel, ground coordinates (x east, y south; millimetres).
    var direction: SIMD2<Double>
    /// Radians per millimetre.
    var number: Double
    /// Millimetres.
    var amplitude: Double
    /// Radians per second of the wind clock.
    var angularFrequency: Double
    var phase: Double

    var wavelength: Double { 2 * .pi / number }
    /// The steepest slope the wave makes on its own.
    var slope: Double { amplitude * number }
}

enum WaveField {
    /// `count` waves with a root-mean-square surface slope of `slope`, from the seed: directions
    /// fanned around one heading (a breeze from one side), wavelengths from 4 to 24 cm.
    static func waves(count: Int, slope: Double, seed: UInt64) -> [Wave] {
        var random = SplitMix(seed: seed &+ 0xC0FFEE)
        let heading = random.next() * 2 * .pi
        var waves: [Wave] = []
        for index in 0..<max(count, 1) {
            // Spread evenly over the fan with a little jitter, so no two run side by side.
            let fan = count > 1 ? (Double(index) / Double(count - 1) - 0.5) : 0
            let angle = heading + fan * 2.4 + (random.next() - 0.5) * 0.3
            // Log-uniform wavelengths, shuffled against the angles.
            let wavelength = 40 * pow(6, random.next())
            let period = 6 * (wavelength / 80).squareRoot() * (0.85 + 0.3 * random.next())
            waves.append(Wave(direction: SIMD2(cos(angle), sin(angle)), number: 2 * .pi / wavelength,
                              amplitude: 1, angularFrequency: 2 * .pi / period, phase: random.next() * 2 * .pi))
        }
        // Each wave gets an equal share of the slope: RMS slope of a sum of sines is √(Σ s² / 2).
        let share = slope * (2 / Double(waves.count)).squareRoot()
        for index in waves.indices { waves[index].amplitude = share / waves[index].number }
        return waves
    }

    /// The mean wind that gives the full response (komorebi's, metres per second).
    static let fullWind = 3.5

    /// The waves as the mean wind leaves them (M4-PLAN 4): those running downwind grow, the
    /// others keep most of their height, so a turning wind does not spin the whole net.
    static func windy(_ waves: [Wave], wind: SIMD2<Double>) -> [Wave] {
        let speed = (wind * wind).sum().squareRoot()
        guard speed.isFinite, speed > 1e-6 else { return waves.map { var w = $0; w.amplitude *= 0.8; return w } }
        let heading = wind / speed, push = min(speed / fullWind, 1)
        return waves.map { wave in
            var grown = wave
            let downwind = max((wave.direction * heading).sum(), 0)
            grown.amplitude *= 0.8 + 0.5 * push * downwind
            return grown
        }
    }

    /// The root-mean-square slope of the surface.
    static func rmsSlope(_ waves: [Wave]) -> Double {
        (waves.reduce(0) { $0 + $1.slope * $1.slope } / 2).squareRoot()
    }

    /// Each wave's phase at `time` (wind-clock seconds), wrapped to one cycle in double precision
    /// so a long-running clock does not make the water stutter on the GPU.
    static func phases(_ waves: [Wave], time: Double) -> [Double] {
        waves.map { wave in
            let value = (wave.phase - wave.angularFrequency * time).truncatingRemainder(dividingBy: 2 * .pi)
            return value < 0 ? value + 2 * .pi : value
        }
    }

    /// Height (mm) and slope of the surface at a ground point, the same sum the shader makes.
    static func surface(_ waves: [Wave], phases: [Double], at point: SIMD2<Double>) -> (height: Double, gradient: SIMD2<Double>) {
        var height = 0.0, gradient = SIMD2<Double>(0, 0)
        for (wave, phase) in zip(waves, phases) {
            let theta = wave.number * (wave.direction * point).sum() + phase
            height += wave.amplitude * sin(theta)
            gradient += wave.amplitude * wave.number * cos(theta) * wave.direction
        }
        return (height, gradient)
    }
}

/// A small deterministic generator (the same seed, the same water).
struct SplitMix {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    /// 0 ..< 1.
    mutating func next() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53)
    }
}
