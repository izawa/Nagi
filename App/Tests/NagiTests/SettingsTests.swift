import EffectCatalog
import Foundation
import NagiKit
import Testing
@testable import Nagi

/// The settings file (DECISIONS D26).
struct SettingsTests {
    let effects = EffectCatalog.all
    /// On by default with the catalog this build has (moss only with the WithMoss trait).
    #if WithMoss
    let quiet = ["komorebi", "caustics", "fireflies", "moss"]
    #else
    let quiet = ["komorebi", "caustics", "fireflies"]
    #endif

    func decode(_ json: String) throws -> NagiSettings {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(NagiSettings.self, from: Data(json.utf8))
    }

    /// A file with only some fields loads, the rest take their defaults.
    @Test func missingFieldsTakeDefaults() throws {
        let settings = try decode(#"{"onsetSeconds": 10}"#)
        #expect(settings.onsetSeconds == 10)
        #expect(settings.strength == 1 && settings.holdForMedia && !settings.showInScreenSharing)
        #expect(settings.lowPower == .reduceFrameRate && settings.deepening == .normal)
    }

    /// Values are made valid: ranges, user ranges and steps, unknown effects and keys dropped.
    @Test func validation() throws {
        let raw = try decode("""
        {"onsetSeconds": 999, "strength": -2,
         "effects": {"komorebi": {"density": 5, "wind": 0.3, "moonlight": false, "exposure": 30},
                     "nosuch": {"x": 1}}}
        """)
        let valid = raw.validated(effects: effects)
        #expect(valid.onsetSeconds == 60)
        #expect(valid.strength == 0)
        let komorebi = try #require(valid.effects["komorebi"])
        #expect(komorebi["density"] == .number(1.2))          // the user range's top
        #expect(komorebi["wind"] == .number(0.5))             // not a step: the default
        #expect(komorebi["moonlight"] == .flag(false))
        #expect(komorebi["exposure"] == nil)                  // the author's tuning, not the user's
        #expect(valid.effects["nosuch"] == nil)
    }

    /// One bad value loses only itself.
    @Test func badValueAlone() throws {
        let settings = try decode(#"{"effects": {"komorebi": {"moonlight": null, "density": 1.1}, "old": null}}"#)
        #expect(settings.effects["komorebi"] == ["density": .number(1.1)])
        #expect(settings.effects["old"] == nil)
        // A damaged entry in the list of effects that are on does not switch everything on.
        let list = try decode(#"{"enabledEffects": [null, 3]}"#)
        #expect(list.enabledEffects == [])
        #expect(try decode("{}").enabledEffects == nil)
    }

    /// A file from before M2 (no list) turns on only the effects that need no permission, and the
    /// first switch starts from that list: adding rain never turns it on by itself (M2-PLAN 4.3).
    @Test func effectsNeedingPermissionStartOff() throws {
        let types: [any Effect.Type] = effects + [GlassStub.self]
        let old = try decode("{}").validated(effects: types)
        #expect(old.enabledEffects == quiet)
        var switched = try decode("{}")
        switched.setEnabled("komorebi", false, among: types)
        #expect(switched.enabledEffects == Array(quiet.dropFirst()))
        #expect(!NagiSettings().isEnabled("test.glass", among: types))
        #expect(try decode(#"{"enabledEffects": ["test.glass"]}"#).validated(effects: types).enabledEffects == ["test.glass"])
        #expect(try decode("{}").effectMode == .all)
    }

    /// An effect with a photosensitivity notice starts off even without needing a permission, and
    /// stays on once chosen (SPEC 2.2).
    @Test func effectsWithNoticeStartOff() throws {
        let types: [any Effect.Type] = effects + [FlashStub.self]
        #expect(!NagiSettings().isEnabled("test.flash", among: types))
        #expect(try decode("{}").validated(effects: types).enabledEffects == quiet)
        var chosen = try decode("{}")
        chosen.setEnabled("test.flash", true, among: types)
        #expect(chosen.validated(effects: types).enabledEffects == quiet + ["test.flash"])
    }

    /// A pause that has run out is cleared.
    @Test func pastPauseClears() {
        var settings = NagiSettings()
        settings.pause = .until(Date(timeIntervalSinceNow: -60))
        #expect(settings.validated(effects: effects).pause == .none)
        settings.pause = .untilResumed
        #expect(settings.validated(effects: effects).pause == .untilResumed)
    }

    /// Saved and loaded, the settings are the same; a file Nagi cannot read is kept aside.
    @MainActor @Test func roundTripAndUnreadable() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let url = folder.appending(path: "settings.json")
        let store = SettingsStore(effects: effects, url: url)
        store.update {
            $0.onsetSeconds = 7
            $0.pause = .untilResumed
            $0.effects["komorebi"] = ["wind": .number(1)]
        }
        store.flush()
        #expect(SettingsStore.load(from: url, effects: effects).settings == store.settings)
        // Quitting without a change does not rewrite the file.
        try Data("{}".utf8).write(to: url)
        store.flush()
        #expect(try Data(contentsOf: url) == Data("{}".utf8))
        // Two unreadable files: both are kept aside.
        func backups() throws -> Int {
            try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix("settings.unreadable-") }.count
        }
        try Data("not json".utf8).write(to: url)
        #expect(SettingsStore.load(from: url, effects: effects).settings == NagiSettings())
        #expect(try backups() == 1)
        try Data("still not json".utf8).write(to: url)
        _ = SettingsStore.load(from: url, effects: effects)
        #expect(try backups() == 2)
    }
}

/// An effect that needs the screen behind it, as rain will.
private final class GlassStub: Effect {
    static let descriptor = EffectDescriptor(id: "test.glass", displayName: "Glass", summary: "",
                                             layer: .glass, capabilities: [.backdrop])
    init(context: EffectContext) throws {}
    func update(_ frame: FrameState) {}
    func render(_ frame: FrameState, view: DisplayView, encoder: any EffectEncoder) throws {}
    func releaseResources() {}
}

/// An effect that needs no permission but may flash beyond the rule.
private final class FlashStub: Effect {
    static let descriptor = EffectDescriptor(id: "test.flash", displayName: "Flash", summary: "",
                                             layer: .light, photosensitivityNotice: "Flashes")
    init(context: EffectContext) throws {}
    func update(_ frame: FrameState) {}
    func render(_ frame: FrameState, view: DisplayView, encoder: any EffectEncoder) throws {}
    func releaseResources() {}
}
