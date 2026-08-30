import AppKit
import Carbon
import Foundation

// The end-to-end number the offscreen suites cannot produce.
//
// A real OverlayPanel on a real screen, with real Core Animation behind it, driven at a
// fixed event rate. The offscreen cost suite times painting; this times everything - the
// painting, the backing store, the compositing - as this process pays for it.
//
// It needs a window on screen, so it is run by hand rather than by run.sh:
//
//     python3 Testing/make_probe.py onscreen LIVE && \
//       swift build --package-path .build/testing/onscreen -c release && \
//       .build/testing/onscreen/.build/release/LIVE
//
// The panel sets ignoresMouseEvents for the whole run: it is a measurement and must never
// take someone's click while it is up.

func cpuSeconds() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
         + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let tools = ToolSettings()
let screen = NSScreen.main!
let panel = OverlayPanel(screen: screen, showsBadge: true, tools: tools)
let view = panel.drawingView
tools.onChange = { view.toolSettingsChanged() }
panel.ignoresMouseEvents = true
panel.orderFront(nil)

let bounds = view.bounds
let seconds = 8.0

func event(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent {
    NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                       windowNumber: panel.windowNumber, context: nil,
                       eventNumber: 0, clickCount: 1, pressure: 1)!
}

// A scribble that stays on screen and crosses itself, the way a real one does.
func scribble(_ index: Int) -> NSPoint {
    let step: CGFloat = 2.5
    let perRow = Int((bounds.width - 160) / step)
    let row = index / perRow
    let column = index % perRow
    return NSPoint(x: 80 + CGFloat(row % 2 == 0 ? column : perRow - 1 - column) * step,
                   y: 80 + CGFloat(row % 18) * 46 + sin(CGFloat(index) * 0.35) * 13)
}

func prefill(strokes count: Int) {
    for index in 0..<count {
        let start = NSPoint(x: 80 + CGFloat(index / 25) * 55, y: 60 + CGFloat(index % 25) * 36)
        view.mouseDown(with: event(.leftMouseDown, start))
        for step in 1...20 {
            let t = CGFloat(step) / 20
            view.mouseDragged(with: event(.leftMouseDragged,
                                          NSPoint(x: start.x + t * 300, y: start.y + sin(t * 6) * 14)))
        }
        view.mouseUp(with: event(.leftMouseUp, NSPoint(x: start.x + 300, y: start.y)))
    }
}

print(String(format: "%.0fx%.0f pt at %.0fx backing, %.0fs per run, 60 events a second",
             bounds.width, bounds.height, screen.backingScaleFactor, seconds))
print("CPU% is of one core, this process only.")
print("")
print("  what the user is doing                          strokes on screen   self CPU%")

func run(_ name: String, existing: Int, body: @escaping (Int) -> Void) {
    view.clear()
    prefill(strokes: existing)
    // Let the prefill's repaints finish so they are not billed to the run.
    RunLoop.current.run(until: Date().addingTimeInterval(1.0))

    let before = cpuSeconds()
    let started = Date()
    var tick = 0
    let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { _ in
        body(tick)
        tick += 1
    }
    RunLoop.current.add(timer, forMode: .common)
    RunLoop.current.run(until: started.addingTimeInterval(seconds))
    timer.invalidate()

    print(String(format: "  %-46@ %5d           %5.1f%%", name as NSString, existing,
                 (cpuSeconds() - before) / Date().timeIntervalSince(started) * 100))
}

run("nothing - the overlay is just up", existing: 200) { _ in }
run("moving the pointer, drawing nothing", existing: 0) {
    view.mouseMoved(with: event(.mouseMoved, scribble($0 * 12)))
}
run("moving the pointer, drawing nothing", existing: 200) {
    view.mouseMoved(with: event(.mouseMoved, scribble($0 * 12)))
}
run("drawing one long unbroken stroke", existing: 0) {
    if $0 == 0 { view.mouseDown(with: event(.leftMouseDown, scribble(0))) }
    view.mouseDragged(with: event(.leftMouseDragged, scribble($0 + 1)))
}
view.finishStrokeInProgress()
run("drawing over a canvas that already has ink", existing: 200) {
    if $0 == 0 { view.mouseDown(with: event(.leftMouseDown, scribble(0))) }
    view.mouseDragged(with: event(.leftMouseDragged, scribble($0 + 1)))
}
view.finishStrokeInProgress()

