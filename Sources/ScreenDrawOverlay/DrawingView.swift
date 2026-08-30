// The canvas. Everything the user sees inside the overlay is painted here, and every
// mouse and key event in drawing mode arrives here.
//
// Three things to know before editing:
//
//   1. Repainting is incremental. A drag invalidates only the rectangle the new segment
//      covers, and draw(_:) skips strokes that do not meet dirtyRect. Repainting the whole
//      view per mouse move cost 26x more; the measurements are in docs/ARCHITECTURE.md.
//      Anything added here should invalidate its own rect, never the view.
//   2. The pointer is drawn, not requested. The system cursor over the panel is made
//      transparent and the crosshair below is ours, because a presenting app hides the
//      real pointer and a background app cannot win that fight.
//   3. The badge in the corner is the only interface. There is no palette on screen on
//      purpose, so it has to say which tool, which colour and how to get out.

import AppKit
import Carbon
import Foundation

final class DrawingView: NSView {

    // 15 a second. Measured: the cost of a fade is one repaint of a full screen
    // transparent layer per tick - about 0.4% CPU each - and is almost independent of how
    // many strokes are fading or how big they are. 20/s cost 5.1%, 15/s costs 4.4% and 12/s
    // 4.3%, so past this point the smoothness is free and the savings are not.
    private static let fadeTickInterval: TimeInterval = 1.0 / 15



    // Undo has to put back what the eraser and Clear take away, not just the last thing
    // drawn, so edits are recorded rather than inferred from the stroke list.
    private struct Removal {
        let index: Int
        let stroke: Stroke
    }

    private enum Edit {
        case added(Stroke)
        case removed([Removal])
    }

    private var strokes: [Stroke] = []
    private var currentStroke: Stroke?
    private var shapeAnchor: NSPoint?
    private var lastStrokePoint: NSPoint?
    private var undoStack: [Edit] = []
    private var redoStack: [Edit] = []
    private var fadeTimer: Timer?
    let tools: ToolSettings
    private var pointerLocation: NSPoint?

    // nil on every screen but one: the badge would be noise repeated on each display.
    private let badge: ModeBadge?
    let showsIndicator: Bool

    // Set by AppDelegate when the click-through hot key is used. The view keeps drawing
    // its strokes either way; what changes is the badge and whether it claims the cursor.
    var isInteractionMode = false {
        didSet {
            guard isInteractionMode != oldValue else {
                return
            }

            // The mouse is about to stop reaching this view (or start again), so a stroke
            // still under the button has to be committed before the tool changes hands.
            finishStrokeInProgress()

            // No mouseMoved arrives while the panel ignores the mouse, so a hover that was
            // in effect at the moment of the switch would stick and hide the badge.
            badge?.isInteractionMode = isInteractionMode
            badge?.forgetHover()
            if isInteractionMode {
                releaseDrawingCursor()
            } else {
                refreshCursorRects()
                applyDrawingCursor()
            }
            // The badge changes text, size and colour; a mode switch is rare enough to
            // just repaint everything.
            needsDisplay = true
        }
    }
    private var mouseTrackingArea: NSTrackingArea?

    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { false }

    init(frame frameRect: NSRect, indicatorBounds: NSRect, showsIndicator: Bool, tools: ToolSettings) {
        self.badge = showsIndicator ? ModeBadge(bounds: indicatorBounds, tools: tools) : nil
        self.showsIndicator = showsIndicator
        self.tools = tools
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        fadeTimer?.invalidate()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let mouseTrackingArea {
            removeTrackingArea(mouseTrackingArea)
        }

        let trackingArea = NSTrackingArea(rect: bounds,
                                          options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate,
                                                    .activeAlways, .inVisibleRect],
                                          owner: self,
                                          userInfo: nil)
        addTrackingArea(trackingArea)
        mouseTrackingArea = trackingArea
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let region = badge?.updateHover(at: point) {
            setNeedsDisplay(region)
        }
        movePointer(to: point)

