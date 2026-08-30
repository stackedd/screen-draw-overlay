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
//      real pointer and a background app cannot win that fight. It lives on a layer of its
//      own, so following the mouse is a layer move and never a repaint - measured at 1.5%
//      of a core against 15.2% for asking the view to repaint instead.
//   3. The badge in the corner is the only interface. There is no palette on screen on
//      purpose, so it has to say which tool, which colour and how to get out. It is a layer
//      too, for the same reason as the pointer: it changed rarely and was being laid out on
//      every repaint.

import AppKit
import Carbon
import Foundation

final class DrawingView: NSView {

    // 15 a second. Measured: the cost of a fade is one repaint of a full screen
    // transparent layer per tick - about 0.4% CPU each - and is almost independent of how
    // many strokes are fading or how big they are. 20/s cost 5.1%, 15/s costs 4.4% and 12/s
    // 4.3%, so past this point the smoothness is free and the savings are not.
    private static let fadeTickInterval: TimeInterval = 1.0 / 15



    // What has been drawn. This view paints it and feeds it events; the rules about what
    // a stroke is and how undo works live in Canvas.
    private let canvas = Canvas()
    private var fadeTimer: Timer?
    let tools: ToolSettings
    private var pointerLocation: NSPoint?

    // nil on every screen but one: the badge would be noise repeated on each display.
    private let badge: ModeBadge?
    let showsIndicator: Bool

    // The pointer rides on this rather than being painted into the view. A repaint of a
    // full screen transparent overlay costs the same whatever its dirty rect, so painting a
    // 26pt crosshair cost as much as painting everything; moving a layer costs a tenth of
    // that and repaints nothing at all (docs/ARCHITECTURE.md).
    private let pointerLayer = CALayer()
    private let badgeLayer = CALayer()

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
            // Click-through hands the real pointer back, so ours goes away with it.
            positionPointerLayer()
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

        pointerLayer.bounds = NSRect(x: 0, y: 0, width: PointerCursor.extent, height: PointerCursor.extent)
        // Without this the pointer eases towards the mouse instead of being under it: Core
        // Animation animates a position change by default and a cursor that lags is worse
        // than no cursor.
        pointerLayer.actions = ["position": NSNull(), "contents": NSNull(),
                                "hidden": NSNull(), "bounds": NSNull()]
        pointerLayer.isHidden = true
        badgeLayer.actions = ["contents": NSNull(), "hidden": NSNull(),
                              "position": NSNull(), "bounds": NSNull()]
        attachLayers()
        refreshPointerImage()
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
        refreshPointerImage()
        refreshBadge()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        refreshPointerImage()
        refreshBadge()
    }

    // The badge first, so the pointer stays on top of it - the same order they used to be
    // painted in.
    private func attachLayers() {
        guard let layer else {
            return
        }

        for sublayer in [badgeLayer, pointerLayer] where sublayer.superlayer !== layer {
            layer.addSublayer(sublayer)
        }
    }

    private var backingScale: CGFloat {
        window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    }

    // Redrawn only when the tool or the colour changes - the laser is a coloured dot, the
    // rest is a crosshair - and when the display's scale does.
    private func refreshPointerImage() {
        pointerLayer.contentsScale = backingScale
        pointerLayer.contents = PointerCursor.image(tool: tools.tool, colour: tools.color,
                                                    scale: backingScale)
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
        movePointer(to: point)

        guard tools.tool != .eraser else {
            erase(at: point)
            return
        }

        guard tools.tool.marksTheCanvas else {
            return
        }

        setNeedsDisplay(canvas.beginStroke(at: point, with: tools))
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        updateBadgeHover(at: point)
        movePointer(to: point)

        guard tools.tool != .eraser else {
            erase(at: point)
            return
        }

        if let dirty = canvas.extendStroke(to: point,
                                           shiftHeld: event.modifierFlags.contains(.shift),
                                           with: tools) {
            setNeedsDisplay(dirty)
        }
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        movePointer(to: point)
        updateBadgeHover(at: point)
        finishStrokeInProgress()
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        movePointer(to: point)
        updateBadgeHover(at: point)
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

    // The badge hides itself while the pointer is over it, so that corner stays drawable.
    private func updateBadgeHover(at point: NSPoint) {
        guard let badge, badge.updateHover(at: point) else {
            return
        }

        badgeLayer.isHidden = badge.isHovered
    }

    private func movePointer(to point: NSPoint?) {
        guard pointerLocation != point else {
            return
        }

        pointerLocation = point
        positionPointerLayer()
    }

    // The whole cost of following the mouse: one layer position, no invalidation, so a
    // pointer crossing a full canvas repaints nothing and re-strokes nothing.
    private func positionPointerLayer() {
        guard !isInteractionMode, let point = pointerLocation else {
            pointerLayer.isHidden = true
            return
        }

        pointerLayer.position = point
        pointerLayer.isHidden = false
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
            canvas.undo().forEach(setNeedsDisplay)
        } else if event.keyCode == UInt16(kVK_ANSI_Z), shortcutFlags == [.command, .shift] {
            canvas.redo().forEach(setNeedsDisplay)
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
        for stroke in canvas.strokes where stroke.repaintBounds.intersects(dirtyRect) {
            let opacity = stroke.opacity(at: now)
            guard opacity > 0 else {
                continue
            }

            stroke.renderColor.withAlphaComponent(stroke.renderColor.alphaComponent * opacity).setStroke()
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

    func finishStrokeInProgress() {
        guard let dirty = canvas.finishStroke() else {
            return
        }

        startFadingIfNeeded()
        setNeedsDisplay(dirty)
    }

    func restore(strokes restored: [Stroke]) {
        canvas.restore(restored)
        needsDisplay = true
    }

    func clear() {
        canvas.clear()
        stopFading()
        needsDisplay = true
    }

    // The badge carries the tool name, its colour and its width, and the pointer is a
    // coloured dot for the laser and a crosshair for everything else, so both pictures
    // belong to the tool. Redrawn on every screen, not just the one the key was pressed on.
    func toolSettingsChanged() {
        refreshPointerImage()
        refreshBadge()
    }

    private func erase(at point: NSPoint) {
        canvas.erase(at: point, radius: tools.eraserRadius).forEach(setNeedsDisplay)
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
        let (dirty, stillFading) = canvas.advanceFade()

        if let dirty {
            setNeedsDisplay(dirty)
        }

        guard !stillFading else {
            return
        }

        stopFading()
    }

    private func stopFading() {
        fadeTimer?.invalidate()
        fadeTimer = nil
    }
}
