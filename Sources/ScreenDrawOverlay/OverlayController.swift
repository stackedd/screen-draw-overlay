// The overlay: what mode it is in, which panels exist, and what happens to a drawing when
// they go away.
//
// Three things worth knowing before changing anything here:
//
//   1. The mode model. Off, drawing, click-through. ⌃⌥⌘D moves between off and drawing and
//      brings click-through back to drawing; ⌃⌥⌘E flips drawing and click-through. Held
//      rather than tapped, ⌃⌥⌘D is momentary.
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
    // The eighth tool is the laser for now and will be the text tool when there is one;
    // the laser keeps Space either way, which is where a momentary thing belongs. Changing
    // a sector's meaning later is a real cost, so it is one slot and it is written down.
    private static let toolOrder: [DrawingTool] = [.pen, .highlighter, .line, .arrow,
                                                   .eraser, .rectangle, .ellipse, .laser]

    private static let toolWheel = Wheel(items: [
        Wheel.Item(label: "PEN", symbol: "pencil.tip"),
        Wheel.Item(label: "MARKER", symbol: "highlighter"),
        Wheel.Item(label: "LINE", symbol: "line.diagonal"),
        Wheel.Item(label: "ARROW", symbol: "arrow.up.right"),
        Wheel.Item(label: "ERASER", symbol: "eraser"),
        Wheel.Item(label: "RECT", symbol: "rectangle"),
        Wheel.Item(label: "OVAL", symbol: "circle"),
        Wheel.Item(label: "LASER", symbol: "dot.circle.and.hand.point.up.left.fill")
    ])

    private static let colourWheel = Wheel(items: zip(
        ["RED", "ORANGE", "YELLOW", "GREEN", "BLUE", "WHITE"], ToolSettings.colors
    ).map { Wheel.Item(label: $0.0, symbol: "circle.fill", tint: $0.1) })

    private static let widthWheel = Wheel(items: ToolSettings.widths.map {
        Wheel.Item(label: "\(Int($0))", symbol: "line.3.horizontal.decrease")
    })

    private let wheels = WheelPanel()
    private let shortcuts = Shortcuts()
    private var menuBar: MenuBarItem?
    private var overlayWindows: [OverlayPanel] = []
    private var drawingViews: [DrawingView] = []
    private var isDrawingMode = false
    private var isInteractionMode = false
    private var overlayScreenLayout: [String] = []
    private static let holdToDrawThreshold: TimeInterval = 0.4

    private var drawingHotKeyPressedAt: Date?
    private var keptDrawings: [String: Canvas.Kept] = [:]
    private let tools = ToolSettings()
    private var keptDrawingsLayout: [String] = []

    // The menu bar item and the display-change observer come up with the controller and
    // stay for the life of the app; the panels come and go.
    @discardableResult
    func start() -> [String] {
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
            drawPressed: { [weak self] in self?.drawingHotKeyPressed() },
            drawReleased: { [weak self] in self?.drawingHotKeyReleased() },
            toggleClickThrough: { [weak self] in self?.toggleInteractionMode() },
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
            tools: { [weak self] in
                self?.wheels.open(OverlayController.toolWheel) { [weak self] index in
                    self?.tools.select(tool: OverlayController.toolOrder[index])
                }
            },
            colours: { [weak self] in
                self?.wheels.open(OverlayController.colourWheel) { [weak self] index in
                    self?.tools.selectColor(index)
                }
            },
            widths: { [weak self] in
                self?.wheels.open(OverlayController.widthWheel) { [weak self] index in
                    self?.tools.selectWidth(index)
                }
            },
            released: { [weak self] in self?.wheels.release() }
        ))
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

    // Tap or hold, on the same shortcut. A tap toggles, as it always has. Holding it turns
    // the overlay into something you reach for the way you reach for a laser pointer:
    // press, scribble, let go, and the screen is yours again - no mode to remember to
    // leave. That is the difference between a tool you switch on and a tool you can leave
    // running in the background all day.
    //
    // Momentary only applies when the press is what opened the overlay. Holding the key
    // while already drawing would otherwise have to undo the tap action mid-hold, which
    // reads as the shortcut fighting you.
    func drawingHotKeyPressed() {
        let wasClosed = !isDrawingMode && overlayWindowSnapshot().isEmpty
        toggleDrawingMode()
        drawingHotKeyPressedAt = wasClosed ? Date() : nil
    }

    func drawingHotKeyReleased() {
        guard let pressedAt = drawingHotKeyPressedAt else {
            return
        }

        drawingHotKeyPressedAt = nil

        // A tap is a toggle and leaves the overlay up; only a deliberate hold puts it away.
        guard Date().timeIntervalSince(pressedAt) >= OverlayController.holdToDrawThreshold else {
            return
        }

        // If the user stepped into click-through during the hold they meant to stay, so
        // the release leaves that alone.
        guard isDrawingMode, !isInteractionMode else {
            return
        }

        hideOverlay(reason: "drawing hot key released")
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
        startDrawingPointer()
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
            windows.forEach { $0.drawingView.releaseDrawingCursor() }
            print("ScreenDrawOverlay: click-through mode ON (drawing kept, clicks pass through)")
        } else {
            // Escape, C and Command+Z are local keys, so the panel has to be key again.
            let keyPanel = windows.first { $0.drawingView.showsBadge } ?? windows[0]
            keyPanel.makeKeyAndOrderFront(nil)
            startDrawingPointer()
            print("ScreenDrawOverlay: click-through mode OFF (drawing again)")
        }

        refreshMenuBar()
    }

    // Drawing mode hands the window server the system arrow with a ring around its tip, so
    // the pointer says which tool is in hand without there ever being two of it. The window
    // server asks whoever owns the window under the pointer, which in drawing mode is us.
    private func startDrawingPointer() {
        drawingViewSnapshot(from: overlayWindowSnapshot()).forEach { drawingView in
            drawingView.refreshCursorRects()
            drawingView.applyDrawingCursor()
        }
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
