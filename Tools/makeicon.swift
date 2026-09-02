import AppKit

// The app's icon, drawn rather than designed in another program - the same way everything else
// on screen here is drawn, so it can be changed with a number and looked at again.
//
//     swiftc -O Tools/makeicon.swift -o /tmp/makeicon && /tmp/makeicon Packaging
//
// It writes Packaging/AppIcon.icns (through an .iconset and iconutil, which is what macOS
// wants) and Packaging/icon-preview.png so somebody can look at the sizes side by side.
//
// What it draws: the dark plate this app puts things on, a marker swipe, and a pen stroke over
// it. That is the whole product in two marks - annotation over something else - and the two
// are the app's own yellow and red. Nothing in it is smaller than a stroke, because an icon
// spends most of its life at 32 points in a menu bar's list and 16 in a Finder sidebar.

let arguments = CommandLine.arguments
let outputDirectory = arguments.count > 1 ? arguments[1] : "Packaging"

func draw(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // The macOS grid: the artwork sits inside a rounded square with room around it.
    let unit = size / 1024
    let plate = NSRect(x: 100 * unit, y: 100 * unit, width: 824 * unit, height: 824 * unit)
    let squircle = NSBezierPath(roundedRect: plate, xRadius: 185 * unit, yRadius: 185 * unit)

    NSGradient(colors: [NSColor(calibratedWhite: 0.16, alpha: 1),
                        NSColor(calibratedWhite: 0.07, alpha: 1)])?
        .draw(in: squircle, angle: -90)

    // A hairline lip, the same one the badge has, so the plate has an edge on a light desktop.
    NSColor.white.withAlphaComponent(0.14).setStroke()
    let lip = NSBezierPath(roundedRect: plate.insetBy(dx: unit, dy: unit),
                           xRadius: 184 * unit, yRadius: 184 * unit)
    lip.lineWidth = 2 * unit
    lip.stroke()

    NSGraphicsContext.saveGraphicsState()
    squircle.addClip()

    // Two marks, and they have to survive being sixteen points wide in a Finder sidebar: the
    // marker's swipe going one way, the pen's stroke crossing it. Bigger and bolder than
    // looked right at 1024, because an icon is judged small.
    let marker = NSBezierPath()
    marker.move(to: NSPoint(x: 210 * unit, y: 380 * unit))
    marker.curve(to: NSPoint(x: 820 * unit, y: 470 * unit),
                 controlPoint1: NSPoint(x: 430 * unit, y: 300 * unit),
                 controlPoint2: NSPoint(x: 610 * unit, y: 560 * unit))
    marker.lineWidth = 190 * unit
    marker.lineCapStyle = .butt
    marker.lineJoinStyle = .round
    NSColor.systemYellow.withAlphaComponent(0.9).setStroke()
    marker.stroke()

    let pen = NSBezierPath()
    pen.move(to: NSPoint(x: 225 * unit, y: 690 * unit))
    pen.curve(to: NSPoint(x: 805 * unit, y: 660 * unit),
              controlPoint1: NSPoint(x: 430 * unit, y: 900 * unit),
              controlPoint2: NSPoint(x: 590 * unit, y: 430 * unit))
    pen.lineWidth = 78 * unit
    pen.lineCapStyle = .round
    pen.lineJoinStyle = .round
    NSColor.systemRed.setStroke()
    pen.stroke()

    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.restoreGraphicsState()

    return rep
}

func write(_ rep: NSBitmapImageRep, to path: String) {
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

let iconset = outputDirectory + "/AppIcon.iconset"
try? FileManager.default.removeItem(atPath: iconset)
try! FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)

for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
                        (256, 1), (256, 2), (512, 1), (512, 2)] {
    let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
    write(draw(size: CGFloat(points * scale)), to: iconset + "/" + name)
}

let convert = Process()
convert.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
convert.arguments = ["-c", "icns", iconset, "-o", outputDirectory + "/AppIcon.icns"]
try! convert.run()
convert.waitUntilExit()
try? FileManager.default.removeItem(atPath: iconset)

// A sheet of the sizes that matter, because an icon is judged small.
let previewWidth = 1024.0
let previewHeight = 600.0
let sheet = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(previewWidth), pixelsHigh: Int(previewHeight),
                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                             colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
sheet.size = NSSize(width: previewWidth, height: previewHeight)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: sheet)
NSColor(calibratedWhite: 0.93, alpha: 1).setFill()
NSRect(x: 0, y: 0, width: previewWidth, height: previewHeight).fill()
NSColor(calibratedWhite: 0.35, alpha: 1).setFill()
NSRect(x: 0, y: 0, width: previewWidth, height: previewHeight / 2).fill()

var x = 24.0
for size in [256.0, 128, 64, 32, 16] {
    let art = draw(size: size * 2)
    for base in [previewHeight / 2, 0] {
        art.draw(in: NSRect(x: x, y: base + (previewHeight / 2 - size) / 2, width: size, height: size))
    }
    x += size + 28
}
NSGraphicsContext.restoreGraphicsState()
write(sheet, to: outputDirectory + "/icon-preview.png")

print("wrote \(outputDirectory)/AppIcon.icns and \(outputDirectory)/icon-preview.png")
