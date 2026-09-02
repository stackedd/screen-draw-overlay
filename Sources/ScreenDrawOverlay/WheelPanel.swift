// The window a wheel appears in, and the hold-and-release that drives it.
//
// It is its own panel rather than a layer on the overlay for a measured reason: a repaint
// costs more the larger its rectangle, and the overlay's is the whole screen. The wheel is
// three hundred points across, so it repaints its own small backing store and never touches
// the ink (docs/ARCHITECTURE.md, "Where the drawing bill actually goes").
//
// The pointer is read by polling NSEvent.mouseLocation rather than by taking mouse events.
// That is what lets the wheel work in every mode - drawing, click-through, and with the
// overlay closed - without the panel having to take the mouse away from whatever is
// underneath. It needs no permission, and the poll runs only while the wheel is up.

import AppKit

final class WheelPanel {
    private final class WheelView: NSView {
        var wheel: Wheel?
        var highlighted: Int?
        var centreLabel: String?

        // Where the hand is, on a layer of its own so that following it does not repaint the
        // wheel: measured, redrawing the whole wheel on every move is 13.7% of a core against
        // 9.1% for redrawing it only when the highlight moves to another sector.
        let dotLayer: CALayer = {
            let layer = CALayer()
            layer.actions = ["position": NSNull(), "contents": NSNull(),
                             "hidden": NSNull(), "bounds": NSNull()]
            layer.isHidden = true
            return layer
        }()

        func showDot(at offset: NSPoint) {
            if dotLayer.superlayer !== layer {
                layer?.addSublayer(dotLayer)
            }

            let scale = window?.backingScaleFactor ?? 2
            if dotLayer.contents == nil || dotLayer.contentsScale != scale {
                let side = Wheel.dotDiameter + 4
                dotLayer.bounds = NSRect(x: 0, y: 0, width: side, height: side)
                dotLayer.contentsScale = scale
                dotLayer.contents = Wheel.dot(scale: scale)
            }

            dotLayer.position = NSPoint(x: bounds.midX + offset.x, y: bounds.midY + offset.y)
            dotLayer.isHidden = false
        }

        override var isOpaque: Bool { false }

        // The wheel is above the overlay, so while it is up it is the window under the
        // pointer, and a window with no cursor rect is a window that shows the system arrow.
        // It wears the same nothing the overlay wears, and draws the pointer itself.
        override func resetCursorRects() {
            super.resetCursorRects()
            addCursorRect(bounds, cursor: PointerCursor.invisible)
        }

        override func cursorUpdate(with event: NSEvent) {
            PointerCursor.invisible.set()
        }

        override func draw(_ dirtyRect: NSRect) {
            guard let wheel, let context = NSGraphicsContext.current?.cgContext else {
                return
            }

            wheel.draw(in: context, bounds: bounds, highlighted: highlighted,
                       centreLabel: centreLabel)
        }
    }

    // Above the overlay, so a wheel opened over a drawing is on top of it.
    private static let level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
    private static let pollInterval: TimeInterval = 1.0 / 60

    private let view: WheelView = {
        let view = WheelView(frame: NSRect(x: 0, y: 0, width: Wheel.extent, height: Wheel.extent))
        view.wantsLayer = true
        return view
    }()
    private let panel: NSPanel
    private var poll: Timer?
    private var centre: NSPoint = .zero
    private var pick: ((Int?) -> Void)?
    // Which showing of the wheel is the current one, so a fade that is still running cannot
    // put away a wheel that has been opened again since.
    private var showing = 0

    var isOpen: Bool { poll != nil }

    // What a release would choose right now, and nil for the dead zone.
    var selection: Int? { view.highlighted }

