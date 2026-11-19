import AppKit
import Observation
import ServiceManagement
import SwiftUI

/// Launch at login (DECISIONS D11): the system's status is the truth. Only `.enabled` shows as on;
/// the item is registered or removed only when the user flips the switch, never at launch, so a
/// removal in System Settings stays removed.
@MainActor @Observable final class LoginItem {
    enum State: Equatable { case on, off, needsApproval }

    private(set) var state = State.off
    private(set) var error: String?

    init() { refresh() }

    static func state(for status: SMAppService.Status) -> State {
        switch status {
        case .enabled: .on
        case .requiresApproval: .needsApproval
        default: .off  // .notRegistered, .notFound
        }
    }

    func refresh() {
        state = Self.state(for: SMAppService.mainApp.status)
    }

    func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        refresh()
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

/// The switch, with the way to System Settings when macOS asks for approval.
struct LoginItemSection: View {
    let login: LoginItem

    var body: some View {
        Section {
            Toggle(String(localized: "ログイン時に起動", bundle: .module),
                   isOn: Binding(get: { login.state == .on }, set: { login.set($0) }))
            if login.state == .needsApproval {
                LabeledContent(String(localized: "システム設定での許可が必要です", bundle: .module)) {
                    Button(String(localized: "ログイン項目を開く", bundle: .module)) { login.openSystemSettings() }
                }
            }
            if let error = login.error {
                Text(String(format: String(localized: "ログイン項目を変更できません: %@", bundle: .module), error))
                    .foregroundStyle(.red)
            }
        }
        .onAppear { login.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            login.refresh()
        }
    }
}
