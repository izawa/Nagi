import CoreGraphics
import Foundation
import NagiCore
import NagiKit
import Testing

/// The window service's rules (M3-PLAN 3.2, 3.3), with a fake list and clock.
struct WindowTrackerTests {
    let display = CGRect(x: 0, y: 0, width: 2560, height: 1440)
    let own: Int32 = 99

    func entry(_ id: UInt32, _ frame: CGRect, pid: Int32 = 10, layer: Int = 0, alpha: Double = 1) -> WindowListEntry {
        WindowListEntry(id: id, pid: pid, layer: layer, alpha: alpha, frame: frame)
    }

    func ingest(_ tracker: inout WindowTracker, _ entries: [WindowListEntry], at now: Double) -> WindowSnapshot {
        tracker.ingest(entries, displays: [display], usableAreas: [display], now: now)
    }

    let a = CGRect(x: 100, y: 100, width: 800, height: 600)

    @Test func ageCountsWhileTheFrameStays() {
        var tracker = WindowTracker(ownPID: own)
        #expect(ingest(&tracker, [entry(1, a)], at: 1000).frontToBack.first?.stationarySeconds == 0)
        #expect(ingest(&tracker, [entry(1, a)], at: 1599).frontToBack.first?.stationarySeconds == 599)
        #expect(ingest(&tracker, [entry(1, a)], at: 8200).frontToBack.first?.stationarySeconds == 7200)
    }

    @Test func movingOrResizingStartsOver() {
        var tracker = WindowTracker(ownPID: own)
        _ = ingest(&tracker, [entry(1, a)], at: 0)
        // Within a point: the same frame.
        #expect(ingest(&tracker, [entry(1, a.offsetBy(dx: 0.8, dy: 0))], at: 100).frontToBack[0].stationarySeconds == 100)
        // A new frame shows as moved at once; the record follows once the next reading finds it
        // there too, counting from when it was first seen.
        #expect(ingest(&tracker, [entry(1, a.offsetBy(dx: 5, dy: 0))], at: 200).frontToBack[0].stationarySeconds == 0)
        #expect(ingest(&tracker, [entry(1, a.offsetBy(dx: 5, dy: 0))], at: 210).frontToBack[0].stationarySeconds == 10)
        let resized = CGRect(x: 105, y: 100, width: 700, height: 600)
        _ = ingest(&tracker, [entry(1, resized)], at: 300)
        #expect(ingest(&tracker, [entry(1, resized)], at: 305).frontToBack[0].stationarySeconds == 5)
    }

    @Test func slidingThroughASpaceSwitchIsNotMoving() {
        // Mid-slide the list reports each window somewhere else every time, then back where it was.
        var tracker = WindowTracker(ownPID: own)
        _ = ingest(&tracker, [entry(1, a)], at: 0)
        _ = ingest(&tracker, [entry(1, a.offsetBy(dx: -900, dy: 0))], at: 100)
        _ = ingest(&tracker, [entry(1, a.offsetBy(dx: -400, dy: 0))], at: 100.2)
        #expect(ingest(&tracker, [entry(1, a)], at: 101).frontToBack[0].stationarySeconds == 101)
        tracker.prune([entry(1, a.offsetBy(dx: -300, dy: 0))], displays: [display], now: 130)
        #expect(ingest(&tracker, [entry(1, a)], at: 160).frontToBack[0].stationarySeconds == 160)
    }

    @Test func creepingAddsUpAgainstWhereItSettled() {
        var tracker = WindowTracker(ownPID: own)
        _ = ingest(&tracker, [entry(1, a)], at: 0)
        #expect(ingest(&tracker, [entry(1, a.offsetBy(dx: 0.6, dy: 0))], at: 10).frontToBack[0].stationarySeconds == 10)
        _ = ingest(&tracker, [entry(1, a.offsetBy(dx: 1.2, dy: 0))], at: 20)
        #expect(ingest(&tracker, [entry(1, a.offsetBy(dx: 1.2, dy: 0))], at: 25).frontToBack[0].stationarySeconds == 5)
    }

    @Test func comingToTheFrontIsNotMoving() {
        var tracker = WindowTracker(ownPID: own)
        let b = CGRect(x: 400, y: 300, width: 800, height: 600)
        _ = ingest(&tracker, [entry(1, a), entry(2, b)], at: 0)
        let swapped = ingest(&tracker, [entry(2, b), entry(1, a)], at: 50)
        #expect(swapped.frontToBack.map(\.id) == [2, 1])
        #expect(swapped.frontToBack.map(\.stationarySeconds) == [50, 50])
    }

