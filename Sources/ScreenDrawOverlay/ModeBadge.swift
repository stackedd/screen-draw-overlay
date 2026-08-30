// The little sign in the corner of the screen, and the whole of this app's on-screen
// interface.
//
// There is no palette and no toolbar on purpose - a tool that occupies screen space is not
// one people leave running - so this badge has to carry everything the user needs to know
// at a glance: which mode they are in, which tool and colour is in hand, and, on its second
// line, the shortcuts that get them out. That last line is a safety feature, not decoration:
// it is the only thing on screen telling someone whose clicks have stopped working what to
// press.
//
// It draws nothing while the pointer is over it, so the corner it occupies stays drawable.
//
// Like the pointer, it is handed over as a picture on a layer rather than painted into the
// view. It changes when the tool, the colour or the mode does - which is rare - and a repaint
// of the overlay costs the same whatever its dirty rect, so a badge painted in draw(_:) was
// laying out two lines of text on every mouse move for a corner nothing had touched.

import AppKit

final class ModeBadge {
    // What the second line says. Escape is not on it: it no longer leaves drawing mode.
    private static let drawingHint = "⌃⌥⌘E click · ⌃⌥⌘D hide"
    private static let interactionHint = "⌃⌥⌘E draw · ⌃⌥⌘Esc quit"

    private static let paddingX: CGFloat = 8
    private static let paddingY: CGFloat = 5
    private static let lineGap: CGFloat = 2
    private static let margin: CGFloat = 14

    private let tools: ToolSettings

    // Where the badge is allowed to sit, in the view's coordinates: the screen's visible
    // area, so it clears the menu bar and the Dock.
    private let bounds: NSRect

    var isInteractionMode = false

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
    func render(scale: CGFloat) -> (image: CGImage?, frame: NSRect) {
        let (mode, hint) = lines()
        let width = max(mode.size().width, hint.size().width) + ModeBadge.paddingX * 2
        let height = mode.size().height + hint.size().height + ModeBadge.lineGap + ModeBadge.paddingY * 2
        frame = NSRect(x: bounds.maxX - width - ModeBadge.margin,
                       y: bounds.maxY - height - ModeBadge.margin,
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

        backgroundColor.setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: width, height: height),
                     xRadius: 5, yRadius: 5).fill()

        // Bottom line first: the context is not flipped, so the mode sits above the hint.
        hint.draw(at: NSPoint(x: ModeBadge.paddingX, y: ModeBadge.paddingY))
        mode.draw(at: NSPoint(x: ModeBadge.paddingX,
                              y: ModeBadge.paddingY + hint.size().height + ModeBadge.lineGap))

        NSGraphicsContext.restoreGraphicsState()

        return (rep.cgImage, frame)
    }

    // Red and solid while the overlay owns the mouse, hollow and neutral while clicks are
    // passing through: the badge answers "where do my clicks go right now?".
    private var text: String {
        guard !isInteractionMode else {
            return "◌ CLICK-THROUGH"
        }

        if tools.tool == .eraser || tools.tool == .laser {
            return "● \(tools.tool.label)"
        }

        let temporary = tools.drawsTemporaryInk ? "TEMP " : ""
        return "● \(temporary)\(tools.tool.label) \(Int(tools.renderWidth))"
    }

    private var backgroundColor: NSColor {
        isInteractionMode
            ? NSColor.black.withAlphaComponent(0.45)
            : NSColor.systemRed.withAlphaComponent(0.72)
    }

    private func lines() -> (mode: NSAttributedString, hint: NSAttributedString) {
        let mode = NSMutableAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.92)
        ])

        // The leading dot is the colour swatch: the only place the active colour is shown,
        // which is what keeps this keyboard-driven tool honest without a palette on screen.
        if !isInteractionMode, mode.length > 0 {
            mode.addAttribute(.foregroundColor, value: tools.color, range: NSRange(location: 0, length: 1))
        }

        let hint = NSAttributedString(string: isInteractionMode ? ModeBadge.interactionHint : ModeBadge.drawingHint,
                                      attributes: [
            .font: NSFont.systemFont(ofSize: 9, weight: .regular),
            .foregroundColor: NSColor.white.withAlphaComponent(0.65)
        ])

        return (mode, hint)
    }
}
