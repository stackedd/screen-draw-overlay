import AppKit
import Carbon

final class Rec: DrawingView {
    var invalidations: [NSRect] = []
    var fullInvalidations = 0
    override func setNeedsDisplay(_ r: NSRect) { invalidations.append(r); super.setNeedsDisplay(r) }
    override var needsDisplay: Bool {
        get { super.needsDisplay }
        set { if newValue { fullInvalidations += 1; invalidations.append(bounds) }; super.needsDisplay = newValue }
    }
}

let scale = Int(ProcessInfo.processInfo.environment["SCALE"] ?? "1") ?? 1
let size = NSSize(width: 900, height: 700)
let frame = NSRect(origin: .zero, size: size)
let tools = ToolSettings()
let view = Rec(frame: frame, indicatorBounds: frame, showsIndicator: true, tools: tools)
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
    view.draw(dirty)
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
func tap(_ code: Int, _ chars: String, _ flags: NSEvent.ModifierFlags = []) {
    view.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                        windowNumber: window.windowNumber, context: nil, characters: chars,
                                        charactersIgnoringModifiers: chars, isARepeat: false, keyCode: UInt16(code))!)
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

tap(kVK_ANSI_P, "p"); drag(from: NSPoint(x: 60, y: 80), to: NSPoint(x: 800, y: 140))
tap(kVK_ANSI_3, "3"); tap(kVK_ANSI_L, "l"); drag(from: NSPoint(x: 60, y: 200), to: NSPoint(x: 800, y: 260))
tap(kVK_ANSI_5, "5"); tap(kVK_ANSI_A, "a"); drag(from: NSPoint(x: 60, y: 320), to: NSPoint(x: 800, y: 380))
tap(kVK_ANSI_4, "4"); tap(kVK_ANSI_R, "r"); drag(from: NSPoint(x: 120, y: 420), to: NSPoint(x: 700, y: 560))
tap(kVK_ANSI_2, "2"); tap(kVK_ANSI_O, "o"); drag(from: NSPoint(x: 200, y: 430), to: NSPoint(x: 620, y: 550))
tap(kVK_ANSI_H, "h"); drag(from: NSPoint(x: 60, y: 620), to: NSPoint(x: 800, y: 620))
tap(kVK_ANSI_E, "e"); drag(from: NSPoint(x: 400, y: 230), to: NSPoint(x: 405, y: 230), steps: 4)
tap(kVK_ANSI_Z, "z", .command)
tap(kVK_ANSI_Z, "z", [.command, .shift])

let full = bitmap()
render(full, frame)

let bytes = full.bytesPerRow * full.pixelsHigh
let a = incremental.bitmapData!, b = full.bitmapData!
var diff = 0, maxDelta = 0
for i in 0..<bytes where a[i] != b[i] { diff += 1; maxDelta = max(maxDelta, abs(Int(a[i]) - Int(b[i]))) }
print("strokes=\(view.capturedStrokes().count) scale=\(scale)x fullViewInvalidations=\(view.fullInvalidations - fullBefore) differingBytes=\(diff)/\(bytes) maxDelta=\(maxDelta)")
