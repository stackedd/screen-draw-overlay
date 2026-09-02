// The overlay: what mode it is in, which panels exist, and what happens to a drawing when
// they go away.
//
// Three things worth knowing before changing anything here:
//
//   1. The mode model. Off, drawing, click-through, and one gesture moves between all three:
//      ⌥Z holds a wheel open, pushing at a tool opens the overlay and hands you that tool,
//      and letting go in the middle leaves - the screen back to the app underneath first,
//      then the overlay away with the drawing kept.
//   2. Overlay lifetime. Panels are created per screen on entry and destroyed on exit, so
//      the drawing is lifted out and filed by display beforehand - hiding is not erasing,
//      only C erases - along with the undo history that goes with it.
//   3. Recovery. forceCloseOverlay releases the mouse before it closes anything, and
//      overlayWindowSnapshot deliberately re-scans NSApp.windows for panels that fell out
//      of our own records. Both exist because a stuck overlay traps the user's clicks.
//
// See docs/ARCHITECTURE.md for the invariants this file must not break.

import AppKit
import Foundation

final class OverlayController {
    // The wheels, and what each sector means. The order runs clockwise from due right, so
    // the two that need no thought are a flick right for the pen and a flick left for the
    // eraser.
    //
    // Eight tools. Getting out is not one of them: that is what the hub is for.
    private static let toolOrder: [DrawingTool] = [.pen, .highlighter, .line, .arrow,
                                                   .eraser, .rectangle, .ellipse, .laser]

    // Built from the order above rather than written out beside it: the two lists had to
    // agree, sector for sector, and nothing was checking that they did.
    private static let toolWheel = Wheel(
        items: toolOrder.map { Wheel.Item(label: $0.label, symbol: $0.symbolName) },
        centreLabel: "CLICK-THROUGH")

    private static let colourWheel = Wheel(items: zip(
        ["RED", "ORANGE", "YELLOW", "GREEN", "BLUE", "WHITE"], ToolSettings.colors
    ).map { Wheel.Item(label: $0.0, symbol: "circle.fill", tint: $0.1) })

    // Size means different things to different tools, so the wheel shows what it means to
    // the one in hand: the line a pen will draw, the wider line a marker will, and the hole
    // an eraser will take out. Every tool brings its own context; a wheel of identical bars
    // with numbers under them is the version that does not.
    private static func widthWheel(for tool: DrawingTool, in colour: NSColor) -> Wheel {
        Wheel(items: ToolSettings.widths.indices.map { index in
            guard tool != .eraser else {
                // Scaled into the space a sector has rather than drawn true size - the
                // biggest eraser is nearly seventy points across - but scaled, not clamped,
                // so the six of them still read in order.
                let radius = ToolSettings.eraserRadius(at: index)
                let smallest = ToolSettings.eraserRadius(at: 0)
                let largest = ToolSettings.eraserRadius(at: ToolSettings.widths.count - 1)
                let shown = 6 + (radius - smallest) / (largest - smallest) * 13
                return Wheel.Item(label: "\(Int(radius * 2))", symbol: "", disc: shown)
            }

            // The laser draws light, not a line, so its sectors are beams: the same halo,
            // colour and white core it will put on the screen, in the colour in hand.
            guard tool != .laser else {
                let drawn = ToolSettings.laserWidth(at: index)
                return Wheel.Item(label: "\(Int(drawn))", symbol: "",
                                  beam: (width: drawn, colour: colour))
            }

            let drawn = ToolSettings.widths[index] * tool.style.widthMultiplier
            return Wheel.Item(label: "\(Int(drawn))", symbol: "", rule: drawn)
        })
    }

    private let wheels = WheelPanel()
    private let shortcuts = Shortcuts()
    private var menuBar: MenuBarItem?
    private var overlayWindows: [OverlayPanel] = []
    private var drawingViews: [DrawingView] = []
    private var isDrawingMode = false
    private var isInteractionMode = false
    private var overlayScreenLayout: [String] = []

