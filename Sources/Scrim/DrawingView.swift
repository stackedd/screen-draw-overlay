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
//   3. The pointer is a cursor, not paint. The panel hands the window server a cursor drawn
//      for the tool in hand, so there is only ever one pointer on screen and following the
//      mouse costs this process nothing at all.
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
    let showsBadge: Bool

    // The pointer rides on this rather than being painted into the view. A repaint of a
    // full screen transparent overlay costs the same whatever its dirty rect, so painting a
    // 26pt crosshair cost as much as painting everything; moving a layer costs a tenth of
    // that and repaints nothing at all (docs/ARCHITECTURE.md).
    // Everything the user sees is on one of these three, bottom to top. None of them is
    // the view's own backing layer, which now paints nothing at all.
    private let inkLayer = CALayer()
    private let badgeLayer = CALayer()
    private let inkPainter = InkPainter()

    // The laser, when it is the tool in hand, and the pointer whatever the tool is. Both are
    // on the overlay rather than on the cursor, because the one thing either has to do is be
    // there - and an app that is presenting can hide a cursor (docs/DECISIONS.md 6).
    private let laserLayer = LaserDot.makeLayer()
    private let pointerLayer = LaserDot.makeLayer()
    private var pointerPoll: Timer?
    // Who was in front before typing pulled the app forward, so that finishing hands it back.
    // Only ever set when the setting that pulls it forward is on.
    private var appToGoBackTo: NSRunningApplication?
    // One shot, while a caret is waiting for its first keystroke. See watchForKeystrokesArriving().
    private var typingWatch: Timer?
    private var lastPointerPoint: NSPoint?
    private var lastPointerUpdate = Date.distantPast

    // Temporary ink, once it is finished: one self-fading layer each, above the ink.
    private let fadingInk = FadingInk()

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
            // Click-through hands the screen back, and neither the pointer nor a laser dot
            // belongs on top of an app the user is now driving.
            showPointer()
            if isInteractionMode {
                releaseDrawingCursor()
            } else {
                refreshCursorRects()
                applyDrawingCursor()
            }
        }
    }
    private var mouseTrackingArea: NSTrackingArea?
    private var noticeTimer: Timer?

    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { false }

    init(frame frameRect: NSRect, badgeBounds: NSRect, showsBadge: Bool, tools: ToolSettings) {
        self.badge = showsBadge ? ModeBadge(bounds: badgeBounds, tools: tools) : nil
        self.showsBadge = showsBadge
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
        refreshPointer()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        fadeTimer?.invalidate()
        pointerPoll?.invalidate()
        noticeTimer?.invalidate()
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
        refreshPointer()
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

        // Bottom to top, and the pointer is on top of everything, where a pointer belongs.
        for sublayer in [inkLayer, badgeLayer, laserLayer, pointerLayer]
        where sublayer.superlayer !== layer {
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

    // The pointer, as a picture on a layer, and the laser's glow beside it. Both are redrawn
    // only when the tool, the colour, the width or the display's scale changes - never on a
    // mouse move, which only moves them.
    //
    // The pointer is drawn here rather than handed to the window server as a cursor, and that
    // reverses a decision this app held for a long time (docs/DECISIONS.md 6). The reason is
    // the thing this app exists for: **an app that is presenting hides the pointer**, and a
    // cursor of ours is then not drawn at all. Measured, with a stand-in for a slideshow: a
    // frontmost app that calls NSCursor.hide leaves NSCursor.currentSystem reporting a
    // perfectly visible cursor, so we cannot even tell it happened - and CGDisplayShowCursor
    // from here does not undo it. During a presentation every tool's pointer vanished and the
    // laser's glow was the only one left, which is exactly what was reported.
    //
    // So the window server gets a cursor that shows nothing, and the pointer is a layer. The
    // failure this used to have - lose the cursor once and there are two pointers with no way
    // back - is answered by the cursor hold in OverlayController, which re-sets the invisible
    // cursor a hundred and twenty times a second: worst case is under a frame of a second
    // pointer, against a pointer that was missing for the whole presentation.
    private func refreshPointer() {
        let extent = LaserDot.extent(for: tools.renderWidth)
        laserLayer.bounds = NSRect(x: 0, y: 0, width: extent, height: extent)
        laserLayer.contentsScale = backingScale
        laserLayer.contents = LaserDot.glow(tools.color, width: tools.renderWidth,
                                            scale: backingScale)

        if let picture = PointerCursor.picture(for: tools, scale: backingScale) {
            pointerLayer.bounds = NSRect(origin: .zero, size: picture.size)
            pointerLayer.contentsScale = backingScale
            pointerLayer.contents = picture.image
        } else {
            // The laser's pointer is its glow, and two marks an inch apart are worse than one.
            pointerLayer.contents = nil
        }

        showPointer()
    }

    private func showPointer() {
        guard !isInteractionMode else {
            // Click-through hands the screen back: the pointer belongs to the app underneath,
            // and a glow sitting on top of what the user is now driving is in the way.
            laserLayer.isHidden = true
            pointerLayer.isHidden = true
            stopPointerPoll()
            return
        }

        // Placed before it is shown: followPointer does both, in that order, so nothing can
        // appear for a frame wherever it was last left.
        followPointer(force: true)
        startPointerPoll()
    }

    // Polled as well as driven by events, because neither is enough on its own. Mouse-moved
    // events only reach the key window and these panels are non-activating, so the moment the
    // user has clicked anything in another app the events stop and the pointer hangs in the
    // air where it was last drawn. The poll works whoever has focus; the events keep it level
    // with the ink it is drawing, which a poll on its own does not.
    //
    // It runs while the overlay is taking the mouse and stops with click-through and with the
    // overlay, so a closed overlay still costs nothing.
    private func startPointerPoll() {
        guard pointerPoll == nil else {
            return
        }

        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            self?.followPointer()
        }
        RunLoop.main.add(timer, forMode: .common)
        pointerPoll = timer
    }

    private func stopPointerPoll() {
        pointerPoll?.invalidate()
        pointerPoll = nil
    }

    // Where the pointer is, and whether this screen is the one that shows it. Called with a
    // point by everything that already has one - a move, a press, a drag - and without one by
    // the poll, which asks the window server instead.
    //
    // Whether anything is shown is decided here, from where the pointer is, rather than by
    // mouseEntered and mouseExited. Those were doing it for the laser, and an exit with no
    // matching entry - a menu opening over the panel is enough - put the glow out for good,
    // because nothing else ever turned it back on. Decided from the pointer's position it
    // heals itself on the next tick, whatever was missed.
    private func followPointer(to point: NSPoint? = nil, force: Bool = false) {
        guard let window, !isInteractionMode else {
            return
        }

        // The poll is the fallback, not the driver. While events are arriving they are ahead
        // of it and both were doing the work, which is two layer moves a frame instead of
        // one: measured, following the pointer went from 0.5% of a core to 2.6% when the
        // pointer became a layer, and a good part of that was this. `force` is for the things
        // that change what should be showing rather than where it is - a tool, a mode - which
        // must not be skipped because an event happened to arrive a moment ago.
        let now = Date()
        if point == nil, !force, now.timeIntervalSince(lastPointerUpdate) < 1.0 / 90 {
            return
        }
        lastPointerUpdate = now

        let here = point ?? convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)

        // One pointer, on the screen it is actually over. Every panel polls, so without this
        // each of them would draw one at the edge nearest the pointer.
        let mine = bounds.contains(here)
        let laserWanted = mine && tools.tool == .laser
        let pointerWanted = mine && pointerLayer.contents != nil

        // Only what is going to be seen is moved: the other layer is hidden, and moving a
        // hidden layer is a layer move nobody asked for. A layer that is *about* to be shown
        // is placed whether or not the pointer moved - picking the laser without moving the
        // mouse would otherwise light it wherever it was last left.
        let moved = here != lastPointerPoint
        lastPointerPoint = here

        // Committed here rather than left to the end of the run loop's turn. The pointer is a
        // layer now, so every frame it waits is a frame it is behind the hand - and a hand
        // notices that in a way it does not notice anything else in this app.
        if moved || laserLayer.isHidden || pointerLayer.isHidden {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            if laserWanted {
                laserLayer.position = here
            }
            if pointerWanted {
                pointerLayer.position = here
            }
            CATransaction.commit()
        }

        if laserLayer.isHidden == laserWanted {
            laserLayer.isHidden = !laserWanted
        }
        if pointerLayer.isHidden == pointerWanted {
            pointerLayer.isHidden = !pointerWanted
        }
    }

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
        followPointer(to: point)

        // Typed rather than dragged: a click puts the caret somewhere. Clicking again while
        // something is being typed finishes it and starts the next one where the click was,
        // which is what every other text tool on this machine does.
        guard !tools.tool.isTyped else {
            if canvas.textInProgress != nil {
                finishTyping()
            }

            invalidateInk(canvas.beginText(at: point, with: tools))
            takeTheKeyboard()
            return
        }

        // Picking something up rather than drawing something new. Nothing under the pointer
        // is not a failure: it is the answer, and the drag does nothing.
        guard tools.tool != .move else {
            canvas.grabStroke(at: point)
            return
        }

        guard tools.tool != .eraser else {
            // One drag is one thing to take back, however many strokes it cuts through.
            canvas.beginErase(at: point)
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
        // The beam is drawn where the event says the pointer is, so the glow is told the same
        // thing: left to the poll, the light trailed the ink it is supposed to be making.
        followPointer(to: point)

        guard tools.tool != .move else {
            if let dirty = canvas.dragGrabbed(to: point) {
                invalidateInk(dirty)
            }

            return
        }

        guard tools.tool != .eraser else {
            erase(at: point)
            return
        }

        if let dirty = canvas.extendStroke(to: point,
                                           shiftHeld: event.modifierFlags.contains(.shift),
                                           with: tools) {
            invalidateInk(dirty)
        }

        // The laser's trail is a run of short pieces, each handed its own fading layer as it
        // is finished, so the light thins out behind the hand rather than hanging at full
        // strength until the button comes up.
        if let cut = canvas.breakBeamIfDue(with: tools) {
            startFadingIfNeeded()
            syncFadingInk()
            invalidateInk(cut)
        }
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        updateBadgeHover(at: point)

        // A caret that was just put down is not a finished mark: it is waiting to be typed
        // into, and the button coming up is not the end of anything.
        guard canvas.textInProgress == nil else {
            return
        }

        finishStrokeInProgress()
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        updateBadgeHover(at: point)
        followPointer(to: point)
    }

    override func mouseEntered(with event: NSEvent) {
        applyDrawingCursor()
        followPointer(to: convert(event.locationInWindow, from: nil))
    }

    // Three ways to claim the cursor, because any one of them can be missed: the cursor
    // rect for a plain pointer move, cursorUpdate for when the window server asks us
    // directly, and mouseEntered for arriving from another app's window.
    // Counted, because "how often are these rebuilt?" turned out to be a question worth
    // asking: the answer was "on every pick", and that was the flash (docs/DECISIONS.md 37).
    private(set) var cursorRectRebuilds = 0

    override func resetCursorRects() {
        super.resetCursorRects()
        cursorRectRebuilds += 1
        guard !isInteractionMode else {
            return
        }

        addCursorRect(bounds, cursor: PointerCursor.invisible)
    }

    override func cursorUpdate(with event: NSEvent) {
        applyDrawingCursor()
    }

    // Safe to call from an event callback: it only sets the cursor. Rebuilding cursor rects
    // from inside cursorUpdate re-enters AppKit's tracking machinery and throws, so that lives
    // in refreshCursorRects, which only mode and tool changes call.
    //
    // Taking the cursor back on a schedule used to live here, throttled to eight times a
    // second and driven by mouse events - which meant it only ran while the mouse was moving,
    // and the case that was actually reported is the pointer standing still. It is
    // OverlayController's cursor hold now, on a timer, so a stationary pointer is covered and
    // a moving one costs nothing to handle.
    // What the window server draws while the overlay is taking the mouse: nothing. The
    // pointer the user sees is the layer above, and this is only here so that nothing else
    // claims the cursor and draws an arrow next to ours.
    func applyDrawingCursor() {
        guard !isInteractionMode else {
            return
        }

        PointerCursor.invisible.set()
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
        // The laser is deliberately not touched here: which screen shows the glow is decided
        // from where the pointer is, on every tick, so an exit with no entry after it cannot
        // put the light out for good.
        //
        // The pointer is on another screen's panel now. A hover left in effect here would
        // keep the badge hidden on this one until the pointer came back and crossed it
        // again, so it is forgotten on the way out.
        guard let badge, badge.isHovered else {
            return
        }

        badge.forgetHover()
        badgeLayer.isHidden = false
    }

    // Says something on the badge for a moment and then takes it back. The badge is the
    // only place this app can say anything at all - there is no dialog and there is not
    // going to be one - so a tool that cannot do what was just asked of it says so here.
    func flash(_ message: String) {
        guard let badge else {
            return
        }

        noticeTimer?.invalidate()
        badge.notice = message
        refreshBadge()

        let timer = Timer(timeInterval: 1.6, repeats: false) { [weak self] _ in
            self?.badge?.notice = nil
            self?.refreshBadge()
            self?.noticeTimer = nil
        }
        RunLoop.main.add(timer, forMode: .common)
        noticeTimer = timer
    }

    // The badge hides itself while the pointer is over it, so that corner stays drawable.
    private func updateBadgeHover(at point: NSPoint) {
        guard let badge, badge.updateHover(at: point) else {
            return
        }

        badgeLayer.isHidden = badge.isHovered
    }

    // Drawing mode owns the keyboard and does nothing with it.
    //
    // There used to be a layer of bare keys here - P for pen, 1 to 6 for colours, C to clear,
    // Command+Z to undo - and they were quick, and they were a trap: they only worked while
    // this panel happened to be the key window, which is a state the user cannot see. Anything
    // this app can be told to do is on the Option row now, registered globally, so it works
    // whatever has the keyboard (docs/DECISIONS.md 30).
    //
    // Keys are still swallowed rather than passed on: an unhandled key travels up the
    // responder chain and ends in a system beep, so typing while drawing made the machine beep
    // on every letter. Escape included - it used to leave drawing mode, and it threw the
    // drawing away just as somebody pressed Escape to get out of a presentation.
    override func keyDown(with event: NSEvent) {
        // The one exception to the rule above, and it is not a shortcut: with the text tool in
        // hand and a caret on screen, the keyboard is the tool. Everything else is still
        // swallowed, including every key while nothing is being typed.
        guard let typed = canvas.textInProgress else {
            return
        }

        switch event.keyCode {
        case UInt16(kVK_Escape):
            // Nothing is left behind, the way Escape means everywhere else.
            if let dirty = canvas.cancelText() {
                invalidateInk(dirty)
            }

            releaseTheKeyboard()
        case UInt16(kVK_Return), UInt16(kVK_ANSI_KeypadEnter):
            finishTyping()
        case UInt16(kVK_Delete):
            if !typed.isEmpty, let dirty = canvas.typeText(String(typed.dropLast())) {
                invalidateInk(dirty)
            }
        default:
            // Control characters are what the keys this app does not handle arrive as - arrows,
            // function keys, the lot - and putting them in the string would draw a box.
            let characters = (event.characters ?? "").filter { !$0.unicodeScalars.contains { scalar in
                CharacterSet.controlCharacters.contains(scalar)
            } }

            if !characters.isEmpty, let dirty = canvas.typeText(typed + characters) {
                invalidateInk(dirty)
            }
        }
    }

    // Committing what was typed, from the keyboard or from a click somewhere else.
    func finishTyping() {
        if let dirty = canvas.finishText() {
            startFadingIfNeeded()
            syncFadingInk()
            invalidateInk(dirty)
        }

        releaseTheKeyboard()
    }

    // Typing is the one thing here that needs the keyboard.
    //
    // **The panel is made key and the app is left where it is.** A `.nonactivatingPanel` is
    // documented to be able to take keyboard input without taking the front - it is what a
    // character palette is - and taking the front is what put a presenter out of their
    // slideshow (docs/DECISIONS.md 39). If that ever fails somewhere, `comesForwardToType`
    // in Settings is the old behaviour, off by default.
    private func takeTheKeyboard() {
        window?.makeKeyAndOrderFront(nil)

        guard tools.comesForwardToType else {
            // Nothing typed yet, and no way to see that the keys are going elsewhere: say so
            // rather than leave somebody typing into a caret that is not listening.
            watchForKeystrokesArriving()
            return
        }

        if NSApp.isActive == false {
            appToGoBackTo = NSWorkspace.shared.frontmostApplication
        }

        NSApp.activate(ignoringOtherApps: true)
    }

    private func releaseTheKeyboard() {
        typingWatch?.invalidate()
        typingWatch = nil

        guard let previous = appToGoBackTo else {
            return
        }

        appToGoBackTo = nil
        previous.activate()
    }

    // A caret with nothing in it, a couple of seconds later, with this app not in front: the
    // keys are going somewhere else and nothing on screen says so. One shot, and it dies with
    // the text session either way (CLAUDE.md, never number 8).
    private func watchForKeystrokesArriving() {
        typingWatch?.invalidate()

        let timer = Timer(timeInterval: 2.5, repeats: false) { [weak self] _ in
            guard let self, self.canvas.textInProgress?.isEmpty == true, !NSApp.isActive else {
                return
            }

            self.flash("Typing is not reaching Scrim - switch on \"come forward while typing\" "
                       + "in Settings")
        }
        RunLoop.main.add(timer, forMode: .common)
        typingWatch = timer
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
            stroke.paint(meeting: dirtyRect)
        }

        if let inProgress = canvas.strokeInProgress, inProgress.repaintBounds.intersects(dirtyRect) {
            inProgress.paint(meeting: dirtyRect)

            // A caret, so that a text tool with nothing typed yet is not an invisible tool.
            // It does not blink: a blink is a timer running for as long as somebody is
            // thinking about what to write, and this app does not leave timers running for
            // decoration.
            if inProgress.style == .text {
                let box = inProgress.path.bounds
                inProgress.color.withAlphaComponent(0.9).setFill()
                NSRect(x: box.maxX - 1, y: box.minY + 2,
                       width: max(1, inProgress.width / 14), height: box.height - 4).fill()
            }
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
        // Something being typed is finished the same way, and the keyboard goes back with it.
        guard canvas.textInProgress == nil else {
            finishTyping()
            return
        }

        // A mark being dragged is finished the same way too: the tool being taken away
        // mid-drag must put it down, not drop it.
        if canvas.isHoldingSomething {
            if let dirty = canvas.dropGrabbed() {
                invalidateInk(dirty)
            }

            return
        }

        // An eraser drag is finished the same way a stroke is, and for the same reason:
        // whenever the tool is taken away mid-drag it has to be committed, not dropped.
        canvas.finishErase()

        guard let dirty = canvas.finishStroke() else {
            return
        }

        startFadingIfNeeded()
        syncFadingInk()
        invalidateInk(dirty)
    }

    func restore(_ kept: Canvas.Kept) {
        canvas.restore(kept)
        syncFadingInk()
        invalidateAllInk()
    }

    // Undo and redo arrive from the actions wheel, which is a global hot key: the canvas can
    // be taken back from whatever the user is doing, on the screen the pointer is over.
    func undo() {
        canvas.undo().forEach(invalidateInk)
        syncFadingInk()
        startFadingIfNeeded()
    }

    func redo() {
        canvas.redo().forEach(invalidateInk)
        syncFadingInk()
        startFadingIfNeeded()
    }

    func clear() {
        canvas.clear()
        stopFading()
        syncFadingInk()
        invalidateAllInk()
    }

    // The badge carries the tool name, its colour and its width, and the pointer is a
    // coloured dot for the laser and a crosshair for everything else, so both pictures
    // belong to the tool. Redrawn on every screen, not just the one the key was pressed on.
    func toolSettingsChanged() {
        // **No cursor rect rebuild here**, and that is the point rather than an omission. The
        // rect holds `PointerCursor.invisible` whatever the tool is - it has, since the pointer
        // became a layer and the window server stopped being handed a picture of the nib
        // (docs/DECISIONS.md 6). So a tool, colour or width change has nothing to rebuild, and
        // rebuilding anyway made the window under the pointer briefly have no cursor rect at
        // all: on a pointer that is moving, which is what a hand does the instant it has picked
        // something, the window server answers that with the plain arrow (37).
        //
        // What is still needed: the cursor set now rather than at the next move, the pointer's
        // own picture rebuilt in the new colour and size, and the badge redrawn.
        CursorLog.note("tool settings changed")
        applyDrawingCursor()
        refreshPointer()
        refreshBadge()
    }

    private func erase(at point: NSPoint) {
        canvas.erase(at: point, radius: tools.eraserRadius).forEach(invalidateInk)
        syncFadingInk()
    }

    // Exists only while temporary ink is on screen: it starts when one is drawn and stops
    // the moment the last one is gone. Like every other timer here (the pointer poll above,
    // the cursor hold in OverlayController) it is tied to something being true, which is what
    // keeps a closed overlay at nothing.
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
        syncFadingInk()

        guard !stillFading else {
            return
        }

        stopFading()
    }

    // Brings the layers in line with what the canvas holds: a new temporary stroke gets one
    // and starts fading, and anything the canvas no longer has - faded out, erased, undone,
    // cleared - loses one. Reconciling rather than tracking each of those separately is

    private func syncFadingInk() {
        fadingInk.contentsScale = backingScale
        fadingInk.sync(with: canvas.strokes, above: inkLayer)
    }

    private func stopFading() {
        fadeTimer?.invalidate()
        fadeTimer = nil
    }
}
