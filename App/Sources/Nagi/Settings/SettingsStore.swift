import AppKit
import Foundation
import NagiCore
import NagiKit
import Observation

/// Loads, saves and applies the user's settings (DECISIONS D26). The file is settings.json in the
/// app's Application Support folder (inside the sandbox container); writes are coalesced and
/// atomic, and a file that cannot be read is kept aside, not overwritten.
@MainActor @Observable final class SettingsStore {
    private(set) var settings: NagiSettings
    private(set) var saveError: String?
    let effects: [any Effect.Type]
    /// The effects' descriptors, for views (a key path to a static member of an existential crashes
    /// Swift 6.4's SILGen, so views do not map over `effects`).
    var descriptors: [EffectDescriptor] { effects.map { $0.descriptor } }
    @ObservationIgnored private let url: URL
    @ObservationIgnored private weak var engine: NagiEngine?
    @ObservationIgnored private var pendingSave: Task<Void, Never>?
    @ObservationIgnored private var pendingExpiry: Task<Void, Never>?
    /// Changed since the last write (so quitting does not rewrite a file it did not change).
    @ObservationIgnored private var dirty = false
    /// A settings file existed but could not be read or kept aside: never overwrite it.
    @ObservationIgnored private var mustNotWrite = false
    /// Debug launch arguments that win over the settings for this session.
    @ObservationIgnored var overrides = Overrides()
    /// Called after the settings reach the engine (the menu's notes depend on them).
    @ObservationIgnored var didApply: (() -> Void)?

    struct Overrides {
        var parameters: [String: [String: ParameterValue]] = [:]
        var frameRateCap: Float?
        var sharing: NSWindow.SharingType?
        var holdForMedia: Bool?
        var strength: Double?
    }

    /// `fresh` starts from the defaults as on a first launch (the saved file is replaced at the
    /// first change); for checking the first-launch guide.
    init(effects: [any Effect.Type], url: URL = SettingsStore.defaultURL, fresh: Bool = false) {
        self.effects = effects
        self.url = url
        // Even when fresh, a file Nagi cannot read is kept aside first.
        let loaded = Self.load(from: url, effects: effects)
        settings = fresh ? NagiSettings().validated(effects: effects) : loaded.settings
        mustNotWrite = !loaded.writable
    }

    static var defaultURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appending(path: "Nagi/settings.json")
    }

    /// Changes the settings, applies them to the engine, and saves shortly after.
    func update(_ change: (inout NagiSettings) -> Void) {
        var next = settings
        change(&next)
        next = next.validated(effects: effects)
        guard next != settings else { return }
        settings = next
        dirty = true
        apply()
        scheduleSave()
    }

    /// Starts applying to `engine` (and does so now).
    func attach(_ engine: NagiEngine) {
        self.engine = engine
        apply()
    }

    /// The values the renderer uses for an effect: the user's, then any debug overrides.
    func parameters(for id: String) -> [String: ParameterValue] {
        var values = settings.effects[id] ?? [:]
        values.merge(overrides.parameters[id] ?? [:]) { _, debug in debug }
        return values
    }

    func apply() {
        guard let engine else { return }
        engine.configure { engine in
            engine.setTiming(onset: settings.onsetSeconds, depthGrowthRate: settings.deepening.growthRate)
            engine.strength = overrides.strength ?? settings.strength
            // At zero nothing can be seen: do not draw at all.
            engine.hold("zero strength", engine.strength <= 0)
            engine.suppressDuringMedia = overrides.holdForMedia ?? settings.holdForMedia
            engine.sharingType = overrides.sharing ?? (settings.showInScreenSharing ? .readOnly : .none)
            let known = Set(effects.map { $0.descriptor.id })
            for id in engine.renderer.effectIDs {
                if known.contains(id) {
                    engine.renderer.parameters[id] = parameters(for: id)
                } else {
                    // A debug effect (the patch): its launch values, then any overrides.
                    engine.renderer.parameters[id, default: [:]].merge(overrides.parameters[id] ?? [:]) { _, new in new }
                }
            }
            // Debug effects always count as on.
            let enabled = Set(engine.renderer.effectIDs.filter { !known.contains($0) || settings.isEnabled($0, among: effects) })
            engine.setEffects(enabled: enabled, mode: settings.effectMode == .random ? .random : .all)
            engine.hold("no effect", enabled.isEmpty)
            switch settings.pause {
            case .none: engine.pausedUntil = nil
            case let .until(date):
                engine.pausedUntil = date
                expirePause(at: date)
            case .untilResumed: engine.pausedUntil = .distantFuture
            }
            engine.frameRateCap = frameRateCap
        }
        didApply?()
    }

    /// Frames per second: 60, or 30 in Low Power Mode unless the user chose otherwise.
    var frameRateCap: Float {
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled && settings.lowPower == .reduceFrameRate
        return overrides.frameRateCap ?? (lowPower ? 30 : 60)
    }

    /// Writes now, if anything changed (on quit, on closing the settings window).
    func flush() {
        pendingSave?.cancel()
        pendingSave = nil
        if dirty { save() }
    }

    /// Clears a timed pause when it ends, so the menu and icon follow the engine.
    private func expirePause(at date: Date) {
        pendingExpiry?.cancel()
        pendingExpiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(date.timeIntervalSinceNow, 0) + 0.5))
            guard !Task.isCancelled else { return }
            self?.recheckPause()
        }
    }

    /// Clears a pause whose deadline has passed, or waits again for the rest (the wall clock
    /// moved, or the Mac slept).
    func recheckPause() {
        update { _ in }
        if case let .until(deadline) = settings.pause { expirePause(at: deadline) }
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    private func save() {
        guard !mustNotWrite else {
            saveError = "settings.json could not be read; it is left as it is"
            return
        }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(settings).write(to: url, options: .atomic)
            saveError = nil
            dirty = false
        } catch {
            saveError = error.localizedDescription
        }
    }

    /// The settings in `url`, and whether the file may be written: a missing file gives the
    /// defaults; an unreadable one (or one from a newer Nagi) is moved aside, and if that fails it
    /// is left alone and never overwritten.
    static func load(from url: URL, effects: [any Effect.Type]) -> (settings: NagiSettings, writable: Bool) {
        guard FileManager.default.fileExists(atPath: url.path) else { return (NagiSettings(), true) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: url), let settings = try? decoder.decode(NagiSettings.self, from: data),
           settings.schema <= NagiSettings.currentSchema {
            return (settings.validated(effects: effects), true)
        }
        // A new name each time, so an earlier backup is never lost.
        let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
            .replacingOccurrences(of: ":", with: "")
        let unique = UUID().uuidString.prefix(8)
        let aside = url.deletingLastPathComponent().appending(path: "settings.unreadable-\(stamp)-\(unique).json")
        let keptAside = (try? FileManager.default.moveItem(at: url, to: aside)) != nil
        return (NagiSettings(), keptAside)
    }
}
