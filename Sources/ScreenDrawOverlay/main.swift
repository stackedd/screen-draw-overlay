import AppKit
import Carbon
import Foundation

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var drawingMenuItem: NSMenuItem?
    private var hotKeyWarningItem: NSMenuItem?
    private var interactionMenuItem: NSMenuItem?
    private var overlayWindows: [OverlayPanel] = []
    private var drawingViews: [DrawingView] = []
    private var toggleHotKey: GlobalHotKey?
    private var interactionHotKey: GlobalHotKey?
    private var emergencyHotKey: GlobalHotKey?
    private var isDrawingMode = false
    private var isInteractionMode = false
    private var overlayScreenLayout: [String] = []
    private var storedStrokes: [String: [NSBezierPath]] = [:]
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

        setupStatusItem()

        NotificationCenter.default.addObserver(self,
                                               selector: #selector(screenParametersDidChange(_:)),
                                               name: NSApplication.didChangeScreenParametersNotification,
                                               object: nil)

        toggleHotKey = GlobalHotKey(id: 1,
                                    keyCode: UInt32(kVK_ANSI_D),
                                    modifiers: UInt32(cmdKey | optionKey | controlKey)) { [weak self] in
            self?.toggleDrawingMode()
        }

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
            hotKeyWarningItem?.title = "Shortcut unavailable: " + unavailable.joined(separator: " ")
            hotKeyWarningItem?.isHidden = false
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

    private func setupStatusItem() {
        // variableLength lets the item size itself to the icon instead of a fixed square.
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        let menu = NSMenu()
        // The titles and the enabled state are driven by the current mode, so AppKit must
        // not second-guess them.
        menu.autoenablesItems = false
        // Hidden unless a shortcut could not be registered; this is where the app says so.
        let warningItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        warningItem.isEnabled = false
        warningItem.isHidden = true
        menu.addItem(warningItem)
        hotKeyWarningItem = warningItem

        let toggleItem = NSMenuItem(title: "Start Drawing",
                                    action: #selector(toggleDrawingModeFromMenu),
                                    keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(toggleItem)
        drawingMenuItem = toggleItem

        let interactionItem = NSMenuItem(title: "Click-Through",
                                         action: #selector(toggleInteractionModeFromMenu),
                                         keyEquivalent: "")
        interactionItem.target = self
        menu.addItem(interactionItem)
        interactionMenuItem = interactionItem
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit",
                                  action: #selector(quit),
                                  keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem?.menu = menu

        updateStatusItemAppearance()
    }

    @objc private func toggleDrawingModeFromMenu() {
        toggleDrawingMode()
    }

    @objc private func toggleInteractionModeFromMenu() {
        toggleInteractionMode()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
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
            let window = OverlayPanel(screen: screen, showsIndicator: index == indicatorIndex)
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
        updateStatusItemAppearance()
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
            updateStatusItemAppearance()
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

        updateStatusItemAppearance()
    }

    // The real pointer is replaced by a fully transparent cursor over the panel, and the
    // view draws its own crosshair instead. NSCursor.hide() was the obvious approach and
    // the wrong one: hiding is per application and only applies while that application is
    // active, so a background .accessory app hides nothing and the user ends up with two
    // pointers. A transparent cursor rect works because the window server asks whoever
    // owns the window under the pointer, which is us.
    private func startDrawingPointer() {
        drawingViewSnapshot(from: overlayWindowSnapshot()).forEach { drawingView in
            drawingView.refreshCursorRects()
            drawingView.applyDrawingCursor()
            drawingView.syncPointerToMouseLocation()
        }
    }

    private func updateStatusItemAppearance() {
        // The menu says the same thing the hot keys do: D returns to drawing or puts the
        // overlay away, E only means anything once there is something on screen.
        // Click-Through is a state, so it reads as a checkable item rather than a second
        // command that would say the same thing as the first one.
        drawingMenuItem?.title = !isDrawingMode
            ? (storedStrokes.isEmpty ? "Start Drawing" : "Show Drawing")
            : (isInteractionMode ? "Back to Drawing" : "Hide Overlay")
        interactionMenuItem?.state = isInteractionMode ? .on : .off
        interactionMenuItem?.isEnabled = isDrawingMode

        guard let button = statusItem?.button else {
            return
        }

        // The menu bar item doubles as the mode light: red while the overlay is taking
        // the mouse, dimmed while it is only showing, plain when there is no overlay.
        // The mode is carried by the symbol, never by a colour. Setting contentTintColor
        // on a template image switches off the appearance-driven rendering that makes a
        // menu bar icon light on a dark menu bar: measured, a tinted icon rendered at
        // luminance 0.000 - black on black - while an untinted one rendered at 0.791.
        let symbolName: String
        let tooltip: String
        if !isDrawingMode {
            symbolName = "scribble"
            tooltip = "Screen Draw Overlay - Control Option Command D to draw"
        } else if isInteractionMode {
            symbolName = "pencil.slash"
            tooltip = "Click-through: drawing is showing, clicks go to the app underneath"
        } else {
            symbolName = "pencil.tip.crop.circle.fill"
            tooltip = "Drawing: the overlay is taking your clicks"
        }

        button.contentTintColor = nil

        if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Screen Draw Overlay") {
            // A template image follows the menu bar's own look in both themes. An icon
            // also takes less width than a letter, which matters on a crowded menu bar
            // where macOS drops the items that do not fit.
            image.isTemplate = true
            button.image = image.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
            ) ?? image
            button.title = ""
        } else {
            // No symbol on this system: fall back to the letter this app shipped with,
            // plainly, so AppKit styles it for the current appearance.
            button.image = nil
            button.title = "D"
        }

        button.toolTip = tooltip
    }

    // The panic key. Anything short of ending the process can in principle still leave
    // the user stuck, so this quits outright, the same as Quit in the menu.
    // applicationWillTerminate releases the overlay's mouse events and closes the panels
    // on the way out.
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
        updateStatusItemAppearance()
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