        guard tools.tool != .eraser else {
            erase(at: point)
            return
        }

        guard tools.tool.marksTheCanvas else {
            return
        }

        let width = tools.renderWidth
        let path = NSBezierPath()
        path.lineWidth = width
        path.lineCapStyle = tools.style.lineCapStyle
        path.lineJoinStyle = .round
        path.move(to: point)

        currentStroke = Stroke(points: [point], path: path, color: tools.color,
                               width: width, style: tools.style,
                               createdAt: tools.drawsTemporaryInk ? Date() : nil)
        shapeAnchor = tools.tool.isShape ? point : nil
        lastStrokePoint = point
        invalidateSegment(from: point, to: point, width: width)
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let region = badge?.updateHover(at: point) {
            setNeedsDisplay(region)
        }
        movePointer(to: point)

        guard tools.tool != .eraser else {
            erase(at: point)
            return
        }

        guard currentStroke != nil else { return }

        // A shape is defined by two points, so it is rebuilt on every move rather than
        // extended. Repainting covers where it was and where it now is.
        if let anchor = shapeAnchor, let existing = currentStroke {
            let end = constrainedShapeEnd(from: anchor, to: point, shiftHeld: event.modifierFlags.contains(.shift))
            let previousBounds = strokeBounds(of: existing)
            let rebuilt = shapePath(from: anchor, to: end, width: existing.width)
            currentStroke = Stroke(points: [anchor, end], path: rebuilt, color: existing.color,
                                   width: existing.width, style: existing.style,
                                   createdAt: existing.createdAt)
            lastStrokePoint = end
            if let updated = currentStroke {
                setNeedsDisplay(previousBounds.union(strokeBounds(of: updated)))
            }
            return
        }

        let previousPoint = lastStrokePoint ?? point
        currentStroke?.path.line(to: point)
        currentStroke?.points.append(point)
        lastStrokePoint = point

        // Only the new segment changed. Invalidating the whole view here meant every
        // mouse move re-stroked every path drawn so far, so the cost of a drag grew
        // with the number of strokes already on screen.
        invalidateSegment(from: previousPoint, to: point, width: currentStroke?.width ?? tools.renderWidth)
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        movePointer(to: point)
        if let region = badge?.updateHover(at: point) {
            setNeedsDisplay(region)
        }
        shapeAnchor = nil

