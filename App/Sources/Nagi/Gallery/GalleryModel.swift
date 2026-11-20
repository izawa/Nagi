import Foundation
import NagiCore
import NagiKit
import Observation

/// What the gallery shows (DECISIONS D24): a debug tool for looking at an effect over a sample
/// background without relaunching. Its values live for the session only.
@MainActor @Observable final class GalleryModel {
    enum Fixture: String, CaseIterable, Identifiable {
        case readingLight = "reading-light", readingDark = "reading-dark"
        var id: String { rawValue }
        var appearance: Appearance { self == .readingDark ? .dark : .light }
    }

    enum Sky: String, CaseIterable, Identifiable {
        case natural, clear
        var id: String { rawValue }
    }

    let effect: any Effect.Type
    var fixture = Fixture.readingLight {
        didSet { appearance = fixture.appearance }
    }
    var appearance = Appearance.light
    /// The day and the local time of day (hours), for the sun and the moon.
    /// The chosen day (its year, month and day are read in whichever calendar applies).
    var day = Calendar.current.startOfDay(for: Date()) {
        didSet { dateSetAt = elapsed }
    }
    var hour = 12.0 {
        didSet { dateSetAt = elapsed }
    }
    /// The display's physical width (a 27-inch display), kept to real sizes.
    var widthMillimetres = 597.0 {
        didSet {
            let bounded = min(max(widthMillimetres.isFinite ? widthMillimetres : 597, 200), 1500)
            if bounded != widthMillimetres { widthMillimetres = bounded }
        }
    }
    /// Seen from Tokyo with Tokyo's clock (the moon presets, checked there); else the time zone's
    /// city and the local clock.
    var inTokyo = false
    private static let tokyo = GeoLocation(latitude: 35.69, longitude: 139.69)
    private var calendar: Calendar {
        var calendar = Calendar.current
        if inTokyo, let zone = TimeZone(identifier: "Asia/Tokyo") { calendar.timeZone = zone }
        return calendar
    }
    /// Seconds on the sky's clock at the start of the run, and seconds run since.
    var windStart = 0.0
    private(set) var elapsed = 0.0
    /// The run's time when the date was last chosen: the sky shows the chosen time then, and moves
    /// on from it.
    private var dateSetAt = 0.0
    var playing = true
    var framesPerSecond = 60
    /// The overall strength (the settings preview shows the user's).
    var strength = 1.0
    /// The system's accessibility settings (the settings preview follows them; the gallery does not).
    var accessibility = AccessibilityAdjustments()
    var depth = 60.0
    var deepening = false
    var sky = Sky.clear {
        didSet { cloudPassAt = nil }
    }
    var strongestWind = false
    private(set) var cloudPassAt: Double?
    var parameters: [String: ParameterValue] = [:]
    /// Entry and exit replayed through the state machine, from `replayStart`.
    private var replay: EnvelopeReplay?
    private var replayStart = 0.0
    private(set) var phase = NagiStatePhase.calm
    private(set) var presence = 1.0

    init(effect: any Effect.Type) {
        self.effect = effect
    }

    /// The chosen day at the chosen wall-clock time (hours and minutes, so a daylight-saving day
    /// still gives the time shown).
    var date: Date {
        let minutes = Int((hour * 60).rounded())
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: day)
        return calendar.date(from: DateComponents(year: parts.year, month: parts.month, day: parts.day,
                                                  hour: min(minutes / 60, 23), minute: minutes / 60 >= 24 ? 59 : minutes % 60))
            ?? day
    }

    /// Advances the run by `seconds` (when playing) and returns the frame to draw.
    func advance(by seconds: Double) -> FrameState {
        if playing {
            elapsed += seconds
            if deepening { depth = min(180, depth + seconds) }
        }
        var weather = EnvironmentModel.Weather(sky: sky == .natural ? .natural : .clear,
                                               strongestWind: strongestWind,
                                               cloudBias: effect.descriptor.weatherHint?.cloudBias ?? 0)
        if let start = cloudPassAt {
            // After the crossing (28 s), back to the chosen sky.
            if windStart + elapsed - start > 30 { cloudPassAt = nil } else { weather.sky = .cloudPass(start: start) }
        }
        var scene = PreviewScene(date: date.addingTimeInterval(-dateSetAt), location: inTokyo ? Self.tokyo : nil, windTime: windStart, weather: weather,
                                 appearance: appearance)
        scene.accessibility = accessibility
        if var running = replay {
            let envelope = running.step(at: elapsed - replayStart, depth: depth)
            replay = running
            // Every entry is a new showing, the replayed one and the one after a simulated input.
            if envelope.phase == .entering, phase != .entering { showings += 1 }
            (phase, presence) = (envelope.phase, envelope.presence)
            return scene.frame(elapsed: elapsed, deltaTime: seconds, phase: envelope.phase.framePhase,
                               presence: envelope.presence, depth: envelope.depth)
        }
        (phase, presence) = (.calm, 1)
        return scene.frame(elapsed: elapsed, deltaTime: seconds, depth: depth)
    }

    /// Back to the start of the run (the same wind, the same clouds).
    func restart() {
        elapsed = 0
        dateSetAt = 0
        replay = nil
        cloudPassAt = nil
    }

    /// How many times the preview has entered (FrameState.showing): a replayed entry is a new
    /// showing, so effects with state (rain) start over as on the desktop.
    private(set) var showings = 0

    /// nagi enters now, as after the hands came to rest.
    func replayEntry() {
        replay = EnvelopeReplay()
        replayStart = elapsed
        playing = true
    }

    /// The hands move now: nagi leaves (and comes back after the onset if left alone).
    func simulateInput() {
        if replay == nil {
            // From the calm picture on screen.
            replay = EnvelopeReplay(startingCalm: true, depth: depth)
            replayStart = elapsed
        }
        replay?.input(at: elapsed - replayStart)
        playing = true
    }

    /// One cloud crosses the sun from now.
    func passCloud() {
        cloudPassAt = windStart + elapsed
        playing = true
    }

    func clearCloudPass() {
        cloudPassAt = nil
    }

    func value(_ spec: ParameterSpec) -> ParameterValue {
        parameters[spec.key] ?? spec.defaultValue
    }

    func resetParameters() {
        parameters = [:]
    }
}
