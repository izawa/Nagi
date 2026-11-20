import AppKit
import NagiCore
import NagiKit
import Observation

/// Screen Recording, which rain needs to bend the screen behind it (SPEC 5, M2-PLAN 4.3).
/// The system shows its dialog only the first time; after that the user turns Nagi on in System
/// Settings. Whether we asked is saved, so a refusal can be told from never asking.
@MainActor @Observable final class ScreenRecording {
    /// `pending`: asked, and the answer is not known yet (the request returns before the user
    /// answers; read again when Nagi becomes active or the settings open).
    enum State { case granted, unasked, pending, denied }

    private(set) var state = State.unasked
    @ObservationIgnored private let store: SettingsStore
    /// Called when the state changes (the engine reads the permission again).
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private var observer: (any NSObjectProtocol)?

    init(store: SettingsStore) {
        self.store = store
        refresh()
        // The answer comes later (the dialog, System Settings): look again when Nagi is active.
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    isolated deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func refresh() {
        let next: State = BackdropCapture.isPermitted ? .granted : (store.settings.screenRecordingAsked ? .denied : .unasked)
        set(next)
    }

    private func set(_ next: State) {
        guard next != state else { return }
        state = next
        onChange?()
    }

    /// Shows the system's dialog (the first time only); its answer is read on `refresh`.
    func request() {
        store.update { $0.screenRecordingAsked = true }
        set(CGRequestScreenCaptureAccess() ? .granted : .pending)
    }

    /// The Screen & System Audio Recording list in System Settings.
    func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }

    /// An effect that needs it was turned on without it: show the Permissions tab, which explains
    /// why and offers the request or System Settings (SPEC 2.3).
    func needsExplaining(_ descriptor: EffectDescriptor) -> Bool {
        descriptor.capabilities.contains(.backdrop) && state != .granted
    }
}
