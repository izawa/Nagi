import CoreGraphics
import Foundation
import NagiKit

/// Windows for previews: nagi-render and the gallery draw `.windows` effects over a made-up
/// arrangement instead of the real screen (M3-PLAN 3.5).
///
/// JSON: `{"size": [1280, 720], "windows": [{"id": 1, "rect": [x, y, w, h], "role": "surface",
/// "age": 7200}, …]}`, front to back, in points of a display of `size`. `role` defaults to
/// surface; `age` (seconds the window has kept its frame) to the age given when it is used.
public struct WindowLayout: Sendable, Equatable, Decodable {
    public let size: [Double]
    public let windows: [Window]

    public struct Window: Sendable, Equatable, Decodable {
        public let id: UInt32
        public let rect: [Double]
        public let role: String?
        public let age: Double?

        init(id: UInt32, rect: [Double], role: String? = nil, age: Double? = nil) {
            self.id = id
            self.rect = rect
            self.role = role
            self.age = age
        }
    }

    init(size: [Double], windows: [Window]) {
        self.size = size
        self.windows = windows
    }

    /// Decoding checks the shapes, so `snapshot` never indexes past an array.
    public init(from decoder: any Decoder) throws {
        enum Keys: String, CodingKey { case size, windows }
        let container = try decoder.container(keyedBy: Keys.self)
        size = try container.decode([Double].self, forKey: .size)
        windows = try container.decode([Window].self, forKey: .windows)
        try validate()
    }

    /// The built-in arrangements, on a 1280 × 720 point display.
    public static let builtIn: [String: WindowLayout] = [
        "single": .init(size: [1280, 720], windows: [.init(id: 101, rect: [200, 160, 880, 460])]),
        "overlap": .init(size: [1280, 720], windows: [
            .init(id: 202, rect: [520, 250, 640, 400]),
            .init(id: 201, rect: [110, 130, 700, 440]),
        ]),
        "panel": .init(size: [1280, 720], windows: [
            .init(id: 302, rect: [700, 90, 260, 170], role: "occluder"),
            .init(id: 301, rect: [160, 140, 900, 500]),
        ]),
        "fullscreen": .init(size: [1280, 720], windows: [.init(id: 401, rect: [0, 0, 1280, 720], role: "occluder")]),
        "empty": .init(size: [1280, 720], windows: []),
    ]

    /// A built-in name, or the path of a JSON file.
    public static func named(_ name: String) throws -> WindowLayout {
        if let layout = builtIn[name] { return layout }
        return try JSONDecoder().decode(WindowLayout.self, from: Data(contentsOf: URL(fileURLWithPath: name)))
    }

    private func validate() throws {
        func finite(_ values: [Double]) -> Bool { values.allSatisfy(\.isFinite) }
        guard size.count == 2, finite(size), size[0] > 0, size[1] > 0 else {
            throw NagiCoreError("window layout: size must be [width, height]")
        }
        guard Set(windows.map(\.id)).count == windows.count else { throw NagiCoreError("window layout: an id is repeated") }
        for window in windows {
            guard window.rect.count == 4, finite(window.rect), window.rect[2] > 0, window.rect[3] > 0,
                  window.age.map({ $0.isFinite && $0 >= 0 }) ?? true,
                  window.role.map({ ["surface", "occluder"].contains($0) }) ?? true
            else { throw NagiCoreError("window layout: bad window \(window.id)") }
        }
    }

    /// The snapshot on `display` (desktop points) when windows without their own age are `age`
    /// seconds old; the desktop is as old. Rectangles stretch from `size` to the display; the
    /// reach of what grows on them does not.
    public func snapshot(on display: CGRect, age: Double) -> WindowSnapshot {
        let sx = display.width / size[0], sy = display.height / size[1]
        let infos = windows.map { window in
            let r = window.rect
            let frame = CGRect(x: display.minX + r[0] * sx, y: display.minY + r[1] * sy, width: r[2] * sx, height: r[3] * sy)
            return WindowInfo(id: window.id, frame: frame, role: window.role == "occluder" ? .occluder : .surface,
                              stationarySeconds: window.age ?? age)
        }
        return WindowSnapshot(frontToBack: infos, layoutRevision: 1, usableAreas: [display], desktopSeconds: age)
    }
}

extension WindowSnapshot {
    /// The same arrangement `seconds` later: every age grows, the layout stays.
    public func aged(by seconds: Double) -> WindowSnapshot {
        var later = self
        for index in later.frontToBack.indices { later.frontToBack[index].stationarySeconds += seconds }
        later.desktopSeconds += seconds
        return later
    }
}
