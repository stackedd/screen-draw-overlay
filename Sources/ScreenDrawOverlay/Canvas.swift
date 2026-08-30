// What has been drawn, and every way it can change.
//
// This is the model half of the overlay: strokes, the stroke being drawn right now, the
// eraser, and the edit history that lets undo put back what the eraser and Clear took away.
// It knows nothing about windows, views or repainting - every method that changes something
// returns the rectangles that changed, and the view decides what to do with them.
//
// Keeping it that way has a practical payoff: the drawing rules can be exercised without a
// window on screen, which is how the mode and editing behaviour is regression-tested.

import AppKit
import Foundation

final class Canvas {
    // Undo has to put back what the eraser and Clear take away, not just the last thing
    // drawn, so edits are recorded rather than inferred from the stroke list. Removals
    // remember where they were, so undo restores depth as well as content.
    private struct Removal {
        let index: Int
        let stroke: Stroke
    }

    private enum Edit {
        case added(Stroke)
        case removed([Removal])
    }

    private(set) var strokes: [Stroke] = []

    // The stroke under the mouse button. Not in `strokes` until it is finished, so an
    // interrupted drag can be committed deliberately rather than half-recorded.
    private(set) var strokeInProgress: Stroke?

    private var shapeAnchor: NSPoint?
    private var lastPoint: NSPoint?
    private var undoStack: [Edit] = []
    private var redoStack: [Edit] = []

    var hasTemporaryInk: Bool {
        strokes.contains { $0.createdAt != nil }
    }

    // MARK: - Drawing a stroke

    func beginStroke(at point: NSPoint, with tools: ToolSettings) -> NSRect {
        let width = tools.renderWidth
        let path = NSBezierPath()
        path.lineWidth = width
        path.lineCapStyle = tools.style.lineCapStyle
        path.lineJoinStyle = .round
        path.move(to: point)

        strokeInProgress = Stroke(points: [point], path: path, color: tools.color,
                                  width: width, style: tools.style,
                                  createdAt: tools.drawsTemporaryInk ? Date() : nil)
        shapeAnchor = tools.tool.isShape ? point : nil
        lastPoint = point

        return Canvas.segmentBounds(from: point, to: point, width: width)
    }

    func extendStroke(to point: NSPoint, shiftHeld: Bool, with tools: ToolSettings) -> NSRect? {
        guard let existing = strokeInProgress else {
            return nil
        }

        // A shape is defined by two points, so it is rebuilt on every move rather than
        // extended. Repainting covers where it was and where it now is.
        if let anchor = shapeAnchor {
            let end = tools.tool.constrainedEnd(from: anchor, to: point, shiftHeld: shiftHeld)
            let previousBounds = existing.repaintBounds
            let rebuilt = tools.tool.shapePath(from: anchor, to: end, width: existing.width)
            let updated = Stroke(points: [anchor, end], path: rebuilt, color: existing.color,
                                 width: existing.width, style: existing.style,
                                 createdAt: existing.createdAt)
            strokeInProgress = updated
            lastPoint = end

            return previousBounds.union(updated.repaintBounds)
        }

        let previousPoint = lastPoint ?? point
        strokeInProgress?.path.line(to: point)
        strokeInProgress?.points.append(point)
        lastPoint = point

        // Only the new segment changed. Invalidating everything here meant every mouse
        // move re-stroked every path drawn so far, so the cost of a drag grew with the
        // number of strokes already on screen.
        return Canvas.segmentBounds(from: previousPoint, to: point, width: existing.width)
    }

    // A stroke the user has not lifted the mouse off yet is still a stroke. Whenever the
    // tool is taken away mid-drag - hiding the overlay, or stepping into click-through -
    // it has to be committed, or it is dropped on the floor.
    @discardableResult
    func finishStroke() -> NSRect? {
        guard let finished = strokeInProgress else {
            return nil
        }

        strokes.append(finished)
        record(.added(finished))
        strokeInProgress = nil
        shapeAnchor = nil
        lastPoint = nil

        return finished.repaintBounds
    }

    // MARK: - Erasing and history

