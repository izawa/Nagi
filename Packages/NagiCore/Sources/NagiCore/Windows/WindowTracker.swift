import CoreGraphics
import NagiKit

/// One row of the system's window list. Names are never read (SPEC 5).
public struct WindowListEntry: Sendable, Equatable {
    public var id: UInt32
    public var pid: Int32
    public var layer: Int
    public var alpha: Double
    /// Desktop points, top-left origin.
    public var frame: CGRect

    public init(id: UInt32, pid: Int32, layer: Int, alpha: Double, frame: CGRect) {
        self.id = id
        self.pid = pid
        self.layer = layer
        self.alpha = alpha
        self.frame = frame
    }
}

/// Turns readings of the window list into snapshots: which windows cover what, and how long each
/// has kept its frame (M3-PLAN 3.2, 3.3). Pure, so the rules can be tested with a fake clock.
public struct WindowTracker: Sendable {
    /// Smaller ordinary windows only cover (sheets, small panels).
    public static let smallestSurface = CGSize(width: 120, height: 60)
    /// An edge moving further than this from where the window settled starts its age over.
    public static let moveTolerance = 1.0

    /// Debug: multiplies every age, to watch hours of growth in minutes on the real screen.
    public var ageScale = 1.0
    private let ownPID: Int32
    private struct Key: Hashable {
        var id: UInt32
        var pid: Int32
    }
    /// Where each ordinary window settled and since when, kept while it is listed at all
    /// (minimized and on other Spaces too: `prune` drops only windows gone from the whole list).
    private var settled: [Key: Settled] = [:]

    private struct Settled {
        var frame: CGRect
        var since: Double
        /// A different frame seen once, and when. While Spaces switch, the list reports windows
        /// part way through the slide, a different place each time: a move counts only when the
        /// next reading finds the window at the same new frame (M3-LOG, checkpoint H).
        var moving: (frame: CGRect, since: Double)?
    }
    private var desktop: (displays: [CGRect], since: Double)?
    private var layout: Layout?
    private var revision: UInt64 = 0

    private struct Layout: Equatable {
        var windows: [Row]
        var displays: [CGRect]
        var usableAreas: [CGRect]
        struct Row: Equatable {
            var id: UInt32
            var frame: CGRect
            var role: WindowInfo.Role
        }
    }

    public init(ownPID: Int32) {
        self.ownPID = ownPID
    }

    /// Takes the whole window list, on screen or not, in any order: keeps every ordinary window's
    /// age, and forgets windows gone from it (their numbers may come back as other windows).
    public mutating func prune(_ listed: [WindowListEntry], displays: [CGRect], now: Double) {
        noteDisplays(displays, now: now)
        var kept: [Key: Settled] = [:]
        for entry in listed where entry.pid != ownPID && entry.layer == 0 {
            kept[Key(id: entry.id, pid: entry.pid)] = settle(entry, now: now)
        }
        settled = kept
    }

    /// Takes the windows on screen, front to back as the system orders them, at `now` seconds of a
    /// clock that keeps running while the Mac sleeps. Windows not on it keep their age.
    public mutating func ingest(_ visible: [WindowListEntry], displays: [CGRect], usableAreas: [CGRect],
                                now: Double) -> WindowSnapshot {
        for entry in visible where entry.pid != ownPID && entry.layer == 0 {
            settled[Key(id: entry.id, pid: entry.pid)] = settle(entry, now: now)
        }
        noteDisplays(displays, now: now)

        var windows: [WindowInfo] = []
        for entry in visible where entry.pid != ownPID {
            guard let role = role(of: entry, displays: displays) else { continue }
            // A window seen at a new frame shows as moved at once; its record keeps the old age
            // until the next reading confirms the move.
            let record = settled[Key(id: entry.id, pid: entry.pid)]
            let since = record.map { $0.moving?.since ?? $0.since } ?? now
            windows.append(WindowInfo(id: entry.id, frame: entry.frame, role: role,
                                      stationarySeconds: (now - since) * ageScale))
        }
        let next = Layout(windows: windows.map { .init(id: $0.id, frame: $0.frame, role: $0.role) },
                          displays: displays, usableAreas: usableAreas)
        if next != layout {
            layout = next
            revision += 1
        }
        return WindowSnapshot(frontToBack: windows, layoutRevision: revision, usableAreas: usableAreas,
                              desktopSeconds: (now - (desktop?.since ?? now)) * ageScale)
    }

    public mutating func noteDisplays(_ displays: [CGRect], now: Double) {
        if desktop?.displays != displays { desktop = (displays, now) }
    }

    /// Where a window settled. Back at (or still at) its frame: unchanged. At a new frame seen
    /// twice in a row: settled there since it was first seen. Seen there once: not yet.
    private func settle(_ entry: WindowListEntry, now: Double) -> Settled {
        guard var record = settled[Key(id: entry.id, pid: entry.pid)] else { return Settled(frame: entry.frame, since: now) }
        if !Self.moved(record.frame, entry.frame) {
            record.moving = nil
        } else if let moving = record.moving, !Self.moved(moving.frame, entry.frame) {
            record = Settled(frame: entry.frame, since: moving.since)
        } else {
            record.moving = (entry.frame, now)
        }
        return record
    }

    /// Nil: not a window effects should know about.
    private func role(of entry: WindowListEntry, displays: [CGRect]) -> WindowInfo.Role? {
        // Below ordinary windows: the desktop's own elements.
        guard entry.layer >= 0, entry.alpha > 0, entry.frame.width > 0, entry.frame.height > 0 else { return nil }
        let coversDisplay = displays.contains { entry.frame.insetBy(dx: -1, dy: -1).contains($0) }
        if entry.layer > 0 {
            // A system window spanning a whole display (the Dock's) is mostly transparent, and its
            // shape is unknown: treated as covering, it would hide everything (M3-PLAN 1.2).
            return coversDisplay ? nil : .occluder
        }
        let small = entry.frame.width < Self.smallestSurface.width || entry.frame.height < Self.smallestSurface.height
        return coversDisplay || small ? .occluder : .surface
    }

    private static func moved(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) > moveTolerance || abs(a.minY - b.minY) > moveTolerance
            || abs(a.maxX - b.maxX) > moveTolerance || abs(a.maxY - b.maxY) > moveTolerance
    }
}
