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

import AppKit

final class ModeBadge {
    // What the second line says. Escape is not on it: it no longer leaves drawing mode.
    private static let drawingHint = "⌃⌥⌘E click · ⌃⌥⌘D hide"
    private static let interactionHint = "⌃⌥⌘E draw · ⌃⌥⌘Esc quit"

    private static let paddingX: CGFloat = 8
    private static let paddingY: CGFloat = 5
    private static let lineGap: CGFloat = 2
    private static let margin: CGFloat = 14

    // Repaints are grown by this much so antialiasing at the edges is covered.
    static let repaintMargin: CGFloat = 4

    private let tools: ToolSettings

    // Where the badge is allowed to sit, in the view's coordinates: the screen's visible
    // area, so it clears the menu bar and the Dock.
    private let bounds: NSRect

    var isInteractionMode = false

    // Hidden while the pointer is over it, so the user can draw in that corner.
    private(set) var isHovered = false

    // The rect the badge last reported. Kept because the badge changes size with the tool
    // name ("PEN 4" against "MARKER 24") and repainting only the new rect would leave the
    // wider version half erased.
    private(set) var lastRect: NSRect = .zero

    init(bounds: NSRect, tools: ToolSettings) {
        self.bounds = bounds
        self.tools = tools
    }

    // MARK: - Geometry

    func rect() -> NSRect {
        let (mode, hint) = lines()
        let width = max(mode.size().width, hint.size().width) + ModeBadge.paddingX * 2
        let height = mode.size().height + hint.size().height + ModeBadge.lineGap + ModeBadge.paddingY * 2

        return NSRect(x: bounds.maxX - width - ModeBadge.margin,
                      y: bounds.maxY - height - ModeBadge.margin,
                      width: width,
                      height: height)
    }

    // The region to repaint when the tool changed: where the badge was and where it now is.
    func repaintRegionAfterToolChange() -> NSRect {
        let updated = rect()
        let region = lastRect == .zero ? updated : lastRect.union(updated)
        return region.insetBy(dx: -ModeBadge.repaintMargin, dy: -ModeBadge.repaintMargin)
    }

    // Returns the region to repaint if the pointer crossing the badge changed anything.
    func updateHover(at point: NSPoint) -> NSRect? {
        let wasHovered = isHovered
        let current = lastRect == .zero ? rect() : lastRect
        isHovered = current.contains(point)

        guard isHovered != wasHovered else {
            return nil
        }

        // Showing or hiding the badge touches only its own rect; whatever is underneath is
        // repainted by the same pass.
        return current.insetBy(dx: -ModeBadge.repaintMargin, dy: -ModeBadge.repaintMargin)
    }

    func forgetHover() {
        isHovered = false
    }

    // MARK: - Painting

    func draw(in dirtyRect: NSRect) {
        lastRect = rect()

        guard !isHovered, dirtyRect.intersects(lastRect) else {
            return
        }

        let (mode, hint) = lines()

        backgroundColor.setFill()
        NSBezierPath(roundedRect: lastRect, xRadius: 5, yRadius: 5).fill()

        // Bottom line first: the view is not flipped, so the mode sits above the hint.
        hint.draw(at: NSPoint(x: lastRect.minX + ModeBadge.paddingX,
                              y: lastRect.minY + ModeBadge.paddingY))
        mode.draw(at: NSPoint(x: lastRect.minX + ModeBadge.paddingX,
                              y: lastRect.minY + ModeBadge.paddingY + hint.size().height + ModeBadge.lineGap))
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
