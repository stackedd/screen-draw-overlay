import AppKit

// Every cursor, on a light background and a dark one, rendered so somebody can look at it.
//
// Not a pass or a fail, so it is not in run.sh. The behaviour suite can check that the hot
// spot is where the ink lands; it cannot tell whether a pen looks like a pen, whether the
// colour reads on a white slide, or whether the thing is simply ugly - which is the report
// that led to this file existing.
//
//     python3 Testing/make_probe.py cursor CURSOR \
//       && swift build --package-path .build/testing/cursor -c release \
//       && OUT=/tmp/cursor.png .build/testing/cursor/.build/release/CURSOR

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let tools = ToolSettings()
let shown: [(DrawingTool, Int)] = [
    (.pen, 0), (.pen, 4), (.highlighter, 2), (.line, 3),
    (.arrow, 0), (.rectangle, 4), (.ellipse, 1), (.eraser, 0)
]

let cell = 78.0
let scale: CGFloat = 2
let width = cell * Double(shown.count)
let height = cell * 2 + 26

let sheet = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * scale),
                             pixelsHigh: Int(height * scale), bitsPerSample: 8, samplesPerPixel: 4,
                             hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                             bytesPerRow: 0, bitsPerPixel: 0)!
sheet.size = NSSize(width: width, height: height)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: sheet)

NSColor(white: 0.93, alpha: 1).setFill()
NSRect(x: 0, y: cell, width: width, height: cell).fill()
NSColor(white: 0.13, alpha: 1).setFill()
NSRect(x: 0, y: 0, width: width, height: cell).fill()
NSColor(white: 0.5, alpha: 1).setFill()
NSRect(x: 0, y: cell * 2, width: width, height: 26).fill()

for (index, entry) in shown.enumerated() {
    tools.select(tool: entry.0)
    tools.selectColor(entry.1)
    let cursor = PointerCursor.cursor(for: tools)
    let size = cursor.image.size
    let x = Double(index) * cell + cell / 2

    for (row, ink) in [(1, NSColor.black), (0, NSColor.white)] {
        // Drawn with the hot spot on a cross hair, so it is obvious where the ink lands.
        let centre = NSPoint(x: x, y: Double(row) * cell + cell / 2)
        let mark = NSBezierPath()
        mark.move(to: NSPoint(x: centre.x - 26, y: centre.y))
        mark.line(to: NSPoint(x: centre.x + 26, y: centre.y))
        mark.move(to: NSPoint(x: centre.x, y: centre.y - 26))
        mark.line(to: NSPoint(x: centre.x, y: centre.y + 26))
        ink.withAlphaComponent(0.18).setStroke()
        mark.lineWidth = 1
        mark.stroke()

        cursor.image.draw(in: NSRect(x: centre.x - size.width / 2, y: centre.y - size.height / 2,
                                     width: size.width, height: size.height))
    }

    NSAttributedString(string: entry.0.label, attributes: [
        .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .medium),
        .foregroundColor: NSColor.white
    ]).draw(at: NSPoint(x: x - 20, y: cell * 2 + 8))
}
NSGraphicsContext.restoreGraphicsState()

let out = ProcessInfo.processInfo.environment["OUT"] ?? "cursor.png"
try! sheet.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
