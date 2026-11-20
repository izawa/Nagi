import CoreGraphics

/// The windows on the screen, for effects that declare `.windows` (SPEC 3.10, M3-PLAN 3.1).
/// Coordinates are desktop points, top-left origin, as `FrameState.displays`.
public struct WindowSnapshot: Sendable, Equatable {
    /// Front to back: the order in the array is the stacking order.
    public var frontToBack: [WindowInfo]
    /// Grows when a window's id, frame, order or role changes, or the displays do; not as time
    /// passes. An effect rebuilds its shapes when it changes.
    public var layoutRevision: UInt64
    /// Each display without the menu bar and the Dock.
    public var usableAreas: [CGRect]
    /// Seconds the displays have kept their arrangement: the age of things growing on the desktop
    /// itself, such as moss in the screen's corners.
    public var desktopSeconds: Double

    public init(frontToBack: [WindowInfo], layoutRevision: UInt64, usableAreas: [CGRect], desktopSeconds: Double) {
        self.frontToBack = frontToBack
        self.layoutRevision = layoutRevision
        self.usableAreas = usableAreas
        self.desktopSeconds = desktopSeconds
    }
}

public struct WindowInfo: Sendable, Equatable {
    /// The window number: stable while the window lives, a seed for its look.
    public var id: UInt32
    public var frame: CGRect
    public var role: Role
    /// Seconds the window has kept its current frame (moving or resizing starts it over). Only
    /// ordinary windows are followed: a window above them (the menu bar, a panel) reports 0.
    public var stationarySeconds: Double

    public enum Role: Sendable, Equatable {
        /// An ordinary window: things may grow on it, and it covers what is behind it.
        case surface
        /// Only covers what is behind it: the menu bar, an open menu, a panel, a full-screen window.
        case occluder
    }

    public init(id: UInt32, frame: CGRect, role: Role, stationarySeconds: Double) {
        self.id = id
        self.frame = frame
        self.role = role
        self.stationarySeconds = stationarySeconds
    }
}
