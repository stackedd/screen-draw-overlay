// The pointer the user actually sees while drawing.
//
// The overlay does not ask the system for a cursor, it hides the real one and paints its
// own. That sounds like the long way round, and it is: NSCursor.hide() is per application
// and only applies while that application is active, so a background app hides nothing and
// the user ends up with two pointers. Handing the window a fully transparent cursor is what
// actually removes the system one, and it needs no permission.
//
// Two shapes: a crosshair for aiming a pen, and a glowing dot for the laser, which is a
// pointer rather than a pen and should look like one.

import AppKit

enum PointerCursor {
    // Modest: big enough to aim with, small enough not to sit on the content.
    static let size: CGFloat = 20
    private static let casingWidth: CGFloat = 3
    private static let centreGap: CGFloat = 3.5

    // A cursor made of nothing, so only the drawn pointer below is visible.
    static let transparent: NSCursor = {
        let image = NSImage(size: NSSize(width: 16, height: 16))
        image.lockFocus()
        NSColor.clear.setFill()
        NSRect(origin: .zero, size: image.size).fill(using: .copy)
        image.unlockFocus()

        return NSCursor(image: image, hotSpot: NSPoint(x: 8, y: 8))
    }()

    // What has to be repainted when the pointer arrives at or leaves a spot.
    static func rect(at point: NSPoint) -> NSRect {
        NSRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size)
            .insetBy(dx: -casingWidth, dy: -casingWidth)
    }

    static func draw(at point: NSPoint, tools: ToolSettings) {
        guard tools.tool != .laser else {
            drawLaserDot(at: point, colour: tools.color)
            return
        }

        drawCrosshair(at: point)
    }

    private static func drawLaserDot(at point: NSPoint, colour: NSColor) {
        let core = size / 3
        colour.withAlphaComponent(0.28).setFill()
        NSBezierPath(ovalIn: NSRect(x: point.x - core, y: point.y - core,
                                    width: core * 2, height: core * 2)).fill()
        colour.setFill()
        NSBezierPath(ovalIn: NSRect(x: point.x - core / 2, y: point.y - core / 2,
                                    width: core, height: core)).fill()
    }

    private static func drawCrosshair(at point: NSPoint) {
        let half = size / 2
        let crosshair = NSBezierPath()
        crosshair.move(to: NSPoint(x: point.x - half, y: point.y))
        crosshair.line(to: NSPoint(x: point.x - centreGap, y: point.y))
        crosshair.move(to: NSPoint(x: point.x + centreGap, y: point.y))
        crosshair.line(to: NSPoint(x: point.x + half, y: point.y))
        crosshair.move(to: NSPoint(x: point.x, y: point.y - half))
        crosshair.line(to: NSPoint(x: point.x, y: point.y - centreGap))
        crosshair.move(to: NSPoint(x: point.x, y: point.y + centreGap))
        crosshair.line(to: NSPoint(x: point.x, y: point.y + half))
        crosshair.lineCapStyle = .round

        // Light casing under a dark core, so it reads on a white slide and on a dark one.
        crosshair.lineWidth = casingWidth
        NSColor.white.withAlphaComponent(0.9).setStroke()
        crosshair.stroke()
        crosshair.lineWidth = 1
        NSColor.black.withAlphaComponent(0.85).setStroke()
        crosshair.stroke()
    }
}
