// An SF Symbol, painted in a colour, cached.
//
// Two things about symbols that cost an afternoon each, so they live in one place now.
//
// A template image does not take the current fill colour when it is drawn: it takes the
// appearance of wherever it lands, which inside a bitmap of our own is black on black. The
// colour has to be painted onto a copy of the image, inside that copy's own context, where
// `sourceAtop` can only touch the glyph itself.
//
// And they are cached, because there are a few dozen in the whole app - eight tools, lit and
// unlit, plus the badge's - and building one on every repaint was most of what following a
// wheel with the mouse cost.

import AppKit

enum Glyph {
    private static var cache: [String: NSImage] = [:]

    static func symbol(_ name: String, pointSize: CGFloat,
                       weight: NSFont.Weight = .medium, colour: NSColor) -> NSImage? {
        let key = "\(name)|\(pointSize)|\(weight.rawValue)|\(colour)"
        if let cached = cache[key] {
            return cached
        }

        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: name)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: pointSize,
                                                                 weight: weight)) else {
            return nil
        }

        let painted = NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            colour.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        cache[key] = painted

        return painted
    }
}
