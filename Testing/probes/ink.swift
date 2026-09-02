import AppKit

// What a stroke actually looks like, at the two ends of the width range, so somebody can look
// at the thing the suites cannot see: whether the ink stops where the hand did, and whether a
// quick line is a curve or a row of chords.
//
//     python3 Testing/make_probe.py ink INK \
//       && swift build --package-path .build/testing/ink -c release \
//       && OUT=/tmp/ink.png .build/testing/ink/.build/release/INK
//
// Not a pass or a fail. It exists because "the marker moves coarsely, especially when it gets
// thick" is a sentence no counting test can answer.

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let scale: CGFloat = 2
let width = 1180.0
let height = 700.0

let sheet = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * scale),
                             pixelsHigh: Int(height * scale), bitsPerSample: 8,
                             samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                             colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
sheet.size = NSSize(width: width, height: height)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: sheet)

NSColor(white: 0.96, alpha: 1).setFill()
NSRect(x: 0, y: 0, width: width, height: height).fill()

func caption(_ text: String, at point: NSPoint) {
    NSAttributedString(string: text, attributes: [
        .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .medium),
        .foregroundColor: NSColor.black.withAlphaComponent(0.7)
    ]).draw(at: point)
}

// Where the hand actually was, drawn as a cross, because the whole question is whether the
// ink stops there or runs past it.
func hand(at point: NSPoint) {
    let cross = NSBezierPath()
    cross.move(to: NSPoint(x: point.x - 9, y: point.y))
    cross.line(to: NSPoint(x: point.x + 9, y: point.y))
    cross.move(to: NSPoint(x: point.x, y: point.y - 9))
    cross.line(to: NSPoint(x: point.x, y: point.y + 9))
    cross.lineWidth = 1
    NSColor.black.setStroke()
    cross.stroke()
}

// A hand moving at speed: sampled the way a mouse is, sixty times a second, so the chords are
// the ones the app really gets.
func hurried(from origin: NSPoint, samples: Int) -> [NSPoint] {
    (0...samples).map { step in
        let t = CGFloat(step) / CGFloat(samples)
        return NSPoint(x: origin.x + t * 320, y: origin.y + sin(t * 5.5) * 46)
    }
}

func stroke(_ points: [NSPoint], width: CGFloat, cap: NSBezierPath.LineCapStyle,
            colour: NSColor, alpha: CGFloat) {
    let path = NSBezierPath()
    path.lineWidth = width
    path.lineCapStyle = cap
    path.lineJoinStyle = .round
    path.move(to: points[0])
    for point in points.dropFirst() {
        path.line(to: point)
    }
    colour.withAlphaComponent(alpha).setStroke()
    path.stroke()
}

// 1. The marker's cap, which is the whole of "the ink runs ahead of the pointer".
caption("a fat marker (56pt), square cap: the ink runs half a width past the hand",
        at: NSPoint(x: 40, y: height - 40))
var points = hurried(from: NSPoint(x: 90, y: height - 120), samples: 14)
stroke(points, width: 56, cap: .square, colour: .systemYellow, alpha: 0.35)
hand(at: points.last!)

caption("the same, butt cap: it stops where the hand stopped",
        at: NSPoint(x: 40, y: height - 230))
points = hurried(from: NSPoint(x: 90, y: height - 310), samples: 14)
stroke(points, width: 56, cap: .butt, colour: .systemYellow, alpha: 0.35)
hand(at: points.last!)

// 2. How angular a quick line is, at both ends of the width range. This is the question
//    smoothing would answer, and it is worth seeing before deciding it is worth the change.
caption("a quick line, sampled 15 times: fat marker, then a 2pt pen",
        at: NSPoint(x: 40, y: height - 420))
points = hurried(from: NSPoint(x: 90, y: height - 500), samples: 14)
stroke(points, width: 56, cap: .butt, colour: .systemBlue, alpha: 0.35)
points = hurried(from: NSPoint(x: 90, y: height - 590), samples: 14)
stroke(points, width: 2, cap: .round, colour: .systemRed, alpha: 1)

caption("the same line sampled 60 times, which is what a slower hand gives",
        at: NSPoint(x: 620, y: height - 590 + 40))
points = hurried(from: NSPoint(x: 660, y: height - 590), samples: 60)
stroke(points, width: 2, cap: .round, colour: .systemRed, alpha: 1)

// 3. A tap, which is the case butt caps break and Stroke.paint() puts back.
caption("a tap: butt caps paint nothing, so the dab is drawn on purpose",
        at: NSPoint(x: 40, y: height - 650))
let tools = ToolSettings()
tools.select(tool: .highlighter)
tools.selectWidth(5)
let canvas = Canvas()
let tap = NSPoint(x: 150, y: height - 680)
_ = canvas.beginStroke(at: tap, with: tools)
canvas.finishStroke()
canvas.strokes.forEach { $0.paint() }
hand(at: tap)

NSGraphicsContext.restoreGraphicsState()
let out = ProcessInfo.processInfo.environment["OUT"] ?? "ink.png"
try! sheet.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
