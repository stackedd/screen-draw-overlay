import AppKit
import Carbon
import Foundation

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var overlayWindows: [OverlayPanel] = []
    private var drawingViews: [DrawingView] = []
    private var toggleHotKey: GlobalHotKey?
    private var emergencyHotKey: GlobalHotKey?
    private var isDrawingMode = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("ScreenDrawOverlay: app launched")

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

        emergencyHotKey = GlobalHotKey(id: 2,
                                       keyCode: UInt32(kVK_Escape),
                                       modifiers: UInt32(cmdKey | optionKey | controlKey)) { [weak self] in
            self?.emergencyCloseOverlay()
        }

        if toggleHotKey?.register() == true {
            print("ScreenDrawOverlay: hotkey registered - Control + Option + Command + D")
        } else {
            showAlert(title: "Hotkey registration failed",
                      message: "Control + Option + Command + D could not be registered. Another app may already be using it.")
        }

        if emergencyHotKey?.register() == true {
            print("ScreenDrawOverlay: hotkey registered - Control + Option + Command + Escape")
        } else {
            showAlert(title: "Emergency hotkey registration failed",
                      message: "Control + Option + Command + Escape could not be registered. If drawing mode gets stuck, stop the app from Xcode.")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        print("ScreenDrawOverlay: app terminating")
        NotificationCenter.default.removeObserver(self)
        forceCloseOverlay(reason: "app terminating")
        toggleHotKey?.unregister()
        emergencyHotKey?.unregister()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem?.button?.title = "D"
        statusItem?.button?.toolTip = "Screen Draw Overlay"

        let menu = NSMenu()
        let toggleItem = NSMenuItem(title: "Toggle Drawing Mode",
                                    action: #selector(toggleDrawingModeFromMenu),
                                    keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(toggleItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit",
                                  action: #selector(quit),
                                  keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem?.menu = menu
    }

    @objc private func toggleDrawingModeFromMenu() {
        toggleDrawingMode()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func toggleDrawingMode() {
        if isDrawingMode || !overlayWindowSnapshot().isEmpty {
            forceCloseOverlay(reason: "toggle-off hotkey")
        } else {
            enterDrawingMode()
        }
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

            // Escape on any screen tears down every overlay, not just its own panel.
            window.onEscape = { [weak self] in
                self?.forceCloseOverlay(reason: "Escape key")
            }
            drawingView.onEscape = { [weak self] in
                self?.forceCloseOverlay(reason: "Escape key")
            }

            windows.append(window)
            views.append(drawingView)
        }

        overlayWindows = windows
        drawingViews = views
        isDrawingMode = true

        print("ScreenDrawOverlay: drawing mode ON")
        print("ScreenDrawOverlay: overlay created on \(windows.count) screen(s)")

        // Only one window can be key, so the secondary panels are just ordered in front.
        // The panels are non-activating, but making one key lets Escape reach keyDown.
        for (index, window) in windows.enumerated() where index != indicatorIndex {
            window.orderFrontRegardless()
        }
        windows[indicatorIndex].makeKeyAndOrderFront(nil)
    }

    @objc private func screenParametersDidChange(_ notification: Notification) {
        guard isDrawingMode || !overlayWindowSnapshot().isEmpty else {
            return
        }

        // A display was plugged in, unplugged or rearranged. The open panels are pinned
        // to frames that may no longer exist, so the safe move is to leave drawing mode
        // rather than re-laying out overlays mid-stroke.
        print("ScreenDrawOverlay: screen configuration changed while drawing")
        forceCloseOverlay(reason: "screen configuration changed")
    }

    private func emergencyCloseOverlay() {
        print("ScreenDrawOverlay: emergency close")
        forceCloseOverlay(reason: "emergency hotkey")
    }

    private func forceCloseOverlay(reason: String) {
        let windows = overlayWindowSnapshot()
        let views = drawingViewSnapshot(from: windows)

        // First make every overlay pass mouse events through, before clearing or closing.
        windows.forEach { window in
            window.ignoresMouseEvents = true
        }

        views.forEach { drawingView in
            drawingView.onEscape = nil
            drawingView.clear()
        }

        windows.forEach { window in
            window.onEscape = nil
            window.orderOut(nil)
            window.close()
            print("ScreenDrawOverlay: overlay destroyed")
        }

        overlayWindows.removeAll()
        drawingViews.removeAll()

        if isDrawingMode || !windows.isEmpty {
            print("ScreenDrawOverlay: drawing mode OFF (\(reason))")
        }

        isDrawingMode = false
    }

    private func overlayWindowSnapshot() -> [OverlayPanel] {
        let appOverlayWindows = NSApp.windows.compactMap { $0 as? OverlayPanel }
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

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}

final class OverlayPanel: NSPanel {
    // Full screen apps (Keynote / PowerPoint presentation mode, full screen Safari) put
    // their window above .floating, so a floating overlay was invisible in exactly the
    // case this app exists for. The shielding level sits above them. Window level does
    // not affect key window eligibility, so Escape still reaches keyDown.
    private static let overlayLevel = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))

    let drawingView: DrawingView
    var onEscape: (() -> Void)?

    init(screen: NSScreen, showsIndicator: Bool) {
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
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        hidesOnDeactivate = false
        isMovable = false
        isReleasedWhenClosed = false

        contentView = drawingView
        makeFirstResponder(drawingView)
    }

    // Borderless panels do not normally become key windows. We opt in only so Escape works.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) {
            onEscape?()
        } else {
            super.keyDown(with: event)
        }
    }
}

