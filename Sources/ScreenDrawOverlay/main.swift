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

        // Safety-first v0.1: only draw over the main screen until the overlay is stable.
        guard let screen = NSScreen.main else {
            print("ScreenDrawOverlay: could not enter drawing mode because NSScreen.main is nil")
            forceCloseOverlay(reason: "missing main screen")
            return
        }

        let window = OverlayPanel(screen: screen)
        let drawingView = window.drawingView
        window.onEscape = { [weak self] in
            self?.forceCloseOverlay(reason: "Escape key")
        }
        drawingView.onEscape = { [weak self] in
            self?.forceCloseOverlay(reason: "Escape key")
        }

        overlayWindows = [window]
        drawingViews = [drawingView]
        isDrawingMode = true

        print("ScreenDrawOverlay: drawing mode ON")
        print("ScreenDrawOverlay: overlay created")

        // The panel is non-activating, but making it key lets Escape reach keyDown.
        window.makeKeyAndOrderFront(nil)
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

    init(screen: NSScreen) {
        let screenFrame = screen.frame
        let visibleFrame = screen.visibleFrame
        let localVisibleFrame = NSRect(x: visibleFrame.minX - screenFrame.minX,
                                       y: visibleFrame.minY - screenFrame.minY,
                                       width: visibleFrame.width,
                                       height: visibleFrame.height)
        drawingView = DrawingView(frame: NSRect(origin: .zero, size: screenFrame.size),
                                  indicatorBounds: localVisibleFrame)

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
    private var paths: [NSBezierPath] = []
    private var currentPath: NSBezierPath?
    private var indicatorBounds: NSRect
    private var indicatorRect: NSRect = .zero
    private var isMouseOverIndicator = false
    private var mouseTrackingArea: NSTrackingArea?
    var onEscape: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { false }

    init(frame frameRect: NSRect, indicatorBounds: NSRect) {
        self.indicatorBounds = indicatorBounds
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
        path.lineWidth = 4
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.move(to: point)

        currentPath = path
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let currentPath else { return }
        let point = convert(event.locationInWindow, from: nil)
        updateIndicatorHover(at: point)
        currentPath.line(to: point)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        updateIndicatorHover(at: convert(event.locationInWindow, from: nil))

        if let currentPath {
            paths.append(currentPath)
        }
        currentPath = nil
        needsDisplay = true
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
        for path in paths {
            path.stroke()
        }
        currentPath?.stroke()
        drawActiveModeIndicator()
    }

    func clear() {
        paths.removeAll()
        currentPath = nil
        needsDisplay = true
    }

    private func undoLastStroke() {
        guard !paths.isEmpty else {
            return
        }

        paths.removeLast()
        needsDisplay = true
    }

    private func drawActiveModeIndicator() {
        indicatorRect = activeModeIndicatorRect()
        guard !isMouseOverIndicator else {
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
        let wasMouseOverIndicator = isMouseOverIndicator
        let currentIndicatorRect = indicatorRect == .zero ? activeModeIndicatorRect() : indicatorRect
        isMouseOverIndicator = currentIndicatorRect.contains(point)

        if isMouseOverIndicator != wasMouseOverIndicator {
            needsDisplay = true
        }
    }
}

final class GlobalHotKey {
    private let hotKeyID: EventHotKeyID
    private let keyCode: UInt32
    private let modifiers: UInt32
    private let handler: () -> Void
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var userData: UnsafeMutableRawPointer?

    init(id: UInt32, keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) {
        hotKeyID = EventHotKeyID(signature: OSType(UInt32(ascii: "SDO1")), id: id)
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.handler = handler
    }

    func register() -> Bool {
        guard hotKeyRef == nil, eventHandlerRef == nil, userData == nil else {
            return true
        }

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))

        let selfPointer = Unmanaged.passRetained(self).toOpaque()
        userData = selfPointer

        let installStatus = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else {
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

            let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
            guard status == noErr,
                  hotKeyID.signature == hotKey.hotKeyID.signature,
                  hotKeyID.id == hotKey.hotKeyID.id else {
                return OSStatus(eventNotHandledErr)
            }

            let handler = hotKey.handler
            DispatchQueue.main.async {
                handler()
            }

            return noErr
        }, 1, &eventType, selfPointer, &eventHandlerRef)

        guard installStatus == noErr else {
            releaseUserData()
            return false
        }

        let registerStatus = RegisterEventHotKey(keyCode,
                                                 modifiers,
                                                 hotKeyID,
                                                 GetApplicationEventTarget(),
                                                 0,
                                                 &hotKeyRef)

        if registerStatus != noErr {
            if let eventHandlerRef {
                RemoveEventHandler(eventHandlerRef)
                self.eventHandlerRef = nil
            }
            releaseUserData()
            return false
        }

        return true
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }

        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }

        releaseUserData()
    }

    deinit {
        unregister()
    }

    private func releaseUserData() {
        if let userData {
            Unmanaged<GlobalHotKey>.fromOpaque(userData).release()
            self.userData = nil
        }
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