// Temporary ink, fading for real: drawn with the temporary flag on, then simply left alone
// for the whole of its life while the CPU is watched. Nothing drives it - each stroke's
// layer takes its own opacity down - so what this measures is whether that is true.
print("")
print("  and temporary ink fading, over the whole of its three seconds")
for count in [3, 10, 50] {
    view.clear()
    tools.toggleTemporaryInk()
    prefill(strokes: count)
    tools.toggleTemporaryInk()
    let before = cpuSeconds()
    let started = Date()
    RunLoop.current.run(until: started.addingTimeInterval(Stroke.fadeDuration))
    print(String(format: "  %-46@ %5d           %5.1f%%", "temporary strokes fading" as NSString,
                 count, (cpuSeconds() - before) / Date().timeIntervalSince(started) * 100))
}
view.clear()

// The wheel, driven the way a hand drives it: open it and sweep the pointer round. It
// reads the pointer by polling rather than by taking events, which is what makes this
// measurable at all - warping the cursor moves it without generating anything to deliver.
//
// Warping sixty times a second is not free either, so the same sweep is run with nothing
// open first. The wheel costs the difference, not the total.
print("")
print("  and the wheel, swept once a second for \(Int(seconds))s")
// Middle of the screen, so opening the wheel does not have to clamp it away from the
// pointer and leave the sweep circling the dead zone.
CGWarpMouseCursorPosition(CGPoint(x: bounds.midX, y: bounds.midY))
RunLoop.current.run(until: Date().addingTimeInterval(0.3))
let start = NSEvent.mouseLocation
let wheelPanel = WheelPanel()

func sweepPointer(around origin: NSPoint, for duration: Double) -> Double {
    RunLoop.current.run(until: Date().addingTimeInterval(0.4))
    let before = cpuSeconds()
    let began = Date()
    let sweep = Timer(timeInterval: 1.0 / 60, repeats: true) { _ in
        let turn = Date().timeIntervalSince(began) * 2 * Double.pi
        CGWarpMouseCursorPosition(CGPoint(x: origin.x + cos(turn) * 100,
                                          y: bounds.maxY - (origin.y + sin(turn) * 100)))
    }
    RunLoop.current.add(sweep, forMode: .common)
    RunLoop.current.run(until: began.addingTimeInterval(duration))
    sweep.invalidate()
    return (cpuSeconds() - before) / Date().timeIntervalSince(began) * 100
}

let control = sweepPointer(around: start, for: seconds)
print(String(format: "  %-46@ %5d           %5.1f%%",
             "nothing open, just the warping" as NSString, 0, control))

// Back to the middle before opening: the wheel centres itself on the pointer, and the
// control sweep left it out on the circle.
CGWarpMouseCursorPosition(CGPoint(x: start.x, y: bounds.maxY - start.y))
RunLoop.current.run(until: Date().addingTimeInterval(0.3))

var picked = -1
wheelPanel.open(OverlayController.toolWheel) { picked = $0 }

// Held open with the pointer still, which is what it is doing while someone decides.
let restingBefore = cpuSeconds()
let restingStarted = Date()
RunLoop.current.run(until: restingStarted.addingTimeInterval(seconds))
print(String(format: "  %-46@ %5d           %5.1f%%", "open, pointer still" as NSString, 0,
             (cpuSeconds() - restingBefore) / Date().timeIntervalSince(restingStarted) * 100))

let withWheel = sweepPointer(around: start, for: seconds)
wheelPanel.release()
CGWarpMouseCursorPosition(CGPoint(x: start.x, y: bounds.maxY - start.y))
print(String(format: "  %-46@ %5d           %5.1f%%   (%.1f%% of it the wheel)",
             "wheel open and following" as NSString, 0, withWheel, withWheel - control))
print("  (it settled on sector \(picked), which only proves the release fired)")

panel.ignoresMouseEvents = true
panel.close()
print("")
print("done")