final class DrawingView: NSView {
    private static let strokeLineWidth: CGFloat = 4

    private var paths: [NSBezierPath] = []
    private var currentPath: NSBezierPath?
    private var lastStrokePoint: NSPoint?
    private var indicatorBounds: NSRect
    private let showsIndicator: Bool
    private var indicatorRect: NSRect = .zero
    private var isMouseOverIndicator = false
    private var mouseTrackingArea: NSTrackingArea?
    var onEscape: (() -> Void)?

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
                                          options: [.mouseMoved, .activeAlways, .inVisibleRect],
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
        invalidateSegment(from: point, to: point)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let currentPath else { return }
        let point = convert(event.locationInWindow, from: nil)
        updateIndicatorHover(at: point)

        let previousPoint = lastStrokePoint ?? point
        currentPath.line(to: point)
        lastStrokePoint = point

        // Only the new segment changed. Invalidating the whole view here meant every
        // mouse move re-stroked every path drawn so far, so the cost of a drag grew
        // with the number of strokes already on screen.
        invalidateSegment(from: previousPoint, to: point)
    }

    override func mouseUp(with event: NSEvent) {
        updateIndicatorHover(at: convert(event.locationInWindow, from: nil))

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
        updateIndicatorHover(at: convert(event.locationInWindow, from: nil))
    }

    override func keyDown(with event: NSEvent) {
        let shortcutFlags = event.modifierFlags.intersection([.command, .shift, .option, .control])

        if event.keyCode == UInt16(kVK_Escape) {
            onEscape?()
        } else if event.keyCode == UInt16(kVK_ANSI_C), shortcutFlags == [] || shortcutFlags == .shift {
            clear()
        } else if event.keyCode == UInt16(kVK_ANSI_Z), shortcutFlags == .command {
            undoLastStroke()
        } else {
            super.keyDown(with: event)
        }
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

        let text = "● DRAW"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.92)
        ]
        let attributedText = NSAttributedString(string: text, attributes: attributes)
        let paddingX: CGFloat = 8
        let paddingY: CGFloat = 5

        NSColor.black.withAlphaComponent(0.42).setFill()
        NSBezierPath(roundedRect: indicatorRect, xRadius: 5, yRadius: 5).fill()

        attributedText.draw(at: NSPoint(x: indicatorRect.minX + paddingX,
                                        y: indicatorRect.minY + paddingY))
    }

    private func activeModeIndicatorRect() -> NSRect {
        let textSize = NSAttributedString(
            string: "● DRAW",
            attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold)]
        ).size()
        let paddingX: CGFloat = 8
        let paddingY: CGFloat = 5
        let margin: CGFloat = 14

        return NSRect(x: indicatorBounds.maxX - textSize.width - paddingX * 2 - margin,
                      y: indicatorBounds.maxY - textSize.height - paddingY * 2 - margin,
                      width: textSize.width + paddingX * 2,
                      height: textSize.height + paddingY * 2)
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
