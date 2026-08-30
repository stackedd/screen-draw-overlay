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
//
// It is handed over as a picture rather than painted where the pointer is. The view carries
// it on a layer of its own and moving that layer is not a repaint at all: measured, asking
// the overlay to repaint where the pointer was and where it arrived costs 15.2% of a core at
// 60 moves a second, and moving a layer costs 1.5% (docs/ARCHITECTURE.md).

import AppKit

enum PointerCursor {
    // Modest: big enough to aim with, small enough not to sit on the content.
    static let size: CGFloat = 20
    private static let casingWidth: CGFloat = 3
    private static let centreGap: CGFloat = 3.5

    // The pointer's picture is this big: the crosshair plus the casing that outlines it.
    static let extent = size + casingWidth * 2

    // A cursor made of nothing, so only the drawn pointer below is visible.
    static let transparent: NSCursor = {
        let image = NSImage(size: NSSize(width: 16, height: 16))
        image.lockFocus()
        NSColor.clear.setFill()
        NSRect(origin: .zero, size: image.size).fill(using: .copy)
        image.unlockFocus()

        return NSCursor(image: image, hotSpot: NSPoint(x: 8, y: 8))
    }()

    // The pointer as a picture, centred, at the display's backing scale. Drawn once per
    // tool and colour rather than once per mouse move.
    static func image(tool: DrawingTool, colour: NSColor, scale: CGFloat) -> CGImage? {
        let pixels = Int((extent * scale).rounded())
        guard pixels > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else {
            return nil
        }

        rep.size = NSSize(width: extent, height: extent)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let centre = NSPoint(x: extent / 2, y: extent / 2)
        if tool == .laser {
            drawLaserDot(at: centre, colour: colour)
        } else {
            drawCrosshair(at: centre)
        }
        NSGraphicsContext.restoreGraphicsState()

        return rep.cgImage
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
