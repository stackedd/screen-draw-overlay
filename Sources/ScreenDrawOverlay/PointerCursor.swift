// The pointer the user sees while drawing: one cursor per tool, in the colour in hand.
//
// The history here is worth keeping, because it is a loop that has been walked twice.
//
// **Tried:** `NSCursor.crosshair`, and `NSCursor.hide()` with `CGDisplayShowCursor`. Hiding
// is per application and only applies while that application is active, so a background
// `.accessory` app hides nothing; that attempt put two pointers on screen at once.
//
// **Tried:** a fully transparent cursor with the app painting its own crosshair underneath.
// It works only while we own the window under the pointer, and the moment something else
// takes the cursor - the menu bar does it reliably - the real arrow is back for good with
// our crosshair still painted beside it. No failure mode between invisible and doubled.
//
// **Tried:** the system arrow with a coloured ring composited around its tip. Safe, and
// nobody liked it: an arrow is what you get when nothing is happening, so an overlay that
// is taking every click on the screen looked exactly like one that was not.
//
// **Now:** each tool draws its own pointer, in the colour it will draw with, with the point
// that matters on the hot spot. A pen is a nib, a highlighter is a chisel, a shape tool is a
// crosshair with the shape it makes beside it, the eraser is a ring the size of the hole it
// leaves, and the laser has none at all because its glow is on the overlay and two marks are
// worse than one. Losing cursor ownership degrades to the plain system arrow, which is a
// thing the user can see and understand rather than a bug.
//
// Everything is drawn light-cased over a dark core, or the reverse, so it reads on a white
// slide and a black one. The hot spot is the centre of the image in every case, which the
// behaviour suite checks: hot spot, the point the tool works from, and the point the ink
// lands on all have to be the same point.

import AppKit

enum PointerCursor {
    private static let casing: CGFloat = 3

    private struct Key: Hashable {
        let tool: DrawingTool
        let colour: Int
        let width: CGFloat
        let eraserRadius: CGFloat
    }

    // Rebuilt only when the tool, colour or width changes, which is a keypress, never a
    // mouse move.
    private static var cache: [Key: NSCursor] = [:]

    static func cursor(for tools: ToolSettings) -> NSCursor {
        let key = Key(tool: tools.tool, colour: tools.colorIndex,
                      width: tools.renderWidth, eraserRadius: tools.eraserRadius)
        if let cached = cache[key] {
            return cached
        }

        let made = make(tool: tools.tool, colour: tools.color,
                        width: tools.renderWidth, eraserRadius: tools.eraserRadius)
        cache[key] = made

        return made
    }

    // How far the drawing reaches from the hot spot, which decides the size of the square it
    // is drawn in. The hot spot is always the middle of that square.
    private static func reach(of tool: DrawingTool, eraserRadius: CGFloat) -> CGFloat {
        switch tool {
        case .eraser: return eraserRadius + casing
        case .laser: return 6
        case .pen, .highlighter: return 30
        default: return 26
        }
    }

    private static func make(tool: DrawingTool, colour: NSColor,
                             width: CGFloat, eraserRadius: CGFloat) -> NSCursor {
        let side = ceil(reach(of: tool, eraserRadius: eraserRadius)) * 2
        let centre = NSPoint(x: side / 2, y: side / 2)

        // Drawn through a handler rather than into a bitmap, so the cursor is redrawn at
        // whatever resolution the display it lands on needs.
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            draw(tool, colour: colour, width: width, eraserRadius: eraserRadius, at: centre)
            return true
        }

