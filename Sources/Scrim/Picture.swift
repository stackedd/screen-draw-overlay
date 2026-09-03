// A picture painted once, at the resolution of the display it is going to appear on.
//
// Three things in this app hand a layer a finished picture instead of painting every frame -
// the badge in the corner, the laser's glow, and each piece of temporary ink on its way out -
// and all three had the same detail wrong. An `NSBitmapImageRep` built from pixel counts
// measures itself in pixels until it is told otherwise, and `NSGraphicsContext` takes that
// measurement **when the context is made**. Setting `size` afterwards renames the picture and
// leaves the context at 1x, so everything was painted into the bottom left quarter of a
// Retina bitmap and then stretched back out over the whole frame.
//
// What that looked like: a badge at half size sitting inside a hover region four times its
// area, a laser glow thirteen points down and to the left of the pointer, and temporary ink
// that jumped down-left and shrank the instant the mouse came up - which is what the fade
// looked like it was doing wrong.
//
// So the order lives in one place, with the reason written next to it, and nothing else in
// the app makes a bitmap by hand.

import AppKit

enum Picture {
    // Paints into a bitmap of `size` points at `scale` pixels to the point. The block draws in
    // points, with the origin at the bottom left, exactly as it would into a view.
    static func drawn(size: NSSize, scale: CGFloat, _ paint: () -> Void) -> CGImage? {
        let pixelsWide = Int((size.width * scale).rounded())
        let pixelsHigh = Int((size.height * scale).rounded())
        guard pixelsWide > 0, pixelsHigh > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: pixelsWide, pixelsHigh: pixelsHigh,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else {
            return nil
        }

        // Before the context is made, never after. This one line is what the file is for.
        rep.size = size

        guard let context = NSGraphicsContext(bitmapImageRep: rep) else {
            return nil
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        paint()
        NSGraphicsContext.restoreGraphicsState()

        return rep.cgImage
    }

    // The smallest rectangle of whole device pixels that covers this one. A layer whose frame
    // is a fraction of a pixel wide gets its picture resampled onto the screen, which on text
    // is exactly as blurry as it sounds and on ink is a hairline that moves when the stroke
    // is handed from the ink layer to a layer of its own.
    static func snapped(_ rect: NSRect, scale: CGFloat) -> NSRect {
        let minX = (rect.minX * scale).rounded(.down) / scale
        let minY = (rect.minY * scale).rounded(.down) / scale
        let maxX = (rect.maxX * scale).rounded(.up) / scale
        let maxY = (rect.maxY * scale).rounded(.up) / scale

        return NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
