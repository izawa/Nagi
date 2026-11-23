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
    /// Set only by an effect that may flash more than the rule allows (SPEC 2.2): it starts off and
    /// shows this beside its switch, so the notice can be read before turning it on.
    public var photosensitivityNotice: LocalizedStringResource?

    public init(id: String, displayName: LocalizedStringResource, summary: LocalizedStringResource,
                layer: EffectLayer, capabilities: Set<Capability> = [], parameters: [ParameterSpec] = [],
                weatherHint: WeatherHint? = nil, photosensitivityNotice: LocalizedStringResource? = nil) {
        self.id = id
        self.displayName = displayName
        self.summary = summary
        self.layer = layer
        self.capabilities = capabilities
        self.parameters = parameters
        self.weatherHint = weatherHint
        self.photosensitivityNotice = photosensitivityNotice
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

    /// How a user sets it in Settings, if at all (SPEC 2.5, DECISIONS D26). Nil keeps it for the
    /// author's tuning (the gallery). `defaultValue` is the recommendation either way.
    public enum UserControl: Sendable {
        /// A slider over a range inside the tuning range.
        case slider(ClosedRange<Double>)
        /// Named steps, each a value of the slider.
        case steps([Step])
        /// The toggle as declared.
        case toggle
        /// A whole number in a range, typed in, or a different one picked at random by a button
        /// labelled `reroll` (komorebi's tree). Numbers in `skipping` are never offered. A choice,
        /// not a look: restoring the recommendation keeps it.
        case wholeNumber(ClosedRange<Int>, skipping: Set<Int> = [], reroll: LocalizedStringResource)

        /// Kept when the user restores the recommended values.
        public var keepsOnReset: Bool {
            if case .wholeNumber = self { true } else { false }
        }
    }

    public struct Step: Sendable {
        public var label: LocalizedStringResource
        public var value: Double
        public init(label: LocalizedStringResource, value: Double) {
            self.label = label
            self.value = value
        }
    }

    public var key: String
    public var label: LocalizedStringResource
    public var kind: Kind
    public var user: UserControl?

    public init(key: String, label: LocalizedStringResource, kind: Kind, user: UserControl? = nil) {
        self.key = key
        self.label = label
        self.kind = kind
        self.user = user
    }

    /// `value` made valid for this parameter: the right type, finite, within the range a user
    /// may set (or the tuning range), and a known choice; otherwise the default.
    public func validated(_ value: ParameterValue?, forUser: Bool) -> ParameterValue {
        switch (kind, value) {
        case let (.slider(range, _), .number(number)?) where number.isFinite:
            var allowed = range
            if forUser {
                switch user {
                case let .slider(userRange): allowed = userRange
                case let .steps(steps):
                    return steps.contains { $0.value == number } ? .number(number) : defaultValue
                case let .wholeNumber(userRange, skipping, _):
                    let whole = Int(min(max(number.rounded(), Double(userRange.lowerBound)), Double(userRange.upperBound)))
                    // A skipped number becomes the next one offered (or the one before, at the top).
                    let offered = (whole...userRange.upperBound).first { !skipping.contains($0) }
                        ?? (userRange.lowerBound...whole).last { !skipping.contains($0) }
                    return offered.map { .number(Double($0)) } ?? defaultValue
                default: break
                }
            }
            return .number(min(max(number, allowed.lowerBound), allowed.upperBound))
        case (.toggle, .flag?):
            return value!
        case let (.choice(options, _), .choice(key)?) where options.contains(where: { $0.key == key }):
            return .choice(key)
        default:
            return defaultValue
        }
    }

    public var defaultValue: ParameterValue {
        switch kind {
        case let .slider(_, value): .number(value)
        case let .toggle(value): .flag(value)
        case let .choice(_, value): .choice(value)
        }
    }
}

public enum ParameterValue: Hashable, Sendable, Codable {
    case number(Double)
    case flag(Bool)
    case choice(String)

    /// Saved as the bare value: a number, true/false, or a string (settings.json, D26).
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let flag = try? container.decode(Bool.self) {
            self = .flag(flag)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else {
            self = .choice(try container.decode(String.self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .number(number): try container.encode(number)
        case let .flag(flag): try container.encode(flag)
        case let .choice(key): try container.encode(key)
        }
    }

    /// A value typed on a command line: a number, `true`/`false`, or else a choice key.
    public init(parsing text: String) {
        if let number = Double(text) {
            self = .number(number)
        } else if text == "true" || text == "false" {
            self = .flag(text == "true")
        } else {
            self = .choice(text)
        }
    }
}

/// The weather an effect would like (SPEC 3.6): rain leans towards overcast.
public struct WeatherHint: Sendable {
    /// Added to the shared cloud cover, −1…1.
    public var cloudBias: Double
    public init(cloudBias: Double) { self.cloudBias = cloudBias }
}
