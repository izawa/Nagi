import AppKit
import NagiKit
import SwiftUI

/// The menu-bar menu (SPEC 2.4, DECISIONS D26): the effects, see it now, pause, settings, quit.
struct MenuContent: View {
    let delegate: AppDelegate
    var store: SettingsStore { delegate.settings }

    var body: some View {
        // The effects' notes (after sunset, komorebi shows nothing): informational, not a command.
        ForEach(delegate.notes.lines, id: \.self) { Text($0) }
        if !delegate.notes.lines.isEmpty { Divider() }
        EffectToggles(store: store)
        Divider()
        Button(String(localized: "今すぐ見る", bundle: .module)) { delegate.engine?.preview() }
            .disabled(delegate.windowsHoldOff || store.settings.strength <= 0
                || !store.settings.anyEnabled(store.effects) || store.settings.isPaused(at: Date()))
        pause
        Divider()
        Button(String(localized: "設定…", bundle: .module)) { delegate.showSettings() }
            .keyboardShortcut(",")
        if AppDelegate.galleryAllowed {
            // A debug tool: not translated (DECISIONS D24).
            Button { delegate.showGallery() } label: { Text(verbatim: "ギャラリー…") }
        }
        Divider()
        Button(String(localized: "凪を終了", bundle: .module)) { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    @ViewBuilder private var pause: some View {
        if store.settings.isPaused(at: Date()) {
            Text(Self.pausedLabel(store.settings.pause))
            Button(String(localized: "再開", bundle: .module)) { store.update { $0.pause = .none } }
        } else {
            Menu(String(localized: "一時停止", bundle: .module)) {
                Button(String(localized: "1 時間", bundle: .module)) {
                    store.update { $0.pause = .until(Date(timeIntervalSinceNow: 3600)) }
                }
                Button(String(localized: "今日いっぱい", bundle: .module)) {
                    store.update { $0.pause = .until(Self.endOfToday()) }
                }
                Button(String(localized: "再開するまで", bundle: .module)) {
                    store.update { $0.pause = .untilResumed }
                }
            }
        }
    }

    static func pausedLabel(_ pause: NagiSettings.Pause) -> String {
        switch pause {
        case let .until(date):
            String(format: String(localized: "%@ まで一時停止中", bundle: .module),
                   date.formatted(date: .omitted, time: .shortened))
        default:
            String(localized: "再開するまで一時停止中", bundle: .module)
        }
    }

    /// The next local midnight (a daylight-saving day is still the rest of today).
    static func endOfToday(now: Date = Date(), calendar: Calendar = .current) -> Date {
        calendar.nextDate(after: now, matching: DateComponents(hour: 0, minute: 0), matchingPolicy: .nextTime)
            ?? now.addingTimeInterval(86400)
    }
}

/// A switch per effect (the menu and the first-launch guide).
struct EffectToggles: View {
    let store: SettingsStore
    var body: some View {
        ForEach(store.descriptors, id: \.id) { descriptor in
            Toggle(isOn: Binding(get: { store.settings.isEnabled(descriptor.id) },
                                 set: { on in store.update { $0.setEnabled(descriptor.id, on, among: store.effects) } })) {
                Text(descriptor.displayName)
            }
        }
    }
}

/// The menu-bar icon: a leaf, with a pause mark while paused.
struct MenuIcon: View {
    let store: SettingsStore
    var body: some View {
        Image(nsImage: store.settings.isPaused(at: Date()) ? MenuGlyph.paused : MenuGlyph.normal)
            .accessibilityLabel(store.settings.isPaused(at: Date())
                ? String(localized: "凪(一時停止中)", bundle: .module) : String(localized: "凪", bundle: .module))
    }
}

extension NagiSettings {
    /// Paused now (a deadline in the past no longer counts).
    func isPaused(at now: Date) -> Bool {
        switch pause {
        case .none: false
        case let .until(date): date > now
        case .untilResumed: true
        }
    }

    func anyEnabled(_ types: [any Effect.Type]) -> Bool {
        types.contains { isEnabled($0.descriptor.id) }
    }

    mutating func setEnabled(_ id: String, _ on: Bool, among types: [any Effect.Type]) {
        var ids = enabledEffects ?? types.map { $0.descriptor.id }
        ids.removeAll { $0 == id }
        if on { ids.append(id) }
        enabledEffects = ids
    }
}