final class OverlayPanel: NSPanel {
    // The one place the overlay's stacking is decided. Drawing mode owns the screen:
    // above the menu bar, above status items, above anything a click could land on.
    //
    // This used to sit one below the menu bar (23) so the menu bar item stayed clickable
    // while drawing. That turned out to be worse in use: the menu bar and its extras kept
    // the pointer and the clicks whenever they were under the cursor, so the real arrow
    // flickered back into view at the top of the screen and menus could be opened by
    // accident in the middle of a stroke. Drawing mode is supposed to interact with
    // nothing; click-through is where interaction happens.
    //
    // Measured 2026-08-26 on macOS 26.5.1: menu bar 24, status items 25, another
    // full-width strip at 26, a Keynote 13.2 slideshow at 9 with its fade at 26.
    // .popUpMenu (101) clears all of them.
    //
    // Being above the menu bar is only safe because nothing on screen is needed to get
    // out: ⌃⌥⌘D hides (keeping the drawing), ⌃⌥⌘E hands control back, and ⌃⌥⌘Esc quits
    // the app outright. All three are global hot keys that do not depend on the overlay.
    private static let overlayLevel = NSWindow.Level.popUpMenu

    let drawingView: DrawingView

    let screenKey: String

    init(screen: NSScreen, showsIndicator: Bool) {
        screenKey = screen.displayIdentifier
        let screenFrame = screen.frame
        let visibleFrame = screen.visibleFrame
        let localVisibleFrame = NSRect(x: visibleFrame.minX - screenFrame.minX,
                                       y: visibleFrame.minY - screenFrame.minY,
                                       width: visibleFrame.width,
                                       height: visibleFrame.height)
        drawingView = DrawingView(frame: NSRect(origin: .zero, size: screenFrame.size),
                                  indicatorBounds: localVisibleFrame,
                                  showsIndicator: showsIndicator)

        // NSPanel subclasses must call a designated initializer. The panel is
        // non-activating so drawing does not fully steal focus from other apps.
        super.init(contentRect: screenFrame,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        setFrame(screenFrame, display: false)

        // These are the important overlay bits: no chrome, no backing fill, and a z-order
        // above full screen apps.
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = OverlayPanel.overlayLevel

        // .canJoinAllSpaces keeps the overlay with the user when they switch Spaces, and
        // .fullScreenAuxiliary lets it join another app's full screen Space instead of
        // forcing a Space switch. Both are needed to draw over a presentation.
        //
        // .stationary keeps the overlay out of Exposé-style sweeps: without it, clicking
        // the wallpaper ("Click wallpaper to reveal desktop") shoves the panels aside like
        // ordinary windows and the drawing appears to vanish. .ignoresCycle keeps the
        // panels out of window cycling, where a full screen transparent panel is never
        // something the user meant to pick.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        hidesOnDeactivate = false
        isMovable = false
        isReleasedWhenClosed = false

        contentView = drawingView
        makeFirstResponder(drawingView)
    }

    // Borderless panels do not normally become key windows. We opt in so the drawing
    // view's own keys - C to clear, Command+Z to undo - reach it.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // Key equivalents are dispatched before keyDown, so without this a Command shortcut
    // pressed while drawing would still reach this app's menu - Command+Q would quit the
    // app in the middle of a stroke - or be handed to the app underneath. Drawing mode
    // interacts with nothing, so they stop here. Command+Z is the one exception, since
    // undo is part of the tool; the global hot keys are unaffected because Carbon
    // delivers those outside this path.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let shortcutFlags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if shortcutFlags == .command, event.charactersIgnoringModifiers?.lowercased() == "z" {
            drawingView.keyDown(with: event)
        }

