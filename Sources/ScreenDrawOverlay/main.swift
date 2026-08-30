import AppKit
import Carbon
import Foundation
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var drawingMenuItem: NSMenuItem?
    private var hotKeyWarningItem: NSMenuItem?
    private var loginItem: NSMenuItem?
    private var interactionMenuItem: NSMenuItem?
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

        setupStatusItem()

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

        // Only offered where the system can do it without a helper bundle, and only for a
        // real installed copy - an unbundled build has nothing to register.
        if #available(macOS 13.0, *), Bundle.main.bundleIdentifier != nil {
            let launchItem = NSMenuItem(title: "Open at Login",
                                        action: #selector(toggleLaunchAtLogin),
                                        keyEquivalent: "")
            launchItem.target = self
            menu.addItem(launchItem)
            loginItem = launchItem
            menu.addItem(.separator())
        }

        let quitItem = NSMenuItem(title: "Quit",
                                  action: #selector(quit),
                                  keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        menu.delegate = self
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

    // The login state can be changed from System Settings behind our back, so it is read
    // when the menu opens rather than cached.
    func menuWillOpen(_ menu: NSMenu) {
        refreshLoginItem()
    }

    @objc private func toggleLaunchAtLogin() {
        guard #available(macOS 13.0, *) else {
            return
        }

        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
                print("ScreenDrawOverlay: will no longer open at login")
            } else {
                try SMAppService.mainApp.register()
                print("ScreenDrawOverlay: will open at login")
            }
        } catch {
            // Nothing to shout about: macOS refuses this for copies in odd places, and the
            // app works exactly the same either way.
            print("ScreenDrawOverlay: could not change the login item - \(error.localizedDescription)")
        }

        refreshLoginItem()
    }

    private func refreshLoginItem() {
        guard #available(macOS 13.0, *), let loginItem else {
            return
        }

        switch SMAppService.mainApp.status {
        case .enabled:
            loginItem.title = "Open at Login"
            loginItem.state = .on
        case .requiresApproval:
            // macOS is waiting for the user in System Settings; saying so beats a
            // checkbox that looks broken.
            loginItem.title = "Open at Login (approve in System Settings)"
            loginItem.state = .mixed
        default:
            loginItem.title = "Open at Login"
            loginItem.state = .off
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
    // reads as the shortcut fighting the user.
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

    init(screen: NSScreen, showsIndicator: Bool, tools: ToolSettings) {
        screenKey = screen.displayIdentifier
        let screenFrame = screen.frame
        let visibleFrame = screen.visibleFrame
        let localVisibleFrame = NSRect(x: visibleFrame.minX - screenFrame.minX,
                                       y: visibleFrame.minY - screenFrame.minY,
                                       width: visibleFrame.width,
                                       height: visibleFrame.height)
        drawingView = DrawingView(frame: NSRect(origin: .zero, size: screenFrame.size),
                                  indicatorBounds: localVisibleFrame,
                                  showsIndicator: showsIndicator,
                                  tools: tools)

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

        // Undo and redo are the tool's own, so they are handed to the view rather than
        // swallowed. Redo carries Shift as well as Command, which an equality check on
        // Command alone silently dropped - the shortcut looked implemented and did
        // nothing.
        let isUndoOrRedo = event.charactersIgnoringModifiers?.lowercased() == "z"
            && (shortcutFlags == .command || shortcutFlags == [.command, .shift])
        if isUndoOrRedo {
            drawingView.keyDown(with: event)
        }

        return true
    }
}

// What the pointer does while the button is down. Freehand tools trail the mouse; shape
// tools are defined by where the drag started and where it is now; the eraser removes
// instead of adding.
enum DrawingTool {
    case pen
    case highlighter
    case line
    case arrow
    case rectangle
    case ellipse
    case eraser
    case laser

    var style: StrokeStyle {
        self == .highlighter ? .highlighter : .pen
    }

    var isShape: Bool {
        self == .line || self == .arrow || self == .rectangle || self == .ellipse
    }

    // Tools that leave nothing behind. The laser is a pointer, not a pen.
    var marksTheCanvas: Bool {
        self != .eraser && self != .laser
    }