    // The two that keep the pointer ours: a burst after something changed, and a slow hold
    // for as long as the overlay is taking the mouse. See takeCursorBack().
    private var cursorSettling: Timer?
    private var cursorHold: Timer?

    private var keptDrawings: [String: Canvas.Kept] = [:]
    private let tools = ToolSettings()
    private var keptDrawingsLayout: [String] = []

    // The menu bar item and the display-change observer come up with the controller and
    // stay for the life of the app; the panels come and go.
    @discardableResult
    func start() -> [String] {
        wheels.onClose = { [weak self] in
            self?.takeCursorBack()
        }

        menuBar = MenuBarItem(actions: MenuBarItem.Actions(
            toggleDrawing: { [weak self] in self?.toggleDrawingMode() },
            toggleClickThrough: { [weak self] in self?.toggleInteractionMode() },
            quit: { NSApp.terminate(nil) }
        ))

        // A tool picked on one screen applies everywhere, and the badge that shows it
        // lives on one panel only, so every panel is told to redraw it.
        tools.onChange = { [weak self] in
            self?.drawingViews.forEach { $0.toolSettingsChanged() }
        }

        NotificationCenter.default.addObserver(self,
                                               selector: #selector(screenParametersDidChange(_:)),
                                               name: NSApplication.didChangeScreenParametersNotification,
                                               object: nil)

        return shortcuts.register(Shortcuts.Actions(
            toolWheel: { [weak self] in self?.openToolWheel() },
            wheelReleased: { [weak self] in self?.wheels.release() },
            quit: {
                print("ScreenDrawOverlay: emergency quit")
                NSApp.terminate(nil)
            },
            undo: { [weak self] in self?.undoOnScreenUnderPointer(redo: false) },
            redo: { [weak self] in self?.undoOnScreenUnderPointer(redo: true) }
        ))
    }

    // The wheels only exist while there is a canvas to change, which is also what keeps ⌥Z
    // out of the way the rest of the time.
    private func startWheels() {
        shortcuts.registerWheels(Shortcuts.WheelActions(
            colours: { [weak self] in self?.openColourWheel() },
            widths: { [weak self] in self?.openWidthWheel() },
            released: { [weak self] in self?.wheels.release() }
        ))
    }

    // The tools wheel carries the mode as well as the tool, which is the whole shape of the
    // thing: push at a tool and you are drawing with it, let go in the middle and the screen
    // belongs to whatever is underneath. Two states and one gesture, instead of a tool
    // picker and a mode shortcut to remember separately.
    // The hub is the way out, and what "out" means depends on where you already are: drawing
    // gives the screen back to the app underneath, and doing it again from there puts the
    // overlay away with the drawing kept. One direction, two steps, and the hub says which
    // one it is about to take - which is why the label is decided here rather than built
    // into the wheel.
    private var hubLabel: String {
        guard isDrawingMode else {
            return "CANCEL"
        }

        return isInteractionMode ? "HIDE" : "CLICK-THROUGH"
    }

    private func openToolWheel() {
        wheels.open(OverlayController.toolWheel, centreLabel: hubLabel) { [weak self] index in
            guard let self else {
                return
            }

            guard let index else {
                self.leaveByTheHub()
                return
            }

            // Picking a tool means drawing with it, whatever the overlay was doing before -
            // including not existing.
            if !isDrawingMode {
                self.enterDrawingMode()
            }
            self.setInteractionMode(false)
            self.tools.select(tool: OverlayController.toolOrder[index])
        }
    }

    private func leaveByTheHub() {
        guard isDrawingMode else {
            return
        }

        if isInteractionMode {
            hideOverlay(reason: "hidden from the wheel")
        } else {
            setInteractionMode(true)
        }
    }

