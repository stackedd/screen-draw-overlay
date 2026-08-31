import AppKit
import Carbon

// A real overlay on a real screen, questioned about the two things that keep being reported
// and keep passing every offscreen test: the laser not appearing, and the system cursor
// turning up while drawing.
//
//     python3 Testing/make_probe.py diagnose DIAG \
//       && swift build --package-path .build/testing/diagnose -c release \
//       && .build/testing/diagnose/.build/release/DIAG
//
// It moves the pointer for a few seconds and puts it back. Run by hand.

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let tools = ToolSettings()
let screen = NSScreen.main!
let panel = OverlayPanel(screen: screen, showsBadge: true, tools: tools)
let view = panel.drawingView
tools.onChange = { view.toolSettingsChanged() }
panel.makeKeyAndOrderFront(nil)
view.refreshCursorRects()
view.applyDrawingCursor()

func describeCursor(_ cursor: NSCursor?) -> String {
    guard let cursor else { return "none" }
    let size = cursor.image.size
    return String(format: "%.0fx%.0f", size.width, size.height)
}

func settle(_ seconds: Double = 0.35) {
    RunLoop.current.run(until: Date().addingTimeInterval(seconds))
}

let home = NSEvent.mouseLocation
func warp(to point: NSPoint) {
    CGWarpMouseCursorPosition(CGPoint(x: point.x, y: screen.frame.maxY - point.y))
    settle()
}

let middle = NSPoint(x: screen.frame.midX, y: screen.frame.midY)
warp(to: middle)
settle(0.6)

print("=== the laser ===")
tools.select(tool: .laser)
settle()

let laser = view.laserLayer
print("  layer attached to the view: \(laser.superlayer === view.layer)")
print("  hidden: \(laser.isHidden)")
print("  bounds: \(laser.bounds.size)")
print("  contents set: \(laser.contents != nil)")
print("  contentsScale: \(laser.contentsScale)")

// Is the picture actually a picture, or a transparent square?
if laser.contents != nil, CFGetTypeID(laser.contents as CFTypeRef) == CGImage.typeID {
    let image = laser.contents as! CGImage
    let width = image.width, height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let space = CGColorSpaceCreateDeviceRGB()
    if let ctx = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                           bytesPerRow: width * 4, space: space,
                           bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var lit = 0
        for index in stride(from: 3, to: pixels.count, by: 4) where pixels[index] > 8 {
            lit += 1
        }
        print("  picture is \(width)x\(height), \(lit) pixels of it are not transparent")
    }
} else {
    print("  contents is not an image: \(String(describing: laser.contents))")
}

let before = laser.position
warp(to: NSPoint(x: middle.x + 180, y: middle.y - 90))
settle(0.3)
print("  followed the pointer: \(laser.position != before) (\(before) -> \(laser.position))")
print("  where the pointer is, in the view: "
      + "\(view.convert(panel.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil))")

// The trail is the half of a laser that a room watching a screen actually reads.
print("  trail marks alive before moving: \(view.laserTrail.count)")
// Spaced in real time, because the marks are deliberately throttled: a tight loop would
// only ever earn one of them.
for step in 0...11 {
    let point = NSPoint(x: middle.x + CGFloat(step) * 7, y: middle.y + sin(Double(step) / 3) * 40)
    view.markTrail(at: point)
    settle(0.035)
}
print("  after sweeping the pointer for \(Int(0.035 * 12 * 1000))ms: \(view.laserTrail.count)")
settle(LaserDot.trailLife + 0.2)
view.markTrail(at: middle)
print("  and after their life runs out: \(view.laserTrail.count) (one is the new mark)")

print("")
print("=== the wheel and the cursor ===")
tools.select(tool: .pen)
settle()
let overlayCursor = PointerCursor.cursor(for: tools)
var closed = false
let wheel = WheelPanel()
wheel.onClose = { closed = true }
wheel.open(OverlayController.toolWheel, cursor: overlayCursor) { _ in }
settle(0.4)
print("  wheel open: the app's cursor is \(describeCursor(NSCursor.current)), "
      + "ours is \(describeCursor(overlayCursor)), same: \(NSCursor.current === overlayCursor)")
wheel.release()
settle(0.3)
print("  wheel closed, onClose fired: \(closed)")
view.refreshCursorRects()
view.applyDrawingCursor()
print("  after the overlay takes it back: same: \(NSCursor.current === overlayCursor)")

print("")
print("=== the cursor ===")
tools.select(tool: .pen)
settle()

func describe(_ cursor: NSCursor?) -> String {
    guard let cursor else { return "none" }
    let size = cursor.image.size
    return String(format: "%.0fx%.0f", size.width, size.height)
}

func report(_ what: String) {
    let ours = PointerCursor.cursor(for: tools)
    let current = NSCursor.current
    print("  \(what): ours \(describe(ours)), the app's current is \(describe(current)), "
          + "same object: \(current === ours)")
}

warp(to: middle)
settle(0.4)
report("after a warp onto the panel")

// The drag the user is doing when the arrow turns up.
func event(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent {
    NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                       windowNumber: panel.windowNumber, context: nil,
                       eventNumber: 0, clickCount: 1, pressure: 1)!
}

view.mouseDown(with: event(.leftMouseDown, middle))
for step in 1...20 {
    view.mouseDragged(with: event(.leftMouseDragged,
                                  NSPoint(x: middle.x + CGFloat(step) * 6, y: middle.y)))
}
report("in the middle of a drag")
view.mouseUp(with: event(.leftMouseUp, NSPoint(x: middle.x + 120, y: middle.y)))
report("after the drag")

tools.stepWidth(by: 2)
settle()
report("after changing the width")

tools.select(tool: .eraser)
settle()
report("after changing the tool")

CGWarpMouseCursorPosition(CGPoint(x: home.x, y: screen.frame.maxY - home.y))
panel.close()
print("")
print("done")
