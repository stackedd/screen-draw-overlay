// The canvas. Everything the user sees inside the overlay is painted here, and every
// mouse and key event in drawing mode arrives here.
//
// Three things to know before editing:
//
//   1. Nothing is painted through NSView.draw(_:). The ink has a CALayer of its own and
//      the badge and the pointer have theirs, because the same repaint of the same full
//      screen transparent layer costs 15.2% of a core asked for through AppKit's view
//      display machinery and 3.5% asked for through a layer (docs/ARCHITECTURE.md).
//   2. Repainting is incremental. A drag invalidates only the rectangle the new segment
//      covers, and the ink is painted skipping strokes that do not meet the dirty rect.
//      Repainting everything per mouse move cost 26x more. Anything added here should
//      invalidate its own rect, never the whole layer.
//   3. The pointer is a cursor, not paint. The panel hands the window server the system
//      arrow with a ring around its tip, so there is only ever one pointer on screen and
//      following the mouse costs this process nothing at all.
//   4. The badge in the corner is the only interface. There is no palette on screen on
//      purpose, so it has to say which tool, which colour and how to get out. It is a layer
//      too, for the same reason as the pointer: it changed rarely and was being laid out on
//      every repaint.

import AppKit
import Carbon
import Foundation

final class DrawingView: NSView {

    // The fade is not painted, so this timer does not drive it - Core Animation does, on
    // each temporary stroke's own layer. All this does is drop ink that has run out of
    // life so the model agrees with the screen, which nothing is waiting on. Twice a
    // second is plenty and costs nothing.
    private static let fadeTickInterval: TimeInterval = 0.5



    // What has been drawn. This view paints it and feeds it events; the rules about what
    // a stroke is and how undo works live in Canvas.
    private let canvas = Canvas()
    private var fadeTimer: Timer?
    let tools: ToolSettings

    // nil on every screen but one: the badge would be noise repeated on each display.
    private let badge: ModeBadge?
    let showsIndicator: Bool

    // The pointer rides on this rather than being painted into the view. A repaint of a
    // full screen transparent overlay costs the same whatever its dirty rect, so painting a
    // 26pt crosshair cost as much as painting everything; moving a layer costs a tenth of
    // that and repaints nothing at all (docs/ARCHITECTURE.md).
    // Everything the user sees is on one of these three, bottom to top. None of them is
    // the view's own backing layer, which now paints nothing at all.
    private let inkLayer = CALayer()
    private let badgeLayer = CALayer()
    private let inkPainter = InkPainter()

    // One layer per temporary stroke, above the ink, each fading itself.
    //
    // Painting the fade was costing what the whole screen costs to repaint: the strokes
    // are invalidated as one region, that region is most of the screen once there are a
    // few of them, and it was being repainted fifteen times a second - 29.8% of a core
    // with fifty of them on screen. Opacity on a layer is not a repaint at all, so this
    // costs nothing whatever is fading (docs/DECISIONS.md).
    private var fadingLayers: [UUID: CALayer] = [:]

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
            // The badge changes text, size and colour with the mode. It used to cost a
            // repaint of the whole view; now it is a new picture on a layer.
            refreshBadge()
            if isInteractionMode {
                releaseDrawingCursor()
            } else {
                refreshCursorRects()
                applyDrawingCursor()
            }
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

