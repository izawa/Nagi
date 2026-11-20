import Foundation
import NagiKit
import Observation

/// Lines for the menu: the effects' notes (Effect.note), e.g. that komorebi shows nothing after
/// sunset, and that an effect cannot run without a permission.
/// Read once a minute and after each settings change, so the menu need not ask the engine itself.
@MainActor @Observable final class EffectNotes {
    private(set) var lines: [String] = []
    @ObservationIgnored private let source: () -> [String]
    @ObservationIgnored private var timer: Timer?

    init(source: @escaping () -> [String]) {
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
        let next = source()
        if next != lines { lines = next }
    }
}
