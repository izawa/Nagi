import AppKit
import CoreGraphics
import NagiKit

/// Reads the window list off the main thread and keeps the latest snapshot (SPEC 3.10,
/// M3-PLAN 3.4). Needs no permission: only numbers, frames, layers and process ids are read.
@MainActor public final class WindowService {
    /// The latest snapshot; nil after `invalidate` until a new `.visible` reading.
    public private(set) var snapshot: WindowSnapshot?
    /// Debug: multiplies every age (M3-PLAN 3.3).
    public var ageScale: Double {
        get { tracker.ageScale }
        set { tracker.ageScale = newValue }
    }
    /// Milliseconds each reading took (`--trace`).
    public var onRead: ((Double) -> Void)?
    /// What the readings found when it changes (`--trace`): counts and ages, never names.
    public var onNote: ((String) -> Void)?

    private var tracker = WindowTracker(ownPID: ProcessInfo.processInfo.processIdentifier)
    private var reading = false
    /// A reading was asked for while a stale one was under way: start it when that one returns.
    private var queued: Kind?
    private var generation = 0
    private let queue = DispatchQueue(label: "org.izawa.Nagi.windows", qos: .userInitiated)
    private let list: @Sendable (Kind) -> [WindowListEntry]?

    /// What a reading asks the system for.
    public enum Kind: Sendable {
        /// The windows on screen, front to back: the snapshot (while nagi shows).
        case visible
        /// Every window, on screen or not, in no promised order: the ages only (while nagi does not show).
        case all
    }

    /// - Parameter list: the system's window list of a kind; nil when it cannot be read. Tests pass a fake.
    public init(list: @escaping @Sendable (Kind) -> [WindowListEntry]? = WindowService.systemList) {
        self.list = list
    }

    /// Seconds on a clock that keeps running while the Mac sleeps (M3-PLAN 3.3, DECISIONS D32).
    public static var now: Double {
        let since = ContinuousClock.now - origin
        return Double(since.components.seconds) + Double(since.components.attoseconds) * 1e-18
    }
    private static let origin = ContinuousClock.now

    /// Asks for a reading unless one is under way (false then). A `.visible` reading replaces the snapshot.
    @discardableResult public func refresh(_ kind: Kind) -> Bool {
        guard !reading else { return false }
        reading = true
        let generation = generation, list = list
        let asked = Self.now
        queue.async { [weak self] in
            let start = DispatchTime.now()
            let entries = list(kind)
            let milliseconds = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e6
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.apply(entries, kind: kind, generation: generation, asked: asked, milliseconds: milliseconds)
                }
            }
        }
        return true
    }

    /// The displays may have been arranged anew: the desktop's age starts over now if they were,
    /// even if they are back as they were by the next reading.
    public func displaysMayHaveChanged() {
        tracker.noteDisplays(Self.displays().frames, now: Self.now)
    }

    /// The screen changed (displays, Space) or the showing ended: the snapshot and a reading under
    /// way may describe the screen before. Neither is offered again; the windows' ages are kept.
    /// `then` is asked for once the reading under way has returned.
    public func invalidate(then kind: Kind? = nil) {
        generation += 1
        snapshot = nil
        if reading { queued = kind } else if let kind { refresh(kind) }
    }

    private func apply(_ entries: [WindowListEntry]?, kind: Kind, generation: Int, asked: Double, milliseconds: Double) {
        reading = false
        onRead?(milliseconds)
        guard generation == self.generation else {
            if let queued {
                self.queued = nil
                refresh(queued)
            }
            return
        }
        // An unreadable list says nothing about the windows: the ages stay, but the last snapshot
        // may be out of date, so none is offered until a reading succeeds.
        guard let entries else {
            onNote?("window list unreadable (\(kind))")
            if kind == .visible { snapshot = nil }
            return
        }
        let (displays, usable) = Self.displays()
        switch kind {
        case .all:
            tracker.prune(entries, displays: displays, now: asked)
            onNote?("window list all n=\(entries.count)")
        case .visible:
            let previous = snapshot?.layoutRevision
            snapshot = tracker.ingest(entries, displays: displays, usableAreas: usable, now: asked)
            if let snapshot, snapshot.layoutRevision != previous {
                let ages = snapshot.frontToBack.filter { $0.role == .surface }
                    .map { "\($0.id):" + String(format: "%.0f", $0.stationarySeconds) }.joined(separator: " ")
                onNote?("windows rev=\(snapshot.layoutRevision) n=\(snapshot.frontToBack.count) ages \(ages)")
            }
        }
    }

    /// The displays and their areas without the menu bar and the Dock, in desktop points.
    static func displays() -> (frames: [CGRect], usable: [CGRect]) {
        let screens = NSScreen.screens
        let primaryHeight = screens.first?.frame.height ?? 0
        func flip(_ rect: CGRect) -> CGRect {
            CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
        }
        return (screens.map { flip($0.frame) }, screens.map { flip($0.visibleFrame) })
    }

    /// The system's window list. Only the on-screen list is promised front to back. Nil when a row
    /// lacks what is needed: better no windows than wrong ones in front.
    public nonisolated static func systemList(_ kind: Kind) -> [WindowListEntry]? {
        let options: CGWindowListOption = kind == .visible ? [.optionOnScreenOnly, .excludeDesktopElements]
            : [.optionAll, .excludeDesktopElements]
        guard let rows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return nil }
        var entries: [WindowListEntry] = []
        entries.reserveCapacity(rows.count)
        for row in rows {
            guard let id = row[kCGWindowNumber as String] as? UInt32,
                  let pid = row[kCGWindowOwnerPID as String] as? Int32,
                  let layer = row[kCGWindowLayer as String] as? Int,
                  let bounds = row[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds) else { return nil }
            let alpha = row[kCGWindowAlpha as String] as? Double ?? 1
            entries.append(WindowListEntry(id: id, pid: pid, layer: layer, alpha: alpha, frame: frame))
        }
        return entries
    }
}
