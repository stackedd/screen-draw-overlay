// The pointer the user sees while drawing: one picture per tool, in the colour in hand.
//
// The history here is worth keeping, because it is a loop that has been walked three times.
//
// **Tried:** `NSCursor.crosshair`, and `NSCursor.hide()` with `CGDisplayShowCursor`. Hiding is
// per application and only applies while that application is active, so a background
// `.accessory` app hides nothing; that attempt put two pointers on screen at once.
//
// **Tried:** a fully transparent cursor with the app painting its own crosshair underneath, in
// `draw(_:)`. It worked and it cost 22.5% of a core, because painting a pointer meant
// repainting a full screen transparent overlay on every mouse move.
//
// **Then:** each tool as a real `NSCursor`, handed to the window server. Free to follow, one
// pointer always, and it degraded to the system arrow if something else took the cursor.
//
// **Now:** the pictures below are painted onto a layer on the overlay, and the window server
// is handed `invisible` - a cursor that exists so nothing else claims the pointer, and shows
// nothing. That is a reversal, and the reason is the thing this app is for: **an app that is
// presenting hides the pointer**, and a cursor of ours is then not drawn at all. During a
// slideshow every tool's pointer vanished and the laser's glow - which was always a layer -
// was the only one left. Measured with a stand-in for a presentation: a frontmost app that
// calls `NSCursor.hide()` leaves `NSCursor.currentSystem` reporting a visible cursor, so we
// cannot detect it, and `CGDisplayShowCursor` from here does not undo it (docs/DECISIONS.md 6).
//
// A pen is a nib, a highlighter is a chisel, a shape tool is a crosshair, the eraser is a ring
// the size of the hole it leaves, and the laser has no picture at all because its glow is its
// pointer and two marks are worse than one.
//
// Everything is drawn light-cased over a dark core, or the reverse, so it reads on a white
// slide and a black one. Every picture is square and drawn from its middle, which is what puts
// the point the tool works from under the pointer: the layer carries it centred.

import AppKit

enum PointerCursor {
    private static let casing: CGFloat = 3

    private struct Key: Hashable {
        let tool: DrawingTool
        let colour: Int
        let width: CGFloat
        let eraserRadius: CGFloat
        let scale: CGFloat
    }

    // Rebuilt only when the tool, colour, width or display changes - a keypress or a wheel,
    // never a mouse move.
    private static var pictures: [Key: (image: CGImage, size: NSSize)] = [:]

    // The tool's picture, and how big it is in points. This is what the overlay shows: the
    // window server is handed `invisible` and the pointer is painted on a layer.
    //
    // nil for the laser, whose glow is its pointer and always was.
    static func picture(for tools: ToolSettings, scale: CGFloat) -> (image: CGImage, size: NSSize)? {
        guard tools.tool != .laser else {
            return nil
        }

        let key = Key(tool: tools.tool, colour: tools.colorIndex, width: tools.renderWidth,
                      eraserRadius: tools.eraserRadius, scale: scale)
        if let cached = pictures[key] {
            return cached
        }

        let side = ceil(reach(of: tools.tool, width: tools.renderWidth,
                              eraserRadius: tools.eraserRadius)) * 2
        let size = NSSize(width: side, height: side)
        guard let image = Picture.drawn(size: size, scale: scale, {
            draw(tools.tool, colour: tools.color, width: tools.renderWidth,
                 eraserRadius: tools.eraserRadius, at: NSPoint(x: side / 2, y: side / 2))
        }) else {
            return nil
        }

        pictures[key] = (image, size)

        return (image, size)
    }

    // What the window server draws while the overlay draws its own pointer: nothing. It is a
    // cursor rather than `NSCursor.hide()` because hiding is per application and only applies
    // while that application is active - a background app hides nothing, which is how this app
    // once put two pointers on a screen.
    static let invisible: NSCursor = {
        let image = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { _ in true }
        return NSCursor(image: image, hotSpot: NSPoint(x: 4, y: 4))
    }()

