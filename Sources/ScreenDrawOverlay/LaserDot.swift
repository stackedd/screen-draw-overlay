// The laser: a glow that follows the pointer.
//
// It is a layer on the overlay rather than a decoration on the cursor, and that is the whole
// point of it. A cursor is only ours while we own the window under the pointer, and the one
// thing a laser has to do is be there - in the middle of a presentation, over anything, on
// whatever the audience is looking at. The glow does not care who owns the cursor.
//
// Following it costs a layer move and no repaint: measured at 1.5% of a core at sixty moves
// a second, against 15.2% for asking the overlay to repaint instead.
//
// It follows by polling NSEvent.mouseLocation, not by mouseMoved. Mouse-moved events only
// reach the key window, and these panels are non-activating - so the moment the user had
// clicked anything in another app the events stopped and the laser hung in the air where it
// was last lit. The wheel already had to solve this; the answer is the same one.

import AppKit
import QuartzCore

enum LaserDot {
    // Big enough to spot from the back of a room, small enough not to hide what it points at.
    static let extent: CGFloat = 54

    private static var glows: [Int: CGImage] = [:]

    // The picture, cached per colour: there are six of them and they never change.
    static func glow(_ colour: NSColor, scale: CGFloat) -> CGImage? {
        let key = Int(scale * 10) * 1000 + (ToolSettings.colors.firstIndex(of: colour) ?? 0)
        if let cached = glows[key] {
            return cached
        }

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
        // A halo that falls off to nothing, then a hot core inside it - which is what a laser
        // spot looks like and what makes it read as light rather than as a drawn circle.
        let halo = NSGradient(colors: [colour.withAlphaComponent(0.62),
                                       colour.withAlphaComponent(0.26),
                                       colour.withAlphaComponent(0)],
                              atLocations: [0, 0.45, 1], colorSpace: .deviceRGB)
        halo?.draw(fromCenter: centre, radius: 0, toCenter: centre, radius: extent / 2, options: [])

        let core = extent * 0.16
        colour.setFill()
        NSBezierPath(ovalIn: NSRect(x: centre.x - core, y: centre.y - core,
                                    width: core * 2, height: core * 2)).fill()
        NSColor.white.withAlphaComponent(0.85).setFill()
        NSBezierPath(ovalIn: NSRect(x: centre.x - core / 2.2, y: centre.y - core / 2.2,
                                    width: core / 1.1, height: core / 1.1)).fill()

        NSGraphicsContext.restoreGraphicsState()

        let image = rep.cgImage
        glows[key] = image

        return image
    }

    // A layer set up to follow a pointer: no implicit animation, or the light lags the hand.
    static func makeLayer() -> CALayer {
        let layer = CALayer()
        layer.bounds = NSRect(x: 0, y: 0, width: extent, height: extent)
        layer.actions = ["position": NSNull(), "contents": NSNull(),
                         "hidden": NSNull(), "bounds": NSNull()]
        layer.isHidden = true

        return layer
    }
}
