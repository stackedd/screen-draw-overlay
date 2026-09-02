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
        // One eraser drag, however many strokes it cut: what it took away and what it left
        // in their place. One edit rather than one per mouse move, or undo would give a
        // drawing back a nibble at a time.
        case erased(originals: [Removal], pieces: [Stroke])

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
            case .erased(let originals, let pieces):
                let keptOriginals = originals.filter { $0.stroke.id != id }
                let keptPieces = pieces.filter { $0.id != id }
                return keptOriginals.isEmpty ? nil : .erased(originals: keptOriginals,
                                                             pieces: keptPieces)
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
            case .erased(let originals, let pieces):
                let keptOriginals = originals.filter { $0.stroke.createdAt == nil }
                let keptPieces = pieces.filter { $0.createdAt == nil }
                return keptOriginals.isEmpty ? nil : .erased(originals: keptOriginals,
                                                             pieces: keptPieces)
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
    private var eraseOriginals: [Removal] = []
    private var erasePieces: [Stroke] = []
    private var lastErasePoint: NSPoint?

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

        let life = tools.drawnInkLife
        strokeInProgress = Stroke(points: [point], path: path, color: tools.color,
                                  width: width, style: tools.style,
                                  createdAt: life == nil ? nil : Date(),
                                  isShape: tools.tool.isShape,
                                  life: life ?? Stroke.fadeDuration)
        shapeAnchor = tools.tool.isShape ? point : nil
        lastPoint = point

        return Canvas.segmentBounds(from: point, to: point,
                                    reach: tools.style.reach(at: width))
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
                                 createdAt: existing.createdAt, isShape: true,
                                 life: existing.life)
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
        return Canvas.segmentBounds(from: previousPoint, to: point,
                                    reach: existing.style.reach(at: existing.width))
    }

    // A stroke the user has not lifted the mouse off yet is still a stroke. Whenever the
    // tool is taken away mid-drag - hiding the overlay, or stepping into click-through -
    // it has to be committed, or it is dropped on the floor.
    @discardableResult
    func finishStroke() -> NSRect? {
        // Temporary ink starts counting down from here rather than from the mouse going down,
        // or a stroke that took longer to draw than it lives is already gone when it lands.
        guard let finished = strokeInProgress?.startingNow() else {
            return nil
        }

        strokes.append(finished)
        record(.added(finished))
        strokeInProgress = nil
        shapeAnchor = nil
        lastPoint = nil

        return finished.repaintBounds
    }

    // Cuts the beam being drawn into its next piece, if the one in hand has run long enough,
    // and says what changed. The new piece starts where the old one ended, so the trail has no
    // gap in it; each piece then fades on its own, which is what makes the light thin out
    // behind the pointer instead of disappearing in one go when the button comes up.
    //
    // Only the laser draws this way. Every other tool draws one stroke per drag, because
    // everything else is a mark somebody meant to keep.
    func breakBeamIfDue(with tools: ToolSettings) -> NSRect? {
        guard tools.tool == .laser,
              let started = strokeInProgress?.createdAt,
              let last = lastPoint,
              Date().timeIntervalSince(started) >= Stroke.beamPiece else {
            return nil
        }

        let closed = finishStroke()
        let opened = beginStroke(at: last, with: tools)

        return closed?.union(opened) ?? opened
    }

    // MARK: - Erasing and history

    // The eraser cuts, it does not delete. Rubbing out whole strokes was the first design
    // and it made the eraser's size meaningless: one touch anywhere on a line took the whole
    // line, so a wide eraser and a narrow one did exactly the same thing. Now a freehand
    // stroke keeps whatever of itself the eraser did not pass over, and the size is the
    // width of the hole it leaves.
    //
    // Shapes are still taken whole. A rectangle's outline is not its polyline, so there is
    // nothing there to cut in half.
    func beginErase(at point: NSPoint) {
        eraseOriginals = []
        erasePieces = []
        lastErasePoint = point
    }

    // Rubs out along the way, not just at the sample. A mouse move can jump a hundred points
    // when the hand is quick, and an eraser that only cut a circle where each event landed
    // skipped whatever lay between two of them - which is the "sometimes it does nothing"
    // that was reported. Overlapping circles along the segment cover the gap, and reuse the
    // one piece of geometry that is already tested rather than inventing a capsule.
    func erase(at point: NSPoint, radius: CGFloat) -> [NSRect] {
        let from = lastErasePoint ?? point
        lastErasePoint = point

        var dirty: [NSRect] = []
        let swept = NSRect(x: min(from.x, point.x), y: min(from.y, point.y),
                           width: abs(point.x - from.x), height: abs(point.y - from.y))

        for index in strokes.indices.reversed() {
            let stroke = strokes[index]
            let reach = radius + stroke.width / 2
            guard stroke.repaintBounds.insetBy(dx: -reach, dy: -reach)
                .intersects(swept.insetBy(dx: -reach, dy: -reach)) else {
                continue
            }

            let before = stroke.outline()
            var survivors = before
            for centre in Canvas.samples(from: from, to: point, every: reach / 2) {
                survivors = survivors.flatMap {
                    Stroke.surviving($0, centre: centre, radius: reach, shorterThan: stroke.width)
                }
            }

            // Nothing was touched if nothing got shorter. Comparing what is left to what
            // there was is also the hit test, so there is only one piece of geometry
            // deciding whether the eraser reached a stroke and what it did to it.
            guard Stroke.totalLength(of: survivors) < Stroke.totalLength(of: before) else {
                continue
            }

            // A stroke this same drag already cut is not something the drag took away; the
            // thing it took away was whatever that piece came from, and that is recorded.
            if let made = erasePieces.firstIndex(where: { $0.id == stroke.id }) {
                erasePieces.remove(at: made)
            } else {
                eraseOriginals.append(Removal(index: index, stroke: stroke))
            }

            dirty.append(stroke.repaintBounds)
            strokes.remove(at: index)

            let pieces = survivors.compactMap { stroke.piece(of: $0) }
            strokes.insert(contentsOf: pieces, at: index)
            erasePieces.append(contentsOf: pieces)
            dirty.append(contentsOf: pieces.map(\.repaintBounds))
        }

        return dirty
    }

    // Centres along the way from one eraser sample to the next, close enough together that
    // their circles overlap.
    private static func samples(from: NSPoint, to: NSPoint, every step: CGFloat) -> [NSPoint] {
        let distance = hypot(to.x - from.x, to.y - from.y)
        guard distance > step, step > 0 else {
            return [to]
        }

        let count = Int((distance / step).rounded(.up))
        return (0...count).map { index in
            let t = CGFloat(index) / CGFloat(count)
            return NSPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
        }
    }

    // The whole drag, as one thing anyone can take back.
    @discardableResult
    func finishErase() -> Bool {
        guard !eraseOriginals.isEmpty else {
            return false
        }

        record(.erased(originals: eraseOriginals.sorted { $0.index < $1.index },
                       pieces: erasePieces))
        eraseOriginals = []
        erasePieces = []
        lastErasePoint = nil

        return true
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
            case .erased(let originals, let pieces):
                let made = Set(pieces.map(\.id))
                strokes.removeAll { made.contains($0.id) }
                for removal in originals {
                    strokes.insert(removal.stroke, at: min(removal.index, strokes.count))
                    dirty.append(removal.stroke.repaintBounds)
                }
                dirty.append(contentsOf: pieces.map(\.repaintBounds))
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
        case .erased(let originals, let pieces):
            let taken = Set(originals.map(\.stroke.id))
            dirty.append(contentsOf: strokes.filter { taken.contains($0.id) }.map(\.repaintBounds))
            strokes.removeAll { taken.contains($0.id) }
            strokes.append(contentsOf: pieces)
            dirty.append(contentsOf: pieces.map(\.repaintBounds))
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

    // The rectangle one segment of a stroke covers: the box between its ends, grown by how far
    // that pen's paint reaches from the middle of the line. `reach` rather than the width,
    // because a fat marker was asking for twice the area it drew on every mouse move.
    private static func segmentBounds(from start: NSPoint, to end: NSPoint, reach: CGFloat) -> NSRect {
        NSRect(x: min(start.x, end.x),
               y: min(start.y, end.y),
               width: abs(end.x - start.x),
               height: abs(end.y - start.y))
            .insetBy(dx: -reach, dy: -reach)
    }
}
