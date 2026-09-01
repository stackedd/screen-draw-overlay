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

    var hotKeyID = EventHotKeyID(signature: OSType(UInt32(ascii: "SDO1")), id: id)
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
    // the cursor the tool in hand is supposed to have.
    let ours = name(PointerCursor.cursor(for: controller.tools))
    let shown = name(NSCursor.currentSystem)
    print("      => the screen shows \(shown), the tool wants \(ours)"
          + (shown == ours ? "" : "   <-- WRONG"))
}

warp(to: middle)
RunLoop.current.run(until: Date().addingTimeInterval(0.6))
print("=== the wheel gesture, as the screen sees it ===")
print("  the system arrow is \(NSCursor.arrow.image.size)")

// Hold the wheel key, push right (the pen), let go.
watch("first tool: the overlay is not open yet", seconds: 1.4, script: [
    (0.10, { fireHotKey(id: 6) }),
    (0.30, { warp(to: NSPoint(x: middle.x + 120, y: middle.y)) }),
    (0.60, { fireHotKey(id: 6, release: true) }),
    (0.80, { warp(to: NSPoint(x: middle.x + 122, y: middle.y + 2)) })
])

// And again with the overlay already up: push down-right, which is the marker.
watch("second tool: the overlay is already up", seconds: 1.4, script: [
    (0.10, { fireHotKey(id: 6) }),
    (0.30, { warp(to: NSPoint(x: middle.x + 90, y: middle.y - 90)) }),
    (0.60, { fireHotKey(id: 6, release: true) }),
    (0.80, { warp(to: NSPoint(x: middle.x + 92, y: middle.y - 92)) })
])

// The width wheel, which is the one the report named.
watch("a width", seconds: 1.4, script: [
    (0.10, { fireHotKey(id: 8) }),
    (0.30, { warp(to: NSPoint(x: middle.x, y: middle.y + 120)) }),
    (0.60, { fireHotKey(id: 8, release: true) }),
    (0.80, { warp(to: NSPoint(x: middle.x + 2, y: middle.y + 122)) })
])

warp(to: home)
controller.shutDown()
print("done")