    // Stable across releases, unlike a case's position, so a stored preference survives
    // the tool list growing.
    var persistedName: String {
        switch self {
        case .pen: return "pen"
        case .highlighter: return "highlighter"
        case .line: return "line"
        case .arrow: return "arrow"
        case .rectangle: return "rectangle"
        case .ellipse: return "ellipse"
        case .eraser: return "eraser"
        case .laser: return "laser"
        }
    }

    init?(persistedName name: String) {
        switch name {
        case "pen": self = .pen
        case "highlighter": self = .highlighter
        case "line": self = .line
        case "arrow": self = .arrow
        case "rectangle": self = .rectangle
        case "ellipse": self = .ellipse
        case "eraser": self = .eraser
        case "laser": self = .laser
        default: return nil
        }
    }

    var label: String {
        switch self {
        case .pen: return "PEN"
        case .highlighter: return "MARKER"
        case .line: return "LINE"
        case .arrow: return "ARROW"
        case .rectangle: return "RECT"
        case .ellipse: return "OVAL"
        case .eraser: return "ERASER"
        case .laser: return "LASER"
        }
    }
}

// What a stroke is drawn with. Highlighter is the same geometry with a wider, softer,
// see-through pass, which is what makes it read as a marker over content.
enum StrokeStyle {
    case pen
    case highlighter

    var widthMultiplier: CGFloat {
        self == .highlighter ? 4 : 1
    }

    var alpha: CGFloat {
        self == .highlighter ? 0.35 : 1
    }

    var lineCapStyle: NSBezierPath.LineCapStyle {
        self == .highlighter ? .square : .round
    }

    var label: String {
        self == .highlighter ? "MARKER" : "PEN"
    }
}

// One finished (or in-progress) mark on the overlay.
//
// The points are kept alongside the path on purpose: an eraser has to answer "is this
// stroke near the pointer?", and NSBezierPath can only answer that for its filled area,
// not for the line itself. Keeping the polyline makes that a distance test.
struct Stroke {
    // How long a temporary stroke lives, and how much of that it spends at full strength
    // before it starts going. Fading from the first instant reads as a rendering fault
    // rather than a decision.
    static let fadeDuration: TimeInterval = 3
    static let fadeHold = 0.55

    var points: [NSPoint]
    let path: NSBezierPath
    let color: NSColor
    let width: CGFloat
    let style: StrokeStyle
    // nil for ink that stays. Set for a temporary stroke, which is what a presenter wants
    // for "look here" marks that should not pile up on the slide.
    let createdAt: Date?

    var renderColor: NSColor {
        color.withAlphaComponent(style.alpha)
    }

    func opacity(at date: Date) -> CGFloat {
        guard let createdAt else {
            return 1
        }

        let age = date.timeIntervalSince(createdAt) / Stroke.fadeDuration
        guard age > Stroke.fadeHold else {
            return 1
        }

        return max(0, CGFloat(1 - (age - Stroke.fadeHold) / (1 - Stroke.fadeHold)))
    }

    var hasFaded: Bool {
        guard let createdAt else {
            return false
        }

        return Date().timeIntervalSince(createdAt) >= Stroke.fadeDuration
    }
}

// The current pen, shared by every screen's panel: picking a colour on one display has to
// apply on all of them, and the badge that shows it lives on only one.
final class ToolSettings {
    static let colors: [NSColor] = [.systemRed, .systemOrange, .systemYellow,
                                    .systemGreen, .systemBlue, .white]
    static let widths: [CGFloat] = [2, 3, 4, 6, 9, 14]

    // Remembered between launches. Someone who always marks up in a thick yellow
    // highlighter should not have to say so every morning.
    private enum Key {
        static let colorIndex = "toolColorIndex"
        static let widthIndex = "toolWidthIndex"
        static let tool = "toolName"
        static let temporaryInk = "toolTemporaryInk"
    }

    private(set) var colorIndex = 0
    private(set) var widthIndex = 2
    private(set) var tool: DrawingTool = .pen
    private(set) var drawsTemporaryInk = false
    private var lastDrawingTool: DrawingTool = .pen

