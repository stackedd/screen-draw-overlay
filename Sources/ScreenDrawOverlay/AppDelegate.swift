// The app itself: what happens when a shortcut is pressed, what the menu bar item says,
// and the lifetime of the overlay panels.
//
// It owns three things worth knowing about before changing anything here:
//
//   1. The mode model. Off, drawing, click-through. ⌃⌥⌘D moves between off and drawing
//      and brings click-through back to drawing; ⌃⌥⌘E flips drawing and click-through;
//      ⌃⌥⌘Esc quits outright. Held rather than tapped, ⌃⌥⌘D is momentary.
//   2. Overlay lifetime. Panels are created per screen on entry and destroyed on exit,
//      so strokes are lifted out and filed by display beforehand (hiding is not erasing;
//      only C erases).
//   3. Recovery. forceCloseOverlay releases the mouse before it closes anything, and
//      overlayWindowSnapshot deliberately re-scans NSApp.windows for panels that fell out
//      of our own records. Both exist because a stuck overlay traps the user's clicks.
//
// See docs/ARCHITECTURE.md for the invariants this file must not break.

import AppKit
import Carbon
import Foundation
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBar: MenuBarItem?
    private var overlayWindows: [OverlayPanel] = []
    private var drawingViews: [DrawingView] = []
    private var toggleHotKey: GlobalHotKey?
    private var interactionHotKey: GlobalHotKey?
    private var emergencyHotKey: GlobalHotKey?
    private var isDrawingMode = false
    private var isInteractionMode = false
    private var overlayScreenLayout: [String] = []
    private static let holdToDrawThreshold: TimeInterval = 0.4

    private var drawingHotKeyPressedAt: Date?
    private var storedStrokes: [String: [Stroke]] = [:]
    private let tools = ToolSettings()
    private var storedStrokesLayout: [String] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("ScreenDrawOverlay: app launched")

        // Two copies at once is a trap, not a feature: macOS lets both register the same
        // global hot keys, so one press opens two overlays stacked on each other and
        // whichever one the user cannot see is the one still taking their clicks.
        // Launching again - by double clicking, or by a login item on top of a copy that
        // is already up - quietly leaves the running one alone.
        guard !AppDelegate.anotherInstanceIsRunning() else {
            print("ScreenDrawOverlay: another copy is already running, quitting this one")
            NSApp.terminate(nil)
            return
        }

        // Keep the app out of the Dock. The small menu bar item is enough for v0.1.
        NSApp.setActivationPolicy(.accessory)

        menuBar = MenuBarItem(actions: MenuBarItem.Actions(
            toggleDrawing: { [weak self] in self?.toggleDrawingMode() },
            toggleClickThrough: { [weak self] in self?.toggleInteractionMode() },
            quit: { NSApp.terminate(nil) }
        ))

        // A tool picked on one screen applies everywhere, and the badge that shows it
        // lives on one panel only, so every panel is told to repaint it.
        tools.onChange = { [weak self] in
            self?.drawingViews.forEach { $0.toolSettingsChanged() }
        }

        NotificationCenter.default.addObserver(self,
                                               selector: #selector(screenParametersDidChange(_:)),
                                               name: NSApplication.didChangeScreenParametersNotification,
                                               object: nil)

        toggleHotKey = GlobalHotKey(id: 1,
                                    keyCode: UInt32(kVK_ANSI_D),
                                    modifiers: UInt32(cmdKey | optionKey | controlKey),
                                    handler: { [weak self] in
            self?.drawingHotKeyPressed()
        }, releaseHandler: { [weak self] in
            self?.drawingHotKeyReleased()
        })

        interactionHotKey = GlobalHotKey(id: 3,
                                         keyCode: UInt32(kVK_ANSI_E),
                                         modifiers: UInt32(cmdKey | optionKey | controlKey)) { [weak self] in
            self?.toggleInteractionMode()
        }

        emergencyHotKey = GlobalHotKey(id: 2,
                                       keyCode: UInt32(kVK_Escape),
                                       modifiers: UInt32(cmdKey | optionKey | controlKey)) { [weak self] in
            self?.emergencyQuit()
        }

        // A modal alert is the wrong tool for a background app: runModal blocks the main
        // thread, and an accessory app's dialog can sit behind everything, so a failure
        // at login would look like a hang. Failures go to the menu bar item instead,
        // which is also the way to work without the shortcut.
        var unavailable: [String] = []
        if toggleHotKey?.register() == true {
            print("ScreenDrawOverlay: hotkey registered - Control + Option + Command + D")
        } else {
            unavailable.append("\u{2303}\u{2325}\u{2318}D")
        }

        if interactionHotKey?.register() == true {
            print("ScreenDrawOverlay: hotkey registered - Control + Option + Command + E")
        } else {
            unavailable.append("\u{2303}\u{2325}\u{2318}E")
        }

        if emergencyHotKey?.register() == true {
            print("ScreenDrawOverlay: hotkey registered - Control + Option + Command + Escape")
        } else {
            unavailable.append("\u{2303}\u{2325}\u{2318}\u{238B}")
        }

        if !unavailable.isEmpty {
            print("ScreenDrawOverlay: hotkeys unavailable: \(unavailable.joined(separator: ", "))")
            menuBar?.reportUnavailableShortcuts(unavailable)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        print("ScreenDrawOverlay: app terminating")
        NotificationCenter.default.removeObserver(self)
        forceCloseOverlay(reason: "app terminating")
        toggleHotKey?.unregister()
        interactionHotKey?.unregister()
        emergencyHotKey?.unregister()
    }

    private static func anotherInstanceIsRunning() -> Bool {
        // Running unbundled (swift run, or a test harness) means there is no identity to
        // compare, so the check stands down rather than guessing.
        guard let bundleID = Bundle.main.bundleIdentifier else {
            return false
        }

        let ownProcessID = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).contains { app in
            app.processIdentifier != ownProcessID && !app.isTerminated
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
    private func drawingHotKeyPressed() {
        let wasClosed = !isDrawingMode && overlayWindowSnapshot().isEmpty
        toggleDrawingMode()
        drawingHotKeyPressedAt = wasClosed ? Date() : nil
    }

    private func drawingHotKeyReleased() {
        guard let pressedAt = drawingHotKeyPressedAt else {
            return
        }

        drawingHotKeyPressedAt = nil

        // A tap is a toggle and leaves the overlay up; only a deliberate hold puts it away.
        guard Date().timeIntervalSince(pressedAt) >= AppDelegate.holdToDrawThreshold else {
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
    // out first and filed under the display they were drawn on.
    private func keepStrokesForNextTime() {
        let windows = overlayWindowSnapshot()
        guard !windows.isEmpty else {
            return
        }

        storedStrokes.removeAll()
        windows.forEach { window in
            // Hiding can land mid-drag; that half-drawn line is still the user's.
            window.drawingView.finishStrokeInProgress()
            let strokes = window.drawingView.capturedStrokes()
            guard !strokes.isEmpty else {
                return
            }

            storedStrokes[window.screenKey] = strokes
        }
        storedStrokesLayout = AppDelegate.screenLayoutSignature()

        let total = storedStrokes.values.reduce(0) { $0 + $1.count }
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

        // One panel per display. The ● DRAW badge would be noise repeated on every
        // screen, so only the main screen's panel draws it; index lookup guarantees
        // exactly one panel gets it even if NSScreen.main is not in NSScreen.screens.
        let indicatorScreen = NSScreen.main ?? screens[0]
        let indicatorIndex = screens.firstIndex { $0.matches(indicatorScreen) } ?? 0

        var windows: [OverlayPanel] = []
        var views: [DrawingView] = []

        for (index, screen) in screens.enumerated() {
            let window = OverlayPanel(screen: screen, showsIndicator: index == indicatorIndex, tools: tools)
            let drawingView = window.drawingView

            if let kept = storedStrokes[window.screenKey] {
                drawingView.restore(strokes: kept)
            }

            windows.append(window)
            views.append(drawingView)
        }

        overlayWindows = windows
        drawingViews = views
        overlayScreenLayout = AppDelegate.screenLayoutSignature()
        isDrawingMode = true
        isInteractionMode = false

        print("ScreenDrawOverlay: drawing mode ON")
        print("ScreenDrawOverlay: overlay created on \(windows.count) screen(s)")

        // Only one window can be key, so the secondary panels are just ordered in front.
        // The panels are non-activating, but making one key lets Escape reach keyDown.
        for (index, window) in windows.enumerated() where index != indicatorIndex {
            window.orderFrontRegardless()
        }
        windows[indicatorIndex].makeKeyAndOrderFront(nil)
        startDrawingPointer()
        refreshMenuBar()
    }

    @objc private func screenParametersDidChange(_ notification: Notification) {
        let layout = AppDelegate.screenLayoutSignature()

        // Kept strokes belong to the displays they were drawn on. If those changed,
        // restoring them would put someone's annotation on the wrong screen at the wrong
        // scale, so they are dropped rather than guessed at.
        if !storedStrokes.isEmpty, layout != storedStrokesLayout {
            print("ScreenDrawOverlay: display layout changed, dropping kept strokes")
            storedStrokes.removeAll()
            storedStrokesLayout.removeAll()
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
    private func toggleInteractionMode() {
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
            let keyPanel = windows.first { $0.drawingView.showsIndicator } ?? windows[0]
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
                        hasKeptStrokes: !storedStrokes.isEmpty)
    }

    // The panic key. Anything short of ending the process can in principle still leave the
    // user stuck, so this quits outright, the same as Quit in the menu.
    // applicationWillTerminate releases the overlay's mouse events and closes the panels on
    // the way out.
    private func emergencyQuit() {
        print("ScreenDrawOverlay: emergency quit")
        NSApp.terminate(nil)
    }

    private func forceCloseOverlay(reason: String) {
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
