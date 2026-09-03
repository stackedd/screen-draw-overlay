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

    // How long a key has to be held before the wheel appears. Under this it is a tap. Pushing
    // the mouse out of the dead zone shows it at once however short the press, because at that
    // point the user is plainly aiming at something.
    //
    // A tenth of a second: long enough that a tap does not flash a wheel, short enough that
    // holding one feels like it opened rather than like it thought about it. It was 0.18 and
    // that was reported as slow.
    static let holdBeforeShowing: TimeInterval = ShortcutSettings.defaultDelay

    // How long this wheel waits, which is a setting: the default suits most hands and some
    // people want it gone (docs/DECISIONS.md 32). Set by open(); zero means the wheel is on
    // screen before the key has finished travelling.
    private var holdForThisOne: TimeInterval = ShortcutSettings.defaultDelay

    private let view: WheelView = {
        let view = WheelView(frame: NSRect(x: 0, y: 0, width: Wheel.extent, height: Wheel.extent))
        view.wantsLayer = true
        return view
    }()
    // Borderless windows cannot become key unless they say so, and this one has to be able
    // to: a window's cursor rects are only honoured while it is the key window, which is what
    // stops the plain arrow appearing next to the wheel (docs/DECISIONS.md 35).
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    private let panel: Panel
    private var poll: Timer?
    private var showTimer: Timer?
    // The burst after this panel appears - see settle().
    private var settling: Timer?
    private var isShowing = false
    private var centre: NSPoint = .zero
    private var pick: ((Int?) -> Void)?
    // Which showing of the wheel is the current one, so a fade that is still running cannot
    // put away a wheel that has been opened again since.
    private var showing = 0

    var isOpen: Bool { poll != nil }

    // What a release would choose right now, and nil for the dead zone.
    var selection: Int? { view.highlighted }

    init() {
        panel = Panel(contentRect: view.frame, styleMask: [.borderless, .nonactivatingPanel],
                      backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = WheelPanel.level
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        // The wheel is driven by a held key and a poll, so it never needs a click - and a
        // panel that took them would be one more thing standing between the user and the
        // app underneath.
        // Set for real in open(): whether it takes them depends on whether anything else of
        // ours is already under the pointer. See appOwnsThePointer.
        panel.ignoresMouseEvents = true
        // Without this a window is told nothing when the mouse moves over it, and a window
        // that hears nothing never applies its cursor rects - which is the whole reason this
        // panel takes the mouse at all.
        panel.acceptsMouseMovedEvents = true
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
    // A tap - letting go before the wheel ever appeared - does nothing on any of them. Their
    // hubs mean "leave" and "cancel", these are keys the whole system gives up to this app,
    // and a key hit by accident must not move somebody's mode or their colour. Undo used to be
    // the exception, on ⌥V; it has a key of its own now (docs/DECISIONS.md 31).
    func open(_ wheel: Wheel, centreLabel: String? = nil,
              delay: TimeInterval = WheelPanel.holdBeforeShowing,
              pick: @escaping (Int?) -> Void) {
        close()

        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
        let extent = Wheel.extent
        var origin = NSPoint(x: pointer.x - extent / 2, y: pointer.y - extent / 2)

        if let bounds = screen?.frame {
            origin.x = min(max(origin.x, bounds.minX + 8), bounds.maxX - extent - 8)
            origin.y = min(max(origin.y, bounds.minY + 8), bounds.maxY - extent - 8)
        }

        // Taking the mouse is how this panel gets to own the cursor, and it only needs to
        // when nothing else of ours does. While the overlay is drawing it keeps its hands off,
        // so a stroke in progress goes on getting its events.
        panel.ignoresMouseEvents = appOwnsThePointer?() ?? true

        view.wheel = wheel
        view.centreLabel = centreLabel
        view.highlighted = nil
        view.dotLayer.isHidden = true
        view.needsDisplay = true
        self.pick = pick
        // The gesture is measured from where the hand is, not from where the wheel had to be
        // drawn. Near a screen edge the panel is pushed back on screen by the clamp above, and
        // taking its centre as the origin left the pointer outside the dead zone the moment the
        // wheel opened: it came up on its own with a sector lit, and letting go chose it - so a
        // tap near an edge changed the tool or the colour. Pushing towards the edge is still
        // limited by the pointer's own travel, which no origin can help with.
        centre = pointer

        panel.setFrameOrigin(origin)
        showing += 1
        PointerCursor.invisible.set()

        // Not shown yet: a short press is a tap, and a tap chooses nothing. The timer, or the
        // first push out of the dead zone, brings it up. A delay of zero means there is no tap
        // to speak of - the wheel is up before the key comes back.
        holdForThisOne = max(0, delay)
        if holdForThisOne == 0 {
            show()
        } else {
            let hold = Timer(timeInterval: holdForThisOne, repeats: false) { [weak self] _ in
                self?.show()
            }
            RunLoop.main.add(hold, forMode: .common)
            showTimer = hold
        }

        // Read where the pointer already is, rather than waiting a frame to find out.
        track(NSEvent.mouseLocation)

        // The cursor is re-set on every tick while the wheel is up, for the same reason the
        // overlay holds it: a window that appears under a stationary pointer is handed the
        // plain arrow by the window server about 25ms later, and the wheel is a window that
        // just appeared. The overlay's own hold does not cover the case where there is no
        // overlay yet, which is exactly the first ⌥X of a session. Every tick rather than
        // every fourth, because a quarter of sixty is a 66ms gap and that is what a flicker
        // is; a wheel is up for about a second, so the whole of it costs 0.05ms x 60.
        let timer = Timer(timeInterval: WheelPanel.pollInterval, repeats: true) { [weak self] _ in
            PointerCursor.invisible.set()
            self?.track(NSEvent.mouseLocation)
        }
        RunLoop.main.add(timer, forMode: .common)
        poll = timer
    }

    // Faded in rather than snapped on. A tenth of a second is what macOS gives anything that
    // appears under the pointer, and a HUD that arrives instantly is one of the small things
    // that reads as "not from here" without anybody being able to say why.
    private func show() {
        showTimer?.invalidate()
        showTimer = nil

        guard !isShowing else {
            return
        }

        isShowing = true
        panel.alphaValue = 0

        // Key only when it is the one holding the cursor. While the overlay is drawing it
        // already owns both, and taking the keyboard off it would take it off the text tool.
        // The panel is non-activating either way, so the app in front stays in front.
        if panel.ignoresMouseEvents {
            panel.orderFrontRegardless()
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.10
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
        panel.invalidateCursorRects(for: view)
        PointerCursor.invisible.set()
        settle()
    }

    // A window that appears under a stationary pointer is handed the plain arrow by the window
    // server about 25ms later, whatever the app set before that - the overlay has had a burst
    // against exactly this since it was measured (docs/DECISIONS.md 6), and the wheel had only
    // its own poll, which is sixty a second. Measured with probes/cursorflash.swift: the arrow
    // was on screen for 15ms as the wheel came up. This is the same burst: 120 a second for a
    // third of a second, then the poll carries it.
    private static let settleInterval: TimeInterval = 1.0 / 120
    private static let settleTicks = 42

    private func settle() {
        settling?.invalidate()

        var ticks = 0
        let timer = Timer(timeInterval: WheelPanel.settleInterval, repeats: true) { [weak self] timer in
            ticks += 1
            PointerCursor.invisible.set()

            guard ticks >= WheelPanel.settleTicks || self == nil else {
                return
            }

            timer.invalidate()
            self?.settling = nil
        }
        RunLoop.main.add(timer, forMode: .common)
        settling = timer
    }

    // The held key came up. Whatever the pointer is pushing towards is the answer; the dead
    // zone in the middle is how the user says never mind.
    func release() {
        // Released before the wheel ever appeared: a tap, and a tap chooses nothing. The hub
        // is only ever reached by letting go in the middle of a wheel that is on screen.
        // Hands the mouse back before anything else, the way forceCloseOverlay does: a panel
        // that is fading out and still taking clicks is the one thing this app must not be.
        panel.ignoresMouseEvents = true

        let tapped = !isShowing
        let chosen = view.highlighted
        let answer = tapped ? nil : pick
        pick = nil
        poll?.invalidate()
        poll = nil
        showTimer?.invalidate()
        showTimer = nil
        settling?.invalidate()
        settling = nil

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
        // Never shown - a tap - so there is nothing to take away.
        guard isShowing else {
            return
        }

        isShowing = false
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

    // Whether this app already owns the window under the pointer - which is to say, whether
    // an overlay is up and taking the mouse. Set by OverlayController, asked on every open.
    //
    // It decides whether this panel takes mouse events, and that decides whether the pointer
    // flickers. `NSCursor.set()` only reaches the screen while the window under the pointer
    // belongs to this app: with no overlay open, or in click-through, the window underneath
    // belongs to somebody else, so setting a cursor sixty times a second changes nothing at
    // all and the wheel comes up next to a plain arrow. Measured, and the numbers are in
    // docs/DECISIONS.md 35.
    var appOwnsThePointer: (() -> Bool)?

    // The way out that does not wait for anything: the overlay is going away, or the app is.
    func close() {
        panel.ignoresMouseEvents = true
        let wasOpen = poll != nil
        poll?.invalidate()
        poll = nil
        showTimer?.invalidate()
        showTimer = nil
        settling?.invalidate()
        settling = nil
        isShowing = false
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

        // Aiming at something is as good as holding: the moment the pointer leaves the dead
        // zone the wheel comes up, however short the press has been so far.
        if selection != nil, !isShowing {
            show()
        }

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
