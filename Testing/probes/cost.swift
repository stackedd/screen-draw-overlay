import AppKit
import Carbon
import Foundation

// What this measures, and what it cannot.
//
// An event goes into the real DrawingView and every rectangle the view asks to have
// repainted is painted, through the app's own draw(_:), into an offscreen bitmap at a
// Retina backing scale. So the number here is the cost of *painting*: path flattening,
// rasterisation, text layout, the lot.
//
// It is not the whole bill. Updating the window's backing store and the window server's
// compositing of a full screen transparent surface happen nowhere in this process, and
// docs/ARCHITECTURE.md puts that at about 0.4% CPU per repaint on its own. This suite
// exists to answer one question the CPU percentages cannot: does the cost of painting grow
// with how much ink is on screen, or is it flat? Everything else is the manual measurement.
//
// Two dirty-region models are run side by side, because which one AppKit uses decides
// whether looking at the real dirty region instead of its bounding box is worth anything:
//
//   rects  - each invalidated rectangle painted on its own
//   union  - one paint per event covering the bounding box of them all
//
// A layer-backed view is believed to get the union. If the two columns are far apart, that
// belief is worth money.

// The ink is painted through a layer of its own now, so this is where a repaint is asked
// for and where the suite watches for one that covers everything.
final class Rec: DrawingView {
    var invalidations: [NSRect] = []
    var fullInvalidations = 0
    override func invalidateInk(_ r: NSRect) { invalidations.append(r) }
    override func invalidateAllInk() { fullInvalidations += 1; invalidations.append(bounds) }
}

let scale = Int(ProcessInfo.processInfo.environment["SCALE"] ?? "2") ?? 2
// A built-in Retina display, in points.
let size = NSSize(width: 1512, height: 982)
let frame = NSRect(origin: .zero, size: size)

func milliseconds() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000 }

final class Bench {
    enum Model { case rects, union }

    let model: Model
    let tools = ToolSettings()
    let view: Rec
    let window: NSWindow
    let rep: NSBitmapImageRep
    var paints = 0
    var paintedArea: Double = 0

    init(_ model: Model) {
        self.model = model
        view = Rec(frame: frame, indicatorBounds: frame, showsIndicator: true, tools: tools)
        window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        let v = view
        tools.onChange = { v.toolSettingsChanged() }
        rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width) * scale,
                               pixelsHigh: Int(size.height) * scale, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        view.invalidations.removeAll()
    }

    func paint() {
        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return }

        var regions: [NSRect] = []
        switch model {
        case .rects:
            regions = view.invalidations
        case .union:
            if let first = view.invalidations.first {
                regions = [view.invalidations.dropFirst().reduce(first) { $0.union($1) }]
            }
        }
        view.invalidations.removeAll()

        for region in regions {
            let dirty = region.integral.intersection(frame)
            guard !dirty.isEmpty else { continue }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = ctx
            ctx.cgContext.clip(to: dirty)
            ctx.cgContext.clear(dirty)
            view.drawInk(in: dirty)
            NSGraphicsContext.restoreGraphicsState()
            paints += 1
            paintedArea += Double(dirty.width) * Double(dirty.height)
        }
    }

    func discardInvalidations() { view.invalidations.removeAll() }

    func event(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                           windowNumber: window.windowNumber, context: nil,
                           eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    // Lays ink down without timing it: the setup for "how much is already on screen".
    func prefill(strokes count: Int) {
        guard count > 0 else { return }
        for index in 0..<count {
            let row = CGFloat(index % 25)
            let column = CGFloat(index / 25)
            let start = NSPoint(x: 80 + column * 55, y: 60 + row * 36)
            view.mouseDown(with: event(.leftMouseDown, start))
            for step in 1...20 {
                let t = CGFloat(step) / 20
                view.mouseDragged(with: event(.leftMouseDragged,
                                              NSPoint(x: start.x + t * 300,
                                                      y: start.y + sin(t * 6) * 14)))
            }
            view.mouseUp(with: event(.leftMouseUp, NSPoint(x: start.x + 300, y: start.y)))
        }
        discardInvalidations()
    }
}

// A hand-drawn line that stays on screen: serpentine rows about 2.5pt apart, wiggling, so
// it overlaps itself the way a real scribble does.
func scribble(_ index: Int) -> NSPoint {
    let step: CGFloat = 2.5
    let perRow = Int((size.width - 160) / step)
    let row = index / perRow
    let column = index % perRow
    let x = 80 + CGFloat(row % 2 == 0 ? column : perRow - 1 - column) * step
    let y = 80 + CGFloat(row % 18) * 46 + sin(CGFloat(index) * 0.35) * 13
    return NSPoint(x: x, y: y)
}

func mean(_ values: ArraySlice<Double>) -> Double {
    values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
}

func line(_ text: String) { print(text) }

// MARK: - Sweep 1: one unbroken drag on an empty canvas
//
// If the cost per event climbs with the point index, redrawing the whole in-progress path
// on every mouse move is quadratic and the last part of a long line is paid for over and
// over. Flat means it is not.

