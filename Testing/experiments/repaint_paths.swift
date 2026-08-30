// What one repaint of a full screen transparent overlay costs, and who pays for it.
//
// This is the measurement the offscreen suites cannot make. They time painting; almost all
// of the bill turned out to be somewhere else, and finding out where needed a real window
// on a real screen. Run it by hand:
//
//     swiftc -O -o /tmp/repaint_paths Testing/experiments/repaint_paths.swift && /tmp/repaint_paths
//
// It puts a transparent panel over the screen for about a minute. The panel sets
// ignoresMouseEvents, so it cannot take a click from anyone while it is up.
//
// The numbers it produced on 2026-08-30 are in docs/ARCHITECTURE.md. Re-run it before
// contradicting them.

import AppKit
import QuartzCore

final class ViewPainter: NSView {
    var draws = 0
    let sublayer = CALayer()
    override var isOpaque: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        draws += 1
        paint(NSGraphicsContext.current!.cgContext, in: dirtyRect)
    }
}

final class LayerPainter: NSObject, CALayerDelegate {
    var draws = 0
    func draw(_ layer: CALayer, in ctx: CGContext) {
        draws += 1
        paint(ctx, in: ctx.boundingBoxOfClipPath)
    }
    // No implicit animation, the same as a pointer layer would need.
    func action(for layer: CALayer, forKey event: String) -> CAAction? { NSNull() }
}

// Deliberately trivial: this measures the cost of *asking* for a repaint, so whatever is
// painted has to be small enough not to matter.
func paint(_ ctx: CGContext, in box: CGRect) {
    ctx.setStrokeColor(NSColor.systemRed.withAlphaComponent(0.35).cgColor)
    ctx.setLineWidth(3)
    ctx.move(to: CGPoint(x: box.minX, y: box.minY))
    ctx.addLine(to: CGPoint(x: box.maxX, y: box.maxY))
    ctx.strokePath()
}

func cpuSeconds() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
         + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
}