    // The eraser rubs out whole strokes: partial erasing would mean splitting paths, and
    // on an annotation overlay "take that line away" is what people actually want.
    func erase(at point: NSPoint, radius: CGFloat) -> [NSRect] {
        var removed: [Removal] = []
        var dirty: [NSRect] = []

        for index in strokes.indices.reversed() {
            let stroke = strokes[index]
            guard stroke.repaintBounds.insetBy(dx: -radius, dy: -radius).contains(point),
                  stroke.distance(to: point) <= radius + stroke.width / 2 else {
                continue
            }

            removed.append(Removal(index: index, stroke: stroke))
            dirty.append(stroke.repaintBounds)
            strokes.remove(at: index)
        }

        guard !removed.isEmpty else {
            return []
        }

        record(.removed(removed.sorted { $0.index < $1.index }))
        return dirty
    }

    func undo() -> [NSRect] {
        guard let edit = undoStack.popLast() else {
            return []
        }

        var dirty: [NSRect] = []
        switch edit {
        case .added(let stroke):
            if !strokes.isEmpty {
                strokes.removeLast()
            }
            dirty.append(stroke.repaintBounds)
        case .removed(let removals):
            for removal in removals {
                strokes.insert(removal.stroke, at: min(removal.index, strokes.count))
                dirty.append(removal.stroke.repaintBounds)
            }
        }

        redoStack.append(edit)
        return dirty
    }

    func redo() -> [NSRect] {
        guard let edit = redoStack.popLast() else {
            return []
        }

        var dirty: [NSRect] = []
        switch edit {
        case .added(let stroke):
            strokes.append(stroke)
            dirty.append(stroke.repaintBounds)
        case .removed(let removals):
            for removal in removals.reversed() where removal.index < strokes.count {
                dirty.append(strokes[removal.index].repaintBounds)
                strokes.remove(at: removal.index)
            }
        }

        undoStack.append(edit)
        return dirty
    }

    // Clearing is an edit like any other, so an accidental Delete can be taken back.
    func clear() {
        finishStroke()

        if !strokes.isEmpty {
            record(.removed(strokes.enumerated().map { Removal(index: $0.offset, stroke: $0.element) }))
        }

        strokes.removeAll()
        strokeInProgress = nil
        shapeAnchor = nil
        lastPoint = nil
    }

    // MARK: - Carrying a drawing across a hide

    // Temporary ink is deliberately left behind: it was drawn to vanish, and bringing it
    // back mid-fade on the next show would be a surprise.
    func capturedStrokes() -> [Stroke] {
        strokes.filter { $0.createdAt == nil }
    }

    func restore(_ restored: [Stroke]) {
        strokes = restored
        strokeInProgress = nil
        shapeAnchor = nil
        lastPoint = nil
        // The history belongs to the session that drew them; undoing into a drawing you
        // did not make is worse than not undoing at all.
        undoStack.removeAll()
        redoStack.removeAll()
    }

    // MARK: - Fading

    // Ages the temporary strokes one step. Returns the region that has to be repainted, if
    // any, and whether anything is still fading - the caller uses that to stop its timer.
    func advanceFade() -> (dirty: NSRect?, stillFading: Bool) {
        let now = Date()
        var stillFading = false
        var changed = false
        var region = NSRect.zero

        for index in strokes.indices.reversed() {
            guard let createdAt = strokes[index].createdAt else {
                continue
            }

            let bounds = strokes[index].repaintBounds

            if strokes[index].hasFaded {
                // Temporary ink is not an edit: it was never meant to stay, so undo has
                // nothing to say about it disappearing.
                strokes.remove(at: index)
                changed = true
            } else {
                stillFading = true
                // Nothing to repaint while the stroke is still at full strength, which is
                // more than half of its life.
                if now.timeIntervalSince(createdAt) / Stroke.fadeDuration > Stroke.fadeHold {
                    changed = true
                }
            }

            region = region == .zero ? bounds : region.union(bounds)
        }

        // One region covering all of them, not one per stroke: fifty separate rects mean
        // fifty repaint passes that each redraw every stroke they touch, and the cost of a
        // fade then grows with the square of what is on screen. Measured: 12.5% CPU.
        return (changed && region != .zero ? region : nil, stillFading)
    }

    // MARK: - Private

    private func record(_ edit: Edit) {
        undoStack.append(edit)
        // A new edit is a new branch: whatever was undone is no longer ahead of us.
        redoStack.removeAll()
    }

    private static func segmentBounds(from start: NSPoint, to end: NSPoint, width: CGFloat) -> NSRect {
        NSRect(x: min(start.x, end.x),
               y: min(start.y, end.y),
               width: abs(end.x - start.x),
               height: abs(end.y - start.y))
            .insetBy(dx: -width, dy: -width)
    }
}
