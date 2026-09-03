import AppKit
import Carbon

// What the window server is actually showing, sampled through the whole wheel gesture.
//
// The suites cannot see this: NSCursor.current is this app's own idea of the cursor and it is
// right the whole time. NSCursor.currentSystem is what is on the screen, which is where the
// reported fault lives - "picking a tool shows the system arrow for a moment first".
//
//     python3 Testing/make_probe.py cursorflash FLASH \
//       && swift build --package-path .build/testing/cursorflash -c release \
//       && .build/testing/cursorflash/.build/release/FLASH
//
// It warps the pointer around the middle of the main screen and puts it back. Run by hand.

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let controller = OverlayController()
controller.start()

let screen = NSScreen.main!
let home = NSEvent.mouseLocation
let middle = NSPoint(x: screen.frame.midX, y: screen.frame.midY)

func warp(to point: NSPoint) {
    CGWarpMouseCursorPosition(CGPoint(x: point.x, y: screen.frame.maxY - point.y))
}

// The same door the behaviour suite uses: Carbon's own event, sent to this process, so the
// gesture runs through the real handlers rather than round them.
func fireHotKey(id: UInt32, release: Bool = false) {
    var event: EventRef?
    let kind = release ? UInt32(kEventHotKeyReleased) : UInt32(kEventHotKeyPressed)
    CreateEvent(nil, OSType(kEventClassKeyboard), kind, 0, 0, &event)
    guard let event else {
        return
    }

    var hotKeyID = EventHotKeyID(signature: OSType(UInt32(ascii: "SCRM")), id: id)
    SetEventParameter(event, EventParamName(kEventParamDirectObject),
                      EventParamType(typeEventHotKeyID), MemoryLayout<EventHotKeyID>.size, &hotKeyID)
    SendEventToEventTarget(event, GetApplicationEventTarget())
}

func name(_ cursor: NSCursor?) -> String {
    guard let cursor else {
        return "none"
    }

    let size = cursor.image.size
    let arrow = NSCursor.arrow.image.size
    if size == arrow {
        return "SYSTEM ARROW"
    }

    return String(format: "%.0fx%.0f", size.width, size.height)
}

// Samples what is on screen every four milliseconds, collapsed to the moments it changed, so
// a flash lasting one frame still shows. `script` is a list of things to do and when.
func watch(_ what: String, seconds: Double, script: [(Double, () -> Void)]) {
    var seen: [(Double, String)] = []
    var notes: [(Double, String)] = []
    var pending = script
    let started = Date()

    let sampler = Timer(timeInterval: 0.004, repeats: true) { _ in
        let now = Date().timeIntervalSince(started)
        while let next = pending.first, now >= next.0 {
            pending.removeFirst()
            next.1()
            notes.append((now, "^ did step"))
        }

        let shown = name(NSCursor.currentSystem)
        if seen.last?.1 != shown {
            seen.append((now, shown))
        }
    }
    RunLoop.main.add(sampler, forMode: .common)
    RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    sampler.invalidate()

    print("  \(what):")
    for entry in (seen + notes).sorted(by: { $0.0 < $1.0 }) {
        print(String(format: "      %6.0f ms  %@", entry.0 * 1000, entry.1))
    }

    // The verdict, which is the line worth reading: what the screen ended up showing, against
    // the cursor that mode is supposed to have. In click-through the answer is the system
    // arrow, on purpose - the pointer belongs to the app underneath there.
    // The overlay's pointer is a layer now, so what the window server should be showing while
    // drawing mode is on is the cursor that shows nothing. In click-through the pointer
    // belongs to the app underneath, so there the only wrong answer is ours.
    let invisible = name(PointerCursor.invisible)
    let shown = name(NSCursor.currentSystem)
    let ours = controller.isInteractionMode ? "anything but \(invisible)" : invisible
    let right = controller.isInteractionMode ? shown != invisible : shown == invisible
    print("      => the screen shows \(shown), this mode wants \(ours)"
          + (right ? "" : "   <-- WRONG"))
}

warp(to: middle)
RunLoop.current.run(until: Date().addingTimeInterval(0.6))
print("=== the wheel gesture, as the screen sees it ===")
print("  the system arrow is \(NSCursor.arrow.image.size)")

