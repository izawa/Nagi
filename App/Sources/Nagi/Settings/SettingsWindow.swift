import AppKit
import NagiCore
import NagiKit
import SwiftUI

struct SettingsView: View {
    let store: SettingsStore
    let login: LoginItem
    let device: (any MTLDevice)?

    var body: some View {
        TabView {
            Tab(String(localized: "一般", bundle: .module), systemImage: "gearshape") {
                GeneralSettings(store: store, login: login)
            }
            Tab(String(localized: "エフェクト", bundle: .module), systemImage: "leaf") {
                EffectSettings(store: store, device: device)
            }
        }
        .frame(width: 640, height: 600)
    }
}

/// When nagi appears and how it behaves (SPEC 2.5).
private struct GeneralSettings: View {
    let store: SettingsStore
    let login: LoginItem

    var body: some View {
        Form {
            LoginItemSection(login: login)
            Section {
                LabeledContent(String(localized: "手を止めてから現れるまで", bundle: .module)) {
                    Stepper(value: binding(\.onsetSeconds), in: 1...60, step: 1) {
                        Text(String(format: String(localized: "%lld 秒", bundle: .module), Int(store.settings.onsetSeconds)))
                            .monospacedDigit()
                    }
                }
                Picker(String(localized: "深まる速さ", bundle: .module), selection: binding(\.deepening)) {
                    Text(String(localized: "ふつう", bundle: .module)).tag(NagiSettings.Deepening.normal)
                    Text(String(localized: "ゆっくり", bundle: .module)).tag(NagiSettings.Deepening.slow)
                }
                .pickerStyle(.segmented)
                LabeledContent(String(localized: "全体の強さ", bundle: .module)) {
                    Slider(value: binding(\.strength), in: 0...1)
                }
            }
            Section {
                Toggle(String(localized: "動画の再生中は出さない", bundle: .module), isOn: binding(\.holdForMedia))
                Toggle(String(localized: "画面共有と画面収録に写す", bundle: .module), isOn: binding(\.showInScreenSharing))
                Picker(String(localized: "低電力モードのとき", bundle: .module), selection: binding(\.lowPower)) {
                    Text(String(localized: "コマ数を半分にする", bundle: .module)).tag(NagiSettings.LowPower.reduceFrameRate)
                    Text(String(localized: "いつもどおり", bundle: .module)).tag(NagiSettings.LowPower.asUsual)
                }
            }
            if let error = store.saveError {
                Section {
                    Text(String(format: String(localized: "設定を保存できません: %@", bundle: .module), error))
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func binding<T>(_ path: WritableKeyPath<NagiSettings, T>) -> Binding<T> {
        Binding(get: { store.settings[keyPath: path] }, set: { value in store.update { $0[keyPath: path] = value } })
    }
}

/// Each effect's user-facing parameters, generated from its descriptor (SPEC 2.5, 3.4), over a
/// live preview of what they change.
private struct EffectSettings: View {
    let store: SettingsStore
    let device: (any MTLDevice)?

    var body: some View {
        Form {
            ForEach(store.descriptors, id: \.id) { descriptor in
                EffectSection(store: store, descriptor: descriptor, device: device)
            }
        }
        .formStyle(.grouped)
    }
}

private struct EffectSection: View {
    let store: SettingsStore
    let descriptor: EffectDescriptor
    let device: (any MTLDevice)?
    @State private var preview: (model: GalleryModel, view: GalleryPreviewView)?

    var body: some View {
        Section {
            if let preview {
                GalleryPreview(view: preview.view)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipShape(.rect(cornerRadius: 6))
            }
            ForEach(descriptor.parameters.filter { $0.user != nil }, id: \.key) { spec in
                control(spec)
            }
            Button(String(localized: "推奨に戻す", bundle: .module)) {
                store.update { $0.effects[descriptor.id] = kept($0.effects[descriptor.id]) }
            }
            .disabled(store.settings.effects[descriptor.id] == kept(store.settings.effects[descriptor.id]))
        } header: {
            Text(descriptor.displayName)
        }
        .onAppear(perform: startPreview)
        .onDisappear(perform: stopPreview)
        .onChange(of: store.settings.effects[descriptor.id]) {
            preview?.model.parameters = store.parameters(for: descriptor.id)
        }
    }

    @ViewBuilder private func control(_ spec: ParameterSpec) -> some View {
        switch spec.user {
        case let .slider(range):
            LabeledContent(String(localized: spec.label)) {
                Slider(value: number(spec, fallback: range.lowerBound), in: range)
            }
        case let .steps(steps):
            Picker(String(localized: spec.label), selection: number(spec, fallback: steps.first?.value ?? 0)) {
                ForEach(steps, id: \.value) { Text($0.label).tag($0.value) }
            }
            .pickerStyle(.segmented)
        case .toggle:
            Toggle(String(localized: spec.label), isOn: Binding {
                if case let .flag(flag) = value(spec) { flag } else { false }
            } set: { set(spec, .flag($0)) })
        case let .wholeNumber(range, skipping, reroll):
            LabeledContent(String(localized: spec.label)) {
                HStack {
                    TextField("", value: number(spec, fallback: Double(range.lowerBound)),
                              format: .number.precision(.fractionLength(0)))
                        .frame(width: 56)
                        .multilineTextAlignment(.trailing)
                    Button(String(localized: reroll)) {
                        // Another number offered, never the same one (when there is another).
                        let offered = range.filter { !skipping.contains($0) && .number(Double($0)) != value(spec) }
                        if let next = offered.randomElement() { set(spec, .number(Double(next))) }
                    }
                }
            }
        case nil:
            EmptyView()
        }
    }

    /// What restoring the recommendation leaves: the choices (the tree), not the look.
    private func kept(_ values: [String: ParameterValue]?) -> [String: ParameterValue]? {
        let keep = Set(descriptor.parameters.filter { $0.user?.keepsOnReset == true }.map(\.key))
        let left = values?.filter { keep.contains($0.key) }
        return left?.isEmpty == false ? left : nil
    }

    private func value(_ spec: ParameterSpec) -> ParameterValue {
        store.settings.effects[descriptor.id]?[spec.key] ?? spec.defaultValue
    }

    private func number(_ spec: ParameterSpec, fallback: Double) -> Binding<Double> {
        Binding {
            if case let .number(number) = value(spec) { number } else { fallback }
        } set: { set(spec, .number($0)) }
    }

    private func set(_ spec: ParameterSpec, _ value: ParameterValue) {
        store.update { $0.effects[descriptor.id, default: [:]][spec.key] = value }
    }

    private func startPreview() {
        guard preview == nil, let device,
              let type = store.effects.first(where: { $0.descriptor.id == descriptor.id }) else { return }
        let model = GalleryModel(effect: type)
        model.fixture = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? .readingDark : .readingLight
        model.parameters = store.parameters(for: descriptor.id)
        model.framesPerSecond = Int(store.frameRateCap)
        model.strength = store.settings.strength
        model.accessibility = NagiEngine.accessibility
        guard let view = try? GalleryPreviewView(model: model, device: device) else { return }
        view.start()
        preview = (model, view)
    }

    private func stopPreview() {
        preview?.view.stop()
        preview = nil
    }
}
