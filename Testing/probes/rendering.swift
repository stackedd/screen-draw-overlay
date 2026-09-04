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

// And a box taken out of the middle of things, which cuts several strokes at once and leaves
// the pieces where they were.
set { tools.select(tool: .eraseArea) }
drag(from: NSPoint(x: 150, y: 330), to: NSPoint(x: 320, y: 400), steps: 8)

let orderBefore = view.capturedStrokes().map { "\(Int($0.points.first?.x ?? 0)),\(Int($0.points.first?.y ?? 0))" }
set { view.undo() }
set { view.redo() }
let orderAfter = view.capturedStrokes().map { "\(Int($0.points.first?.x ?? 0)),\(Int($0.points.first?.y ?? 0))" }
if orderBefore != orderAfter {
    print("      undo+redo changed the order:")
    print("        before \(orderBefore.joined(separator: " "))")
    print("        after  \(orderAfter.joined(separator: " "))")
}


let full = bitmap()
render(full, frame)

let bytes = full.bytesPerRow * full.pixelsHigh
let a = incremental.bitmapData!, b = full.bitmapData!
var diff = 0, maxDelta = 0
// Where they differ, not just how much: a count says something is wrong and a box says what.
var box: NSRect?
for i in 0..<bytes where a[i] != b[i] {
    diff += 1
    maxDelta = max(maxDelta, abs(Int(a[i]) - Int(b[i])))

    let pixel = i / 4
    let x = CGFloat(pixel % full.pixelsWide) / CGFloat(scale)
    let y = CGFloat(pixel / full.pixelsWide) / CGFloat(scale)
    let point = NSRect(x: x, y: y, width: 1, height: 1)
    box = box.map { $0.union(point) } ?? point
}

if let box {
    print("      differences lie in \(Int(box.minX)),\(Int(box.minY)) "
          + "\(Int(box.width))x\(Int(box.height))")

    // Which marks are there at all, in view coordinates: the box came from bitmap rows and
    // this is the only way to say what it is sitting on.
    let inView = NSRect(x: box.minX, y: size.height - box.maxY,
                        width: box.width, height: box.height)
    print("      which is \(Int(inView.minX)),\(Int(inView.minY)) on the canvas")
    for stroke in view.capturedStrokes() where stroke.repaintBounds.intersects(inView) {
        print("        touching: \(stroke.style) w\(Int(stroke.width)) "
              + "bounds \(Int(stroke.repaintBounds.minX)),\(Int(stroke.repaintBounds.minY)) "
              + "\(Int(stroke.repaintBounds.width))x\(Int(stroke.repaintBounds.height))")
    }

    // And, if asked, the two of them side by side with the differences marked, because a
    // count and a box say something is wrong and a picture says what.
    if let out = ProcessInfo.processInfo.environment["DIFF"] {
        let marked = NSBitmapImageRep(bitmapDataPlanes: nil,
                                      pixelsWide: full.pixelsWide, pixelsHigh: full.pixelsHigh,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB,
                                      bytesPerRow: full.bytesPerRow, bitsPerPixel: 32)!
        let marks = marked.bitmapData!
        for i in 0..<bytes {
            marks[i] = b[i]
        }

        for i in stride(from: 0, to: bytes, by: 4) where
            a[i] != b[i] || a[i + 1] != b[i + 1] || a[i + 2] != b[i + 2] || a[i + 3] != b[i + 3] {
            marks[i] = 255
            marks[i + 1] = 0
            marks[i + 2] = 0
            marks[i + 3] = 255
        }

        try! marked.representation(using: .png, properties: [:])!
            .write(to: URL(fileURLWithPath: out))
        print("      wrote \(out): the single pass, with every differing pixel in red")

        // And the two of them magnified, side by side, over the box where they differ. A
        // difference of four parts in 255 across a 29x6 band is not visible at size, and
        // "look at it" is the only way to tell a missing cap from a join drawn twice.
        let margin: CGFloat = 6
        let crop = box.insetBy(dx: -margin, dy: -margin)
        let zoom: CGFloat = 12
        let sheet = Picture.drawn(size: NSSize(width: crop.width * zoom * 2 + 24,
                                               height: crop.height * zoom), scale: 1) {
            NSColor.white.setFill()
            NSRect(x: 0, y: 0, width: crop.width * zoom * 2 + 24, height: crop.height * zoom).fill()
            NSGraphicsContext.current?.imageInterpolation = .none

            for (offset, rep) in [(CGFloat(0), incremental), (crop.width * zoom + 24, full)] {
                // The box came from bitmap rows, which count from the top; a rep draws from
                // the bottom like everything else here.
                let from = NSRect(x: crop.minX * CGFloat(scale),
                                  y: CGFloat(rep.pixelsHigh) - crop.maxY * CGFloat(scale),
                                  width: crop.width * CGFloat(scale),
                                  height: crop.height * CGFloat(scale))
                rep.draw(in: NSRect(x: offset, y: 0, width: crop.width * zoom,
                                    height: crop.height * zoom),
                         from: from, operation: .sourceOver, fraction: 1,
                         respectFlipped: true, hints: [.interpolation: NSImageInterpolation.none])
            }
        }

        let zoomed = out.replacingOccurrences(of: ".png", with: "-zoom.png")
        try! NSBitmapImageRep(cgImage: sheet!).representation(using: .png, properties: [:])!
            .write(to: URL(fileURLWithPath: zoomed))
        print("      wrote \(zoomed): incremental on the left, single pass on the right")
    }
}
print("moved=\(moved ? "yes" : "NOTHING") strokes=\(view.capturedStrokes().count) scale=\(scale)x fullInkInvalidations=\(view.fullInvalidations - fullBefore) differingBytes=\(diff)/\(bytes) maxDelta=\(maxDelta)")
