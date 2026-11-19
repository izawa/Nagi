import Foundation
import NagiKit
import Observation

/// The effects' notes for the menu (Effect.note), e.g. that komorebi shows nothing after sunset.
/// Read once a minute and after each settings change, so the menu need not ask the engine itself.
@MainActor @Observable final class EffectNotes {
    private(set) var lines: [String] = []
    @ObservationIgnored private let source: () -> [LocalizedStringResource]
    @ObservationIgnored private var timer: Timer?

    init(source: @escaping () -> [LocalizedStringResource]) {
        self.source = source
    }

    func start() {
        refresh()
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func refresh() {
        let next = source().map { String(localized: $0) }
        if next != lines { lines = next }
    }
}