        return true
    }
}

final class DrawingView: NSView {
    private static let strokeLineWidth: CGFloat = 4

    // A cursor made of nothing. The pointer over the panel has to disappear so only the
    // drawn crosshair is visible, and this is the one way to do that which needs no
    // permission and does not depend on the app being frontmost.
    private static let transparentCursor: NSCursor = {
        let image = NSImage(size: NSSize(width: 16, height: 16))
        image.lockFocus()
        NSColor.clear.setFill()
        NSRect(origin: .zero, size: image.size).fill(using: .copy)
        image.unlockFocus()

        return NSCursor(image: image, hotSpot: NSPoint(x: 8, y: 8))
    }()

    // Modest: big enough to aim with, small enough not to sit on the content.
    private static let pointerSize: CGFloat = 20
    private static let pointerCasingWidth: CGFloat = 3
    private static let pointerCentreGap: CGFloat = 3.5

    // Always shown: what the other two shortcuts do from here. Escape is not on this
    // list because it no longer leaves drawing mode - this line is the only place a
    // stuck-feeling user is told what does.
    private static let drawingHintText = "⌃⌥⌘E click · ⌃⌥⌘D hide"
    private static let interactionHintText = "⌃⌥⌘E draw · ⌃⌥⌘Esc quit"
    private static let indicatorPaddingX: CGFloat = 8
    private static let indicatorPaddingY: CGFloat = 5
    private static let indicatorLineGap: CGFloat = 2
    private static let indicatorMargin: CGFloat = 14

    private var paths: [NSBezierPath] = []
    private var currentPath: NSBezierPath?
    private var lastStrokePoint: NSPoint?
    private var pointerLocation: NSPoint?
    private var indicatorBounds: NSRect
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
            isMouseOverIndicator = false
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
    private var indicatorRect: NSRect = .zero
    private var isMouseOverIndicator = false
    private var mouseTrackingArea: NSTrackingArea?

    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { false }

    init(frame frameRect: NSRect, indicatorBounds: NSRect, showsIndicator: Bool) {
        self.indicatorBounds = indicatorBounds
        self.showsIndicator = showsIndicator
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
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
        updateIndicatorHover(at: point)

        let path = NSBezierPath()
        path.lineWidth = DrawingView.strokeLineWidth
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.move(to: point)

        currentPath = path
        lastStrokePoint = point
        movePointer(to: point)
        invalidateSegment(from: point, to: point)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let currentPath else { return }
        let point = convert(event.locationInWindow, from: nil)
        updateIndicatorHover(at: point)

        let previousPoint = lastStrokePoint ?? point
        currentPath.line(to: point)
        lastStrokePoint = point
        movePointer(to: point)

        // Only the new segment changed. Invalidating the whole view here meant every
        // mouse move re-stroked every path drawn so far, so the cost of a drag grew
        // with the number of strokes already on screen.
        invalidateSegment(from: previousPoint, to: point)
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        movePointer(to: point)
        updateIndicatorHover(at: point)

        if let currentPath {
            paths.append(currentPath)
            // The pixels do not change here, the path just moves from currentPath into
            // paths. Repainting its own bounds once per stroke is cheap insurance.
            setNeedsDisplay(strokeBounds(of: currentPath))
        }
        currentPath = nil
        lastStrokePoint = nil
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        movePointer(to: point)
        updateIndicatorHover(at: point)
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

        addCursorRect(bounds, cursor: DrawingView.transparentCursor)
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

        DrawingView.transparentCursor.set()
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
            setNeedsDisplay(pointerRect(at: previous))
        }

