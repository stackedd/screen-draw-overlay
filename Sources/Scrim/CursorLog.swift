// What the screen is actually showing, on request.
//
// This exists because of the one fault in this app that has survived three fixes and cannot be
// reproduced from the outside: "picking a tool shows the system pointer for a moment". Every
// probe here drives the real handlers and measures clean, because a probe warps the pointer
// and a hand moves it, and AppKit's cursor machinery does not behave the same way for both.
//
// So the app can say what it sees, on the machine where it happens:
//
//     SCRIM_CURSOR_LOG=1 dist/Scrim.app/Contents/MacOS/Scrim
//
// It samples NSCursor.currentSystem - what the window server is drawing, as opposed to
// NSCursor.current, which is this app's own idea of it and has been right the whole time -
// every four milliseconds, and prints only the moments it changed, next to what the app
// believed was happening. A flash of one frame shows up as two lines 8ms apart.
//
// The other switch takes the cursor hold out of the picture:
//
//     SCRIM_CURSOR_LOG=1 SCRIM_CURSOR_HOLD=0 dist/.../Scrim
//
// so that "is the hold closing the gap, or is it causing the flicker?" becomes a question an
// experiment answers rather than an argument.
//
// Off unless asked for, and off means nothing at all: no timer, no sampling, no cost. On, it
// costs about 4% of a core (0.157ms a sample, 250 a second), which is fine for the minute it
// takes to reproduce something and wrong for anything else.

import AppKit

enum CursorLog {
    private static var timer: Timer?
    private static var last: String?
    private static var lastChanged = Date()
    private static var lastState = ""
    private static let started = Date()
    // Every stretch where the screen showed something that is not ours while drawing mode had
    // the mouse. This is the list the fault lives in, so it is printed again on the way out -
    // scrolling back through a minute of lines to find two of them is how a flash gets missed.
    private static var wrong: [(at: TimeInterval, lasted: TimeInterval, shown: String, state: String)] = []

    static var isOn: Bool {
        ProcessInfo.processInfo.environment["SCRIM_CURSOR_LOG"] != nil
    }

    static func startIfAsked(reporting state: @escaping () -> String) {
        guard isOn, timer == nil else {
            return
        }

        print("Scrim: cursor log on, sampling what the screen shows every 4ms")
        print("CURSOR      time    for  what the screen shows   what the app thinks")

        let timer = Timer(timeInterval: 0.004, repeats: true) { _ in
            sample(state())
        }
        RunLoop.main.add(timer, forMode: .common)
        CursorLog.timer = timer
    }

    private static func sample(_ state: String) {
        let shown = describe(NSCursor.currentSystem)
        guard shown != last else {
            return
        }

        let now = Date()
        let held = now.timeIntervalSince(lastChanged)

        // What just ended, if it was the wrong thing to be showing. "Drawing" here means the
        // overlay has the mouse: in click-through the pointer belongs to the app underneath
        // and the system arrow is the right answer, not the fault.
        if let last, last != "ours (shows nothing)", lastState.hasPrefix("drawing") {
            wrong.append((at: lastChanged.timeIntervalSince(started), lasted: held,
                          shown: last, state: lastState))
        }

        last = shown
        lastChanged = now
        lastState = state
        print(String(format: "CURSOR %8.3fs %5.0fms  %-22@  %@",
                     now.timeIntervalSince(started), held * 1000,
                     shown as NSString, state as NSString))
    }

    // Printed on the way out, because the thing being hunted is two lines in a hundred.
    static func summarise() {
        guard isOn else {
            return
        }

        print("")
        print("CURSOR summary: \(wrong.count) moment(s) where the screen showed something "
              + "that was not ours while the overlay had the mouse")
        for moment in wrong {
            print(String(format: "CURSOR   at %6.3fs for %5.0fms  %@   (%@)",
                         moment.at, moment.lasted * 1000,
                         moment.shown as NSString, moment.state as NSString))
        }

        if let longest = wrong.map(\.lasted).max() {
            print(String(format: "CURSOR   the longest was %.0fms", longest * 1000))
        }
    }

    private static func describe(_ cursor: NSCursor?) -> String {
        guard let cursor else {
            return "nothing (hidden)"
        }

        let size = cursor.image.size
        if size == PointerCursor.invisible.image.size {
            return "ours (shows nothing)"
        }

        if size == NSCursor.arrow.image.size {
            return "SYSTEM ARROW"
        }

        return String(format: "another one, %.0fx%.0f", size.width, size.height)
    }
}
