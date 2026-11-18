import Foundation

/// What an effect declares about itself (SPEC 3.4).
public struct EffectDescriptor: Sendable {
    /// A stable id such as "komorebi"; also the key for saved parameters.
    public var id: String
    public var displayName: LocalizedStringResource
    public var summary: LocalizedStringResource
    public var layer: EffectLayer
    public var capabilities: Set<Capability>
    public var parameters: [ParameterSpec]
    public var weatherHint: WeatherHint?

    public init(id: String, displayName: LocalizedStringResource, summary: LocalizedStringResource,
                layer: EffectLayer, capabilities: Set<Capability> = [], parameters: [ParameterSpec] = [],
                weatherHint: WeatherHint? = nil) {
        self.id = id
        self.displayName = displayName
        self.summary = summary
        self.layer = layer
        self.capabilities = capabilities
        self.parameters = parameters
        self.weatherHint = weatherHint
    }
}

/// Where an effect sits in the composite, bottom to top (SPEC 3.5).
public enum EffectLayer: Int, Comparable, Sendable, CaseIterable {
    /// On the surface of windows: moss, fallen leaves.
    case surface
    /// Light falling on everything: komorebi.
    case light
    /// On the glass of the display: raindrops.
    case glass

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public enum Capability: Hashable, Sendable {
    /// The screen under this layer, as a texture (needs Screen Recording; M2).
    case backdrop
    /// The window list (M3).
    case windows
    /// Values above SDR white where the display allows it.
    case extendedRange
}

/// A parameter the settings window generates a control for (SPEC 2.5, 3.4).
public struct ParameterSpec: Sendable {
    public enum Kind: Sendable {
        case slider(range: ClosedRange<Double>, defaultValue: Double)
        case toggle(defaultValue: Bool)
        case choice(options: [Option], defaultValue: String)
    }

    public struct Option: Sendable {
        public var key: String
        public var label: LocalizedStringResource
        public init(key: String, label: LocalizedStringResource) {
            self.key = key
            self.label = label
        }
    }

    public var key: String
    public var label: LocalizedStringResource
    public var kind: Kind

    public init(key: String, label: LocalizedStringResource, kind: Kind) {
        self.key = key
        self.label = label
        self.kind = kind
    }

    public var defaultValue: ParameterValue {
        switch kind {
        case let .slider(_, value): .number(value)
        case let .toggle(value): .flag(value)
        case let .choice(_, value): .choice(value)
        }
    }
}

public enum ParameterValue: Hashable, Sendable {
    case number(Double)
    case flag(Bool)
    case choice(String)
}

/// The weather an effect would like (SPEC 3.6): rain leans towards overcast.
public struct WeatherHint: Sendable {
    /// Added to the shared cloud cover, −1…1.
    public var cloudBias: Double
    public init(cloudBias: Double) { self.cloudBias = cloudBias }
}