        pointerLocation = point

        if let point {
            setNeedsDisplay(pointerRect(at: point))
        }
    }

    private func pointerRect(at point: NSPoint) -> NSRect {
        NSRect(x: point.x - DrawingView.pointerSize / 2,
               y: point.y - DrawingView.pointerSize / 2,
               width: DrawingView.pointerSize,
               height: DrawingView.pointerSize)
            .insetBy(dx: -DrawingView.pointerCasingWidth, dy: -DrawingView.pointerCasingWidth)
    }

    private func drawPointer(in dirtyRect: NSRect) {
        guard !isInteractionMode, let point = pointerLocation,
              dirtyRect.intersects(pointerRect(at: point)) else {
            return
        }

        let half = DrawingView.pointerSize / 2
        let gap = DrawingView.pointerCentreGap
        let crosshair = NSBezierPath()
        crosshair.move(to: NSPoint(x: point.x - half, y: point.y))
        crosshair.line(to: NSPoint(x: point.x - gap, y: point.y))
        crosshair.move(to: NSPoint(x: point.x + gap, y: point.y))
        crosshair.line(to: NSPoint(x: point.x + half, y: point.y))
        crosshair.move(to: NSPoint(x: point.x, y: point.y - half))
        crosshair.line(to: NSPoint(x: point.x, y: point.y - gap))
        crosshair.move(to: NSPoint(x: point.x, y: point.y + gap))
        crosshair.line(to: NSPoint(x: point.x, y: point.y + half))
        crosshair.lineCapStyle = .round

        // Light casing under a dark core, so it reads on a white slide and on a dark one.
        crosshair.lineWidth = DrawingView.pointerCasingWidth
        NSColor.white.withAlphaComponent(0.9).setStroke()
        crosshair.stroke()
        crosshair.lineWidth = 1
        NSColor.black.withAlphaComponent(0.85).setStroke()
        crosshair.stroke()
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
            undoLastStroke()
        }

        // Everything else is swallowed rather than passed on. Drawing mode owns the
        // keyboard the same way it owns the mouse: an unhandled key would travel up the
        // responder chain and end in a system beep, so typing while drawing made the
        // machine beep on every letter. Click-through is where the keyboard belongs to
        // someone else.
    }

    // Escape can also arrive as a cancel action rather than a plain keyDown; swallow it
    // there too, silently, for the same reason.
    override func cancelOperation(_ sender: Any?) {
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        NSColor.systemRed.setStroke()

        // Skip strokes that are nowhere near the region being repainted. With
        // incremental invalidation this is what keeps a drag cheap on a long session.
        for path in paths where strokeBounds(of: path).intersects(dirtyRect) {
            path.stroke()
        }

        if let currentPath, strokeBounds(of: currentPath).intersects(dirtyRect) {
            currentPath.stroke()
        }

        drawActiveModeIndicator(in: dirtyRect)
        drawPointer(in: dirtyRect)
    }

    func capturedStrokes() -> [NSBezierPath] {
        paths
    }

    // A stroke the user has not lifted the mouse off yet is still a stroke. Whenever the
    // tool is taken away mid-drag - hiding the overlay, or stepping into click-through -
    // it has to be committed, or it is dropped on the floor: hiding lost it, and after a
    // round trip through click-through it sat there unfinished until the next mouseDown
    // silently replaced it.
    func finishStrokeInProgress() {
        guard let currentPath else {
            return
        }

        paths.append(currentPath)
        self.currentPath = nil
        lastStrokePoint = nil
        setNeedsDisplay(strokeBounds(of: currentPath))
    }

    func restore(strokes: [NSBezierPath]) {
        paths = strokes
        currentPath = nil
        lastStrokePoint = nil
        needsDisplay = true
    }

    func clear() {
        paths.removeAll()
        currentPath = nil
        lastStrokePoint = nil
        needsDisplay = true
    }

    // NSBezierPath.bounds covers the path geometry only, so grow it by the line width to
    // include the stroke itself, its round caps and antialiasing.
    private func strokeBounds(of path: NSBezierPath) -> NSRect {
        path.bounds.insetBy(dx: -DrawingView.strokeLineWidth, dy: -DrawingView.strokeLineWidth)
    }

    private func invalidateSegment(from start: NSPoint, to end: NSPoint) {
        let segment = NSRect(x: min(start.x, end.x),
                             y: min(start.y, end.y),
                             width: abs(end.x - start.x),
                             height: abs(end.y - start.y))
        setNeedsDisplay(segment.insetBy(dx: -DrawingView.strokeLineWidth,
                                        dy: -DrawingView.strokeLineWidth))
    }

    private func undoLastStroke() {
        guard !paths.isEmpty else {
            return
        }

        paths.removeLast()
        needsDisplay = true
    }

    private func drawActiveModeIndicator(in dirtyRect: NSRect) {
        guard showsIndicator else {
            return
        }

        indicatorRect = activeModeIndicatorRect()
        guard !isMouseOverIndicator, dirtyRect.intersects(indicatorRect) else {
            return
        }

        let (mode, hint) = indicatorLines()

        indicatorBackgroundColor.setFill()
        NSBezierPath(roundedRect: indicatorRect, xRadius: 5, yRadius: 5).fill()

        // Bottom line first: the view is not flipped, so the mode sits above the hint.
        hint.draw(at: NSPoint(x: indicatorRect.minX + DrawingView.indicatorPaddingX,
                              y: indicatorRect.minY + DrawingView.indicatorPaddingY))
        mode.draw(at: NSPoint(x: indicatorRect.minX + DrawingView.indicatorPaddingX,
                              y: indicatorRect.minY + DrawingView.indicatorPaddingY
                                 + hint.size().height + DrawingView.indicatorLineGap))
    }

    // Red and solid while the overlay owns the mouse, hollow and neutral while clicks are
    // passing through: the badge answers "where do my clicks go right now?".
    private var indicatorText: String {
        isInteractionMode ? "◌ CLICK-THROUGH" : "● DRAW"
    }

    private var indicatorBackgroundColor: NSColor {
        isInteractionMode
            ? NSColor.black.withAlphaComponent(0.45)
            : NSColor.systemRed.withAlphaComponent(0.72)
    }

    // The badge says which mode you are in; without the second line it never says how to
    // get out, which is the one thing a user who thinks they are stuck needs. Modifier
    // glyphs keep it to a glance rather than a sentence to read mid-presentation.
    private func indicatorLines() -> (mode: NSAttributedString, hint: NSAttributedString) {
        let mode = NSAttributedString(string: indicatorText, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.92)
        ])
        let hintText = isInteractionMode ? DrawingView.interactionHintText : DrawingView.drawingHintText
        let hint = NSAttributedString(string: hintText, attributes: [
            .font: NSFont.systemFont(ofSize: 9, weight: .regular),
            .foregroundColor: NSColor.white.withAlphaComponent(0.65)
        ])

        return (mode, hint)
    }

    private func activeModeIndicatorRect() -> NSRect {
        let (mode, hint) = indicatorLines()
        let width = max(mode.size().width, hint.size().width) + DrawingView.indicatorPaddingX * 2
        let height = mode.size().height + hint.size().height + DrawingView.indicatorLineGap
            + DrawingView.indicatorPaddingY * 2

        return NSRect(x: indicatorBounds.maxX - width - DrawingView.indicatorMargin,
                      y: indicatorBounds.maxY - height - DrawingView.indicatorMargin,
                      width: width,
                      height: height)
    }

    private func updateIndicatorHover(at point: NSPoint) {
        guard showsIndicator else {
            return
        }

        let wasMouseOverIndicator = isMouseOverIndicator
        let currentIndicatorRect = indicatorRect == .zero ? activeModeIndicatorRect() : indicatorRect
        isMouseOverIndicator = currentIndicatorRect.contains(point)

        if isMouseOverIndicator != wasMouseOverIndicator {
            // Showing or hiding the badge only touches the badge's own rect; anything
            // drawn underneath it is repainted by draw(_:) for the same rect.
            setNeedsDisplay(currentIndicatorRect.insetBy(dx: -DrawingView.strokeLineWidth,
                                                         dy: -DrawingView.strokeLineWidth))
        }
    }
}

