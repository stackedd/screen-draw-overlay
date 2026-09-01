// The laser: a glow that follows the pointer.
//
// It is a layer on the overlay rather than a decoration on the cursor, and that is the whole
// point of it. A cursor is only ours while we own the window under the pointer, and the one
// thing a laser has to do is be there - in the middle of a presentation, over anything, on
// whatever the audience is looking at. The glow does not care who owns the cursor.
//
// What it leaves behind is not drawn here: holding the button draws an ordinary stroke that
// happens to live half a second, which is the fading-ink machinery doing its job. A trail of
// little dots was tried instead and looked exactly like what it was - beads, appearing and
// vanishing under a pointer nobody had pressed.
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
    // Big enough to spot from the back of a room, small enough not to hide what it points at -
    // and it follows the width in hand, because the size wheel means something to the laser
    // now. The middle setting is the 54pt this has always been; the ends are a fine pointer
    // and one somebody at the back of a hall can follow. Capped, because past a certain size
    // it stops pointing at anything.
    static func extent(for width: CGFloat) -> CGFloat {
        min(96, (34 + width * 3.3).rounded())
    }

    private struct Key: Hashable {
        let colour: Int
        let width: CGFloat
        let scale: CGFloat
    }

    private static var glows: [Key: CGImage] = [:]

    // The picture, cached: a handful of colours by a handful of widths, and none of them
    // change once drawn.
    static func glow(_ colour: NSColor, width: CGFloat, scale: CGFloat) -> CGImage? {
        let key = Key(colour: ToolSettings.colors.firstIndex(of: colour) ?? 0,
                      width: width, scale: scale)
        if let cached = glows[key] {
            return cached
        }

        let extent = extent(for: width)
        let image = Picture.drawn(size: NSSize(width: extent, height: extent), scale: scale) {
            let centre = NSPoint(x: extent / 2, y: extent / 2)
            // A halo that falls off to nothing, then a hot core inside it - which is what a
            // laser spot looks like and what makes it read as light rather than as a drawn
            // circle.
            let halo = NSGradient(colors: [colour.withAlphaComponent(0.62),
                                           colour.withAlphaComponent(0.26),
                                           colour.withAlphaComponent(0)],
                                  atLocations: [0, 0.45, 1], colorSpace: .deviceRGB)
            halo?.draw(fromCenter: centre, radius: 0, toCenter: centre, radius: extent / 2,
                       options: [])

            let core = extent * 0.16
            colour.setFill()
            NSBezierPath(ovalIn: NSRect(x: centre.x - core, y: centre.y - core,
                                        width: core * 2, height: core * 2)).fill()
            NSColor.white.withAlphaComponent(0.85).setFill()
            NSBezierPath(ovalIn: NSRect(x: centre.x - core / 2.2, y: centre.y - core / 2.2,
                                        width: core / 1.1, height: core / 1.1)).fill()
        }

        glows[key] = image

        return image
    }

    // A layer set up to follow a pointer: no implicit animation, or the light lags the hand.
    // Its bounds are set with the picture, which changes with the width in hand.
    static func makeLayer() -> CALayer {
        let layer = CALayer()
        layer.actions = ["position": NSNull(), "contents": NSNull(),
                         "hidden": NSNull(), "bounds": NSNull()]
        layer.isHidden = true

        return layer
    }
}
