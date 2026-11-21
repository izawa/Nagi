import AppKit
import NagiKit
import SwiftUI

/// The menu-bar panel (SPEC 2.4, DECISIONS D26, D34): the effects, see it now, pause, settings,
/// quit. A panel rather than a menu, so several effects can be switched without reopening it;
/// what leads elsewhere closes it first.
struct MenuContent: View {
    let delegate: AppDelegate
    var store: SettingsStore { delegate.settings }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            EffectToggles(store: store, screenRecording: delegate.screenRecording) {
                Self.closePanel()
                delegate.showSettings(tab: .permissions)
            }
            Toggle(String(localized: "1 つを選んで出す", bundle: .module), isOn: Binding(
                get: { store.settings.effectMode == .random },
                set: { on in store.update { $0.effectMode = on ? .random : .all } }))
            // The effects' notes (after sunset, komorebi shows nothing): informational, not a
            // command. Below the switches, so a note coming or going never moves them.
            ForEach(delegate.notes.lines, id: \.self) { line in
                Text(line).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            row(String(localized: "今すぐ見る", bundle: .module)) { delegate.engine?.preview() }
                .disabled(delegate.windowsHoldOff || store.settings.strength <= 0
                    || !(delegate.engine?.hasRunnableEffect ?? false) || store.settings.isPaused(at: Date()))
            pause
            Divider()
            row(String(localized: "設定…", bundle: .module)) { delegate.showSettings() }
                .keyboardShortcut(",")
            if AppDelegate.galleryAllowed {
                // A debug tool: not translated (DECISIONS D24).
                row("ギャラリー…") { delegate.showGallery() }
            }
            Divider()
            row(String(localized: "凪を終了", bundle: .module)) { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
        .toggleStyle(RowSwitch())
        .padding(14)
        .frame(width: 280, alignment: .leading)
    }

    /// A command: closes the panel, then acts.
    private func row(_ title: String, action: @escaping () -> Void) -> some View {
        Button {
            Self.closePanel()
            action()
        } label: {
            Text(verbatim: title).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
    }

    /// The panel is the key window while it is open.
    static func closePanel() {
        NSApp.keyWindow?.close()
    }

    @ViewBuilder private var pause: some View {
        if store.settings.isPaused(at: Date()) {
            Text(Self.pausedLabel(store.settings.pause)).foregroundStyle(.secondary)
            row(String(localized: "再開", bundle: .module)) { store.update { $0.pause = .none } }
        } else {
            // A pull-down in the panel; after choosing, the panel says until when.
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
            .fixedSize()
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

/// A switch at the right end of its row, so the switches line up whatever the label's length.
/// The label stays part of the switch: clicking it switches, and VoiceOver reads it.
struct RowSwitch: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Toggle(isOn: configuration.$isOn) {
            // A switch's label does not switch on its own on macOS: clicking the name should.
            configuration.label.frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { configuration.isOn.toggle() }
        }
        .toggleStyle(.switch)
    }
}

/// A switch per effect (the menu and the first-launch guide).
struct EffectToggles: View {
    let store: SettingsStore
    let screenRecording: ScreenRecording
    /// Shows why an effect needs a permission and how to give it.
    let explainPermission: () -> Void
    var body: some View {
        ForEach(store.descriptors, id: \.id) { descriptor in
            Toggle(isOn: Binding(get: { store.settings.isEnabled(descriptor.id, among: store.effects) },
                                 set: { on in
                                     store.update { $0.setEnabled(descriptor.id, on, among: store.effects) }
                                     if on, screenRecording.needsExplaining(descriptor) { explainPermission() }
                                 })) {
                // Offered even without its permission, saying what it needs (SPEC 2.3).
                if descriptor.capabilities.contains(.backdrop), screenRecording.state != .granted {
                    Text(String(format: String(localized: "%@(画面収録の許可が必要)", bundle: .module),
                                String(localized: descriptor.displayName)))
                } else {
                    Text(descriptor.displayName)
                }
            }
        }
    }
}

/// The menu-bar icon: a drop over its ripples; while paused, only the still water (D30).
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

    mutating func setEnabled(_ id: String, _ on: Bool, among types: [any Effect.Type]) {
        var ids = enabledEffects ?? Self.defaultEnabled(types)
        ids.removeAll { $0 == id }
        if on { ids.append(id) }
        enabledEffects = ids
    }
}
