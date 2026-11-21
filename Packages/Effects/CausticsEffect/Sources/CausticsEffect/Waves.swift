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
            // 8 s for an 8 cm wave at full flow: the author found 6 s a little quick at stop W2.
            let period = 8 * (wavelength / 80).squareRoot() * (0.85 + 0.3 * random.next())
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

    /// How much a wave answers gusts and deepening, 0 for the long swell … 1 for the shortest
    /// ripples (wavelengths 12 cm and down to 4 cm).
    static func shortness(_ wave: Wave) -> Double {
        min(max((120 - wave.wavelength) / 80, 0), 1)
    }

    /// The waves as nagi deepens (M4-PLAN 4): at first only the long swell, its soft arcs; from
    /// 20 to 40 seconds the middle waves close the net; from 30 to 50 the short ripples join.
    static func deepened(_ waves: [Wave], depth: Double) -> [Wave] {
        func smooth(_ a: Double, _ b: Double, _ x: Double) -> Double {
            let t = min(max((x - a) / (b - a), 0), 1)
            return t * t * (3 - 2 * t)
        }
        let middle = smooth(20, 40, depth), short = smooth(30, 50, depth)
        // The longest wave is the swell whatever its length, so the opening always moves.
        let swell = waves.indices.max { waves[$0].wavelength < waves[$1].wavelength }
        return waves.indices.map { index in
            let wave = waves[index]
            var grown = wave
            guard index != swell else { return grown }
            let s = shortness(wave)
            // Long waves stay; the shorter the wave, the later it comes.
            grown.amplitude *= s < 0.5 ? 1 - (1 - middle) * (s / 0.5) : middle * (1 - (s - 0.5) / 0.5) + short * ((s - 0.5) / 0.5)
            return grown
        }
    }

    /// The root-mean-square slope of the surface.
    static func rmsSlope(_ waves: [Wave]) -> Double {
        (waves.reduce(0) { $0 + $1.slope * $1.slope } / 2).squareRoot()
    }

    /// The slowest flow, as a share of the full speed (the periods above).
    static let slowestFlow = 0.2

    /// How far the water has moved by wind-clock `time`, in seconds at full speed. The speed
    /// wanders between 20 % and 100 % of the full speed (the author's 15–75 % of the speed before
    /// stop W2), slowly rising and falling over one to three minutes. It is three sines summed, so
    /// any moment has a closed form and the water never jumps when the speed changes.
    static func flow(time: Double, seed: UInt64) -> Double {
        var random = SplitMix(seed: seed &+ 0xF10E)
        let middle = (1 + slowestFlow) / 2, swing = (1 - slowestFlow) / 2
        var moved = middle * time
        for (weight, period) in [(0.5, 170.0), (0.3, 110.0), (0.2, 70.0)] {
            let p = period * (0.85 + 0.3 * random.next()), start = random.next() * 2 * .pi
            let angle = (2 * .pi * time / p + start).truncatingRemainder(dividingBy: 2 * .pi)
            // ∫ sin(2π t / p + start) dt from 0 to time.
            moved += swing * weight * p / (2 * .pi) * (cos(start) - cos(angle))
        }
        return moved
    }

    /// Each wave's phase at `time` (seconds of flow), wrapped to one cycle in double precision
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