final class GlobalHotKey {
    // Ownership, on purpose: a GlobalHotKey is owned by whoever created it (AppDelegate
    // keeps both hot keys alive for the lifetime of the app). The Carbon callback must
    // never own it - register() used to pass a retained pointer as userData, which meant
    // deinit could never run and the unregister() in it was dead code. Instead the
    // callback looks the hot key up in `registeredHotKeys`, which holds weak references.
    // An unregistered or deallocated hot key is simply not found, so the callback cannot
    // reach freed memory, and unregistering/re-registering at runtime works.
    private final class WeakHotKey {
        weak var value: GlobalHotKey?

        init(_ value: GlobalHotKey) {
            self.value = value
        }
    }

    private static let signature = OSType(UInt32(ascii: "SDO1"))

    // One handler for every hot key instead of one per hot key. It holds no per-instance
    // state and is installed with a nil userData pointer, so there is nothing in it that
    // can dangle; it is installed once and left in place for the life of the process.
    private static var sharedEventHandler: EventHandlerRef?
    private static var registeredHotKeys: [UInt32: WeakHotKey] = [:]

    private let hotKeyID: EventHotKeyID
    private let keyCode: UInt32
    private let modifiers: UInt32
    private let handler: () -> Void
    private var hotKeyRef: EventHotKeyRef?