        return NSCursor(image: image, hotSpot: centre)
    }

    private static func draw(_ tool: DrawingTool, colour: NSColor,
                             width: CGFloat, eraserRadius: CGFloat, at tip: NSPoint) {
        switch tool {
        case .laser:
            // Nothing. The glow on the overlay is the pointer, and it is there whoever owns
            // the cursor - which a cursor cannot promise.
            break
        case .eraser:
            drawEraser(at: tip, radius: eraserRadius)
        case .pen:
            drawNib(at: tip, colour: colour, width: width, chisel: false)
        case .highlighter:
            drawNib(at: tip, colour: colour, width: width, chisel: true)
        default:
            drawCrosshair(at: tip, colour: colour)
            drawShapeGlyph(tool, at: NSPoint(x: tip.x + 15, y: tip.y + 15), colour: colour)
        }
    }

    // A nib, point down-left, with the point on the hot spot. The barrel goes up and right,
    // away from what is being drawn, so the ink appears in front of the hand rather than
    // under the cursor.
    private static func drawNib(at tip: NSPoint, colour: NSColor, width: CGFloat, chisel: Bool) {
        let spread: CGFloat = chisel ? 8 : 5
        let length: CGFloat = chisel ? 17 : 15

        let nib = NSBezierPath()
        nib.move(to: tip)
        nib.line(to: NSPoint(x: tip.x + spread, y: tip.y + length))
        nib.line(to: NSPoint(x: tip.x + length, y: tip.y + spread))
        nib.close()

        // The barrel: a stub of the pen behind the nib, thick enough to read at a glance and
        // scaled a little by the width in hand.
        let barrel = NSBezierPath()
        let start = NSPoint(x: tip.x + (spread + length) / 2, y: tip.y + (spread + length) / 2)
        barrel.move(to: start)
        barrel.line(to: NSPoint(x: start.x + 11, y: start.y + 11))
        barrel.lineWidth = min(max(width, 4), 11) + 3
        barrel.lineCapStyle = .round

        NSColor.white.withAlphaComponent(0.95).setStroke()
        nib.lineWidth = casing
        nib.lineJoinStyle = .round
        nib.stroke()
        barrel.stroke()

        colour.withAlphaComponent(chisel ? 0.6 : 1).setFill()
        nib.fill()
        barrel.lineWidth = min(max(width, 4), 11)
        colour.withAlphaComponent(chisel ? 0.6 : 1).setStroke()
        barrel.stroke()
    }

    // A ring the size of what it will rub out. It is the only cursor that changes size, and
    // it does so because the size is the whole point of it.
    private static func drawEraser(at centre: NSPoint, radius: CGFloat) {
        let ring = NSBezierPath(ovalIn: NSRect(x: centre.x - radius, y: centre.y - radius,
                                               width: radius * 2, height: radius * 2))
        ring.lineWidth = casing
        NSColor.white.withAlphaComponent(0.95).setStroke()
        ring.stroke()
        ring.lineWidth = 1.5
        NSColor.black.withAlphaComponent(0.85).setStroke()
        ring.stroke()
    }

    // For the tools that place a corner: a fine cross with a gap in the middle, so the
    // exact point stays visible.
    private static func drawCrosshair(at centre: NSPoint, colour: NSColor) {
        let arm: CGFloat = 11
        let gap: CGFloat = 3.5

        let cross = NSBezierPath()
        for (dx, dy) in [(-1.0, 0.0), (1.0, 0.0), (0.0, -1.0), (0.0, 1.0)] {
            cross.move(to: NSPoint(x: centre.x + CGFloat(dx) * gap, y: centre.y + CGFloat(dy) * gap))
            cross.line(to: NSPoint(x: centre.x + CGFloat(dx) * arm, y: centre.y + CGFloat(dy) * arm))
        }
        cross.lineCapStyle = .round

        cross.lineWidth = casing
        NSColor.white.withAlphaComponent(0.95).setStroke()
        cross.stroke()
        cross.lineWidth = 1.2
        NSColor.black.withAlphaComponent(0.85).setStroke()
        cross.stroke()
    }

    // The shape the tool makes, small, beside the cross. Every tool brings its own context;
    // this is the cheapest possible version of that.
    private static func drawShapeGlyph(_ tool: DrawingTool, at seat: NSPoint, colour: NSColor) {
        let size: CGFloat = 9
        let box = NSRect(x: seat.x - size / 2, y: seat.y - size / 2, width: size, height: size)

        let glyph = NSBezierPath()
        switch tool {
        case .rectangle:
            glyph.appendRect(box)
        case .ellipse:
            glyph.appendOval(in: box)
        case .arrow:
            glyph.move(to: NSPoint(x: box.minX, y: box.minY))
            glyph.line(to: NSPoint(x: box.maxX, y: box.maxY))
            glyph.move(to: NSPoint(x: box.maxX - size * 0.55, y: box.maxY))
            glyph.line(to: NSPoint(x: box.maxX, y: box.maxY))
            glyph.line(to: NSPoint(x: box.maxX, y: box.maxY - size * 0.55))
        default:
            glyph.move(to: NSPoint(x: box.minX, y: box.minY))
            glyph.line(to: NSPoint(x: box.maxX, y: box.maxY))
        }
        glyph.lineJoinStyle = .round
        glyph.lineCapStyle = .round

        glyph.lineWidth = casing
        NSColor.white.withAlphaComponent(0.95).setStroke()
        glyph.stroke()
        glyph.lineWidth = 1.6
        colour.setStroke()
        glyph.stroke()
    }
}
