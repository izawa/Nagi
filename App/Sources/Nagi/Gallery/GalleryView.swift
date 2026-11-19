import AppKit
import EffectCatalog
import NagiCore
import NagiKit
import SwiftUI

/// The gallery's window content: the picture, and a panel of controls (DECISIONS D24). A debug
/// tool, so its labels are not translated.
struct GalleryView: View {
    @Bindable var model: GalleryModel
    let preview: GalleryPreviewView

    var body: some View {
        HStack(spacing: 0) {
            GalleryPreview(view: preview)
                .frame(minWidth: 480, minHeight: 270)
            Divider()
            ScrollView {
                Form { controls }
                    .formStyle(.grouped)
            }
            .frame(width: 320)
        }
    }

    @ViewBuilder private var controls: some View {
        Section("背景と外観") {
            Picker("背景", selection: $model.fixture) {
                Text("本文(ライト)").tag(GalleryModel.Fixture.readingLight)
                Text("本文(ダーク)").tag(GalleryModel.Fixture.readingDark)
            }
            Picker("外観", selection: $model.appearance) {
                Text("ライト").tag(Appearance.light)
                Text("ダーク").tag(Appearance.dark)
            }
            LabeledContent("画面の幅 (mm)") {
                TextField("", value: $model.widthMillimetres, format: .number).frame(width: 80)
            }
        }
        Section("日時") {
            DatePicker("日付", selection: $model.day, displayedComponents: .date)
            LabeledContent("時刻 \(Self.clock(model.hour))") {
                Slider(value: $model.hour, in: 0...24)
            }
            HStack {
                Button("今日の正午") {
                    model.inTokyo = false
                    set(day: Calendar.current.startOfDay(for: Date()), hour: 12)
                }
                // Tokyo, where these were checked (DECISIONS D21).
                Button("満月の夜") { set(iso: "2026-11-25T00:00:00+09:00", tokyo: true) }
                Button("半月の夕方") { set(iso: "2026-12-17T19:00:00+09:00", tokyo: true) }
            }
            if model.inTokyo { Text("場所と時計: 東京").foregroundStyle(.secondary) }
        }
        Section("時間") {
            Toggle("再生", isOn: $model.playing)
            LabeledContent("風の時計 \(model.windStart + model.elapsed, format: .number.precision(.fractionLength(0))) 秒") {
                Button("始めに戻す") { model.restart() }
            }
            LabeledContent("始めの風の時計 (秒)") {
                TextField("", value: $model.windStart, format: .number).frame(width: 80)
            }
            Picker("フレームの速さ", selection: $model.framesPerSecond) {
                Text("30 fps").tag(30)
                Text("60 fps").tag(60)
            }
            .pickerStyle(.segmented)
        }
        Section("深さ") {
            LabeledContent("深さ \(Int(model.depth)) 秒") {
                Slider(value: $model.depth, in: 0...60)
            }
            Toggle("実時間で深める", isOn: $model.deepening)
        }
        Section("凪の出入り") {
            HStack {
                Button("入場を再生") { model.replayEntry() }
                Button("入力をまねる") { model.simulateInput() }
            }
            Text("局面 \(Self.name(model.phase))・現れ具合 \(model.presence, format: .number.precision(.fractionLength(2)))")
                .foregroundStyle(.secondary)
        }
        Section("空と風") {
            Picker("空", selection: $model.sky) {
                Text("晴れ").tag(GalleryModel.Sky.clear)
                Text("普段の空").tag(GalleryModel.Sky.natural)
            }
            .pickerStyle(.segmented)
            Button("雲を 1 つ通す") { model.passCloud() }
            Toggle("最も強い風", isOn: $model.strongestWind)
        }
        Section("\(String(localized: model.effect.descriptor.displayName))の設定") {
            ForEach(model.effect.descriptor.parameters, id: \.key) { spec in
                parameterControl(spec)
            }
            Button("既定に戻す") { model.resetParameters() }
        }
    }

    @ViewBuilder private func parameterControl(_ spec: ParameterSpec) -> some View {
        switch spec.kind {
        case let .slider(range, _):
            let value = Binding<Double> {
                if case let .number(number) = model.value(spec) { number } else { range.lowerBound }
            } set: { model.parameters[spec.key] = .number($0) }
            LabeledContent {
                Slider(value: value, in: range)
            } label: {
                Text(spec.label) + Text(" \(value.wrappedValue, format: .number.precision(.fractionLength(2)))")
            }
        case .toggle:
            Toggle(isOn: Binding<Bool> {
                if case let .flag(flag) = model.value(spec) { flag } else { false }
            } set: { model.parameters[spec.key] = .flag($0) }) {
                Text(spec.label)
            }
        case let .choice(options, _):
            Picker(selection: Binding<String> {
                if case let .choice(key) = model.value(spec) { key } else { options.first?.key ?? "" }
            } set: { model.parameters[spec.key] = .choice($0) }) {
                ForEach(options, id: \.key) { Text($0.label).tag($0.key) }
            } label: {
                Text(spec.label)
            }
        }
    }

    private func set(day: Date, hour: Double) {
        model.day = day
        model.hour = hour
    }

    /// A preset instant, seen from Tokyo on Tokyo's wall clock.
    private func set(iso: String, tokyo: Bool) {
        guard let date = ISO8601DateFormatter().date(from: iso), let zone = TimeZone(identifier: "Asia/Tokyo") else { return }
        model.inTokyo = tokyo
        var calendar = Calendar.current
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let day = Calendar.current.date(from: DateComponents(year: parts.year, month: parts.month, day: parts.day))
        set(day: day ?? date, hour: Double(parts.hour ?? 0) + Double(parts.minute ?? 0) / 60)
    }

    private static func clock(_ hour: Double) -> String {
        let minutes = Int((hour * 60).rounded())
        return String(format: "%02d:%02d", minutes / 60 % 25, minutes % 60)
    }

    private static func name(_ phase: NagiStatePhase) -> String {
        switch phase {
        case .active: "隠れている"
        case .entering: "入場中"
        case .calm: "凪"
        case .leaving: "退場中"
        }
    }
}

/// Opens and closes the gallery; while it is open nagi is held off, and closing frees everything.
@MainActor final class GalleryWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var preview: GalleryPreviewView?
    private weak var engine: NagiEngine?

    init(engine: NagiEngine) {
        self.engine = engine
    }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        guard let engine, let effect = EffectCatalog.all.first else { return }
        let model = GalleryModel(effect: effect)
        do {
            let preview = try GalleryPreviewView(model: model, device: engine.renderer.device)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 640),
                                  styleMask: [.titled, .closable, .resizable, .miniaturizable],
                                  backing: .buffered, defer: false)
            window.title = "ギャラリー"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: GalleryView(model: model, preview: preview))
            window.delegate = self
            window.center()
            self.window = window
            self.preview = preview
            engine.heldOff = true
            preview.start()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
        } catch {
            NSLog("Gallery could not open: %@", error.localizedDescription)
        }
    }

    func windowWillClose(_ notification: Notification) {
        preview?.stop()
        preview = nil
        window = nil
        engine?.heldOff = false
    }
}