        if let currentStroke {
            strokes.append(currentStroke)
            recordEdit(.added(currentStroke))
            startFadingIfNeeded()
            // The pixels do not change here, the stroke just moves from currentStroke
            // into strokes. Repainting its own bounds once is cheap insurance.
            setNeedsDisplay(strokeBounds(of: currentStroke))
        }
        currentStroke = nil
        lastStrokePoint = nil
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        movePointer(to: point)
        if let region = badge?.updateHover(at: point) {
            setNeedsDisplay(region)
        }
    }

    override func mouseEntered(with event: NSEvent) {
        applyDrawingCursor()
        movePointer(to: convert(event.locationInWindow, from: nil))
    }

    // Three ways to claim the cursor, because any one of them can be missed: the cursor
    // rect for a plain pointer move, cursorUpdate for when the window server asks us
    // directly, and mouseEntered for arriving from another app's window.
    override func resetCursorRects() {
        super.resetCursorRects()
        guard !isInteractionMode else {
            return
        }

        addCursorRect(bounds, cursor: PointerCursor.transparent)
    }

    override func cursorUpdate(with event: NSEvent) {
        applyDrawingCursor()
    }

    // Safe to call from an event callback: it only sets the cursor. Rebuilding cursor
    // rects from inside cursorUpdate re-enters AppKit's tracking machinery and throws,
    // so that lives in refreshCursorRects, which only mode changes call.
    func applyDrawingCursor() {
        guard !isInteractionMode else {
            return
        }

        PointerCursor.transparent.set()
    }

    func releaseDrawingCursor() {
        // Click-through: the app underneath owns the pointer again. Dropping our cursor
        // rects is what hands it over; setting the arrow just avoids a moment with no
        // pointer at all before the next mouse move.
        refreshCursorRects()
        NSCursor.arrow.set()
    }

    func refreshCursorRects() {
        window?.invalidateCursorRects(for: self)
    }

    override func mouseExited(with event: NSEvent) {
        // The pointer is on another screen's panel now; that one draws it.
        movePointer(to: nil)
    }

    // The crosshair is drawn by this view instead of being asked for from the system,
    // so it survives a presenting app that keeps hiding the real pointer.
    func syncPointerToMouseLocation() {
        guard let window else {
            movePointer(to: nil)
            return
        }

        let point = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        movePointer(to: bounds.contains(point) ? point : nil)
    }

    private func movePointer(to point: NSPoint?) {
        guard pointerLocation != point else {
            return
        }

        // Only the pixels the pointer left and the ones it arrived at, never the view.
        if let previous = pointerLocation {
            setNeedsDisplay(PointerCursor.rect(at: previous))
        }

        pointerLocation = point

        if let point {
            setNeedsDisplay(PointerCursor.rect(at: point))
        }
    }

    private func drawPointer(in dirtyRect: NSRect) {
        guard !isInteractionMode, let point = pointerLocation,
              dirtyRect.intersects(PointerCursor.rect(at: point)) else {
            return
        }

        PointerCursor.draw(at: point, tools: tools)
    }

    override func keyDown(with event: NSEvent) {
        let shortcutFlags = event.modifierFlags.intersection([.command, .shift, .option, .control])

        if event.keyCode == UInt16(kVK_Escape) {
            // Swallowed on purpose. Escape used to leave drawing mode, but that only
            // worked while the panel happened to be key - a state the user cannot see -
            // and it threw the drawing away just as someone pressed Escape to get out of
            // a presentation. Not calling super also keeps AppKit from beeping.
            return
        } else if event.keyCode == UInt16(kVK_ANSI_C), shortcutFlags == [] || shortcutFlags == .shift {
            clear()
        } else if event.keyCode == UInt16(kVK_ANSI_Z), shortcutFlags == .command {
            undoLastEdit()
        } else if event.keyCode == UInt16(kVK_ANSI_Z), shortcutFlags == [.command, .shift] {
            redoLastEdit()
        } else if event.keyCode == UInt16(kVK_Delete) || event.keyCode == UInt16(kVK_ForwardDelete),
                  shortcutFlags == [] {
            clear()
        } else if shortcutFlags == [] {
            handleToolKey(event.keyCode)
        }

        // Everything else is swallowed rather than passed on. Drawing mode owns the
        // keyboard the same way it owns the mouse: an unhandled key would travel up the
        // responder chain and end in a system beep, so typing while drawing made the
        // machine beep on every letter. Click-through is where the keyboard belongs to
        // someone else.
    }

    // Drawing mode owns the keyboard, so the tool keys are plain letters and digits - no
    // modifiers to hold while the other hand is drawing. Mnemonic throughout: P pen,
    // H highlighter, L line, A arrow, R rectangle, O oval, E eraser.
    private func handleToolKey(_ keyCode: UInt16) {
        switch Int(keyCode) {
        case kVK_ANSI_1: tools.selectColor(0)
        case kVK_ANSI_2: tools.selectColor(1)
        case kVK_ANSI_3: tools.selectColor(2)
        case kVK_ANSI_4: tools.selectColor(3)
        case kVK_ANSI_5: tools.selectColor(4)
        case kVK_ANSI_6: tools.selectColor(5)
        case kVK_ANSI_LeftBracket: tools.stepWidth(by: -1)
        case kVK_ANSI_RightBracket: tools.stepWidth(by: 1)
        case kVK_ANSI_P: tools.select(tool: .pen)
        case kVK_ANSI_H: tools.select(tool: .highlighter)
        case kVK_ANSI_L: tools.select(tool: .line)
        case kVK_ANSI_A: tools.select(tool: .arrow)
        case kVK_ANSI_R: tools.select(tool: .rectangle)
        case kVK_ANSI_O: tools.select(tool: .ellipse)
        case kVK_ANSI_E: tools.select(tool: .eraser)
        case kVK_Space: tools.toggleLaser()
        case kVK_ANSI_T: tools.toggleTemporaryInk()
        default: break
        }
    }

    // Escape can also arrive as a cancel action rather than a plain keyDown; swallow it
    // there too, silently, for the same reason.
    override func cancelOperation(_ sender: Any?) {
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        // Skip strokes that are nowhere near the region being repainted. With
        // incremental invalidation this is what keeps a drag cheap on a long session.
        let now = Date()
        for stroke in strokes where strokeBounds(of: stroke).intersects(dirtyRect) {
            let opacity = stroke.opacity(at: now)
            guard opacity > 0 else {
                continue
            }

            stroke.renderColor.withAlphaComponent(stroke.renderColor.alphaComponent * opacity).setStroke()
            stroke.path.stroke()
        }

        if let currentStroke, strokeBounds(of: currentStroke).intersects(dirtyRect) {
            currentStroke.renderColor.setStroke()
            currentStroke.path.stroke()
        }

        badge?.draw(in: dirtyRect)
        drawPointer(in: dirtyRect)
    }

    // Temporary ink is deliberately left behind: it was drawn to vanish, and bringing it
    // back mid-fade on the next show would be a surprise.
    func capturedStrokes() -> [Stroke] {
        strokes.filter { $0.createdAt == nil }
    }

    // A stroke the user has not lifted the mouse off yet is still a stroke. Whenever the
    // tool is taken away mid-drag - hiding the overlay, or stepping into click-through -
    // it has to be committed, or it is dropped on the floor: hiding lost it, and after a
    // round trip through click-through it sat there unfinished until the next mouseDown
    // silently replaced it.
    func finishStrokeInProgress() {
        guard let currentStroke else {
            return
        }

        strokes.append(currentStroke)
        recordEdit(.added(currentStroke))
        startFadingIfNeeded()
        self.currentStroke = nil
        shapeAnchor = nil
        lastStrokePoint = nil
        setNeedsDisplay(strokeBounds(of: currentStroke))
    }

    func restore(strokes restored: [Stroke]) {
        strokes = restored
        undoStack.removeAll()
        redoStack.removeAll()
        currentStroke = nil
        lastStrokePoint = nil
        needsDisplay = true
    }

    // Clearing is an edit like any other, so an accidental Delete can be taken back.
    func clear() {
        finishStrokeInProgress()

        if !strokes.isEmpty {
            recordEdit(.removed(strokes.enumerated().map { Removal(index: $0.offset, stroke: $0.element) }))
        }

        strokes.removeAll()
        currentStroke = nil
        shapeAnchor = nil
        lastStrokePoint = nil
        fadeTimer?.invalidate()
        fadeTimer = nil
        needsDisplay = true
    }

    // The badge carries the tool name, its colour and its width, so a tool change has to
    // repaint it - on every screen, not just the one the key was pressed on.
    //
    // The text changes length with the tool ("PEN 4" against "MARKER 24") and the badge is
    // anchored to the corner, so it grows leftwards: repainting only where it used to be
    // leaves the wider version half drawn. Old rect and new rect, both.
    func toolSettingsChanged() {
        guard let badge else {
            return
        }

        setNeedsDisplay(badge.repaintRegionAfterToolChange())
    }

    // Shapes are two-point figures. Holding Shift snaps a line or arrow to the nearest 45
    // degrees and makes a rectangle square or an ellipse round, which is what every other
    // drawing tool does and what fingers expect.
    private func constrainedShapeEnd(from anchor: NSPoint, to point: NSPoint, shiftHeld: Bool) -> NSPoint {
        guard shiftHeld else {
            return point
        }

        let dx = point.x - anchor.x
        let dy = point.y - anchor.y

        if tools.tool == .rectangle || tools.tool == .ellipse {
            let side = max(abs(dx), abs(dy))
            return NSPoint(x: anchor.x + (dx < 0 ? -side : side), y: anchor.y + (dy < 0 ? -side : side))
        }

        let angle = atan2(dy, dx)
        let step = CGFloat.pi / 4
        let snapped = (angle / step).rounded() * step
        let length = hypot(dx, dy)
        return NSPoint(x: anchor.x + cos(snapped) * length, y: anchor.y + sin(snapped) * length)
    }

    private func shapePath(from anchor: NSPoint, to end: NSPoint, width: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        path.lineWidth = width
        path.lineCapStyle = .round
        path.lineJoinStyle = .round

        switch tools.tool {
        case .rectangle:
            path.appendRect(NSRect(x: min(anchor.x, end.x), y: min(anchor.y, end.y),
                                   width: abs(end.x - anchor.x), height: abs(end.y - anchor.y)))
        case .ellipse:
            path.appendOval(in: NSRect(x: min(anchor.x, end.x), y: min(anchor.y, end.y),
                                       width: abs(end.x - anchor.x), height: abs(end.y - anchor.y)))
        case .arrow:
            path.move(to: anchor)
            path.line(to: end)
            // Head scaled to the line width so a thick arrow does not end in a pin prick.
            let headLength = max(12, width * 3.5)
            let angle = atan2(end.y - anchor.y, end.x - anchor.x)
            let spread = CGFloat.pi / 7
            for side in [angle + .pi - spread, angle + .pi + spread] {
                path.move(to: end)
                path.line(to: NSPoint(x: end.x + cos(side) * headLength, y: end.y + sin(side) * headLength))
            }
        default:
            path.move(to: anchor)
            path.line(to: end)
        }

        return path
    }

    // The eraser rubs out whole strokes: partial erasing would mean splitting paths, and
    // on an annotation overlay "take that line away" is what people actually want.
    private func erase(at point: NSPoint) {
        let radius = tools.eraserRadius
        var removed: [Removal] = []

        for index in strokes.indices.reversed() {
            let stroke = strokes[index]
            guard strokeBounds(of: stroke).insetBy(dx: -radius, dy: -radius).contains(point) else {
                continue
            }

            guard distance(from: point, to: stroke) <= radius + stroke.width / 2 else {
                continue
            }

            removed.append(Removal(index: index, stroke: stroke))
            setNeedsDisplay(strokeBounds(of: stroke))
            strokes.remove(at: index)
        }

        guard !removed.isEmpty else {
            return
        }

        recordEdit(.removed(removed.sorted { $0.index < $1.index }))
    }

    // Distance from the pointer to the stroke's polyline. This is why Stroke keeps its
    // points: NSBezierPath can only test its filled area, not the line itself.
    private func distance(from point: NSPoint, to stroke: Stroke) -> CGFloat {
        guard let first = stroke.points.first else {
            return .greatestFiniteMagnitude
        }

        guard stroke.points.count > 1 else {
            return hypot(point.x - first.x, point.y - first.y)
        }

        var best = CGFloat.greatestFiniteMagnitude
        for index in 1..<stroke.points.count {
            best = min(best, distance(from: point, toSegmentFrom: stroke.points[index - 1], to: stroke.points[index]))
        }

        return best
    }

    private func distance(from point: NSPoint, toSegmentFrom start: NSPoint, to end: NSPoint) -> CGFloat {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy

        guard lengthSquared > 0 else {
            return hypot(point.x - start.x, point.y - start.y)
        }

        let t = max(0, min(1, ((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared))
        return hypot(point.x - (start.x + t * dx), point.y - (start.y + t * dy))
    }

    // The only timer in the app, and it exists only while temporary ink is on screen:
    // it starts when one is drawn and stops the moment the last one is gone, so an idle
    // overlay still costs nothing.
    private func startFadingIfNeeded() {
        guard fadeTimer == nil, strokes.contains(where: { $0.createdAt != nil }) else {
            return
        }

        let timer = Timer(timeInterval: DrawingView.fadeTickInterval, repeats: true) { [weak self] _ in
            self?.advanceFade()
        }
        RunLoop.main.add(timer, forMode: .common)
        fadeTimer = timer
    }

    private func advanceFade() {
        let now = Date()
        var fadingRemains = false
        var changed = false
        var region = NSRect.zero

        for index in strokes.indices.reversed() {
            guard let createdAt = strokes[index].createdAt else {
                continue
            }

            let bounds = strokeBounds(of: strokes[index])

            if strokes[index].hasFaded {
                // Temporary ink is not an edit: it was never meant to stay, so undo has
                // nothing to say about it disappearing.
                strokes.remove(at: index)
                changed = true
            } else {
                fadingRemains = true
                // Nothing to repaint while the stroke is still at full strength, which is
                // more than half of its life.
                if now.timeIntervalSince(createdAt) / Stroke.fadeDuration > Stroke.fadeHold {
                    changed = true
                }
            }

            region = region == .zero ? bounds : region.union(bounds)
        }

        // One repaint covering all of them, not one per stroke: fifty separate rects mean
        // fifty passes that each redraw every stroke they touch, and the cost of a fade
        // then grows with the square of what is on screen. Measured: 12.5% CPU that way.
        if changed, region != .zero {
            setNeedsDisplay(region)
        }

        guard !fadingRemains else {
            return
        }

        fadeTimer?.invalidate()
        fadeTimer = nil
    }

    private func recordEdit(_ edit: Edit) {
        undoStack.append(edit)
        // A new edit is a new branch: whatever was undone is no longer ahead of us.
        redoStack.removeAll()
    }

    private func undoLastEdit() {
        guard let edit = undoStack.popLast() else {
            return
        }

        switch edit {
        case .added(let stroke):
            if !strokes.isEmpty {
                strokes.removeLast()
            }
            setNeedsDisplay(strokeBounds(of: stroke))
        case .removed(let removals):
            for removal in removals {
                strokes.insert(removal.stroke, at: min(removal.index, strokes.count))
                setNeedsDisplay(strokeBounds(of: removal.stroke))
            }
        }

        redoStack.append(edit)
    }

    private func redoLastEdit() {
        guard let edit = redoStack.popLast() else {
            return
        }

        switch edit {
        case .added(let stroke):
            strokes.append(stroke)
            setNeedsDisplay(strokeBounds(of: stroke))
        case .removed(let removals):
            for removal in removals.reversed() where removal.index < strokes.count {
                setNeedsDisplay(strokeBounds(of: strokes[removal.index]))
                strokes.remove(at: removal.index)
            }
        }

        undoStack.append(edit)
    }

    // NSBezierPath.bounds covers the path geometry only, so grow it by that stroke's own
    // line width to include the drawn line, its caps and antialiasing.
    private func strokeBounds(of stroke: Stroke) -> NSRect {
        stroke.path.bounds.insetBy(dx: -stroke.width, dy: -stroke.width)
    }

    private func invalidateSegment(from start: NSPoint, to end: NSPoint, width: CGFloat) {
        let segment = NSRect(x: min(start.x, end.x),
                             y: min(start.y, end.y),
                             width: abs(end.x - start.x),
                             height: abs(end.y - start.y))
        setNeedsDisplay(segment.insetBy(dx: -width, dy: -width))
    }



}