line("== 1. one unbroken stroke, empty canvas (per-event ms: first tenth -> last tenth)")
for model in [Bench.Model.rects, .union] {
    for points in [100, 500, 2000, 5000] {
        let bench = Bench(model)
        bench.view.mouseDown(with: bench.event(.leftMouseDown, scribble(0)))
        bench.paint()

        var times: [Double] = []
        times.reserveCapacity(points)
        for index in 1...points {
            let start = milliseconds()
            bench.view.mouseDragged(with: bench.event(.leftMouseDragged, scribble(index)))
            bench.paint()
            times.append(milliseconds() - start)
        }
        bench.view.mouseUp(with: bench.event(.leftMouseUp, scribble(points)))
        bench.paint()

        let tenth = max(1, points / 10)
        let first = mean(times[0..<tenth])
        let last = mean(times[(points - tenth)...])
        line(String(format: "   %-5@ %5d pts   first %.3f   last %.3f   x%.1f   total %.0f ms",
                    model == .rects ? "rects" : "union" as NSString, points, first, last,
                    first > 0 ? last / first : 0, times.reduce(0, +)))
    }
}

// MARK: - Sweep 2: moving the pointer, drawing nothing
//
// The crosshair invalidates where it left and where it arrived. Every stroke those rects
// touch is redrawn, so a busy canvas can cost CPU while the user is only moving the mouse.

line("")
line("== 2. pointer moves only, nothing drawn (per-event ms)")
for model in [Bench.Model.rects, .union] {
    for existing in [0, 50, 200] {
        for (speedName, speed) in [("slow 8pt", CGFloat(8)), ("fast 60pt", CGFloat(60))] {
            let bench = Bench(model)
            bench.prefill(strokes: existing)
            var x: CGFloat = 100
            var y: CGFloat = 500
            var times: [Double] = []
            for _ in 0..<200 {
                x += speed
                y += speed * 0.35
                if x > size.width - 100 { x = 100 }
                if y > size.height - 100 { y = 100 }
                let start = milliseconds()
                bench.view.mouseMoved(with: bench.event(.mouseMoved, NSPoint(x: x, y: y)))
                bench.paint()
                times.append(milliseconds() - start)
            }
            line(String(format: "   %-5@ %3d strokes  %-9@  %.3f ms/move   %d paints   %.1f Mpx painted",
                        model == .rects ? "rects" : "union" as NSString, existing,
                        speedName as NSString, mean(times[0...]), bench.paints,
                        bench.paintedArea / 1_000_000))
        }
    }
}

// MARK: - Sweep 3: the same short drag on a canvas that already holds ink
//
// This is the one that answers the reported symptom directly: does drawing get more
// expensive as the screen fills up?

line("")
line("== 3. a 60-point drag, canvas already holding ink (per-event ms)")
for model in [Bench.Model.rects, .union] {
    for existing in [0, 50, 200] {
        let bench = Bench(model)
        bench.prefill(strokes: existing)
        bench.view.mouseDown(with: bench.event(.leftMouseDown, NSPoint(x: 200, y: 700)))
        bench.paint()
        var times: [Double] = []
        for index in 1...60 {
            let point = NSPoint(x: 200 + CGFloat(index) * 18, y: 700 + sin(CGFloat(index) * 0.4) * 40)
            let start = milliseconds()
            bench.view.mouseDragged(with: bench.event(.leftMouseDragged, point))
            bench.paint()
            times.append(milliseconds() - start)
        }
        bench.view.mouseUp(with: bench.event(.leftMouseUp, NSPoint(x: 1280, y: 700)))
        bench.paint()
        line(String(format: "   %-5@ %3d strokes   %.3f ms/move   %.1f Mpx painted",
                    model == .rects ? "rects" : "union" as NSString, existing,
                    mean(times[0...]), bench.paintedArea / 1_000_000))
    }
}

// MARK: - Sweep 4: a fade tick
//
// Kept as a guard rather than as a measurement. A fade is not painted any more - each
// temporary stroke fades itself, on a layer - so this should paint nothing at all. If it
// starts painting again, something has put the fade back on the repaint path, and the cost
// of that is in docs/DECISIONS.md.

line("")
line("== 4. one fade tick, 50 temporary strokes (should paint nothing)")
for model in [Bench.Model.rects, .union] {
    let bench = Bench(model)
    bench.prefill(strokes: 50)
    let backdated = Date().addingTimeInterval(-Stroke.fadeDuration * 0.7)
    bench.view.canvas.strokes = bench.view.canvas.strokes.map {
        Stroke(points: $0.points, path: $0.path, color: $0.color, width: $0.width,
               style: $0.style, createdAt: backdated)
    }
    bench.discardInvalidations()

    var times: [Double] = []
    for _ in 0..<15 {
        let start = milliseconds()
        bench.view.advanceFade()
        bench.paint()
        times.append(milliseconds() - start)
    }
    line(String(format: "   %-5@ %.3f ms/tick   %.1f Mpx painted",
                model == .rects ? "rects" : "union" as NSString,
                mean(times[0...]), bench.paintedArea / 1_000_000))
}

line("")
line("   Painting only. The backing store update and the window server's compositing of a")
line("   full screen transparent surface are not in these numbers - measure those on the")
line("   real app (docs/ARCHITECTURE.md).")