        badgeLayer.actions = ["contents": NSNull(), "hidden": NSNull(),
                              "position": NSNull(), "bounds": NSNull()]
        inkPainter.view = self
        inkLayer.delegate = inkPainter
        inkLayer.frame = NSRect(origin: .zero, size: frameRect.size)
        attachLayers()
        refreshBadge()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        fadeTimer?.invalidate()
    }

    // AppKit can hand the view a new backing layer when it changes windows, and both
    // pictures are only right for one backing scale.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        attachLayers()
        refreshBadge()
        inkLayer.contentsScale = backingScale
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        refreshBadge()
        // A layer keeps its pixels through a scale change, so they have to be redrawn or
        // the drawing stays at the old display's resolution.
        inkLayer.contentsScale = backingScale
        inkLayer.setNeedsDisplay()
    }

    // Ink, then badge: the order they used to be painted in. The pointer is not here - it
    // is a cursor, and the window server draws it above everything.
    private func attachLayers() {
        guard let layer else {
            return
        }

        for sublayer in [inkLayer, badgeLayer] where sublayer.superlayer !== layer {
            layer.addSublayer(sublayer)
        }
    }

    // The panels are the size of their screen and do not resize in normal use, but a layer
    // does not follow its view's bounds on its own and a stale ink layer would clip the
    // drawing.
    override func layout() {
        super.layout()

        guard inkLayer.frame != bounds else {
            return
        }

        inkLayer.frame = bounds
        inkLayer.setNeedsDisplay()
    }

    private var backingScale: CGFloat {
        window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    }

    // Same story: a new picture on a tool, colour or mode change, and nothing at all on a
    // mouse move.
    private func refreshBadge() {
        guard let badge else {
            return
        }

        let (image, frame) = badge.render(scale: backingScale)
        badgeLayer.contentsScale = backingScale
        badgeLayer.contents = image
        badgeLayer.frame = frame
        badgeLayer.isHidden = badge.isHovered
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
        updateBadgeHover(at: point)

        guard tools.tool != .eraser else {
            erase(at: point)
            return
        }

        guard tools.tool.marksTheCanvas else {
            return
        }

        invalidateInk(canvas.beginStroke(at: point, with: tools))
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        updateBadgeHover(at: point)

        guard tools.tool != .eraser else {
            erase(at: point)
            return
        }

        if let dirty = canvas.extendStroke(to: point,
                                           shiftHeld: event.modifierFlags.contains(.shift),
                                           with: tools) {
            invalidateInk(dirty)
        }
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        updateBadgeHover(at: point)
        finishStrokeInProgress()
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        updateBadgeHover(at: point)
    }

    override func mouseEntered(with event: NSEvent) {
        applyDrawingCursor()
    }

    // Three ways to claim the cursor, because any one of them can be missed: the cursor
    // rect for a plain pointer move, cursorUpdate for when the window server asks us
    // directly, and mouseEntered for arriving from another app's window.
    override func resetCursorRects() {
        super.resetCursorRects()
        guard !isInteractionMode else {
            return
        }

        addCursorRect(bounds, cursor: PointerCursor.cursor(for: tools))
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

        PointerCursor.cursor(for: tools).set()
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
        // The pointer is on another screen's panel now. A hover left in effect here would
        // keep the badge hidden on this one until the pointer came back and crossed it
        // again, so it is forgotten on the way out.
        guard let badge, badge.isHovered else {
            return
        }

        badge.forgetHover()
        badgeLayer.isHidden = false
    }

    // The badge hides itself while the pointer is over it, so that corner stays drawable.
    private func updateBadgeHover(at point: NSPoint) {
        guard let badge, badge.updateHover(at: point) else {
            return
        }

        badgeLayer.isHidden = badge.isHovered
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
            undo()
        } else if event.keyCode == UInt16(kVK_ANSI_Z), shortcutFlags == [.command, .shift] {
            redo()
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

    // The two ways the ink is asked to repaint. Everything that changes what is on the
    // canvas goes through one of them, and the rendering suite watches them: a drag that
    // invalidates everything is the bug that suite exists to catch.
    private func invalidateInk(_ rect: NSRect) {
        inkLayer.setNeedsDisplay(rect)
    }

    private func invalidateAllInk() {
        inkLayer.setNeedsDisplay()
    }

    // Called by the ink layer's delegate, with a graphics context already current.
    func drawInk(in dirtyRect: NSRect) {
        // Skip strokes that are nowhere near the region being repainted. With
        // incremental invalidation this is what keeps a drag cheap on a long session.
        // Temporary ink is not here: it is on a layer of its own, fading itself.
        for stroke in canvas.strokes
        where stroke.createdAt == nil && stroke.repaintBounds.intersects(dirtyRect) {
            stroke.renderColor.setStroke()
            stroke.path.stroke()
        }

        if let inProgress = canvas.strokeInProgress, inProgress.repaintBounds.intersects(dirtyRect) {
            inProgress.renderColor.setStroke()
            inProgress.path.stroke()
        }
    }

    // What AppDelegate lifts out before the panels are destroyed, and puts back when they
    // are recreated: hiding the overlay is not erasing it.
    func capturedStrokes() -> [Stroke] {
        canvas.capturedStrokes()
    }

    func capturedDrawing() -> Canvas.Kept {
        canvas.capture()
    }

    func finishStrokeInProgress() {
        guard let dirty = canvas.finishStroke() else {
            return
        }

        startFadingIfNeeded()
        syncFadingLayers()
        invalidateInk(dirty)
    }

    func restore(_ kept: Canvas.Kept) {
        canvas.restore(kept)
        syncFadingLayers()
        invalidateAllInk()
    }

    // Undo and redo reach the canvas from two directions: Command+Z while the panel is key,
    // and the global shortcut, which works whatever has the keyboard.
    func undo() {
        canvas.undo().forEach(invalidateInk)
        syncFadingLayers()
        startFadingIfNeeded()
    }

    func redo() {
        canvas.redo().forEach(invalidateInk)
        syncFadingLayers()
        startFadingIfNeeded()
    }

    func clear() {
        canvas.clear()
        stopFading()
        syncFadingLayers()
        invalidateAllInk()
    }

    // The badge carries the tool name, its colour and its width, and the pointer is a
    // coloured dot for the laser and a crosshair for everything else, so both pictures
    // belong to the tool. Redrawn on every screen, not just the one the key was pressed on.
    func toolSettingsChanged() {
        // The ring is drawn in the tool's colour and sized to its nib, so the cursor is
        // rebuilt and set at once rather than at the next mouse move. Safe here: rebuilding
        // cursor rects is only forbidden from inside cursorUpdate, and this is a keypress.
        refreshCursorRects()
        applyDrawingCursor()
        refreshBadge()
    }

    private func erase(at point: NSPoint) {
        canvas.erase(at: point, radius: tools.eraserRadius).forEach(invalidateInk)
        syncFadingLayers()
    }

    // The only timer in the app, and it exists only while temporary ink is on screen:
    // it starts when one is drawn and stops the moment the last one is gone, so an idle
    // overlay still costs nothing.
    private func startFadingIfNeeded() {
        guard fadeTimer == nil, canvas.hasTemporaryInk else {
            return
        }

        let timer = Timer(timeInterval: DrawingView.fadeTickInterval, repeats: true) { [weak self] _ in
            self?.advanceFade()
        }
        RunLoop.main.add(timer, forMode: .common)
        fadeTimer = timer
    }

    private func advanceFade() {
        let stillFading = canvas.dropFadedInk()
        syncFadingLayers()

        guard !stillFading else {
            return
        }

        stopFading()
    }

    // Brings the layers in line with what the canvas holds: a new temporary stroke gets one
    // and starts fading, and anything the canvas no longer has - faded out, erased, undone,
    // cleared - loses one. Reconciling rather than tracking each of those separately is
    // what keeps the eraser and undo working on temporary ink without either of them
    // knowing that it lives on a layer.
    private func syncFadingLayers() {
        var wanted: Set<UUID> = []

        for stroke in canvas.strokes where stroke.createdAt != nil {
            wanted.insert(stroke.id)
            guard fadingLayers[stroke.id] == nil, let layer = makeFadingLayer(for: stroke) else {
                continue
            }

            fadingLayers[stroke.id] = layer
            inkLayer.superlayer?.insertSublayer(layer, above: inkLayer)
        }

        for (id, layer) in fadingLayers where !wanted.contains(id) {
            layer.removeFromSuperlayer()
            fadingLayers.removeValue(forKey: id)
        }
    }

    // The stroke painted once into a picture of its own, then handed the rest of its life
    // as an opacity animation. The curve is the one the painted version had: full strength
    // for the first stretch, because fading from the first instant reads as a rendering
    // fault rather than a decision.
    private func makeFadingLayer(for stroke: Stroke) -> CALayer? {
        guard let createdAt = stroke.createdAt else {
            return nil
        }

        let frame = stroke.repaintBounds
        let scale = backingScale
        guard frame.width > 0, frame.height > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: Int((frame.width * scale).rounded(.up)),
                                         pixelsHigh: Int((frame.height * scale).rounded(.up)),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else {
            return nil
        }

        rep.size = frame.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.translateBy(x: -frame.minX, y: -frame.minY)
        stroke.renderColor.setStroke()
        stroke.path.stroke()
        NSGraphicsContext.restoreGraphicsState()

        let layer = CALayer()
        layer.frame = frame
        layer.contentsScale = scale
        layer.contents = rep.cgImage
        layer.actions = ["contents": NSNull(), "position": NSNull(), "bounds": NSNull()]

        let age = Date().timeIntervalSince(createdAt)
        let remaining = Stroke.fadeDuration - age
        guard remaining > 0 else {
            return nil
        }

        let animation = CAKeyframeAnimation(keyPath: "opacity")
        let holdEnds = Stroke.fadeDuration * Stroke.fadeHold
        animation.values = [1, 1, 0]
        animation.keyTimes = [0, NSNumber(value: max(0, min(1, (holdEnds - age) / remaining))), 1]
        animation.duration = remaining
        animation.fillMode = .forwards
        animation.isRemovedOnCompletion = false
        layer.opacity = 0
        layer.add(animation, forKey: "fade")

        return layer
    }

    private func stopFading() {
        fadeTimer?.invalidate()
        fadeTimer = nil
    }
}
