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
    private static let drawingHint = "⌥Z wheel · middle hands it back · ⌃⌥⌘Z undo"
    private static let interactionHint = "⌥Z wheel · pick a tool to draw · ⌃⌥⌘Esc quit"

    private static let paddingX: CGFloat = 11
    private static let paddingY: CGFloat = 8
    private static let lineGap: CGFloat = 3
    private static let margin: CGFloat = 16
    private static let cornerRadius: CGFloat = 8

    // The colour swatch, in its own column to the left of both lines. Drawn rather than
    // typed: a coloured "●" glyph is at the mercy of the font and came out looking like a
    // typo at this size.
    private static let swatchDiameter: CGFloat = 10
    private static let swatchGap: CGFloat = 8

    // The mode stripe down the left edge.
    private static let stripeWidth: CGFloat = 4

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
        let column = ModeBadge.swatchDiameter + ModeBadge.swatchGap
        let width = ModeBadge.snappedUp(ModeBadge.paddingX * 2 + column + textWidth, scale: scale)
        let height = ModeBadge.snappedUp(mode.size().height + hint.size().height
                                             + ModeBadge.lineGap + ModeBadge.paddingY * 2,
                                         scale: scale)
        frame = NSRect(x: ModeBadge.snappedDown(bounds.maxX - width - ModeBadge.margin, scale: scale),
                       y: ModeBadge.snappedDown(bounds.maxY - height - ModeBadge.margin, scale: scale),
                       width: width,
                       height: height)

        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: Int((width * scale).rounded()),
                                         pixelsHigh: Int((height * scale).rounded()),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else {
            return (nil, frame)
        }

        rep.size = NSSize(width: width, height: height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context

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

        // The one loud thing on the badge, and the only warning that clicks are not reaching
        // whatever is underneath. Clipped to the plate so it follows the rounded corner.
        if !isInteractionMode {
            NSGraphicsContext.saveGraphicsState()
            plate.addClip()
            NSColor.systemRed.setFill()
            NSRect(x: 0, y: 0, width: ModeBadge.stripeWidth, height: height).fill()
            NSGraphicsContext.restoreGraphicsState()
        }

        // Bottom line first: the context is not flipped, so the mode sits above the hint.
        let textX = ModeBadge.paddingX + ModeBadge.swatchDiameter + ModeBadge.swatchGap
        hint.draw(at: NSPoint(x: textX, y: ModeBadge.paddingY))
        let modeY = ModeBadge.paddingY + hint.size().height + ModeBadge.lineGap
        mode.draw(at: NSPoint(x: textX, y: modeY))

        drawSwatch(centredOn: modeY + mode.size().height / 2)

        NSGraphicsContext.restoreGraphicsState()

        return (rep.cgImage, frame)
    }

    // Filled in the pen's colour while drawing; hollow while clicks are passing through,
    // because in that mode there is no colour in hand.
    private func drawSwatch(centredOn y: CGFloat) {
        let diameter = ModeBadge.swatchDiameter
        let circle = NSBezierPath(ovalIn: NSRect(x: ModeBadge.paddingX, y: y - diameter / 2,
                                                 width: diameter, height: diameter))
        guard !isInteractionMode else {
            circle.lineWidth = 1.5
            NSColor.white.withAlphaComponent(0.75).setStroke()
            circle.stroke()
            return
        }

        tools.color.setFill()
        circle.fill()
        // A firm white ring, not a hint of one: the plate is red and so is the first pen,
        // and a swatch that vanishes into the plate is worse than no swatch.
        circle.lineWidth = 2
        NSColor.white.withAlphaComponent(0.95).setStroke()
        circle.stroke()
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
            return "CLICK-THROUGH"
        }

        if tools.tool == .eraser || tools.tool == .laser {
            return tools.tool.label
        }

        let temporary = tools.drawsTemporaryInk ? "TEMP " : ""
        return "\(temporary)\(tools.tool.label) \(Int(tools.renderWidth))"
    }

    private var backgroundColor: NSColor {
        isInteractionMode
            ? NSColor.black.withAlphaComponent(0.62)
            : NSColor.black.withAlphaComponent(0.72)
    }

    private func lines() -> (mode: NSAttributedString, hint: NSAttributedString) {
        let mode = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.white,
            .kern: 0.3
        ])

        let hint = NSAttributedString(string: notice ?? (isInteractionMode ? ModeBadge.interactionHint
                                                                            : ModeBadge.drawingHint),
                                      attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: notice == nil ? .medium : .semibold),
            .foregroundColor: notice == nil
                ? NSColor.white.withAlphaComponent(0.78)
                : NSColor.systemYellow
        ])

        return (mode, hint)
    }
}
