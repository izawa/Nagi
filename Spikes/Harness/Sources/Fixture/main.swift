import AppKit
import Darwin
import Dispatch
import SpikeLog

private enum Scene: String {
    case panels
    case s5
}

@MainActor
private final class FixtureView: NSView {
    private let gray: CGFloat

    init(gray: CGFloat) {
        self.gray = gray
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
    private let logQueue = DispatchQueue(label: "Fixture.log")
    private var exitTimer: (any DispatchSourceTimer)?
    private var windows: [(window: NSWindow, gray: CGFloat)] = []
    private var primaryFrame = CGRect.zero
    private var initialFrames: [CGRect] = []
    private var stepIndex = 0

    init(scene: Scene, duration: TimeInterval) {
        self.scene = scene
        self.duration = duration
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
            let shades: [CGFloat] = [0.1, 0.5, 1.0]
            for (index, gray) in shades.enumerated() {
                let offset = CGFloat(index - (shades.count - 1)) * (base.width + 12)
                addWindow("Gray \(gray)", gray: gray, frame: base.offsetBy(dx: offset, dy: 0))
            }
        case .s5:
            addWindow("A", gray: 0.22, frame: base.offsetBy(dx: -132, dy: 72))
            addWindow("B", gray: 0.76, frame: base.offsetBy(dx: -30, dy: 20))
            initialFrames = windows.map { $0.window.frame }
        }

        logWindows("ready", ["duration": duration])

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

    private func addWindow(_ title: String, gray: CGFloat, frame: CGRect) {
        let style: NSWindow.StyleMask = .titled
        let window = NSWindow(
            contentRect: NSWindow.contentRect(forFrameRect: frame, styleMask: style),
            styleMask: style,
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.level = .normal
        window.isMovable = false
        window.tabbingMode = .disallowed
        window.animationBehavior = .none
        window.colorSpace = .sRGB
        window.contentView = FixtureView(gray: gray)
        windows.append((window, gray))

        // Show the scene on an inactive launch without changing the key window.
        window.orderFrontRegardless()
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

    let arguments = Array(CommandLine.arguments.dropFirst())
    guard (arguments.count == 2 || arguments.count == 4),
          arguments[0] == "--scene", let scene = Scene(rawValue: arguments[1]) else {
        SpikeLog.emit("error", ["message": "Usage: Fixture --scene panels|s5 [--duration seconds]"])
        Darwin.exit(EXIT_FAILURE)
    }

    let duration: TimeInterval
    if arguments.count == 4 {
        guard arguments[2] == "--duration", let seconds = Double(arguments[3]),
              seconds.isFinite, seconds > 0 else {
            SpikeLog.emit("error", ["message": "--duration requires a positive number of seconds"])
            Darwin.exit(EXIT_FAILURE)
        }
        duration = min(seconds, 600)
    } else {
        duration = 30
    }

    let app = NSApplication.shared
    // Info.plist already makes this a regular app, in which case this returns false.
    app.setActivationPolicy(.regular)

    let fixture = Fixture(scene: scene, duration: duration)
    app.delegate = fixture
    withExtendedLifetime(fixture) {
        app.run()
    }
}

main()