// WindowServer's own CPU time, so the bill can be split between this process and the
// compositor. ps reports hundredths, which is enough over an eight second run.
func windowServerCPUSeconds() -> Double {
    func output(_ path: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        try? process.run()
        process.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    let pid = output("/usr/bin/pgrep", ["-x", "WindowServer"])
    guard !pid.isEmpty else { return 0 }
    let parts = output("/bin/ps", ["-o", "time=", "-p", pid]).split(separator: ":").map { Double($0) ?? 0 }
    switch parts.count {
    case 2: return parts[0] * 60 + parts[1]
    case 3: return parts[0] * 3600 + parts[1] * 60 + parts[2]
    default: return 0
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let screen = NSScreen.main!
let frame = screen.frame
let view = ViewPainter(frame: NSRect(origin: .zero, size: frame.size))
view.wantsLayer = true

let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                    backing: .buffered, defer: false)
panel.isOpaque = false
panel.backgroundColor = .clear
panel.hasShadow = false
panel.level = .popUpMenu
panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
// This is a measurement, not an overlay. It must never take someone's click.
panel.ignoresMouseEvents = true
panel.contentView = view
panel.orderFront(nil)

let painter = LayerPainter()
let inkLayer = CALayer()
inkLayer.frame = NSRect(origin: .zero, size: frame.size)
inkLayer.delegate = painter
inkLayer.contentsScale = screen.backingScaleFactor
view.layer!.addSublayer(inkLayer)

view.sublayer.frame = NSRect(x: 0, y: 0, width: 26, height: 26)
view.sublayer.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.35).cgColor
view.sublayer.actions = ["position": NSNull()]
view.layer!.addSublayer(view.sublayer)

let seconds = 8.0
print(String(format: "%.0fx%.0f pt at %.0fx backing, panel at level %d, %.0fs per run",
             frame.width, frame.height, screen.backingScaleFactor, panel.level.rawValue, seconds))
print("CPU% is of one core.")
print("")
print("  what is asked for                              rate  repaints   self   WindowServer")

func run(_ name: String, rate: Double, reset: () -> Void, draws: () -> Int,
         body: @escaping (Int) -> Void) {
    // Settle first, so the previous run's work is not billed to this one.
    RunLoop.current.run(until: Date().addingTimeInterval(0.7))
    reset()
    let selfBefore = cpuSeconds()
    let serverBefore = windowServerCPUSeconds()
    let started = Date()

    var tick = 0
    let timer = Timer(timeInterval: rate > 0 ? 1.0 / rate : seconds, repeats: true) { _ in
        body(tick)
        tick += 1
    }
    RunLoop.current.add(timer, forMode: .common)
    RunLoop.current.run(until: started.addingTimeInterval(seconds))
    timer.invalidate()

    let elapsed = Date().timeIntervalSince(started)
    print(String(format: "  %-44@ %4.0f     %5d  %5.1f%%         %5.1f%%",
                 name as NSString, rate, draws(),
                 (cpuSeconds() - selfBefore) / elapsed * 100,
                 (windowServerCPUSeconds() - serverBefore) / elapsed * 100))
}

func small(_ tick: Int) -> NSRect { NSRect(x: 200 + CGFloat(tick % 300), y: 300, width: 40, height: 40) }
func large(_ tick: Int) -> NSRect { NSRect(x: 200 + CGFloat(tick % 300), y: 300, width: 400, height: 400) }
// The whole screen, which is what a fade's union region comes to.
func everything(_ tick: Int) -> NSRect { view.bounds.insetBy(dx: CGFloat(tick % 3), dy: 0) }

let viewReset = { view.draws = 0 }
let viewDraws = { view.draws }
let layerReset = { painter.draws = 0 }
let layerDraws = { painter.draws }

run("nothing at all", rate: 0, reset: viewReset, draws: viewDraws) { _ in }
run("NSView.setNeedsDisplay, 40x40", rate: 60, reset: viewReset, draws: viewDraws) {
    view.setNeedsDisplay(small($0))
}
run("NSView.setNeedsDisplay, 400x400", rate: 60, reset: viewReset, draws: viewDraws) {
    view.setNeedsDisplay(large($0))
}
run("NSView.setNeedsDisplay, 40x40", rate: 120, reset: viewReset, draws: viewDraws) {
    view.setNeedsDisplay(small($0))
}
run("CALayer.setNeedsDisplay, 40x40", rate: 60, reset: layerReset, draws: layerDraws) {
    inkLayer.setNeedsDisplay(small($0))
}
run("CALayer.setNeedsDisplay, 40x40", rate: 120, reset: layerReset, draws: layerDraws) {
    inkLayer.setNeedsDisplay(small($0))
}
run("CALayer.setNeedsDisplay, 400x400", rate: 60, reset: layerReset, draws: layerDraws) {
    inkLayer.setNeedsDisplay(large($0))
}
run("CALayer.setNeedsDisplay, whole screen", rate: 60, reset: layerReset, draws: layerDraws) {
    inkLayer.setNeedsDisplay(everything($0))
}
run("CALayer.setNeedsDisplay, whole screen", rate: 15, reset: layerReset, draws: layerDraws) {
    inkLayer.setNeedsDisplay(everything($0))
}
run("NSView.setNeedsDisplay, whole screen", rate: 15, reset: viewReset, draws: viewDraws) {
    view.setNeedsDisplay(everything($0))
}
run("moving a sublayer, no repaint", rate: 60, reset: layerReset, draws: layerDraws) {
    view.sublayer.position = CGPoint(x: 200 + CGFloat($0 % 300), y: 300)
}
run("moving a sublayer, no repaint", rate: 120, reset: layerReset, draws: layerDraws) {
    view.sublayer.position = CGPoint(x: 200 + CGFloat($0 % 300), y: 300)
}

panel.orderOut(nil)
print("")
print("Read it as: the bill is the number of repaints, not their area; a repaint asked for")
print("through NSView costs several times one asked for through a CALayer; and moving a")
print("layer costs almost nothing because it is not a repaint at all.")
