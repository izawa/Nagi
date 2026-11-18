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
