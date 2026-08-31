import AppKit

// The wheels, rendered to a PNG so somebody can look at them.
//
// Not a pass or a fail, so it is not in run.sh. It exists because the suites cannot catch
// the things that go wrong with a picture - blurry text, a swatch the same colour as the
// plate it sits on, a label too long for the hub it has to fit inside. The badge taught that
// lesson twice; this is the tool for not learning it a third time.
//
//     python3 Testing/make_probe.py wheel WHEEL \
//       && swift build --package-path .build/testing/wheel -c release \
//       && OUT=/tmp/wheel.png .build/testing/wheel/.build/release/WHEEL

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let side = Wheel.extent
let scale: CGFloat = 2
let panels: [(String, Wheel, Int?)] = [
    ("tools, nothing picked", OverlayController.toolWheel, nil),
    ("tools, eraser", OverlayController.toolWheel, 4),
    ("colours, blue", OverlayController.colourWheel, 4),
    ("widths, 6", OverlayController.widthWheel, 3)
]

let sheet = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(side * CGFloat(panels.count) * scale),
                             pixelsHigh: Int(side * scale), bitsPerSample: 8, samplesPerPixel: 4,
                             hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                             bytesPerRow: 0, bitsPerPixel: 0)!
sheet.size = NSSize(width: side * CGFloat(panels.count), height: side)

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: sheet)
let ctx = NSGraphicsContext.current!.cgContext

// Something with detail underneath, because the wheel is translucent and the question is
// whether it still reads over a busy screen.
NSGradient(colors: [NSColor(calibratedRed: 0.24, green: 0.30, blue: 0.42, alpha: 1),
                    NSColor(calibratedRed: 0.55, green: 0.42, blue: 0.38, alpha: 1)])!
    .draw(in: NSRect(origin: .zero, size: sheet.size), angle: 35)
NSColor.white.withAlphaComponent(0.3).setStroke()
for row in 0..<40 {
    let line = NSBezierPath()
    line.move(to: NSPoint(x: 0, y: CGFloat(row) * 15))
    line.line(to: NSPoint(x: sheet.size.width, y: CGFloat(row) * 15 + 40))
    line.lineWidth = 1
    line.stroke()
}

for (index, panel) in panels.enumerated() {
    let box = NSRect(x: CGFloat(index) * side, y: 0, width: side, height: side)
    panel.1.draw(in: ctx, bounds: box, highlighted: panel.2)
    NSAttributedString(string: panel.0, attributes: [
        .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .medium),
        .foregroundColor: NSColor.white.withAlphaComponent(0.9)
    ]).draw(at: NSPoint(x: box.minX + 14, y: 10))
}
NSGraphicsContext.restoreGraphicsState()

let out = ProcessInfo.processInfo.environment["OUT"] ?? "wheel.png"
try! sheet.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
