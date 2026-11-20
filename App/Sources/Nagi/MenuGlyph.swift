import AppKit

/// The menu-bar glyph (DECISIONS D30): the app icon's scene reduced to a template image. A drop
/// above two rings; while paused, only the still water's ring. Drawn on a 36-unit grid (18 pt).
@MainActor enum MenuGlyph {
    static let normal = image(paused: false)
    static let paused = image(paused: true)

    private static func image(paused: Bool) -> NSImage {
        // AppKit may call the drawing handler on any thread, so it is not isolated to the main actor.
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { @Sendable _ in
            let transform = NSAffineTransform()
            transform.scale(by: 0.5)
            transform.concat()
            NSColor.black.set()
            if paused {
                stroke(oval(x: 18, y: 24, rx: 13, ry: 3.8), width: 2.4)
            } else {
                drop().fill()
                stroke(oval(x: 18, y: 27, rx: 4.6, ry: 1.3), width: 2)
                stroke(oval(x: 18, y: 27, rx: 15.5, ry: 4.8), width: 2)
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    /// A teardrop: a point at the top, a round bottom (radius 5.2 around (18, 13)).
    nonisolated private static func drop() -> NSBezierPath {
        let path = NSBezierPath()
        let k = 0.5523 * 5.2  // a quarter circle as a cubic
        path.move(to: NSPoint(x: 18, y: 3))
        path.curve(to: NSPoint(x: 12.8, y: 13), controlPoint1: NSPoint(x: 15.2, y: 7), controlPoint2: NSPoint(x: 12.8, y: 10))
        path.curve(to: NSPoint(x: 18, y: 18.2), controlPoint1: NSPoint(x: 12.8, y: 13 + k), controlPoint2: NSPoint(x: 18 - k, y: 18.2))
        path.curve(to: NSPoint(x: 23.2, y: 13), controlPoint1: NSPoint(x: 18 + k, y: 18.2), controlPoint2: NSPoint(x: 23.2, y: 13 + k))
        path.curve(to: NSPoint(x: 18, y: 3), controlPoint1: NSPoint(x: 23.2, y: 10), controlPoint2: NSPoint(x: 20.8, y: 7))
        path.close()
        return path
    }

    nonisolated private static func oval(x: Double, y: Double, rx: Double, ry: Double) -> NSBezierPath {
        NSBezierPath(ovalIn: NSRect(x: x - rx, y: y - ry, width: 2 * rx, height: 2 * ry))
    }

    nonisolated private static func stroke(_ path: NSBezierPath, width: Double) {
        path.lineWidth = width
        path.stroke()
    }
}