// Each gesture is the real one: hold the key, push the mouse, let go - and then **do not
// touch the mouse**, which is the case the report is about. Nothing asks the app for a cursor
// again while the pointer is still, so anything that takes it in the next three seconds keeps
// it until the user moves.
func gesture(_ what: String, key: UInt32, push: NSPoint, watching seconds: Double = 3.0) {
    watch(what, seconds: seconds, script: [
        (0.10, { fireHotKey(id: key) }),
        (0.30, { warp(to: NSPoint(x: middle.x + push.x, y: middle.y + push.y)) }),
        (0.60, { fireHotKey(id: key, release: true) })
    ])
}

// The tools wheel: first the pick that has to create the panels, then one over an overlay
// that is already up.
gesture("first tool: the overlay is not open yet, then three seconds of holding still",
        key: 6, push: NSPoint(x: 120, y: 0))
warp(to: middle)
gesture("second tool: the overlay is already up", key: 6, push: NSPoint(x: 90, y: -90))
warp(to: middle)

// The two wheels that only change what is in hand.
gesture("a width", key: 8, push: NSPoint(x: 0, y: 120))
warp(to: middle)
gesture("a colour", key: 7, push: NSPoint(x: -120, y: 0))
warp(to: middle)

// Pushing the mouse the way a hand does, rather than one jump: the window server asks the
// window under the pointer for a cursor on every move, so a moving pointer is the case where
// owning that window matters. A hand pushes for about a third of a second.
func push(from start: NSPoint, to end: NSPoint, over seconds: Double, steps: Int = 20) -> [(Double, () -> Void)] {
    (1...steps).map { step in
        let t = Double(step) / Double(steps)
        return (seconds * t + 0.30, {
            warp(to: NSPoint(x: start.x + (end.x - start.x) * CGFloat(t),
                             y: start.y + (end.y - start.y) * CGFloat(t)))
        })
    }
}

func swept(_ what: String, key: UInt32, to end: NSPoint) {
    watch(what, seconds: 3.0, script:
        [(0.10, { fireHotKey(id: key) })]
        + push(from: middle, to: end, over: 0.35)
        + [(0.75, { fireHotKey(id: key, release: true) })])
}

// A hand actually pushing the mouse, which is what the report is about: with the overlay up
// this app owns the window under the pointer and the answer should never change.
swept("a colour, with the mouse pushed the way a hand pushes it",
      key: 7, to: NSPoint(x: middle.x - 120, y: middle.y))
warp(to: middle)

// The same push in click-through, where the overlay hands the mouse to the app underneath -
// so while a wheel is up, the window under the pointer is not ours.
controller.toggleInteractionMode()
swept("the same push in click-through, where we own nothing under the pointer",
      key: 7, to: NSPoint(x: middle.x - 120, y: middle.y))
controller.toggleInteractionMode()
warp(to: middle)

// The moment the report is about now: letting go, and then **carrying on moving the mouse**,
// which is what a hand does. Every move asks the window server for a cursor again, and between
// the wheel handing the mouse back and the overlay having it there is a window where the
// answer comes from somebody else.
func pickedAndKeptMoving(_ what: String, key: UInt32, to end: NSPoint) {
    watch(what, seconds: 3.0, script:
        [(0.10, { fireHotKey(id: key) })]
        + push(from: middle, to: end, over: 0.30)
        + [(0.62, { fireHotKey(id: key, release: true) })]
        // Still moving, for half a second after the pick.
        + push(from: end, to: NSPoint(x: end.x, y: end.y - 100), over: 0.50).map { ($0.0 + 0.35, $0.1) })
}

// From nothing: the pick that creates the overlay, with the hand still going.
controller.toggleDrawingMode()
warp(to: middle)
pickedAndKeptMoving("the first tool, and the hand keeps moving after the pick",
                    key: 6, to: NSPoint(x: middle.x + 120, y: middle.y))
warp(to: middle)

// And over an overlay that is already up.
pickedAndKeptMoving("a colour, and the hand keeps moving after the pick",
                    key: 7, to: NSPoint(x: middle.x - 120, y: middle.y))
warp(to: middle)

// And the way out: letting go in the middle, which hands the screen back.
gesture("the hub, which hands the screen back", key: 6, push: NSPoint(x: 0, y: 0))

warp(to: home)
controller.shutDown()
print("done")
