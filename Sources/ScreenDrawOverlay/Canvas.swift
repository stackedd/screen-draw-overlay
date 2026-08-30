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
    //
    // Removal and Edit are the canvas's own vocabulary - nothing outside makes one - but
    // they are not private, because Kept carries them across a hide and Kept has to be
    // nameable by whoever holds a hidden drawing.
    struct Removal {
        let index: Int
        let stroke: Stroke
    }

    enum Edit {
        case added(Stroke)
        case removed([Removal])

        // Temporary ink is not something anyone can take back: it was drawn to vanish. When
        // it goes, the entries naming it go too, or undo steps over an entry that does
        // nothing and redo puts back ink that has already expired.
        func forgetting(_ id: UUID) -> Edit? {
            switch self {
            case .added(let stroke):
                return stroke.id == id ? nil : self
            case .removed(let removals):
                let kept = removals.filter { $0.stroke.id != id }
                return kept.isEmpty ? nil : .removed(kept)
            }
        }

        // The same filter, for the ink that does not survive a hide.
        var withoutTemporaryInk: Edit? {
            switch self {
            case .added(let stroke):
                return stroke.createdAt == nil ? self : nil
            case .removed(let removals):
                let kept = removals.filter { $0.stroke.createdAt == nil }
                return kept.isEmpty ? nil : .removed(kept)
            }
        }
    }

    // What a hide keeps so a show can put it back. The history travels with the ink: an
    // undo that cannot take back the strokes you are looking at is worse than no undo.
    struct Kept {
        fileprivate let strokes: [Stroke]
        fileprivate let undoStack: [Edit]
        fileprivate let redoStack: [Edit]

        var strokeCount: Int { strokes.count }
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

    // Steps back to the most recent edit that can still be taken back. An entry naming a
    // stroke that is no longer here is skipped rather than applied to whatever happens to
    // be last - that mistake took back the wrong line.
    func undo() -> [NSRect] {
        while let edit = undoStack.popLast() {
            var dirty: [NSRect] = []

            switch edit {
            case .added(let stroke):
                guard let index = strokes.firstIndex(where: { $0.id == stroke.id }) else {
                    continue
                }

                strokes.remove(at: index)
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

        return []
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
            // By name, not by the index it had then: anything undone in between has moved
            // these along.
            for removal in removals.reversed() {
                guard let index = strokes.firstIndex(where: { $0.id == removal.stroke.id }) else {
                    continue
                }

                dirty.append(strokes[index].repaintBounds)
                strokes.remove(at: index)
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

    // The history goes across with the ink. It used to be thrown away here, on the grounds
    // that undoing into a drawing you did not make is worse than not undoing at all - true,
    // but this is the same drawing, in the same session, put back on the same screen. What
    // the old rule actually produced was hiding the overlay and finding that the last five
    // minutes of work could no longer be taken back.
    func capture() -> Kept {
        Kept(strokes: capturedStrokes(),
             undoStack: undoStack.compactMap(\.withoutTemporaryInk),
             redoStack: redoStack.compactMap(\.withoutTemporaryInk))
    }

    func restore(_ kept: Kept) {
        strokes = kept.strokes
        strokeInProgress = nil
        shapeAnchor = nil
        lastPoint = nil
        undoStack = kept.undoStack
        redoStack = kept.redoStack
    }

    // MARK: - Fading

    // Drops temporary ink that has run out of life, and says whether any is left. It no
    // longer says what to repaint, because a fade is not painted any more: each temporary
    // stroke sits on a layer of its own and Core Animation takes its opacity down. What
    // this is for is keeping the model honest - a stroke that has faded is gone, so the
    // eraser, undo and "is anything still fading" all agree with what is on screen.
    @discardableResult
    func dropFadedInk() -> Bool {
        var stillFading = false

        for index in strokes.indices.reversed() {
            guard strokes[index].createdAt != nil else {
                continue
            }

            if strokes[index].hasFaded {
                // Temporary ink is not an edit: it was never meant to stay, so undo has
                // nothing to say about it disappearing - and nothing to say about it at
                // all, which is why the entry that put it there goes as well.
                let faded = strokes.remove(at: index)
                forget(faded.id)
            } else {
                stillFading = true
            }
        }

        return stillFading
    }

    // MARK: - Private

    private func forget(_ id: UUID) {
        undoStack = undoStack.compactMap { $0.forgetting(id) }
        redoStack = redoStack.compactMap { $0.forgetting(id) }
    }

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
