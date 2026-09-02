// The little sign in the corner of the screen, and the whole of this app's on-screen
// interface.
//
// There is no palette and no toolbar on purpose - a tool that occupies screen space is not
// one people leave running - so this badge has to carry everything the user needs to know
// at a glance: which mode they are in, which tool and colour is in hand, and, on its second
// line, the shortcuts that get them out. That last line is a safety feature, not decoration:
// it is the only thing on screen telling someone whose clicks have stopped working what to
// press - which is now one key and one flick, so the line names the wheel and what its middle
// does. Undo is on it too, because the shortcut that always works is the global one and there
// is nowhere else to learn it.
//
// It draws nothing while the pointer is over it, so the corner it occupies stays drawable.
//
// The plate is dark and the mode is carried by the red stripe down its left edge, not by the
// plate's own colour. A red plate was tried and it cost the thing the badge is actually for:
// the colour swatch is the only place the pen's colour is shown, and the first pen is red,
// so on a red plate the swatch disappeared into it.
//
// Like the pointer, it is handed over as a picture on a layer rather than painted into the
// view. It changes when the tool, the colour or the mode does - which is rare - and a repaint
// of the overlay costs the same whatever its dirty rect, so a badge painted in draw(_:) was
// laying out two lines of text on every mouse move for a corner nothing had touched.

import AppKit

final class ModeBadge {
    // What the second line says. Escape is not on it: it no longer leaves drawing mode.
    private static let drawingHint = "⌥Z tools · ⌥V undo · middle of a wheel hands it back"
    private static let interactionHint = "⌥Z tools · ⌥V undo · ⌃⌥⌘Esc quits"


    // Sized for a screen rather than for a screenshot. These were set while the badge was
    // being drawn at half scale by a bug two files away (docs/DECISIONS.md 28), so every one
    // of them had been nudged up to compensate for something that was not the type's fault.
    // At the size it is actually shown, 13 over 10 with 11x8 padding is a placard.
    private static let paddingX: CGFloat = 12
    private static let paddingY: CGFloat = 7
    private static let lineGap: CGFloat = 2
    private static let margin: CGFloat = 16
    private static let cornerRadius: CGFloat = 10

    // The tool, drawn in the colour it will draw with, in its own column to the left of both
    // lines: one mark that says which tool and which colour, instead of a swatch that says
    // half of it. The eraser and click-through have no colour, so theirs is plain.
    private static let glyphColumn: CGFloat = 15
    private static let glyphGap: CGFloat = 8

    // The mode stripe down the left edge.
    private static let stripeWidth: CGFloat = 3

    private let tools: ToolSettings

    // Where the badge is allowed to sit, in the view's coordinates: the screen's visible
    // area, so it clears the menu bar and the Dock.
    private let bounds: NSRect

    var isInteractionMode = false

    // Something to say for a second or two, in place of the shortcut line. The badge is the
    // only place on screen this app can say anything, so anything it needs to say goes
    // here rather than into a dialog nobody asked for.
    var notice: String?

    // Hidden while the pointer is over it, so the user can draw in that corner.
    private(set) var isHovered = false

    // Where the badge actually sits, as of the last picture drawn. Not the same as `bounds`,
    // which is where it is allowed to sit: the badge changes size with the tool name ("PEN 4"
    // against "MARKER 24") and is anchored to the corner, so it grows leftwards.
    private(set) var frame: NSRect = .zero

    init(bounds: NSRect, tools: ToolSettings) {
        self.bounds = bounds
        self.tools = tools
    }

    // MARK: - Hovering

    // Returns whether the pointer crossing the badge changed anything, so the caller knows
    // to show or hide it.
    func updateHover(at point: NSPoint) -> Bool {
        let wasHovered = isHovered
        isHovered = frame.contains(point)

        return isHovered != wasHovered
    }

    func forgetHover() {
        isHovered = false
    }

    // MARK: - Painting

    // The badge as a picture, and where it goes. The two come back together because they
    // change together: the badge is anchored to the corner and grows leftwards as the tool
    // name gets longer, so a new name moves its origin as well as its size.
    //
    // Everything is snapped to whole device pixels. A layer whose frame is a fraction of a
    // pixel wide gets its picture resampled onto the screen, and 10pt text resampled by a
    // third of a pixel is exactly as blurry as it sounds.
    func render(scale: CGFloat) -> (image: CGImage?, frame: NSRect) {
        let (mode, hint) = lines()
        let textWidth = max(mode.size().width, hint.size().width)
        let column = ModeBadge.glyphColumn + ModeBadge.glyphGap
        let width = ModeBadge.snappedUp(ModeBadge.paddingX * 2 + column + textWidth, scale: scale)
        let height = ModeBadge.snappedUp(mode.size().height + hint.size().height
                                             + ModeBadge.lineGap + ModeBadge.paddingY * 2,
                                         scale: scale)
        frame = NSRect(x: ModeBadge.snappedDown(bounds.maxX - width - ModeBadge.margin, scale: scale),
                       y: ModeBadge.snappedDown(bounds.maxY - height - ModeBadge.margin, scale: scale),
                       width: width,
                       height: height)

        let image = Picture.drawn(size: frame.size, scale: scale) {
            let box = NSRect(x: 0, y: 0, width: width, height: height)
            let plate = NSBezierPath(roundedRect: box, xRadius: ModeBadge.cornerRadius,
                                     yRadius: ModeBadge.cornerRadius)
            backgroundColor.setFill()
            plate.fill()
            // A hairline lip. Without it the plate has no edge against a light background and
            // reads as a flat sticker rather than something sitting on top of the screen.
            let lip = NSBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5),
                                   xRadius: ModeBadge.cornerRadius - 0.5,
                                   yRadius: ModeBadge.cornerRadius - 0.5)
            lip.lineWidth = 1
            NSColor.white.withAlphaComponent(0.22).setStroke()
            lip.stroke()