    init() {
        let defaults = UserDefaults.standard
        if let stored = defaults.object(forKey: Key.colorIndex) as? Int,
           ToolSettings.colors.indices.contains(stored) {
            colorIndex = stored
        }

        if let stored = defaults.object(forKey: Key.widthIndex) as? Int,
           ToolSettings.widths.indices.contains(stored) {
            widthIndex = stored
        }

        // The eraser and the laser are things you pick up for a moment, not a pen to
        // start the day with, so they are never what comes back.
        if let name = defaults.string(forKey: Key.tool),
           let stored = DrawingTool(persistedName: name), stored.marksTheCanvas {
            tool = stored
            lastDrawingTool = stored
        }

        drawsTemporaryInk = defaults.bool(forKey: Key.temporaryInk)
    }

    private func persist() {
        let defaults = UserDefaults.standard
        defaults.set(colorIndex, forKey: Key.colorIndex)
        defaults.set(widthIndex, forKey: Key.widthIndex)
        // The eraser and the laser are momentary; what comes back next launch is the last
        // thing that actually drew.
        defaults.set(lastDrawingTool.persistedName, forKey: Key.tool)
        defaults.set(drawsTemporaryInk, forKey: Key.temporaryInk)
    }

    var style: StrokeStyle {
        tool.style
    }

    // Set by AppDelegate so every panel repaints its badge when the tool changes.
    var onChange: (() -> Void)?

    var color: NSColor {
        ToolSettings.colors[colorIndex]
    }

    // The width a stroke is actually drawn with, multiplier included.
    var renderWidth: CGFloat {
        ToolSettings.widths[widthIndex] * style.widthMultiplier
    }

    func selectColor(_ index: Int) {
        guard ToolSettings.colors.indices.contains(index), index != colorIndex else {
            return
        }

        colorIndex = index
        persist()
        onChange?()
    }

    func stepWidth(by delta: Int) {
        let next = min(max(widthIndex + delta, 0), ToolSettings.widths.count - 1)
        guard next != widthIndex else {
            return
        }

        widthIndex = next
        persist()
        onChange?()
    }

    func select(tool newTool: DrawingTool) {
        guard newTool != tool else {
            return
        }

        tool = newTool
        if newTool.marksTheCanvas {
            lastDrawingTool = newTool
        }
        persist()
        onChange?()
    }

    // Space is a switch, not a one-way trip: it drops the laser and hands back whatever
    // was in hand before.
    func toggleLaser() {
        select(tool: tool == .laser ? lastDrawingTool : .laser)
    }

    func toggleTemporaryInk() {
        drawsTemporaryInk.toggle()
        persist()
        onChange?()
    }

    // How close the pointer has to be to a stroke to rub it out. Tied to the pen width so
    // a fat pen gets a fat eraser, with a floor that keeps it usable at 2pt.
    var eraserRadius: CGFloat {
        max(12, ToolSettings.widths[widthIndex])
    }
}

final class DrawingView: NSView {

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

    // 15 a second. Measured: the cost of a fade is one repaint of a full screen
    // transparent layer per tick - about 0.4% CPU each - and is almost independent of how
    // many strokes are fading or how big they are. 20/s cost 5.1%, 15/s costs 4.4% and 12/s
    // 4.3%, so past this point the smoothness is free and the savings are not.
    private static let fadeTickInterval: TimeInterval = 1.0 / 15

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
    private static let indicatorRepaintMargin: CGFloat = 4

    // Undo has to put back what the eraser and Clear take away, not just the last thing
    // drawn, so edits are recorded rather than inferred from the stroke list.
    private struct Removal {
        let index: Int
        let stroke: Stroke
    }

    private enum Edit {
        case added(Stroke)
        case removed([Removal])
    }

    private var strokes: [Stroke] = []
    private var currentStroke: Stroke?
    private var shapeAnchor: NSPoint?
    private var lastStrokePoint: NSPoint?
    private var undoStack: [Edit] = []
    private var redoStack: [Edit] = []
    private var fadeTimer: Timer?
    let tools: ToolSettings
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

