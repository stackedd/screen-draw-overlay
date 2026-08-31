import AppKit

// The eraser, rendered so somebody can look at it.
//
// Not a pass or a fail, so it is not in run.sh. Counting strokes proves the eraser cut
// something; it cannot show that the hole is the size of the eraser, that a shape comes
// apart the way a line does, or that no crumbs are left sitting in the gap. Every one of
// those has been wrong at least once.
//
//     python3 Testing/make_probe.py eraser ERASER \
//       && swift build --package-path .build/testing/eraser -c release \
//       && OUT=/tmp/eraser.png .build/testing/eraser/.build/release/ERASER

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let width = 560.0, rowHeight = 170.0
let scale: CGFloat = 2

func scribble(into canvas: Canvas, with tools: ToolSettings) {
    canvas.beginStroke(at: NSPoint(x: 30, y: 85), with: tools)
    for step in 1...110 {
        canvas.extendStroke(to: NSPoint(x: 30 + Double(step) * 3.6,
                                        y: 85 + sin(Double(step) * 0.23) * 38),
                            shiftHeld: false, with: tools)
    }
    canvas.finishStroke()
}

func rectangle(into canvas: Canvas, with tools: ToolSettings) {
    tools.select(tool: .rectangle)
    canvas.beginStroke(at: NSPoint(x: 330, y: 40), with: tools)
    canvas.extendStroke(to: NSPoint(x: 520, y: 130), shiftHeld: false, with: tools)
    canvas.finishStroke()
    tools.select(tool: .pen)
}

func row(_ label: String, radius: CGFloat?, sweep: Bool) -> NSBitmapImageRep {
    let tools = ToolSettings()
    tools.select(tool: .pen)
    tools.selectColor(0)
    let canvas = Canvas()
    scribble(into: canvas, with: tools)
    rectangle(into: canvas, with: tools)

    if let radius {
        canvas.beginErase(at: NSPoint(x: 150, y: 160))
        if sweep {
            // One event that jumps the whole way, which is what a quick hand produces.
            _ = canvas.erase(at: NSPoint(x: 210, y: 10), radius: radius)
            canvas.beginErase(at: NSPoint(x: 380, y: 160))
            _ = canvas.erase(at: NSPoint(x: 430, y: 10), radius: radius)
        } else {
            for step in 0...30 {
                _ = canvas.erase(at: NSPoint(x: 150 + Double(step) * 2, y: 160 - Double(step) * 5),
                                 radius: radius)
            }
            canvas.beginErase(at: NSPoint(x: 380, y: 160))
            for step in 0...30 {
                _ = canvas.erase(at: NSPoint(x: 380 + Double(step) * 1.6, y: 160 - Double(step) * 5),
                                 radius: radius)
            }
        }
        canvas.finishErase()
    }

    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * scale),
                              pixelsHigh: Int(rowHeight * scale), bitsPerSample: 8, samplesPerPixel: 4,
                              hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                              bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: width, height: rowHeight)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor(white: 0.16, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: width, height: rowHeight).fill()
    for stroke in canvas.strokes {
        stroke.renderColor.setStroke()
        stroke.path.stroke()
    }
    NSAttributedString(string: "\(label)   \(canvas.strokes.count) stroke(s)", attributes: [
        .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
        .foregroundColor: NSColor.white.withAlphaComponent(0.85)
    ]).draw(at: NSPoint(x: 14, y: rowHeight - 22))
    NSGraphicsContext.restoreGraphicsState()

    return rep
}

let rows = [row("before", radius: nil, sweep: false),
            row("slow drag, 12pt", radius: 12, sweep: false),
            row("slow drag, 30pt", radius: 30, sweep: false),
            row("one fast jump, 12pt", radius: 12, sweep: true)]

let sheet = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * scale),
                             pixelsHigh: Int(rowHeight * Double(rows.count) * scale),
                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                             colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
sheet.size = NSSize(width: width, height: rowHeight * Double(rows.count))
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: sheet)
for (index, drawn) in rows.enumerated() {
    drawn.draw(in: NSRect(x: 0, y: Double(rows.count - 1 - index) * rowHeight,
                          width: width, height: rowHeight))
}
NSGraphicsContext.restoreGraphicsState()

let out = ProcessInfo.processInfo.environment["OUT"] ?? "eraser.png"
try! sheet.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