    // The other two only change what is in hand, so their hub is a plain cancel: reaching
    // for a colour and landing in the middle should not move the mode.
    // Colour means nothing to the eraser, so the colour wheel does not open for it. Handing
    // back the pen instead was tried and was worse: it answered a question nobody asked and
    // put a different tool in your hand than the one you were holding. The badge says why
    // instead - it is the only place on screen this app can say anything.
    private func openColourWheel() {
        guard tools.tool != .eraser else {
            drawingViews.forEach { $0.flash("The eraser has no colour") }
            return
        }

        wheels.open(OverlayController.colourWheel) { [weak self] index in
            index.map { self?.tools.selectColor($0) }
        }
    }

    private func openWidthWheel() {
        wheels.open(OverlayController.widthWheel(for: tools.tool, in: tools.color)) { [weak self] index in
            index.map { self?.tools.selectWidth($0) }
        }
    }

    private func stopWheels() {
        shortcuts.unregisterWheels()
        wheels.close()
    }

    func shutDown() {
        NotificationCenter.default.removeObserver(self)
        forceCloseOverlay(reason: "app terminating")
        shortcuts.unregister()
    }

    // Said in the menu, never in a dialog: runModal blocks the main thread and an accessory
    // app's alert can sit behind every window, so a failure at login would look like a hang.
    func reportUnavailableShortcuts(_ shortcuts: [String]) {
        menuBar?.reportUnavailableShortcuts(shortcuts)
    }

    func undoOnScreenUnderPointer(redo: Bool) {
        let windows = overlayWindowSnapshot()
        guard isDrawingMode, !windows.isEmpty else {
            return
        }

        let location = NSEvent.mouseLocation
        let window = windows.first { $0.frame.contains(location) }
            ?? windows.first { $0.drawingView.showsBadge }
            ?? windows[0]

        if redo {
            window.drawingView.redo()
        } else {
            window.drawingView.undo()
        }
    }

    // Three states - off, drawing, click-through - and D always means "get me back to
    // drawing, or put the overlay away". Putting it away is a hide, not a delete: the
    // strokes are kept and come back on the next D, so a mistyped shortcut costs nothing.
    // C is the only thing that erases a drawing.
    private func toggleDrawingMode() {
        if isDrawingMode, isInteractionMode {
            setInteractionMode(false)
        } else if isDrawingMode || !overlayWindowSnapshot().isEmpty {
            hideOverlay(reason: "toggle-off hotkey")
        } else {
            enterDrawingMode()
        }
    }

    private func hideOverlay(reason: String) {
        keepStrokesForNextTime()
        forceCloseOverlay(reason: reason)
    }

    // Strokes live inside the panels, which are destroyed on close, so they are lifted
    // out first and filed under the display they were drawn on - with the undo history
    // that goes with them, because hiding the overlay is not meant to cost you the last
    // five minutes of taking things back.
    private func keepStrokesForNextTime() {
        let windows = overlayWindowSnapshot()
        guard !windows.isEmpty else {
            return
        }

        keptDrawings.removeAll()
        windows.forEach { window in
            // Hiding can land mid-drag; that half-drawn line is still the user's.
            window.drawingView.finishStrokeInProgress()
            let kept = window.drawingView.capturedDrawing()
            guard kept.strokeCount > 0 else {
                return
            }

            keptDrawings[window.screenKey] = kept
        }
        keptDrawingsLayout = OverlayController.screenLayoutSignature()

        let total = keptDrawings.values.reduce(0) { $0 + $1.strokeCount }
        print("ScreenDrawOverlay: kept \(total) stroke(s) for the next time drawing mode opens")
    }

