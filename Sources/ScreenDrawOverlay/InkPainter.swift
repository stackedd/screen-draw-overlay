// The ink layer's delegate.
//
// It exists because the delegate cannot be the view. An NSView is already the delegate of
// its own backing layer, and AppKit's implementations of those methods assume that is the
// layer being asked about, so handing it a second one invites trouble that only shows up
// later. This is the whole of the indirection: make a context current, ask the view to paint.

import AppKit
import QuartzCore

final class InkPainter: NSObject, CALayerDelegate {
    weak var view: DrawingView?

    func draw(_ layer: CALayer, in context: CGContext) {
        guard let view else {
            return
        }

        // The painting is all AppKit - NSBezierPath, NSColor - so it needs a current
        // graphics context. Not flipped, to match the view it stands in for.
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        view.drawInk(in: context.boundingBoxOfClipPath)
        NSGraphicsContext.restoreGraphicsState()
    }

    // Ink appears where it was drawn, at once. Core Animation would otherwise cross-fade
    // every change to the layer's contents.
    func action(for layer: CALayer, forKey event: String) -> CAAction? {
        NSNull()
    }
}
