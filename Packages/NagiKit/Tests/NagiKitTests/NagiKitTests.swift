import NagiKit
import Testing

@Test func layersOrderBottomToTop() {
    #expect(EffectLayer.allCases.sorted() == [.surface, .light, .glass])
}

@Test func parameterDefaults() {
    let slider = ParameterSpec(key: "strength", label: "Strength", kind: .slider(range: 0...1, defaultValue: 0.7))
    let toggle = ParameterSpec(key: "moon", label: "Moon", kind: .toggle(defaultValue: true))
    #expect(slider.defaultValue == .number(0.7))
    #expect(toggle.defaultValue == .flag(true))
}

@Test func frameParameterLookup() {
    let frame = FrameState(time: 0, deltaTime: 0, date: .distantPast, phase: .calm, presence: 1, depth: 0,
                           appearance: .light, parameters: ["strength": .number(0.3)], seed: 1)
    #expect(frame.number("strength", default: 1) == 0.3)
    #expect(frame.number("missing", default: 0.5) == 0.5)
    #expect(frame.flag("strength", default: false) == false)
}

@Test func skyLightFadesTheSunInFrom5To10Degrees() {
    func weight(sunDegrees: Double) -> Double? {
        var environment = SharedEnvironment()
        environment.sun = CelestialPosition(altitude: sunDegrees * .pi / 180, azimuth: 0)
        environment.moon = CelestialPosition(altitude: -0.5, azimuth: 0)
        return SkyLight(environment, moonlight: true)?.weight
    }
    #expect(weight(sunDegrees: 5) == nil)
    #expect(abs(weight(sunDegrees: 7.5)! - 0.5) < 1e-9)
    #expect(weight(sunDegrees: 10) == 1)
}

@Test func skyLightIsTheMoonOnADarkNight() {
    var environment = SharedEnvironment()
    environment.sun = CelestialPosition(altitude: -20 * .pi / 180, azimuth: 0)
    environment.moon = CelestialPosition(altitude: 40 * .pi / 180, azimuth: 2)
    environment.moonPhase = 0.5
    let full = SkyLight(environment, moonlight: true)
    #expect(full?.isMoon == true && full?.weight == 1 && full?.position.azimuth == 2)
    #expect(SkyLight(environment, moonlight: false) == nil)
    environment.moonPhase = 0
    #expect(SkyLight(environment, moonlight: true) == nil)
    environment.moonPhase = 0.5
    environment.moon.altitude = -0.1
    #expect(SkyLight(environment, moonlight: true) == nil)
}
