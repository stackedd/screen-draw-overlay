// The pointer the user sees while drawing: the system arrow, with an accessory around its
// tip, handed to the window server as a single NSCursor.
//
// This is a deliberate reversal. The app used to hand the panel a fully transparent cursor
// and paint its own crosshair underneath, so that a presenting app which hides the pointer
// could not take it away. The trouble is that it only holds while we own the window under
// the pointer: the moment something else takes the cursor - the menu bar is the reliable way
// to see it - the real arrow comes back and never leaves, and from then on there are two
// pointers on screen, ours and the system's. A transparent cursor has no failure mode
// between "invisible" and "doubled".
//
// One cursor cannot double. The arrow is always there, drawn by the window server at its own
// rate and costing this process nothing, and what says "you are in drawing mode, with this
// tool, in this colour" is the ring around its tip. Losing cursor ownership now degrades to
// a plain arrow instead of to a bug.
//
// The hot spot is the centre of the ring, which is also the arrow's own tip and the point
// the ink lands on. Those three being the same point is the whole design; the behaviour
// suite checks it.

import AppKit

enum PointerCursor {
    // Big enough to see around the arrow, small enough not to sit on the content.
    private static let ringRadius: CGFloat = 11
    private static let casingWidth: CGFloat = 3

    private struct Key: Hashable {
        let tool: DrawingTool
        let colour: Int
        let width: CGFloat
        let eraserRadius: CGFloat
    }

    // Cursors are rebuilt only when the tool, colour or width changes, which is a keypress,
    // not a mouse move.
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

    private static func make(tool: DrawingTool, colour: NSColor,
                             width: CGFloat, eraserRadius: CGFloat) -> NSCursor {
        let arrow = NSCursor.arrow
        let arrowImage = arrow.image
        let arrowSize = arrowImage.size
        // NSCursor's hot spot is measured from the top left of its image.
        let hotSpot = arrow.hotSpot

        // The eraser's ring is the size of what it will rub out, which is worth showing.
        let radius = tool == .eraser ? eraserRadius : ringRadius

        // Square, and big enough for the ring and for however far the arrow hangs off its
        // own tip in each direction.
        let reach = max(radius + casingWidth,
                        max(hotSpot.x, arrowSize.width - hotSpot.x),
                        max(hotSpot.y, arrowSize.height - hotSpot.y))
        let side = ceil(reach) * 2 + 2
        let centre = NSPoint(x: side / 2, y: side / 2)

        // Drawn through a handler rather than into a bitmap, so the cursor is redrawn at
        // whatever resolution the display it lands on needs.
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            draw(accessory: tool, colour: colour, width: width, radius: radius, at: centre)
            // The arrow last, on top, with its own tip on the centre.
            arrowImage.draw(at: NSPoint(x: centre.x - hotSpot.x,
                                        y: centre.y - arrowSize.height + hotSpot.y),
                            from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }

        return NSCursor(image: image, hotSpot: centre)
    }

    private static func draw(accessory tool: DrawingTool, colour: NSColor,
                             width: CGFloat, radius: CGFloat, at centre: NSPoint) {
        guard tool != .laser else {
            drawLaserDot(at: centre, colour: colour)
            return
        }

        let ring = NSBezierPath(ovalIn: NSRect(x: centre.x - radius, y: centre.y - radius,
                                               width: radius * 2, height: radius * 2))

        // Light casing under a dark core, so it reads on a white slide and on a dark one.
        ring.lineWidth = casingWidth
        NSColor.white.withAlphaComponent(0.9).setStroke()
        ring.stroke()
        ring.lineWidth = 1.5
        // The eraser takes ink away rather than adding it, so it is not shown in the pen's
        // colour - that would read as "about to draw in red".
        (tool == .eraser ? NSColor.black.withAlphaComponent(0.8) : colour).setStroke()
        ring.stroke()

        guard tool != .eraser else {
            return
        }

        // A nib the size of the line about to be drawn, on the spot it will land. Clamped,
        // because a 24pt highlighter would otherwise fill the ring.
        let nib = min(max(width, 3), radius * 1.1)
        NSColor.white.withAlphaComponent(0.85).setStroke()
        let dot = NSBezierPath(ovalIn: NSRect(x: centre.x - nib / 2, y: centre.y - nib / 2,
                                              width: nib, height: nib))
        dot.lineWidth = 1
        colour.setFill()
        dot.fill()
        dot.stroke()
    }

    private static func drawLaserDot(at point: NSPoint, colour: NSColor) {
        let core = ringRadius * 0.7
        colour.withAlphaComponent(0.28).setFill()
        NSBezierPath(ovalIn: NSRect(x: point.x - core, y: point.y - core,
                                    width: core * 2, height: core * 2)).fill()
        colour.setFill()
        NSBezierPath(ovalIn: NSRect(x: point.x - core / 2, y: point.y - core / 2,
                                    width: core, height: core)).fill()
    }
}
