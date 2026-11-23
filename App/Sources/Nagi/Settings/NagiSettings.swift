import Foundation
import NagiKit

/// What the user has chosen (SPEC 2.4, 2.5; DECISIONS D26). Saved as settings.json; a missing
/// field takes its default, so older files still load.
struct NagiSettings: Codable, Equatable {
    static let currentSchema = 1

    enum Pause: Codable, Equatable {
        case none
        case until(Date)
        case untilResumed
    }

    enum Deepening: String, Codable, CaseIterable {
        case normal, slow
        var growthRate: Double { self == .normal ? 1 : 0.5 }
    }

    /// How the enabled effects show (SPEC 2.3): all layered, or one drawn at random.
    enum EffectMode: String, Codable, CaseIterable {
        case all, random
    }

    enum LowPower: String, Codable, CaseIterable {
        /// Draw at 30 fps instead of 60 (one quality step lower, SPEC 2.2).
        case reduceFrameRate
        case asUsual
    }

    var schema = Self.currentSchema
    var onboarded = false
    /// The effects the user turned on. Nil (a file from before M2, or none yet) means the
    /// effects that need no permission (`defaultEnabled`): adding rain must not turn it on.
    var enabledEffects: [String]?
    var effectMode = EffectMode.all
    /// Screen Recording was asked for once (the system shows its dialog only the first time).
    var screenRecordingAsked = false
    var pause = Pause.none
    var onsetSeconds = 3.0
    var deepening = Deepening.normal
    var strength = 1.0
    var holdForMedia = true
    var showInScreenSharing = false
    var lowPower = LowPower.reduceFrameRate
    /// Per effect, the user's values by parameter key (only user-facing parameters).
    var effects: [String: [String: ParameterValue]] = [:]

    init() {}

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = NagiSettings()
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        schema = value(.schema, defaults.schema)
        onboarded = value(.onboarded, defaults.onboarded)
        // Entry by entry: a damaged entry must not turn the list into "all effects on" (nil).
        enabledEffects = value(.enabledEffects, [LenientID]?.none)?.compactMap(\.id)
        effectMode = value(.effectMode, defaults.effectMode)
        screenRecordingAsked = value(.screenRecordingAsked, defaults.screenRecordingAsked)
        pause = value(.pause, defaults.pause)
        onsetSeconds = value(.onsetSeconds, defaults.onsetSeconds)
        deepening = value(.deepening, defaults.deepening)
        strength = value(.strength, defaults.strength)
        holdForMedia = value(.holdForMedia, defaults.holdForMedia)
        showInScreenSharing = value(.showInScreenSharing, defaults.showInScreenSharing)
        lowPower = value(.lowPower, defaults.lowPower)
        // Each value on its own, so one bad value does not lose its neighbours.
        let lenient = value(.effects, [String: LenientRecord]())
        effects = lenient.compactMapValues { $0.values?.compactMapValues(\.value) }
    }

    /// Every value made valid against the effects the app has: numbers in range, unknown effects
    /// and parameters dropped, a past pause cleared.
    func validated(effects types: [any Effect.Type], now: Date = Date()) -> NagiSettings {
        var valid = self
        valid.schema = Self.currentSchema
        valid.onsetSeconds = onsetSeconds.isFinite ? min(max(onsetSeconds.rounded(), 1), 60) : 3
        valid.strength = strength.isFinite ? min(max(strength, 0), 1) : 1
        if case let .until(date) = pause, date <= now { valid.pause = .none }
        let ids = Set(types.map { $0.descriptor.id })
        valid.enabledEffects = (enabledEffects ?? Self.defaultEnabled(types)).filter { ids.contains($0) }
        valid.effects = [:]
        for type in types {
            let specs = type.descriptor.parameters.filter { $0.user != nil }
            guard let saved = effects[type.descriptor.id] else { continue }
            var values: [String: ParameterValue] = [:]
            for spec in specs where saved[spec.key] != nil {
                values[spec.key] = spec.validated(saved[spec.key], forUser: true)
            }
            if !values.isEmpty { valid.effects[type.descriptor.id] = values }
        }
        return valid
    }

    /// Valid settings always hold a list; before validation, nil reads as `defaultEnabled`.
    func isEnabled(_ id: String, among types: [any Effect.Type]) -> Bool {
        (enabledEffects ?? Self.defaultEnabled(types)).contains(id)
    }

    /// On by default: the effects that need no permission (SPEC 5: rain is for those who allow it)
    /// and carry no photosensitivity notice (SPEC 2.2: those are turned on by choice).
    static func defaultEnabled(_ types: [any Effect.Type]) -> [String] {
        types.map { $0.descriptor }
            .filter { !$0.capabilities.contains(.backdrop) && $0.photosensitivityNotice == nil }
            .map { $0.id }
    }
}

/// A saved effect ID, or nil if the entry is not a string.
private struct LenientID: Decodable {
    let id: String?
    init(from decoder: any Decoder) throws {
        id = try? String(from: decoder)
    }
}

/// One effect's saved values, or nil if the record is not an object.
private struct LenientRecord: Decodable {
    let values: [String: Lenient]?
    init(from decoder: any Decoder) throws {
        values = try? [String: Lenient](from: decoder)
    }
}

/// A saved parameter value, or nil if it is not one (null, an object, …).
private struct Lenient: Decodable {
    let value: ParameterValue?
    init(from decoder: any Decoder) throws {
        value = try? ParameterValue(from: decoder)
    }
}