    private func enterDrawingMode() {
        guard !isDrawingMode else {
            return
        }

        let screens = NSScreen.screens
        guard !screens.isEmpty else {
            print("ScreenDrawOverlay: could not enter drawing mode because there are no screens")
            forceCloseOverlay(reason: "no screens available")
            return
        }

        // One panel per display. The badge would be noise repeated on every screen, so
        // only the main screen's panel draws it; the index lookup guarantees exactly one
        // panel gets it even if NSScreen.main is not in NSScreen.screens.
        let badgeScreen = NSScreen.main ?? screens[0]
        let badgeIndex = screens.firstIndex { $0.matches(badgeScreen) } ?? 0

        var windows: [OverlayPanel] = []
        var views: [DrawingView] = []

        for (index, screen) in screens.enumerated() {
            let window = OverlayPanel(screen: screen, showsBadge: index == badgeIndex, tools: tools)
            let drawingView = window.drawingView

            if let kept = keptDrawings[window.screenKey] {
                drawingView.restore(kept)
            }

            windows.append(window)
            views.append(drawingView)
        }

        overlayWindows = windows
        drawingViews = views
        overlayScreenLayout = OverlayController.screenLayoutSignature()
        isDrawingMode = true
        isInteractionMode = false

        print("ScreenDrawOverlay: drawing mode ON")
        print("ScreenDrawOverlay: overlay created on \(windows.count) screen(s)")

        // Only one window can be key, so the secondary panels are just ordered in front.
        // The panels are non-activating, but making one key lets Escape reach keyDown.
        for (index, window) in windows.enumerated() where index != badgeIndex {
            window.orderFrontRegardless()
        }
        windows[badgeIndex].makeKeyAndOrderFront(nil)
        takeCursorBack()
        startWheels()
        refreshMenuBar()
    }

    @objc private func screenParametersDidChange(_ notification: Notification) {
        let layout = OverlayController.screenLayoutSignature()

        // Kept strokes belong to the displays they were drawn on. If those changed,
        // restoring them would put someone's annotation on the wrong screen at the wrong
        // scale, so they are dropped rather than guessed at.
        if !keptDrawings.isEmpty, layout != keptDrawingsLayout {
            print("ScreenDrawOverlay: display layout changed, dropping kept strokes")
            keptDrawings.removeAll()
            keptDrawingsLayout.removeAll()
            refreshMenuBar()
        }

        guard isDrawingMode || !overlayWindowSnapshot().isEmpty else {
            return
        }

        // This notification fires for more than displays coming and going: it also fires
        // when the Dock hides or the menu bar auto-hides, which is exactly what happens
        // when a presentation starts. Those change only visibleFrame and move no overlay,
        // so reacting to them would tear the overlay down at the very moment the user
        // starts presenting. Compare the actual display layout and ignore the rest.
        guard layout != overlayScreenLayout else {
            return
        }

        // A display really was plugged in, unplugged or rearranged. The open panels are
        // pinned to frames that may no longer exist, so the safe move is to leave drawing
        // mode rather than re-laying out overlays mid-stroke.
        print("ScreenDrawOverlay: display layout changed while drawing")
        forceCloseOverlay(reason: "display layout changed")
    }

    // Display identity plus frame: unaffected by the Dock or the menu bar showing and
    // hiding, which only move visibleFrame.
    private static func screenLayoutSignature() -> [String] {
        NSScreen.screens.map { $0.displayIdentifier + "@" + NSStringFromRect($0.frame) }
    }

    // Drawing mode has two sub-modes. Drawing: the panels take the mouse, so strokes land
    // on the overlay and clicks never reach the app underneath. Click-through: the panels
    // stop taking the mouse so the user can drive the app underneath - advance a slide,
    // switch apps - while every stroke stays on screen. Leaving drawing mode is what
    // clears the drawing; switching modes never does.
    func toggleInteractionMode() {
        guard isDrawingMode, !overlayWindowSnapshot().isEmpty else {
            print("ScreenDrawOverlay: click-through toggle ignored, drawing mode is off")
            return
        }

        setInteractionMode(!isInteractionMode)
    }

