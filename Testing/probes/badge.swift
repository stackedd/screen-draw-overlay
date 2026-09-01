import AppKit

// The badge, in every mode, over a checkerboard so its edge and its transparency both show.
// Not a pass or a fail. It is here because the badge has been wrong twice in ways no count
// could see: once blurry, once with a swatch the same colour as the plate under it.
//
//     python3 Testing/make_probe.py badge BADGE \
//       && swift build --package-path .build/testing/badge -c release \
//       && OUT=/tmp/badge.png .build/testing/badge/.build/release/BADGE

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let scale: CGFloat = 2
let area = NSRect(x: 0, y: 0, width: 520, height: 120)

func made(_ configure: (ToolSettings, ModeBadge) -> Void) -> (CGImage, NSRect) {
    let tools = ToolSettings()
    tools.select(tool: .pen)
    tools.selectColor(0)
    if tools.drawsTemporaryInk { tools.toggleTemporaryInk() }
    let badge = ModeBadge(bounds: area, tools: tools)
    configure(tools, badge)
    let (image, frame) = badge.render(scale: scale)
    return (image!, frame)
}

var samples: [(String, CGImage, NSRect)] = []
var one = made { _, _ in }
samples.append(("pen, drawing", one.0, one.1))
one = made { tools, _ in tools.select(tool: .highlighter); tools.selectColor(4) }
samples.append(("marker", one.0, one.1))
one = made { tools, _ in tools.select(tool: .eraser) }
samples.append(("eraser", one.0, one.1))
one = made { _, badge in badge.isInteractionMode = true }
samples.append(("click-through", one.0, one.1))
one = made { tools, badge in
    tools.select(tool: .eraser)
    badge.notice = "The eraser has no colour"
}
samples.append(("saying something", one.0, one.1))

let width = 620.0, rowHeight = 62.0
let sheet = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * scale),
                             pixelsHigh: Int(rowHeight * Double(samples.count) * scale),
                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                             colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
sheet.size = NSSize(width: width, height: rowHeight * Double(samples.count))
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: sheet)
let ctx = NSGraphicsContext.current!.cgContext

var square = 0
for y in stride(from: 0.0, to: Double(sheet.size.height), by: 16) {
    for x in stride(from: 0.0, to: width, by: 16) {
        (square % 2 == 0 ? NSColor(white: 0.82, alpha: 1) : NSColor(white: 0.6, alpha: 1)).setFill()
        NSRect(x: x, y: y, width: 16, height: 16).fill()
        square += 1
    }
    square += 1
}

for (index, sample) in samples.enumerated() {
    let originY = Double(index) * rowHeight + (rowHeight - Double(sample.2.height)) / 2
    ctx.draw(sample.1, in: CGRect(x: 20, y: originY, width: sample.2.width, height: sample.2.height))
    NSAttributedString(string: "\(sample.0)  \(Int(sample.2.width))pt", attributes: [
        .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .regular),
        .foregroundColor: NSColor.black
    ]).draw(at: NSPoint(x: 20 + Double(sample.2.width) + 14, y: originY + 4))
}
NSGraphicsContext.restoreGraphicsState()

let out = ProcessInfo.processInfo.environment["OUT"] ?? "badge.png"
try! sheet.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