    init() {
        panel = NSPanel(contentRect: view.frame, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = WheelPanel.level
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        // The wheel is driven by a held key and a poll, so it never needs a click - and a
        // panel that took them would be one more thing standing between the user and the
        // app underneath.
        panel.ignoresMouseEvents = true
        // NSPanel hides itself when the app deactivates unless told otherwise, which for a
        // background app means never appearing at all.
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.contentView = view
    }

    // Opens centred on the pointer, or as close to it as fits: a wheel half off the screen
    // would put half its sectors somewhere the pointer cannot reach.
    // The pick is handed nil for the hub rather than nothing at all, because the hub is not
    // always a cancel: on the tools wheel it is the way out to driving the system.
    func open(_ wheel: Wheel, centreLabel: String? = nil, pick: @escaping (Int?) -> Void) {
        close()

        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
        let extent = Wheel.extent
        var origin = NSPoint(x: pointer.x - extent / 2, y: pointer.y - extent / 2)

        if let bounds = screen?.frame {
            origin.x = min(max(origin.x, bounds.minX + 8), bounds.maxX - extent - 8)
            origin.y = min(max(origin.y, bounds.minY + 8), bounds.maxY - extent - 8)
        }

        view.wheel = wheel
        view.centreLabel = centreLabel
        view.highlighted = nil
        view.dotLayer.isHidden = true
        view.needsDisplay = true
        self.pick = pick
        centre = NSPoint(x: origin.x + extent / 2, y: origin.y + extent / 2)

        panel.setFrameOrigin(origin)
        // Faded in rather than snapped on. A tenth of a second is what macOS gives anything
        // that appears under the pointer, and a HUD that arrives instantly is one of the small
        // things that reads as "not from here" without anybody being able to say why.
        showing += 1
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.10
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
        panel.invalidateCursorRects(for: view)
        PointerCursor.invisible.set()

        // Read where the pointer already is, rather than waiting a frame to find out.
        track(NSEvent.mouseLocation)

        // The cursor is re-set a few times a second while the wheel is up, for the same reason
        // the overlay holds it: a window that appears under a stationary pointer is handed the
        // plain arrow by the window server about 25ms later, and the wheel is a window that
        // just appeared. The overlay's own hold does not cover the case where there is no
        // overlay yet, which is exactly the first ⌥Z of a session.
        var tick = 0
        let timer = Timer(timeInterval: WheelPanel.pollInterval, repeats: true) { [weak self] _ in
            tick += 1
            if tick % 4 == 0 {
                PointerCursor.invisible.set()
            }

            self?.track(NSEvent.mouseLocation)
        }
        RunLoop.main.add(timer, forMode: .common)
        poll = timer
    }

    // The held key came up. Whatever the pointer is pushing towards is the answer; the dead
    // zone in the middle is how the user says never mind.
    func release() {
        let chosen = view.highlighted
        let answer = pick
        pick = nil
        poll?.invalidate()
        poll = nil

        // The choice first, so that whatever it changed - the tool, and with it the cursor -
        // has already happened by the time this window goes away.
        answer?(chosen)

        fadeOut()
        onClose?()
    }

    // On the way out it goes the same way it came in. The panel takes no clicks, so the extra
    // twelfth of a second it stays on screen is in nobody's way - and the cursor is being held
    // by the overlay underneath for a third of a second either way (OverlayController).
    private func fadeOut() {
        let thisOne = showing
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.08
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.showing == thisOne else {
                return
            }

            self.panel.orderOut(nil)
        })
    }

    // Whoever opened the wheel gets told when it has gone, because the overlay underneath
    // has to take the cursor back: the pointer has not moved, so nothing else will ask it to.
    var onClose: (() -> Void)?

    // The way out that does not wait for anything: the overlay is going away, or the app is.
    func close() {
        let wasOpen = poll != nil
        poll?.invalidate()
        poll = nil
        showing += 1
        panel.orderOut(nil)

        if wasOpen {
            onClose?()
        }
    }

    // Where the pointer is, in screen coordinates. Taken as an argument rather than read
    // in here so that the wheel can be driven without a hand on the mouse, which is the
    // only way the behaviour suite can reach it.
    func track(_ pointer: NSPoint) {
        let offset = NSPoint(x: pointer.x - centre.x, y: pointer.y - centre.y)
        let selection = view.wheel?.selection(for: offset)

        // The dot follows the hand and costs a layer move; the wheel itself is repainted
        // only when the highlight crosses into another sector, which is a handful of times
        // in the second a wheel is up.
        view.showDot(at: offset)

        guard selection != view.highlighted else {
            return
        }

        view.highlighted = selection
        view.needsDisplay = true
    }
}