    init(id: UInt32, keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) {
        hotKeyID = EventHotKeyID(signature: GlobalHotKey.signature, id: id)
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.handler = handler
    }

    func register() -> Bool {
        guard hotKeyRef == nil else {
            return true
        }

        guard GlobalHotKey.installSharedEventHandlerIfNeeded() else {
            return false
        }

        GlobalHotKey.registeredHotKeys[hotKeyID.id] = WeakHotKey(self)

        let registerStatus = RegisterEventHotKey(keyCode,
                                                 modifiers,
                                                 hotKeyID,
                                                 GetApplicationEventTarget(),
                                                 0,
                                                 &hotKeyRef)

        guard registerStatus == noErr, hotKeyRef != nil else {
            hotKeyRef = nil
            GlobalHotKey.registeredHotKeys.removeValue(forKey: hotKeyID.id)
            return false
        }

        return true
    }

    func unregister() {
        // Order matters: stop Carbon from delivering events first, then drop the entry the
        // callback would look this instance up in.
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }

        if GlobalHotKey.registeredHotKeys[hotKeyID.id]?.value === self {
            GlobalHotKey.registeredHotKeys.removeValue(forKey: hotKeyID.id)
        }
    }

    deinit {
        unregister()
    }

    private static func installSharedEventHandlerIfNeeded() -> Bool {
        guard sharedEventHandler == nil else {
            return true
        }

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))

        let installStatus = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            guard let event else {
                return OSStatus(eventNotHandledErr)
            }

            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event,
                                           EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID),
                                           nil,
                                           MemoryLayout<EventHotKeyID>.size,
                                           nil,
                                           &hotKeyID)

            guard status == noErr,
                  hotKeyID.signature == GlobalHotKey.signature,
                  let hotKey = GlobalHotKey.registeredHotKeys[hotKeyID.id]?.value else {
                return OSStatus(eventNotHandledErr)
            }

            // Copy the closure out of the instance so the async block never touches the
            // hot key object, which may be gone by the time the block runs.
            let handler = hotKey.handler
            DispatchQueue.main.async {
                handler()
            }

            return noErr
        }, 1, &eventType, nil, &sharedEventHandler)

        guard installStatus == noErr else {
            sharedEventHandler = nil
            return false
        }

        return true
    }
}

extension NSScreen {
    // NSScreen instances are not guaranteed to be identical across calls, so fall back
    // to the display ID when object identity does not match.
    // Stable per display, so a drawing can be put back on the screen it was drawn on.
    var displayIdentifier: String {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard let displayID = deviceDescription[key] as? CGDirectDisplayID else {
            return "unknown"
        }

        return String(displayID)
    }

    func matches(_ other: NSScreen) -> Bool {
        if self === other {
            return true
        }

        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard let lhs = deviceDescription[key] as? CGDirectDisplayID,
              let rhs = other.deviceDescription[key] as? CGDirectDisplayID else {
            return false
        }

        return lhs == rhs
    }
}

extension UInt32 {
    init(ascii string: String) {
        precondition(string.utf8.count == 4)
        self = string.utf8.reduce(0) { partial, byte in
            (partial << 8) + UInt32(byte)
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
