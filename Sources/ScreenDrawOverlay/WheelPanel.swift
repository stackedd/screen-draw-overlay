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

        override var isOpaque: Bool { false }

        override func draw(_ dirtyRect: NSRect) {
            guard let wheel, let context = NSGraphicsContext.current?.cgContext else {
                return
            }

            wheel.draw(in: context, bounds: bounds, highlighted: highlighted)
        }
    }

    // Above the overlay, so a wheel opened over a drawing is on top of it.
    private static let level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
    private static let pollInterval: TimeInterval = 1.0 / 60

    private let view = WheelView(frame: NSRect(x: 0, y: 0, width: Wheel.extent, height: Wheel.extent))
    private let panel: NSPanel
    private var poll: Timer?
    private var centre: NSPoint = .zero
    private var pick: ((Int) -> Void)?

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
    func open(_ wheel: Wheel, pick: @escaping (Int) -> Void) {
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
        view.highlighted = nil
        view.needsDisplay = true
        self.pick = pick
        centre = NSPoint(x: origin.x + extent / 2, y: origin.y + extent / 2)

        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()

        // Read where the pointer already is, rather than waiting a frame to find out.
        track(NSEvent.mouseLocation)

        let timer = Timer(timeInterval: WheelPanel.pollInterval, repeats: true) { [weak self] _ in
            self?.track(NSEvent.mouseLocation)
        }
        RunLoop.main.add(timer, forMode: .common)
        poll = timer
    }

    // The held key came up. Whatever the pointer is pushing towards is the answer; the dead
    // zone in the middle is how the user says never mind.
    func release() {
        let chosen = view.highlighted
        close()

        if let chosen {
            pick?(chosen)
        }
        pick = nil
    }

    func close() {
        poll?.invalidate()
        poll = nil
        panel.orderOut(nil)
    }

    // Where the pointer is, in screen coordinates. Taken as an argument rather than read
    // in here so that the wheel can be driven without a hand on the mouse, which is the
    // only way the behaviour suite can reach it.
    func track(_ pointer: NSPoint) {
        let offset = NSPoint(x: pointer.x - centre.x, y: pointer.y - centre.y)
        let selection = view.wheel?.selection(for: offset)

        // Only when it changes, which is a handful of times in the second a wheel is up.
        guard selection != view.highlighted else {
            return
        }

        view.highlighted = selection
        view.needsDisplay = true
    }
}