    @Test func offScreenWindowsKeepTheirAge() {
        // Minimized or on another Space: still in the whole list, so the age goes on.
        var tracker = WindowTracker(ownPID: own)
        _ = ingest(&tracker, [entry(1, a)], at: 0)
        #expect(ingest(&tracker, [], at: 100).frontToBack.isEmpty)
        tracker.prune([entry(1, a)], displays: [display], now: 400)
        #expect(ingest(&tracker, [entry(1, a)], at: 900).frontToBack[0].stationarySeconds == 900)
        // Moved while off screen: the whole list tells.
        tracker.prune([entry(1, a.offsetBy(dx: 50, dy: 0))], displays: [display], now: 1000)
        tracker.prune([entry(1, a.offsetBy(dx: 50, dy: 0))], displays: [display], now: 1030)
        #expect(ingest(&tracker, [entry(1, a.offsetBy(dx: 50, dy: 0))], at: 1100).frontToBack[0].stationarySeconds == 100)
    }

    @Test func aWindowGoneFromTheListIsForgotten() {
        var tracker = WindowTracker(ownPID: own)
        _ = ingest(&tracker, [entry(1, a)], at: 0)
        tracker.prune([], displays: [display], now: 100)
        // The same number again is another window.
        #expect(ingest(&tracker, [entry(1, a)], at: 200).frontToBack[0].stationarySeconds == 0)
    }

    @Test func roles() {
        var tracker = WindowTracker(ownPID: own)
        let snapshot = ingest(&tracker, [
            entry(1, CGRect(x: 0, y: 0, width: 2560, height: 30), layer: 24),  // the menu bar
            entry(2, display, layer: 20),  // the Dock's window spans the display
            entry(3, CGRect(x: 0, y: 0, width: 400, height: 400), pid: own),  // our overlay
            entry(4, CGRect(x: 10, y: 10, width: 100, height: 50)),  // small
            entry(5, display),  // full screen
            entry(6, a, alpha: 0),
            entry(7, a, layer: -2147483601),
            entry(8, a, alpha: 0.9),
        ], at: 0)
        #expect(snapshot.frontToBack.map(\.id) == [1, 4, 5, 8])
        #expect(snapshot.frontToBack.map(\.role) == [.occluder, .occluder, .occluder, .surface])
    }

    @Test func revisionFollowsTheLayoutNotTime() {
        var tracker = WindowTracker(ownPID: own)
        let first = ingest(&tracker, [entry(1, a)], at: 0).layoutRevision
        #expect(ingest(&tracker, [entry(1, a)], at: 100).layoutRevision == first)
        // The layout follows what is on screen at once, even before a move counts for the age.
        #expect(ingest(&tracker, [entry(1, a.offsetBy(dx: 10, dy: 0))], at: 200).layoutRevision == first + 1)
    }

    @Test func desktopAgeFollowsTheDisplays() {
        var tracker = WindowTracker(ownPID: own)
        // Counted from the first reading of either kind: while nagi does not show, too.
        tracker.prune([], displays: [display], now: 0)
        #expect(ingest(&tracker, [], at: 500).desktopSeconds == 500)
        let wider = tracker.ingest([], displays: [display, display.offsetBy(dx: 2560, dy: 0)],
                                   usableAreas: [display], now: 600)
        #expect(wider.desktopSeconds == 0)
    }

    @Test func ageScaleMultipliesEveryAge() {
        var tracker = WindowTracker(ownPID: own)
        tracker.ageScale = 60
        _ = ingest(&tracker, [entry(1, a)], at: 0)
        let later = ingest(&tracker, [entry(1, a)], at: 10)
        #expect(later.frontToBack[0].stationarySeconds == 600)
        #expect(later.desktopSeconds == 600)
    }

    @Test func layoutsRejectBadShapes() {
        let bad = Data(#"{"size": [], "windows": []}"#.utf8)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(WindowLayout.self, from: bad) }
        let short = Data(#"{"size": [100, 100], "windows": [{"id": 1, "rect": [1, 2]}]}"#.utf8)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(WindowLayout.self, from: short) }
    }

    @Test func layoutsScaleToTheDisplay() throws {
        let layout = try WindowLayout.named("single")
        let snapshot = layout.snapshot(on: CGRect(x: 0, y: 0, width: 2560, height: 1440), age: 3600)
        #expect(snapshot.frontToBack[0].frame == CGRect(x: 400, y: 320, width: 1760, height: 920))
        #expect(snapshot.aged(by: 60).frontToBack[0].stationarySeconds == 3660)
    }
}
