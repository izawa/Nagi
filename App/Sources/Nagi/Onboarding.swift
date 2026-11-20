import SwiftUI

/// The first-launch guide (SPEC 2.5, DECISIONS D26): what nagi does, which effects, launch at
/// login. Shown once; closing it in any way counts as done.
struct OnboardingView: View {
    let store: SettingsStore
    let login: LoginItem
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(String(localized: "凪へようこそ", bundle: .module)).font(.title2.bold())
            Text(String(format: String(localized: "キーボードとマウスから手を離して %lld 秒たつと、画面に木漏れ日が少しずつ現れます。手を動かすと、すぐに消えます。", bundle: .module),
                        Int(store.settings.onsetSeconds)))
            Text(String(localized: "日の光で描くので、日が沈むと現れません。月が出ている夜は、月明かりで薄く現れます。", bundle: .module))
            Text(String(localized: "一時停止と設定は、メニューバーのしずくのアイコンから開けます。", bundle: .module))
            Form {
                EffectToggles(store: store)
                LoginItemSection(login: login)
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button(String(localized: "始める", bundle: .module), action: done)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(24)
        .frame(width: 480)
    }
}
