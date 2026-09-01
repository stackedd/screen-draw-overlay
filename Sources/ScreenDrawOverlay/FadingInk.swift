// Temporary ink, while it is on its way out.
//
// A temporary stroke is painted once into a picture, put on a layer of its own, and handed
// the rest of its life as a keyframed opacity animation. Core Animation takes it down;
// nothing here runs per frame.
//
// It is done this way because the obvious way is expensive. Painting the fade meant
// invalidating every fading stroke as one region, and once there are a few of them that
// region is most of the screen - and a layer repaint costs more as its rect grows. Measured
// with fifty strokes fading: 29.8% of a core painted, 0.7% like this (docs/DECISIONS.md 8).
//
// The layers are reconciled against the canvas rather than updated by each thing that
// changes it, which is what lets the eraser, undo, redo, clear and restore all work on
// temporary ink without any of them knowing it lives on a layer.

import AppKit
import QuartzCore

final class FadingInk {
    private var layers: [UUID: CALayer] = [:]

    // The display's scale, kept in step by the view that owns this.
    var contentsScale: CGFloat = 2

    // Brings the layers in line with the strokes the canvas holds: a new temporary stroke
    // gets one and starts fading, and anything the canvas no longer has - faded out,
    // erased, undone, cleared - loses one. Reconciling rather than tracking each of those
    // separately is what keeps the eraser and undo working on temporary ink without either
    // of them knowing that it lives on a layer.
    func sync(with strokes: [Stroke], above inkLayer: CALayer) {
        var wanted: Set<UUID> = []

        for stroke in strokes where stroke.createdAt != nil {
            wanted.insert(stroke.id)
            guard layers[stroke.id] == nil, let layer = makeLayer(for: stroke) else {
                continue
            }

            layers[stroke.id] = layer
            inkLayer.superlayer?.insertSublayer(layer, above: inkLayer)
        }

        for (id, layer) in layers where !wanted.contains(id) {
            layer.removeFromSuperlayer()
            layers.removeValue(forKey: id)
        }
    }

    // The stroke painted once into a picture of its own, then handed the rest of its life
    // as an opacity animation. The curve is the one the painted version had: full strength
    // for the first stretch, because fading from the first instant reads as a rendering
    // fault rather than a decision.
    private func makeLayer(for stroke: Stroke) -> CALayer? {
        guard let createdAt = stroke.createdAt else {
            return nil
        }

        let age = Date().timeIntervalSince(createdAt)
        let remaining = stroke.life - age
        guard remaining > 0 else {
            return nil
        }

        // Whole device pixels. The stroke is handed from the ink layer to this one at the
        // moment the mouse comes up, and a picture resampled by a fraction of a pixel reads
        // as the ink shifting under the hand.
        let frame = Picture.snapped(stroke.repaintBounds, scale: contentsScale)
        guard frame.width > 0, frame.height > 0,
              let image = Picture.drawn(size: frame.size, scale: contentsScale, {
                  NSGraphicsContext.current?.cgContext.translateBy(x: -frame.minX, y: -frame.minY)
                  stroke.renderColor.setStroke()
                  stroke.path.stroke()
              }) else {
            return nil
        }

        let layer = CALayer()
        layer.frame = frame
        layer.contentsScale = contentsScale
        layer.contents = image
        layer.actions = ["contents": NSNull(), "position": NSNull(), "bounds": NSNull()]

        let animation = CAKeyframeAnimation(keyPath: "opacity")
        let holdEnds = stroke.life * Stroke.fadeHold
        animation.values = [1, 1, 0]
        animation.keyTimes = [0, NSNumber(value: max(0, min(1, (holdEnds - age) / remaining))), 1]
        animation.duration = remaining
        // Ease out, not linear: ink that thins away has to look like it is going rather than
        // like a dimmer being turned down at a constant rate.
        animation.timingFunctions = [CAMediaTimingFunction(name: .linear),
                                     CAMediaTimingFunction(name: .easeIn)]
        animation.fillMode = .forwards
        animation.isRemovedOnCompletion = false
        layer.opacity = 0
        layer.add(animation, forKey: "fade")

        return layer
    }
}
