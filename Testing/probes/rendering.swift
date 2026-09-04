import AppKit
import Carbon

// The ink is painted through a layer of its own now, so this is where a repaint is asked
// for and where the suite watches for one that covers everything.
final class Rec: DrawingView {
    var invalidations: [NSRect] = []
    var fullInvalidations = 0
    override func invalidateInk(_ r: NSRect) { invalidations.append(r) }
    override func invalidateAllInk() { fullInvalidations += 1; invalidations.append(bounds) }
}

let scale = Int(ProcessInfo.processInfo.environment["SCALE"] ?? "1") ?? 1
let size = NSSize(width: 900, height: 700)
let frame = NSRect(origin: .zero, size: size)
let tools = ToolSettings()
let view = Rec(frame: frame, badgeBounds: frame, showsBadge: true, tools: tools)
let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
window.contentView = view
tools.onChange = { view.toolSettingsChanged() }

func bitmap() -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width) * scale,
                               pixelsHigh: Int(size.height) * scale, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    return rep
}
func render(_ rep: NSBitmapImageRep, _ dirty: NSRect) {
    guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return }
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = ctx
    ctx.cgContext.clip(to: dirty); ctx.cgContext.clear(dirty)
    view.drawInk(in: dirty)
    NSGraphicsContext.restoreGraphicsState()
}
let incremental = bitmap()
render(incremental, frame)
view.invalidations.removeAll()
let fullBefore = view.fullInvalidations
func flush() {
    for r in view.invalidations { render(incremental, r.integral.intersection(frame)) }
    view.invalidations.removeAll()
}
func mouse(_ t: NSEvent.EventType, _ p: NSPoint, shift: Bool = false) -> NSEvent {
    NSEvent.mouseEvent(with: t, location: p, modifierFlags: shift ? .shift : [], timestamp: 0,
                       windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
}
// The tools used to be changed with bare keys; they are wheels now (docs/DECISIONS.md 30), so
// this session asks the same things of the same objects and paints what comes back.
func set(_ change: () -> Void) {
    change()
    flush()
}
func drag(from a: NSPoint, to b: NSPoint, steps: Int = 24, shift: Bool = false) {
    view.mouseDown(with: mouse(.leftMouseDown, a, shift: shift)); flush()
    for i in 1...steps {
        let t = CGFloat(i) / CGFloat(steps)
        view.mouseDragged(with: mouse(.leftMouseDragged, NSPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t), shift: shift)); flush()
    }
    view.mouseUp(with: mouse(.leftMouseUp, b, shift: shift)); flush()
}

set { tools.select(tool: .pen) }; drag(from: NSPoint(x: 60, y: 80), to: NSPoint(x: 800, y: 140))
set { tools.selectColor(2) }; set { tools.select(tool: .line) }; drag(from: NSPoint(x: 60, y: 200), to: NSPoint(x: 800, y: 260))
set { tools.selectColor(4) }; set { tools.select(tool: .arrow) }; drag(from: NSPoint(x: 60, y: 320), to: NSPoint(x: 800, y: 380))
set { tools.selectColor(3) }; set { tools.select(tool: .rectangle) }; drag(from: NSPoint(x: 120, y: 420), to: NSPoint(x: 700, y: 560))
set { tools.selectColor(1) }; set { tools.select(tool: .ellipse) }; drag(from: NSPoint(x: 200, y: 430), to: NSPoint(x: 620, y: 550))
set { tools.select(tool: .highlighter) }; drag(from: NSPoint(x: 60, y: 620), to: NSPoint(x: 800, y: 620))
// The marker at its widest, because the rectangle a stroke asks to have repainted is now its
// own reach rather than a whole width either side - and a 56pt line is where being one point
// too mean would show.
set { tools.selectWidth(ToolSettings.widths.count - 1) }
drag(from: NSPoint(x: 80, y: 680), to: NSPoint(x: 780, y: 660), steps: 30)
set { tools.selectWidth(2) }

// Typed, not dragged: a caret goes down, letters go in one at a time, and Return finishes it.
// Text is painted from a string rather than from a path, so it is the one thing on this canvas
// whose incremental repaint could disagree with a full one for a reason none of the others
// could have.
func type(_ characters: String, at point: NSPoint) {
    view.mouseDown(with: mouse(.leftMouseDown, point)); flush()
    view.mouseUp(with: mouse(.leftMouseUp, point)); flush()
    for character in characters {
        view.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                            timestamp: 0, windowNumber: 0, context: nil,
                                            characters: String(character),
                                            charactersIgnoringModifiers: String(character),
                                            isARepeat: false, keyCode: 0)!)
        flush()
    }

    view.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                        timestamp: 0, windowNumber: 0, context: nil,
                                        characters: "\r", charactersIgnoringModifiers: "\r",
                                        isARepeat: false, keyCode: UInt16(kVK_Return))!)
    flush()
}

set { tools.selectColor(5) }; set { tools.select(tool: .text) }
type("Scrim", at: NSPoint(x: 620, y: 700))
// Moving something is the one edit that invalidates two rectangles for one mark - where it
// was and where it went - so it is the one most likely to leave a hole behind.
set { tools.select(tool: .move) }
let beforeMove = view.capturedStrokes().last?.points.first
drag(from: NSPoint(x: 620, y: 700), to: NSPoint(x: 500, y: 730), steps: 10)
let afterMove = view.capturedStrokes().last?.points.first
// Printed, because a move that grabbed nothing would leave this suite comparing a session
// that never moved anything and saying it agreed with itself.
let moved = beforeMove != nil && beforeMove != afterMove

set { tools.selectWidth(2) }
set { tools.select(tool: .eraser) }; drag(from: NSPoint(x: 400, y: 230), to: NSPoint(x: 405, y: 230), steps: 4)
set { view.undo() }
set { view.redo() }

let full = bitmap()
render(full, frame)

let bytes = full.bytesPerRow * full.pixelsHigh
let a = incremental.bitmapData!, b = full.bitmapData!
var diff = 0, maxDelta = 0
for i in 0..<bytes where a[i] != b[i] { diff += 1; maxDelta = max(maxDelta, abs(Int(a[i]) - Int(b[i]))) }
print("moved=\(moved ? "yes" : "NOTHING") strokes=\(view.capturedStrokes().count) scale=\(scale)x fullInkInvalidations=\(view.fullInvalidations - fullBefore) differingBytes=\(diff)/\(bytes) maxDelta=\(maxDelta)")
