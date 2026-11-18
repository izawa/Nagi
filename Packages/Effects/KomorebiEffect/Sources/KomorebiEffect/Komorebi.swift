import NagiKit

/// Komorebi, sunlight through leaves (SPEC 4.1). Built in M1 stages 3 and 4; draws nothing yet.
public final class Komorebi: Effect {
    public static let descriptor = EffectDescriptor(
        id: "komorebi",
        displayName: "木漏れ日",
        summary: "梢の隙間から落ちる日の光",
        layer: .light,
        capabilities: [.extendedRange],
        parameters: [
            ParameterSpec(key: "strength", label: "強さ", kind: .slider(range: 0...1, defaultValue: 1)),
            ParameterSpec(key: "density", label: "樹冠の密度", kind: .slider(range: 0...1, defaultValue: 0.6)),
            ParameterSpec(key: "wind", label: "風の強さ", kind: .slider(range: 0...1, defaultValue: 0.5)),
            ParameterSpec(key: "scale", label: "スケール", kind: .slider(range: 0.5...2, defaultValue: 1)),
            ParameterSpec(key: "moonlight", label: "月明かり", kind: .toggle(defaultValue: true)),
        ]
    )

    public init(context: EffectContext) throws {}
    public func update(_ frame: FrameState) {}
    public func render(_ frame: FrameState, view: DisplayView, encoder: any EffectEncoder) throws {}
    public func releaseResources() {}
}
