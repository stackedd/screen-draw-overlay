import AppKit

// The laser, rendered so somebody can look at it: the glow at three sizes, and the trail it
// leaves - beside the pen line it used to leave, which is the whole point of the change.
//
//     python3 Testing/make_probe.py laser LASER \
//       && swift build --package-path .build/testing/laser -c release \
//       && OUT=/tmp/laser.png .build/testing/laser/.build/release/LASER
//
// Not a pass or a fail. A suite can check that a beam is drawn and that it goes away; it
// cannot say whether the thing on the screen looks like light or like a red line.

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let scale: CGFloat = 2
let width = 1180.0
let height = 560.0

let sheet = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * scale),
                             pixelsHigh: Int(height * scale), bitsPerSample: 8,
                             samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                             colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
sheet.size = NSSize(width: width, height: height)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: sheet)
let context = NSGraphicsContext.current!.cgContext

// A slide underneath: dark on the left, light on the right, because a laser has to read on
// both and the halo is the part that stops doing so first.
NSColor(white: 0.12, alpha: 1).setFill()
NSRect(x: 0, y: 0, width: width / 2, height: height).fill()
NSColor(white: 0.94, alpha: 1).setFill()
NSRect(x: width / 2, y: 0, width: width / 2, height: height).fill()

func caption(_ text: String, at point: NSPoint, dark: Bool) {
    NSAttributedString(string: text, attributes: [
        .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .medium),
        .foregroundColor: dark ? NSColor.white.withAlphaComponent(0.75)
                               : NSColor.black.withAlphaComponent(0.65)
    ]).draw(at: point)
}

// A hand-drawn sweep, as points, so the trail bends the way a wrist does.
func sweep(from origin: NSPoint) -> [NSPoint] {
    (0...60).map { step in
        let t = CGFloat(step) / 60
        return NSPoint(x: origin.x + t * 300, y: origin.y + sin(t * 3.4) * 34)
    }
}

func path(_ points: ArraySlice<NSPoint>) -> NSBezierPath {
    let line = NSBezierPath()
    line.move(to: points.first ?? .zero)
    for point in points.dropFirst() {
        line.line(to: point)
    }
    return line
}

// The trail as it is actually built: pieces, each on its own layer at its own opacity,
// oldest and faintest at the tail.
func trail(from origin: NSPoint, width beamWidth: CGFloat, colour: NSColor, asBeam: Bool) {
    let points = sweep(from: origin)
    let pieces = 6
    let each = points.count / pieces

    for piece in 0..<pieces {
        let start = piece * each
        let end = min(points.count, start + each + 1)
        let opacity = pow(CGFloat(piece + 1) / CGFloat(pieces), 1.6)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.cgContext.setAlpha(opacity)
        let line = path(points[start..<end])
        if asBeam {
            StrokeStyle.paintBeam(line, width: beamWidth, colour: colour)
        } else {
            line.lineWidth = beamWidth
            line.lineCapStyle = .round
            line.lineJoinStyle = .round
            colour.setStroke()
            line.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}

func glow(_ colour: NSColor, width: CGFloat, at centre: NSPoint) {
    let extent = LaserDot.extent(for: width)
    guard let image = LaserDot.glow(colour, width: width, scale: scale) else {
        return
    }

    context.draw(image, in: CGRect(x: centre.x - extent / 2, y: centre.y - extent / 2,
                                   width: extent, height: extent))
}

for (side, dark) in [(0.0, true), (width / 2, false)] {
    let colour: NSColor = dark ? .systemRed : .systemBlue

    caption("the trail, as light", at: NSPoint(x: side + 40, y: height - 40), dark: dark)
    trail(from: NSPoint(x: side + 60, y: height - 110), width: 6, colour: colour, asBeam: true)
    glow(colour, width: 6, at: NSPoint(x: side + 360, y: height - 110 + sin(3.4) * 34))

    caption("what it was: a pen line that disappears",
            at: NSPoint(x: side + 40, y: height - 190), dark: dark)
    trail(from: NSPoint(x: side + 60, y: height - 260), width: 6, colour: colour, asBeam: false)

    caption("the size wheel: three of its six settings",
            at: NSPoint(x: side + 40, y: height - 330), dark: dark)
    for (index, setting) in [0, 2, 5].enumerated() {
        let beamWidth = ToolSettings.laserWidth(at: setting)
        let centre = NSPoint(x: side + 90 + CGFloat(index) * 170, y: height - 430)
        glow(colour, width: beamWidth, at: centre)
        let line = NSBezierPath()
        line.move(to: NSPoint(x: centre.x - 60, y: centre.y - 70))
        line.line(to: NSPoint(x: centre.x + 60, y: centre.y - 70))
        StrokeStyle.paintBeam(line, width: beamWidth, colour: colour)
        caption("\(Int(beamWidth))pt", at: NSPoint(x: centre.x - 10, y: centre.y - 100), dark: dark)
    }
}

NSGraphicsContext.restoreGraphicsState()
let out = ProcessInfo.processInfo.environment["OUT"] ?? "laser.png"
try! sheet.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
