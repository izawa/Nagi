/// Which effects run in a showing (SPEC 2.3). Decided when nagi shows and kept until it hides.
public struct EffectSelection: Sendable {
    public enum Mode: Sendable, Equatable {
        /// Every enabled effect, layered.
        case all
        /// One enabled effect, drawn at entry; the same one for 30 minutes after the draw.
        case random
    }

    /// How long a random draw is kept (SPEC 2.3): a short break does not change the scene.
    public static let keep: Double = 30 * 60

    public var mode = Mode.all
    /// The effects the user turned on.
    public var enabled: Set<String> = []
    private var draw: (id: String, at: Double)?

    public init() {}

    /// The enabled effects that can run now, in `order` (the catalog's).
    public func eligible(in order: [String], unavailable: Set<String>) -> [String] {
        order.filter { enabled.contains($0) && !unavailable.contains($0) }
    }

    /// What the next showing would run, without drawing: random mode's kept draw if it can still
    /// run, else every eligible effect (any of which it may draw). `silent`: as in `resolve`.
    public func upcoming(order: [String], unavailable: Set<String>, silent: Set<String> = [],
                         now: Double) -> [String] {
        let eligible = eligible(in: order, unavailable: unavailable)
        guard mode == .random else { return eligible }
        let candidates = Self.candidates(eligible, silent: silent)
        return kept(candidates, now: now).map { [$0] } ?? candidates
    }

    /// The effects to run in a showing that starts at `now`. Empty when none can run.
    /// `silent`: effects that would draw nothing now (Effect.note: komorebi on a moonless night).
    /// Random mode leaves them out of the draw, and draws again if its kept effect is one, so a
    /// showing is not empty for 30 minutes; when every eligible effect is silent, it draws as before.
    public mutating func resolve(order: [String], unavailable: Set<String>, silent: Set<String> = [],
                                 now: Double, using random: inout some RandomNumberGenerator) -> [String] {
        let eligible = eligible(in: order, unavailable: unavailable)
        guard mode == .random else { return eligible }
        let candidates = Self.candidates(eligible, silent: silent)
        if let id = kept(candidates, now: now) { return [id] }
        guard let id = candidates.randomElement(using: &random) else { return [] }
        draw = (id, now)
        return [id]
    }

    private static func candidates(_ eligible: [String], silent: Set<String>) -> [String] {
        let drawing = eligible.filter { !silent.contains($0) }
        return drawing.isEmpty ? eligible : drawing
    }

    /// Random mode's draw, while it is under 30 minutes old and is still a candidate.
    private func kept(_ candidates: [String], now: Double) -> String? {
        guard let draw, candidates.contains(draw.id), now - draw.at < Self.keep else { return nil }
        return draw.id
    }
}