    init(frame frameRect: NSRect, indicatorBounds: NSRect, showsIndicator: Bool, tools: ToolSettings) {
        self.indicatorBounds = indicatorBounds
        self.showsIndicator = showsIndicator
        self.tools = tools
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        fadeTimer?.invalidate()
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
        movePointer(to: point)

        guard tools.tool != .eraser else {
            erase(at: point)
            return
        }

        guard tools.tool.marksTheCanvas else {
            return
        }

        let width = tools.renderWidth
        let path = NSBezierPath()
        path.lineWidth = width
        path.lineCapStyle = tools.style.lineCapStyle
        path.lineJoinStyle = .round
        path.move(to: point)

        currentStroke = Stroke(points: [point], path: path, color: tools.color,
                               width: width, style: tools.style,
                               createdAt: tools.drawsTemporaryInk ? Date() : nil)
        shapeAnchor = tools.tool.isShape ? point : nil
        lastStrokePoint = point
        invalidateSegment(from: point, to: point, width: width)
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        updateIndicatorHover(at: point)
        movePointer(to: point)

        guard tools.tool != .eraser else {
            erase(at: point)
            return
        }

        guard currentStroke != nil else { return }

        // A shape is defined by two points, so it is rebuilt on every move rather than
        // extended. Repainting covers where it was and where it now is.
        if let anchor = shapeAnchor, let existing = currentStroke {
            let end = constrainedShapeEnd(from: anchor, to: point, shiftHeld: event.modifierFlags.contains(.shift))
            let previousBounds = strokeBounds(of: existing)
            let rebuilt = shapePath(from: anchor, to: end, width: existing.width)
            currentStroke = Stroke(points: [anchor, end], path: rebuilt, color: existing.color,
                                   width: existing.width, style: existing.style,
                                   createdAt: existing.createdAt)
            lastStrokePoint = end
            if let updated = currentStroke {
                setNeedsDisplay(previousBounds.union(strokeBounds(of: updated)))
            }
            return
        }

        let previousPoint = lastStrokePoint ?? point
        currentStroke?.path.line(to: point)
        currentStroke?.points.append(point)
        lastStrokePoint = point

        // Only the new segment changed. Invalidating the whole view here meant every
        // mouse move re-stroked every path drawn so far, so the cost of a drag grew
        // with the number of strokes already on screen.
        invalidateSegment(from: previousPoint, to: point, width: currentStroke?.width ?? tools.renderWidth)
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        movePointer(to: point)
        updateIndicatorHover(at: point)
        shapeAnchor = nil

        if let currentStroke {
            strokes.append(currentStroke)
            recordEdit(.added(currentStroke))
            startFadingIfNeeded()
            // The pixels do not change here, the stroke just moves from currentStroke
            // into strokes. Repainting its own bounds once is cheap insurance.
            setNeedsDisplay(strokeBounds(of: currentStroke))
        }
        currentStroke = nil
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

        // The laser is a pointer, so it looks like one: a dot in the current colour with a
        // soft halo, instead of the crosshair you aim a pen with.
        guard tools.tool != .laser else {
            let core = DrawingView.pointerSize / 3
            tools.color.withAlphaComponent(0.28).setFill()
            NSBezierPath(ovalIn: NSRect(x: point.x - core, y: point.y - core,
                                        width: core * 2, height: core * 2)).fill()
            tools.color.setFill()
            NSBezierPath(ovalIn: NSRect(x: point.x - core / 2, y: point.y - core / 2,
                                        width: core, height: core)).fill()
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
            undoLastEdit()
        } else if event.keyCode == UInt16(kVK_ANSI_Z), shortcutFlags == [.command, .shift] {
            redoLastEdit()
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
        for stroke in strokes where strokeBounds(of: stroke).intersects(dirtyRect) {
            let opacity = stroke.opacity(at: now)
            guard opacity > 0 else {
                continue
            }

            stroke.renderColor.withAlphaComponent(stroke.renderColor.alphaComponent * opacity).setStroke()
            stroke.path.stroke()
        }

        if let currentStroke, strokeBounds(of: currentStroke).intersects(dirtyRect) {
            currentStroke.renderColor.setStroke()
            currentStroke.path.stroke()
        }

        drawActiveModeIndicator(in: dirtyRect)
        drawPointer(in: dirtyRect)
    }

    // Temporary ink is deliberately left behind: it was drawn to vanish, and bringing it
    // back mid-fade on the next show would be a surprise.
    func capturedStrokes() -> [Stroke] {
        strokes.filter { $0.createdAt == nil }
    }

    // A stroke the user has not lifted the mouse off yet is still a stroke. Whenever the
    // tool is taken away mid-drag - hiding the overlay, or stepping into click-through -
    // it has to be committed, or it is dropped on the floor: hiding lost it, and after a
    // round trip through click-through it sat there unfinished until the next mouseDown
    // silently replaced it.
    func finishStrokeInProgress() {
        guard let currentStroke else {
            return
        }

        strokes.append(currentStroke)
        recordEdit(.added(currentStroke))
        startFadingIfNeeded()
        self.currentStroke = nil
        shapeAnchor = nil
        lastStrokePoint = nil
        setNeedsDisplay(strokeBounds(of: currentStroke))
    }

    func restore(strokes restored: [Stroke]) {
        strokes = restored
        undoStack.removeAll()
        redoStack.removeAll()
        currentStroke = nil
        lastStrokePoint = nil
        needsDisplay = true
    }

    // Clearing is an edit like any other, so an accidental Delete can be taken back.
    func clear() {
        finishStrokeInProgress()

        if !strokes.isEmpty {
            recordEdit(.removed(strokes.enumerated().map { Removal(index: $0.offset, stroke: $0.element) }))
        }

        strokes.removeAll()
        currentStroke = nil
        shapeAnchor = nil
        lastStrokePoint = nil
        fadeTimer?.invalidate()
        fadeTimer = nil
        needsDisplay = true
    }

    // The badge carries the tool name, its colour and its width, so a tool change has to
    // repaint it - on every screen, not just the one the key was pressed on.
    //
    // The text changes length with the tool ("PEN 4" against "MARKER 24") and the badge is
    // anchored to the corner, so it grows leftwards: repainting only where it used to be
    // leaves the wider version half drawn. Old rect and new rect, both.
    func toolSettingsChanged() {
        guard showsIndicator else {
            return
        }

        let updated = activeModeIndicatorRect()
        let region = indicatorRect == .zero ? updated : indicatorRect.union(updated)
        setNeedsDisplay(region.insetBy(dx: -DrawingView.indicatorRepaintMargin,
                                       dy: -DrawingView.indicatorRepaintMargin))
    }

    // Shapes are two-point figures. Holding Shift snaps a line or arrow to the nearest 45
    // degrees and makes a rectangle square or an ellipse round, which is what every other
    // drawing tool does and what fingers expect.
    private func constrainedShapeEnd(from anchor: NSPoint, to point: NSPoint, shiftHeld: Bool) -> NSPoint {
        guard shiftHeld else {
            return point
        }

        let dx = point.x - anchor.x
        let dy = point.y - anchor.y

        if tools.tool == .rectangle || tools.tool == .ellipse {
            let side = max(abs(dx), abs(dy))
            return NSPoint(x: anchor.x + (dx < 0 ? -side : side), y: anchor.y + (dy < 0 ? -side : side))
        }

        let angle = atan2(dy, dx)
        let step = CGFloat.pi / 4
        let snapped = (angle / step).rounded() * step
        let length = hypot(dx, dy)
        return NSPoint(x: anchor.x + cos(snapped) * length, y: anchor.y + sin(snapped) * length)
    }

    private func shapePath(from anchor: NSPoint, to end: NSPoint, width: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        path.lineWidth = width
        path.lineCapStyle = .round
        path.lineJoinStyle = .round

        switch tools.tool {
        case .rectangle:
            path.appendRect(NSRect(x: min(anchor.x, end.x), y: min(anchor.y, end.y),
                                   width: abs(end.x - anchor.x), height: abs(end.y - anchor.y)))
        case .ellipse:
            path.appendOval(in: NSRect(x: min(anchor.x, end.x), y: min(anchor.y, end.y),
                                       width: abs(end.x - anchor.x), height: abs(end.y - anchor.y)))
        case .arrow:
            path.move(to: anchor)
            path.line(to: end)
            // Head scaled to the line width so a thick arrow does not end in a pin prick.
            let headLength = max(12, width * 3.5)
            let angle = atan2(end.y - anchor.y, end.x - anchor.x)
            let spread = CGFloat.pi / 7
            for side in [angle + .pi - spread, angle + .pi + spread] {
                path.move(to: end)
                path.line(to: NSPoint(x: end.x + cos(side) * headLength, y: end.y + sin(side) * headLength))
            }
        default:
            path.move(to: anchor)
            path.line(to: end)
        }

        return path
    }

    // The eraser rubs out whole strokes: partial erasing would mean splitting paths, and
    // on an annotation overlay "take that line away" is what people actually want.
    private func erase(at point: NSPoint) {
        let radius = tools.eraserRadius
        var removed: [Removal] = []

        for index in strokes.indices.reversed() {
            let stroke = strokes[index]
            guard strokeBounds(of: stroke).insetBy(dx: -radius, dy: -radius).contains(point) else {
                continue
            }

            guard distance(from: point, to: stroke) <= radius + stroke.width / 2 else {
                continue
            }

            removed.append(Removal(index: index, stroke: stroke))
            setNeedsDisplay(strokeBounds(of: stroke))
            strokes.remove(at: index)
        }

        guard !removed.isEmpty else {
            return
        }

        recordEdit(.removed(removed.sorted { $0.index < $1.index }))
    }

    // Distance from the pointer to the stroke's polyline. This is why Stroke keeps its
    // points: NSBezierPath can only test its filled area, not the line itself.
    private func distance(from point: NSPoint, to stroke: Stroke) -> CGFloat {
        guard let first = stroke.points.first else {
            return .greatestFiniteMagnitude
        }

        guard stroke.points.count > 1 else {
            return hypot(point.x - first.x, point.y - first.y)
        }

        var best = CGFloat.greatestFiniteMagnitude
        for index in 1..<stroke.points.count {
            best = min(best, distance(from: point, toSegmentFrom: stroke.points[index - 1], to: stroke.points[index]))
        }

        return best
    }

    private func distance(from point: NSPoint, toSegmentFrom start: NSPoint, to end: NSPoint) -> CGFloat {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy

        guard lengthSquared > 0 else {
            return hypot(point.x - start.x, point.y - start.y)
        }

        let t = max(0, min(1, ((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared))
        return hypot(point.x - (start.x + t * dx), point.y - (start.y + t * dy))
    }

    // The only timer in the app, and it exists only while temporary ink is on screen:
    // it starts when one is drawn and stops the moment the last one is gone, so an idle
    // overlay still costs nothing.
    private func startFadingIfNeeded() {
        guard fadeTimer == nil, strokes.contains(where: { $0.createdAt != nil }) else {
            return
        }

        let timer = Timer(timeInterval: DrawingView.fadeTickInterval, repeats: true) { [weak self] _ in
            self?.advanceFade()
        }
        RunLoop.main.add(timer, forMode: .common)
        fadeTimer = timer
    }

    private func advanceFade() {
        let now = Date()
        var fadingRemains = false
        var changed = false
        var region = NSRect.zero

        for index in strokes.indices.reversed() {
            guard let createdAt = strokes[index].createdAt else {
                continue
            }

            let bounds = strokeBounds(of: strokes[index])

            if strokes[index].hasFaded {
                // Temporary ink is not an edit: it was never meant to stay, so undo has
                // nothing to say about it disappearing.
                strokes.remove(at: index)
                changed = true
            } else {
                fadingRemains = true
                // Nothing to repaint while the stroke is still at full strength, which is
                // more than half of its life.
                if now.timeIntervalSince(createdAt) / Stroke.fadeDuration > Stroke.fadeHold {
                    changed = true
                }
            }

            region = region == .zero ? bounds : region.union(bounds)
        }

        // One repaint covering all of them, not one per stroke: fifty separate rects mean
        // fifty passes that each redraw every stroke they touch, and the cost of a fade
        // then grows with the square of what is on screen. Measured: 12.5% CPU that way.
        if changed, region != .zero {
            setNeedsDisplay(region)
        }

        guard !fadingRemains else {
            return
        }

        fadeTimer?.invalidate()
        fadeTimer = nil
    }

    private func recordEdit(_ edit: Edit) {
        undoStack.append(edit)
        // A new edit is a new branch: whatever was undone is no longer ahead of us.
        redoStack.removeAll()
    }

    private func undoLastEdit() {
        guard let edit = undoStack.popLast() else {
            return
        }

        switch edit {
        case .added(let stroke):
            if !strokes.isEmpty {
                strokes.removeLast()
            }
            setNeedsDisplay(strokeBounds(of: stroke))
        case .removed(let removals):
            for removal in removals {
                strokes.insert(removal.stroke, at: min(removal.index, strokes.count))
                setNeedsDisplay(strokeBounds(of: removal.stroke))
            }
        }

        redoStack.append(edit)
    }

    private func redoLastEdit() {
        guard let edit = redoStack.popLast() else {
            return
        }

        switch edit {
        case .added(let stroke):
            strokes.append(stroke)
            setNeedsDisplay(strokeBounds(of: stroke))
        case .removed(let removals):
            for removal in removals.reversed() where removal.index < strokes.count {
                setNeedsDisplay(strokeBounds(of: strokes[removal.index]))
                strokes.remove(at: removal.index)
            }
        }

        undoStack.append(edit)
    }

    // NSBezierPath.bounds covers the path geometry only, so grow it by that stroke's own
    // line width to include the drawn line, its caps and antialiasing.
    private func strokeBounds(of stroke: Stroke) -> NSRect {
        stroke.path.bounds.insetBy(dx: -stroke.width, dy: -stroke.width)
    }

    private func invalidateSegment(from start: NSPoint, to end: NSPoint, width: CGFloat) {
        let segment = NSRect(x: min(start.x, end.x),
                             y: min(start.y, end.y),
                             width: abs(end.x - start.x),
                             height: abs(end.y - start.y))
        setNeedsDisplay(segment.insetBy(dx: -width, dy: -width))
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
        guard !isInteractionMode else {
            return "◌ CLICK-THROUGH"
        }

        if tools.tool == .eraser || tools.tool == .laser {
            return "● \(tools.tool.label)"
        }

        let temporary = tools.drawsTemporaryInk ? "TEMP " : ""
        return "● \(temporary)\(tools.tool.label) \(Int(tools.renderWidth))"
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
        let mode = NSMutableAttributedString(string: indicatorText, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.92)
        ])

        // The leading dot is the colour swatch: the only place the active colour is shown,
        // which is what keeps this keyboard-driven tool honest without a palette on screen.
        if !isInteractionMode, mode.length > 0 {
            mode.addAttribute(.foregroundColor, value: tools.color, range: NSRange(location: 0, length: 1))
        }
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
            setNeedsDisplay(currentIndicatorRect.insetBy(dx: -DrawingView.indicatorRepaintMargin,
                                                         dy: -DrawingView.indicatorRepaintMargin))
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
    private let releaseHandler: (() -> Void)?
    private var hotKeyRef: EventHotKeyRef?

    init(id: UInt32,
         keyCode: UInt32,
         modifiers: UInt32,
         handler: @escaping () -> Void,
         releaseHandler: (() -> Void)? = nil) {
        hotKeyID = EventHotKeyID(signature: GlobalHotKey.signature, id: id)
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.handler = handler
        self.releaseHandler = releaseHandler
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

        // Both halves of the keypress. The release half is what lets a hot key be held
        // rather than toggled - press and hold to draw, let go to put it away.
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]

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
            let isRelease = GetEventKind(event) == UInt32(kEventHotKeyReleased)
            guard let handler = isRelease ? hotKey.releaseHandler : hotKey.handler else {
                return OSStatus(eventNotHandledErr)
            }

            DispatchQueue.main.async {
                handler()
            }

            return noErr
        }, eventTypes.count, &eventTypes, nil, &sharedEventHandler)

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