            // The one loud thing on the badge, and the only warning that clicks are not
            // reaching whatever is underneath. Clipped to the plate so it follows the corner.
            if !isInteractionMode {
                NSGraphicsContext.saveGraphicsState()
                plate.addClip()
                NSColor.systemRed.setFill()
                NSRect(x: 0, y: 0, width: ModeBadge.stripeWidth, height: height).fill()
                NSGraphicsContext.restoreGraphicsState()
            }

            // Bottom line first: the context is not flipped, so the mode sits above the hint.
            let textX = ModeBadge.paddingX + ModeBadge.glyphColumn + ModeBadge.glyphGap
            hint.draw(at: NSPoint(x: textX, y: ModeBadge.paddingY))
            let modeY = ModeBadge.paddingY + hint.size().height + ModeBadge.lineGap
            mode.draw(at: NSPoint(x: textX, y: modeY))

            drawTool(centredOn: (height - ModeBadge.glyphColumn) / 2)
        }

        return (image, frame)
    }

    // The tool in hand, in the colour it draws with. It is the only place on screen either of
    // those appears, so it has to carry both: a swatch alone said the colour and left the tool
    // to the words beside it, and in click-through there is no tool in hand at all, which is
    // what the pointer glyph says.
    private func drawTool(centredOn y: CGFloat) {
        let box = NSRect(x: ModeBadge.paddingX, y: y,
                         width: ModeBadge.glyphColumn, height: ModeBadge.glyphColumn)
        let colour = isInteractionMode
            ? NSColor.white.withAlphaComponent(0.7)
            : (tools.tool == .eraser ? NSColor.white.withAlphaComponent(0.9) : tools.color)
        let name = isInteractionMode ? "cursorarrow" : tools.tool.symbolName

        guard let glyph = Glyph.symbol(name, pointSize: 13, weight: .semibold, colour: colour) else {
            // No symbol on this system: a disc of the colour still says which pen is in hand.
            colour.setFill()
            NSBezierPath(ovalIn: box.insetBy(dx: 3, dy: 3)).fill()
            return
        }

        glyph.draw(in: NSRect(x: box.midX - glyph.size.width / 2,
                              y: box.midY - glyph.size.height / 2,
                              width: glyph.size.width, height: glyph.size.height))
    }

    // Whole device pixels, in points. A badge that is 87.34pt wide on a 2x display asks the
    // window server to resample 175 pixels of picture onto 174.68 pixels of screen.
    private static func snappedUp(_ value: CGFloat, scale: CGFloat) -> CGFloat {
        (value * scale).rounded(.up) / scale
    }

    private static func snappedDown(_ value: CGFloat, scale: CGFloat) -> CGFloat {
        (value * scale).rounded(.down) / scale
    }

    // The badge answers "where do my clicks go right now?". Darker while clicks are passing
    // through, with the red stripe gone: nothing is being captured.
    private var text: String {
        guard !isInteractionMode else {
            return "Click-through"
        }

        // The eraser's size is drawn around the pointer, so the badge would only be saying
        // it twice. Everything else that has a width says it here.
        if tools.tool == .eraser {
            return tools.tool.name
        }

        let temporary = tools.drawsTemporaryInk ? "Temp " : ""
        return "\(temporary)\(tools.tool.name) \(Int(tools.renderWidth))"
    }

    private var backgroundColor: NSColor {
        isInteractionMode
            ? NSColor.black.withAlphaComponent(0.62)
            : NSColor.black.withAlphaComponent(0.72)
    }

    private func lines() -> (mode: NSAttributedString, hint: NSAttributedString) {
        let mode = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white
        ])

        let hint = NSAttributedString(string: notice ?? (isInteractionMode ? ModeBadge.interactionHint
                                                                            : ModeBadge.drawingHint),
                                      attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: notice == nil ? .regular : .semibold),
            .foregroundColor: notice == nil
                ? NSColor.white.withAlphaComponent(0.72)
                : NSColor.systemYellow
        ])

        return (mode, hint)
    }
}