    // The pen's geometry, from the width in hand. Everything else is derived from this, so
    // the picture and the space it needs cannot disagree - and a fat pen looks fat, which is
    // the point of drawing a pen at all rather than an arrow with a colour on it.
    private struct Barrel {
        let nib: CGFloat
        let nibHalf: CGFloat
        let body: CGFloat
        let bodyHalf: CGFloat
        // A marker is held flat, so its tip is a chisel rather than a point.
        let chiselHalf: CGFloat

        var length: CGFloat { nib + body }

        init(width: CGFloat, chisel: Bool) {
            nib = (chisel ? 8 : 11) + width * 0.30
            nibHalf = (chisel ? 3.0 : 1.2) + width * 0.18
            body = (chisel ? 16 : 21) + width * 0.5
            bodyHalf = (chisel ? 5.2 : 3.8) + width * 0.34
            chiselHalf = chisel ? 2.2 + width * 0.16 : 0
        }
    }

    // How far the drawing reaches from the hot spot, which decides the size of the square it
    // is drawn in. The hot spot is always the middle of that square.
    private static func reach(of tool: DrawingTool, width: CGFloat, eraserRadius: CGFloat) -> CGFloat {
        switch tool {
        case .eraser: return eraserRadius + casing
        case .laser: return 6
        case .pen: return Barrel(width: width, chisel: false).length + casing + 2
        case .highlighter: return Barrel(width: width, chisel: true).length + casing + 2
        default: return 18
        }
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
            drawPen(at: tip, colour: colour, width: width, chisel: false)
        case .highlighter:
            drawPen(at: tip, colour: colour, width: width, chisel: true)
        default:
            // The shape tools place a corner, so they get a crosshair and nothing else. A
            // crosshair with a little picture beside it was two cursors in one place.
            drawCrosshair(at: tip, colour: colour)
        }
    }

    // A pen, held at forty-five degrees with its tip on the hot spot and its barrel up and
    // to the right - out of the way of what is being drawn, so the ink appears in front of
    // the hand rather than under it.
    private static func drawPen(at tip: NSPoint, colour: NSColor, width: CGFloat, chisel: Bool) {
        let barrel = Barrel(width: width, chisel: chisel)
        // Along the pen, and across it.
        let along = NSPoint(x: 0.7071, y: 0.7071)
        let across = NSPoint(x: -0.7071, y: 0.7071)

        func at(_ distance: CGFloat, _ offset: CGFloat) -> NSPoint {
            NSPoint(x: tip.x + along.x * distance + across.x * offset,
                    y: tip.y + along.y * distance + across.y * offset)
        }

        let outline = NSBezierPath()
        if chisel {
            outline.move(to: at(0, -barrel.chiselHalf))
            outline.line(to: at(0, barrel.chiselHalf))
        } else {
            outline.move(to: tip)
        }
        outline.line(to: at(barrel.nib, barrel.nibHalf))
        outline.line(to: at(barrel.length, barrel.bodyHalf))
        outline.line(to: at(barrel.length, -barrel.bodyHalf))
        outline.line(to: at(barrel.nib, -barrel.nibHalf))
        outline.close()
        outline.lineJoinStyle = .round

        // Light casing under a coloured body, so the pen reads on a white slide and a black
        // one without changing colour to do it.
        outline.lineWidth = casing
        NSColor.white.withAlphaComponent(0.95).setStroke()
        outline.stroke()
        colour.withAlphaComponent(chisel ? 0.75 : 1).setFill()
        outline.fill()
        outline.lineWidth = 1
        NSColor.black.withAlphaComponent(0.35).setStroke()
        outline.stroke()

        // The collar where the nib meets the barrel, which is what makes it read as a pen
        // at a glance rather than as a wedge.
        let collar = NSBezierPath()
        collar.move(to: at(barrel.nib, barrel.nibHalf))
        collar.line(to: at(barrel.nib, -barrel.nibHalf))
        collar.lineWidth = 1.4
        NSColor.white.withAlphaComponent(0.85).setStroke()
        collar.stroke()
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
}
