import AppKit
import Darwin
import Dispatch
import SpikeLog

private enum Scene: String {
    case panels
    case s5
    case flash
}

@MainActor
private final class FixtureView: NSView {
    var gray: CGFloat {
        didSet { needsDisplay = true }
    }
    private let showsReference: Bool

    init(gray: CGFloat, showsReference: Bool) {
        self.gray = gray
        self.showsReference = showsReference
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("FixtureView is created in code")
    }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(srgbRed: gray, green: gray, blue: gray, alpha: 1).setFill()
        dirtyRect.fill()
        guard showsReference else { return }

        let gridGray = gray < 0.5 ? gray + 0.16 : gray - 0.16
        NSColor(srgbRed: gridGray, green: gridGray, blue: gridGray, alpha: 1).setFill()
        for x in stride(from: bounds.minX, to: bounds.maxX, by: 20) {
            CGRect(x: x, y: bounds.minY, width: 1, height: bounds.height).fill()
        }
        for y in stride(from: bounds.minY, to: bounds.maxY, by: 20) {
            CGRect(x: bounds.minX, y: y, width: bounds.width, height: 1).fill()
        }

        let paragraph = "静かな画面で、文字と背景の見え方を確かめます。 The body text and grid provide fixed reference points while the overlay changes."
        (paragraph as NSString).draw(
            with: bounds.insetBy(dx: 24, dy: 24),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: gray < 0.5 ? NSColor.white : NSColor.black,
            ],
            context: nil
        )
    }
}

@MainActor
private final class Fixture: NSObject, NSApplicationDelegate {
    private let scene: Scene
    private let duration: TimeInterval
    private let grays: [CGFloat]
    private let logQueue = DispatchQueue(label: "Fixture.log")
    private var exitTimer: (any DispatchSourceTimer)?
    private var windows: [(window: NSWindow, gray: CGFloat)] = []
    private var primaryFrame = CGRect.zero
    private var initialFrames: [CGRect] = []
    private var stepIndex = 0

    init(scene: Scene, duration: TimeInterval, grays: [CGFloat]) {
        self.scene = scene
        self.duration = duration
        self.grays = grays
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let screen = NSScreen.screens.first else {
            SpikeLog.emit("error", ["message": "No primary display"])
            Darwin.exit(EXIT_FAILURE)
        }
        primaryFrame = screen.frame
        let visible = screen.visibleFrame
        let base = CGRect(x: visible.maxX - 24 - 360, y: visible.minY + 24, width: 360, height: 240)

        switch scene {
        case .panels:
            for (index, gray) in grays.enumerated() {
                let offset = CGFloat(index - (grays.count - 1)) * (base.width + 12)
                addWindow("Gray \(gray)", gray: gray, frame: base.offsetBy(dx: offset, dy: 0))
            }
        case .s5:
            addWindow("A", gray: 0.22, frame: base.offsetBy(dx: -132, dy: 72))
            addWindow("B", gray: 0.76, frame: base.offsetBy(dx: -30, dy: 20))
            initialFrames = windows.map { $0.window.frame }
        case .flash:
            let frame = CGRect(x: visible.minX + 24, y: visible.minY + 24, width: 200, height: 200)
            let view = addWindow("Flash", gray: 0, frame: frame, style: .borderless)
            let timer = Timer(timeInterval: 0.2, repeats: true) { @Sendable [weak view] _ in
                MainActor.assumeIsolated {
                    guard let view else { return }
                    view.gray = 1 - view.gray
                    // S4 compares this time with the capture's first sample of the new colour.
                    SpikeLog.emit("flash-toggle", ["gray": view.gray])
                }
            }
            RunLoop.main.add(timer, forMode: .common)
        }

        logWindows(scene == .flash ? "flash-ready" : "ready", ["duration": duration])

        // Keep the timeout independent of AppKit's run loop. SpikeLog flushes stdout.
        let timer = DispatchSource.makeTimerSource(queue: logQueue)
        timer.schedule(deadline: .now() + duration)
        timer.setEventHandler { @Sendable in
            SpikeLog.emit("exit")
            Darwin._exit(EXIT_SUCCESS)
        }
        exitTimer = timer
        timer.activate()

        if scene == .s5 {
            let stepTimer = Timer(fire: Date(timeIntervalSinceNow: 2), interval: 2, repeats: true) { @Sendable [weak self] _ in
                MainActor.assumeIsolated {
                    self?.runNextStep()
                }
            }
            RunLoop.main.add(stepTimer, forMode: .common)
        }
    }