    private func setInteractionMode(_ enabled: Bool) {
        let windows = overlayWindowSnapshot()
        guard isDrawingMode, !windows.isEmpty, enabled != isInteractionMode else {
            return
        }

        isInteractionMode = enabled

        windows.forEach { window in
            window.ignoresMouseEvents = isInteractionMode
            window.drawingView.isInteractionMode = isInteractionMode
        }

        if isInteractionMode {
            // Handing the mouse over is not enough: the panel stays the key window until
            // something else takes it, so the keyboard - Escape included - would still be
            // swallowed here. Step out of the way so the app underneath owns input.
            NSApp.deactivate()
            // Hand the real pointer back; the drawn one belongs to drawing mode only.
            stopHoldingCursor()
            windows.forEach { $0.drawingView.releaseDrawingCursor() }
            print("ScreenDrawOverlay: click-through mode ON (drawing kept, clicks pass through)")
        } else {
            // Escape, C and Command+Z are local keys, so the panel has to be key again.
            let keyPanel = windows.first { $0.drawingView.showsBadge } ?? windows[0]
            keyPanel.makeKeyAndOrderFront(nil)
            takeCursorBack()
            print("ScreenDrawOverlay: click-through mode OFF (drawing again)")
        }

        refreshMenuBar()
    }

    // Drawing mode hands the window server a cursor drawn for the tool in hand, so the
    // pointer says what it is about to do without there ever being two of it. The window
    // server asks whoever owns the window under the pointer, which in drawing mode is us.
    //
    // **Setting the cursor is not the same as keeping it**, and this is the whole of an arrow
    // people kept seeing. Measured with `Testing/probes/cursorflash.swift`, which samples
    // `NSCursor.currentSystem` - what is actually on the screen, as opposed to this app's own
    // idea of it - every four milliseconds: a panel that appears under a stationary pointer is
    // handed the plain arrow by the window server about 25ms after it appears, whatever the
    // app set before that, and **nothing asks us again until the mouse moves**. That last part
    // is what makes it a fault rather than a flicker: the arrow stays until the user moves the
    // mouse, and the app's own NSCursor.current is right the whole time.
    //
    // Two things hold it, because one was not enough. `takeCursorBack()` asks hard for a third
    // of a second after something we know about - a panel arriving, a wheel closing, a mode
    // change. `holdCursor()` then keeps asking, gently, for as long as drawing mode is on,
    // which covers the cases nobody has reproduced yet: it was still being reported after the
    // first half measured clean on every path this repo can drive, and a symptom that survives
    // a fix nobody can reproduce is worth answering at the symptom.
    //
    // Both are cheap, and measured rather than assumed: `NSCursor.set()` is 0.049ms, so sixty
    // a second is 0.3% of a core - and setting it blind is three times cheaper than asking
    // `NSCursor.currentSystem` what is on screen first (0.157ms). Neither timer exists while
    // the overlay is closed, which is where the "idle costs nothing" promise lives.
    //
    // Sixty rather than twenty because twenty was still visible: the gap between the window
    // server handing out an arrow and us taking it back was up to 50ms, which is three frames,
    // and it was reported as a flicker. At the display's own rate the worst case is one frame.
    private static let cursorHoldInterval: TimeInterval = 1.0 / 60
    private static let cursorSettleInterval: TimeInterval = 1.0 / 120
    private static let cursorSettleTicks = 42

    private func takeCursorBack() {
        // No overlay, or the screen handed back: the pointer belongs to whatever is
        // underneath, and it has to be a pointer somebody can see. This is load-bearing now
        // that the wheel wears a cursor that shows nothing - without it, closing a wheel with
        // no overlay open would leave the user with no pointer at all.
        guard isDrawingMode, !isInteractionMode else {
            NSCursor.arrow.set()
            return
        }

        setDrawingCursor()
        holdCursor()
        cursorSettling?.invalidate()

        var attempts = 0
        let timer = Timer(timeInterval: OverlayController.cursorSettleInterval,
                          repeats: true) { [weak self] timer in
            attempts += 1
            // Only the cursor, not the rects. Rebuilding cursor rects is the call that must
            // never be made from inside AppKit's tracking machinery (docs/DECISIONS.md 6), so
            // the repeated half is the one that does nothing but set a cursor.
            self?.applyCursorEverywhere()

            guard attempts >= OverlayController.cursorSettleTicks || self == nil else {
                return
            }

            timer.invalidate()
            self?.cursorSettling = nil
        }
        RunLoop.main.add(timer, forMode: .common)
        cursorSettling = timer
    }

