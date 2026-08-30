// Who owns the cursor, at which window level - a manual check, and why it has to be one.
//
// The overlay sits at .popUpMenu (101), above the menu bar and the status items, and the
// real arrow still comes back when the pointer reaches the top of the screen. Whether a
// higher window level fixes that decides whether the pointer can be a drawn tool shape or
// has to stay the system arrow with a ring around it.
//
// Two ways to measure it automatically were tried and neither works:
//
//   - NSCursor.currentSystem reports the system's idea of the cursor, not what is on
//     screen. It answered "not ours" in the middle of a panel we own.
//   - CGWarpMouseCursorPosition moves the pointer without generating any event, so nothing
//     asks the view for a cursor and the counters stay at zero however the pointer moves.
//     Synthesising the move instead needs CGEventPost, which needs Accessibility - the one
//     permission this app will not ask for, so a measurement that needs it is not
//     measuring this app.
//
// So it needs a hand on the mouse. Run it, move the pointer around the places it names, and
// read the summary:
//
//     swiftc -O -o /tmp/cursor_ownership Testing/experiments/cursor_ownership.swift \
//       && /tmp/cursor_ownership
//
// A big pink disc means the overlay owns the cursor there. The ordinary arrow means it does
// not, and no cursor we choose will show up in that spot.

import AppKit

final class Catcher: NSView {
    private(set) var seen: Set<String> = []
    private var tracking: NSTrackingArea?

    let cursor: NSCursor = {
        let side: CGFloat = 47
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            NSColor.systemPink.withAlphaComponent(0.9).setFill()
            NSBezierPath(ovalIn: NSRect(x: 4, y: 4, width: side - 8, height: side - 8)).fill()
            NSColor.white.setStroke()
            let ring = NSBezierPath(ovalIn: NSRect(x: 4, y: 4, width: side - 8, height: side - 8))
            ring.lineWidth = 2
            ring.stroke()
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: side / 2, y: side / 2))
    }()

    override var isOpaque: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking {
            removeTrackingArea(tracking)
        }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseMoved, .cursorUpdate, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: cursor)
    }

    // Both are recorded because they answer different halves of the question: cursorUpdate
    // is the window server asking us what the cursor should be, mouseMoved is it telling us
    // where the pointer is. Losing the first is what makes the arrow come back.
    override func cursorUpdate(with event: NSEvent) {
        cursor.set()
        note(event, "cursor")
    }

    override func mouseMoved(with event: NSEvent) {
        note(event, "moved")
    }

    func reset() {
        seen = []
    }

    private func note(_ event: NSEvent, _ kind: String) {
        seen.insert("\(kind):\(region(for: convert(event.locationInWindow, from: nil)))")
    }

    private func region(for point: NSPoint) -> String {
        if point.y > bounds.maxY - 26 {
            if point.x > bounds.maxX - 220 { return "menu bar right (Control Center)" }
            if point.x < 220 { return "menu bar left (Apple menu)" }
            return "menu bar middle"
        }
        if point.y < 90 { return "the bottom, where the Dock is" }
        return "the middle of the screen"
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let screen = NSScreen.main!
let frame = screen.frame
let view = Catcher(frame: NSRect(origin: .zero, size: frame.size))
view.wantsLayer = true

let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                    backing: .buffered, defer: false)
panel.isOpaque = false
panel.backgroundColor = .clear
panel.hasShadow = false
panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
panel.acceptsMouseMovedEvents = true
panel.contentView = view

let seconds = 14.0
print("Move the pointer slowly around the screen and along the top edge - over the middle,")
print("the Apple menu, the clock, Control Center - and over the Dock. \(Int(seconds))s per level.")
print("A big pink disc means the overlay owns the cursor there.")

for (name, level) in [("popUpMenu (101) - what the app ships with", NSWindow.Level.popUpMenu),
                      ("shielding (\(Int(CGShieldingWindowLevel()))) - the untried one",
                       NSWindow.Level(rawValue: Int(CGShieldingWindowLevel())))] {
    panel.level = level
    panel.makeKeyAndOrderFront(nil)
    panel.invalidateCursorRects(for: view)
    view.reset()

    print("")
    print("=== level \(name) - go ===")
    RunLoop.current.run(until: Date().addingTimeInterval(seconds))

    let regions = ["the middle of the screen", "menu bar left (Apple menu)", "menu bar middle",
                   "menu bar right (Control Center)", "the bottom, where the Dock is"]
    for region in regions {
        let owned = view.seen.contains("cursor:\(region)")
        let moved = view.seen.contains("moved:\(region)")
        let verdict = owned ? "ours" : (moved ? "MOUSE YES, CURSOR NO" : "not visited")
        print(String(format: "  %-34@ %@", region as NSString, verdict as NSString))
    }
    panel.orderOut(nil)
    RunLoop.current.run(until: Date().addingTimeInterval(0.4))
}

print("")
print("\"not visited\" means the pointer never went there - not a result. Try again.")