    @discardableResult
    private func addWindow(_ title: String, gray: CGFloat, frame: CGRect, style: NSWindow.StyleMask = .titled) -> FixtureView {
        let window = NSWindow(
            contentRect: NSWindow.contentRect(forFrameRect: frame, styleMask: style),
            styleMask: style,
            backing: .buffered,
            defer: false
        )
        window.title = title
        // Panels and the flash stay above the author's windows, which come to the front as they work;
        // S5 checks the order of ordinary windows, so its windows stay at the normal level.
        window.level = scene == .s5 ? .normal : .floating
        window.isMovable = false
        window.tabbingMode = .disallowed
        window.animationBehavior = .none
        window.colorSpace = .sRGB
        let view = FixtureView(gray: gray, showsReference: scene != .flash)
        window.contentView = view
        windows.append((window, gray))

        // Show the scene on an inactive launch without changing the key window.
        window.orderFrontRegardless()
        return view
    }

    private var orderedFixtureWindows: [NSWindow] {
        NSApplication.shared.orderedWindows.filter { candidate in
            windows.contains { $0.window === candidate }
        }
    }

    private func runNextStep() {
        let a = windows[0].window
        let b = windows[1].window
        let name: String
        let target: NSWindow

        // AppKit's y-axis points up. The step deltas are in the logged, y-down space.
        switch stepIndex {
        case 0:
            name = "move-a"
            target = a
            a.setFrameOrigin(initialFrames[0].offsetBy(dx: 40, dy: -20).origin)
        case 1:
            name = "resize-b"
            target = b
            // Grow down and right from B's original top-left corner.
            var frame = initialFrames[1]
            frame.origin.y -= 20
            frame.size.width += 30
            frame.size.height += 20
            b.setFrame(frame, display: true)
        case 2:
            let ordered = orderedFixtureWindows
            guard ordered.count == windows.count, let back = ordered.last else { return }
            name = "bring-to-front"
            target = back
            back.orderFrontRegardless()  // orderFront(nil) does not reorder on screen while inactive
        case 3:
            name = "move-a-back"
            target = a
            a.setFrameOrigin(initialFrames[0].origin)
        default:
            name = "resize-b-back"
            target = b
            b.setFrame(initialFrames[1], display: true)
        }

        stepIndex = (stepIndex + 1) % 5
        logWindows("step", ["step": name, "windowNumber": target.windowNumber])
    }

    private func logWindows(_ event: String, _ extra: [String: any Sendable]) {
        if let screen = NSScreen.screens.first {
            primaryFrame = screen.frame
        }
        let info: [[String: any Sendable]] = windows.map { window, gray in
            let frame = window.frame
            return [
                "title": window.title,
                "windowNumber": window.windowNumber,
                "frame": [
                    "x": Double(frame.minX - primaryFrame.minX),
                    "y": Double(primaryFrame.maxY - frame.maxY),
                    "width": Double(frame.width),
                    "height": Double(frame.height),
                ],
                "backgroundGray": Double(gray),
                "colorSpace": "sRGB",
            ]
        }
        var fields = extra
        fields["scene"] = scene.rawValue
        fields["windows"] = info
        fields["orderedWindows"] = orderedFixtureWindows.map(\.windowNumber)
        logQueue.sync { @Sendable [fields] in
            SpikeLog.emit(event, fields)
        }
    }
}

@MainActor
private func main() {
    SpikeLog.header()

    let usage = "Usage: Fixture --scene panels|s5|flash [--duration seconds] [--grays a,b,c]"
    func fail(_ message: String) -> Never {
        SpikeLog.emit("error", ["message": message])
        Darwin.exit(EXIT_FAILURE)
    }

    let arguments = Array(CommandLine.arguments.dropFirst())
    var scene: Scene?
    var duration: TimeInterval = 30
    var grays: [CGFloat]?
    var seen: Set<String> = []
    guard arguments.count.isMultiple(of: 2) else { fail(usage) }
    for index in stride(from: 0, to: arguments.count, by: 2) {
        let option = arguments[index]
        let value = arguments[index + 1]
        guard seen.insert(option).inserted else { fail("Duplicate option \(option)") }
        switch option {
        case "--scene":
            guard let selected = Scene(rawValue: value) else { fail(usage) }
            scene = selected
        case "--duration":
            guard let seconds = Double(value), seconds.isFinite, seconds > 0 else {
                fail("--duration requires a positive number of seconds")
            }
            duration = min(seconds, 600)
        case "--grays":
            let parts = value.split(separator: ",", omittingEmptySubsequences: false)
            let values = parts.compactMap { Double($0) }
            guard parts.count == 3, values.count == 3, values.allSatisfy({ (0...1).contains($0) }) else {
                fail("--grays requires three comma-separated values between 0 and 1")
            }
            grays = values.map { CGFloat($0) }
        default:
            fail("Unknown option \(option)")
        }
    }

    guard let scene else { fail(usage) }
    guard grays == nil || scene == .panels else { fail("--grays requires --scene panels") }

    let app = NSApplication.shared
    // Info.plist already makes this a regular app, in which case this returns false.
    app.setActivationPolicy(.regular)

    let fixture = Fixture(scene: scene, duration: duration, grays: grays ?? [0.1, 0.5, 1.0])
    app.delegate = fixture
    withExtendedLifetime(fixture) {
        app.run()
    }
}

main()