    // For as long as the overlay is taking the mouse. It stops on click-through, where the
    // pointer belongs to the app underneath, and when the overlay goes away.
    private func holdCursor() {
        guard cursorHold == nil, isDrawingMode, !isInteractionMode else {
            return
        }

        let timer = Timer(timeInterval: OverlayController.cursorHoldInterval,
                          repeats: true) { [weak self] _ in
            self?.applyCursorEverywhere()
        }
        RunLoop.main.add(timer, forMode: .common)
        cursorHold = timer
    }

    private func stopHoldingCursor() {
        cursorHold?.invalidate()
        cursorHold = nil
        cursorSettling?.invalidate()
        cursorSettling = nil
    }

    private func setDrawingCursor() {
        drawingViewSnapshot(from: overlayWindowSnapshot()).forEach { drawingView in
            drawingView.refreshCursorRects()
            drawingView.applyDrawingCursor()
        }
    }

    private func applyCursorEverywhere() {
        drawingViewSnapshot(from: overlayWindowSnapshot()).forEach { $0.applyDrawingCursor() }
    }

    private func refreshMenuBar() {
        menuBar?.update(isDrawing: isDrawingMode,
                        isClickThrough: isInteractionMode,
                        hasKeptStrokes: !keptDrawings.isEmpty)
    }

    // The panic key. Anything short of ending the process can in principle still leave the
    // user stuck, so this quits outright, the same as Quit in the menu.
    // applicationWillTerminate releases the overlay's mouse events and closes the panels on
    // the way out.
    private func forceCloseOverlay(reason: String) {
        // Before anything else: the wheels belong to an overlay that is about to stop
        // existing, and ⌥Z has to go back to typing what it types.
        stopWheels()
        stopHoldingCursor()

        let windows = overlayWindowSnapshot()
        let views = drawingViewSnapshot(from: windows)

        // First make every overlay pass mouse events through, before clearing or closing.
        windows.forEach { window in
            window.ignoresMouseEvents = true
        }

        views.forEach { drawingView in
            drawingView.clear()
        }

        windows.forEach { window in
            window.orderOut(nil)
            window.close()
            print("ScreenDrawOverlay: overlay destroyed")
        }

        // The panels carried the transparent cursor; with them gone, make sure this app
        // is not still asking for an invisible pointer.
        NSCursor.arrow.set()

        overlayWindows.removeAll()
        drawingViews.removeAll()
        overlayScreenLayout.removeAll()

        if isDrawingMode || !windows.isEmpty {
            print("ScreenDrawOverlay: drawing mode OFF (\(reason))")
        }

        isDrawingMode = false
        isInteractionMode = false
        refreshMenuBar()
    }

    private func overlayWindowSnapshot() -> [OverlayPanel] {
        // Still scanning NSApp.windows, because the point of this is to find a panel that
        // is on screen but has fallen out of our own records. Closed panels linger in
        // NSApp.windows until they are deallocated, though, and counting those as live
        // overlays made D hide an overlay that was already gone - so the drawing was
        // captured from an emptied panel and lost. Only what is actually on screen counts.
        let appOverlayWindows = NSApp.windows.compactMap { $0 as? OverlayPanel }.filter { $0.isVisible }
        var seenWindowIDs = Set<ObjectIdentifier>()

        return (overlayWindows + appOverlayWindows).filter { window in
            let id = ObjectIdentifier(window)
            if seenWindowIDs.contains(id) {
                return false
            }
            seenWindowIDs.insert(id)
            return true
        }
    }

    private func drawingViewSnapshot(from windows: [OverlayPanel]) -> [DrawingView] {
        var seenViewIDs = Set<ObjectIdentifier>()

        return (drawingViews + windows.map(\.drawingView)).filter { drawingView in
            let id = ObjectIdentifier(drawingView)
            if seenViewIDs.contains(id) {
                return false
            }
            seenViewIDs.insert(id)
            return true
        }
    }
}
