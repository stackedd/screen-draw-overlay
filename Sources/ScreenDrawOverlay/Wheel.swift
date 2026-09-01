// A radial menu: hold a key, push the mouse in a direction, let go.
//
// The whole point is that it costs no aim. There is no small target to hit - a sector is a
// forty-five degree wedge of the screen around wherever the pointer already was - so it can
// be driven at speed without looking, which is what a tool you use in the middle of talking
// to a room has to be.
//
// This type is the model and the drawing, and nothing else: it knows its sectors, which one
// a direction picks, and how to paint itself into a context. Where it appears and how it is
// opened is WheelPanel's business, and what a sector means is the caller's.

import AppKit

struct Wheel {
    struct Item {
        let label: String
        // An SF Symbol, which is macOS 11 and so is the floor this app already targets.
        let symbol: String
        // Set where the sector *is* the colour - the colour wheel - and left nil where the
        // glyph should read as an icon rather than a swatch.
        let tint: NSColor?
        // Set where the sector is a thickness. A line of that thickness says what it is;
        // the same icon six times over with a number under it makes you read.
        let rule: CGFloat?
        // Set where the sector is an area rather than a line - the eraser's size. A bar is
        // the wrong picture for a hole.
        let disc: CGFloat?

        init(label: String, symbol: String, tint: NSColor? = nil,
             rule: CGFloat? = nil, disc: CGFloat? = nil) {
            self.label = label
            self.symbol = symbol
            self.tint = tint
            self.rule = rule
            self.disc = disc
        }
    }

    // Big enough to read across a room's projector, small enough to sit inside one screen
    // at the corner the pointer happens to be in.
    static let outerRadius: CGFloat = 138
    static let innerRadius: CGFloat = 52
    // Room for the drop shadow, so the panel does not clip it.
    static let margin: CGFloat = 18
    static var extent: CGFloat { (outerRadius + margin) * 2 }

    let items: [Item]

    // What the hub says when nothing is picked, and therefore what letting go in the middle
    // does. The tools wheel overrides it as it opens, because what the middle does there
    // depends on what the overlay is doing at the time.
    let centreLabel: String

    init(items: [Item], centreLabel: String = "CANCEL") {
        self.items = items
        self.centreLabel = centreLabel
    }

    // Sector zero points right and they run clockwise, so the two that need no thought -
    // the pen and the eraser - are a flick right and a flick left.
    private var sweep: CGFloat { items.isEmpty ? 0 : .pi * 2 / CGFloat(items.count) }

    // Which sector a push in this direction picks, or nil for none: inside the dead zone
    // in the middle, which is how you change your mind. Come back to the centre, let go,
    // nothing happens.
    func selection(for offset: NSPoint) -> Int? {
        guard !items.isEmpty else {
            return nil
        }

        let distance = hypot(offset.x, offset.y)
        guard distance >= Wheel.innerRadius else {
            return nil
        }

        // Clockwise from due right, with the sector centred on its direction rather than
        // starting at it - so "straight right" is the middle of the pen's wedge and not
        // the seam between two of them.
        var angle = -atan2(offset.y, offset.x) + sweep / 2
        while angle < 0 {
            angle += .pi * 2
        }

        return Int(angle / sweep) % items.count
    }

    // The direction a sector sits in, for placing its label.
    private func direction(of index: Int) -> CGFloat {
        -CGFloat(index) * sweep
    }

    // MARK: - Painting

    func draw(in context: CGContext, bounds: NSRect, highlighted: Int?,
              centreLabel override: String? = nil) {
        guard !items.isEmpty else {
            return
        }

        let centre = NSPoint(x: bounds.midX, y: bounds.midY)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)

        for (index, item) in items.enumerated() {
            drawSector(index, item: item, at: centre, lit: index == highlighted)
        }

        // The hub, over the sectors' inner edge. It is also the cancel target, so it says
        // so rather than being an unexplained hole.
        let hub = NSBezierPath(ovalIn: NSRect(x: centre.x - Wheel.innerRadius,
                                              y: centre.y - Wheel.innerRadius,
                                              width: Wheel.innerRadius * 2,
                                              height: Wheel.innerRadius * 2))
        NSColor.black.withAlphaComponent(0.55).setFill()
        hub.fill()
        NSColor.white.withAlphaComponent(0.16).setStroke()
        hub.lineWidth = 1
        hub.stroke()

        let title = highlighted.map { items[$0].label } ?? (override ?? centreLabel)
        let colour = highlighted == nil
            ? NSColor.white.withAlphaComponent(0.45)
            : NSColor.white
        let text = NSAttributedString(string: title, attributes: [
            // The hub is a circle, so a long word has to come down to fit inside it.
            .font: NSFont.systemFont(ofSize: title.count > 9 ? 11 : 13, weight: .semibold),
            .foregroundColor: colour,
            .kern: 0.4
        ])
        let size = text.size()
        text.draw(at: NSPoint(x: centre.x - size.width / 2, y: centre.y - size.height / 2))

        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawSector(_ index: Int, item: Item, at centre: NSPoint, lit: Bool) {
        let middle = direction(of: index)
        let half = sweep / 2
        // A hairline of space between wedges, so eight of them read as eight and not as a
        // disc with lines on it.
        let gap: CGFloat = 0.012

        let wedge = NSBezierPath()
        wedge.appendArc(withCenter: centre, radius: Wheel.outerRadius,
                        startAngle: (middle - half + gap) * 180 / .pi,
                        endAngle: (middle + half - gap) * 180 / .pi)
        wedge.appendArc(withCenter: centre, radius: Wheel.innerRadius,
                        startAngle: (middle + half - gap) * 180 / .pi,
                        endAngle: (middle - half + gap) * 180 / .pi,
                        clockwise: true)
        wedge.close()

        // Lit in the sector's own colour where it has one, so choosing blue does not light up
        // red, and in the colour the rest of macOS uses for a selection where the sector is a
        // tool rather than a colour. It was this app's own red, which is a choice a Mac app
        // does not get to make: everything else on the screen highlights in the accent colour
        // the user picked in System Settings.
        (lit ? (item.tint ?? NSColor.controlAccentColor).withAlphaComponent(0.92)
             : NSColor.black.withAlphaComponent(0.62)).setFill()
        wedge.fill()
        // A white edge on the lit one whatever the accent is, so a graphite or a yellow
        // selection still reads as the selected one.
        NSColor.white.withAlphaComponent(lit ? 0.5 : 0.12).setStroke()
        wedge.lineWidth = lit ? 1.5 : 1
        wedge.stroke()

        let seat = NSPoint(x: centre.x + cos(middle) * (Wheel.innerRadius + Wheel.outerRadius) / 2,
                           y: centre.y + sin(middle) * (Wheel.innerRadius + Wheel.outerRadius) / 2)
        drawGlyph(item, at: seat, lit: lit)
    }

    private func drawGlyph(_ item: Item, at seat: NSPoint, lit: Bool) {
        let ink = lit ? NSColor.white : NSColor.white.withAlphaComponent(0.82)

        let label = NSAttributedString(string: item.label, attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: lit ? .semibold : .medium),
            .foregroundColor: ink.withAlphaComponent(lit ? 0.95 : 0.62),
            .kern: 0.5
        ])
        let labelSize = label.size()

        // A colour sector is a swatch, not an icon: drawing the colour itself says more
        // than any symbol tinted with it, and it cannot come out looking like a glyph that
        // failed to load.
        if let tint = item.tint {
            let radius: CGFloat = 11
            let swatch = NSBezierPath(ovalIn: NSRect(x: seat.x - radius, y: seat.y - radius + 7,
                                                     width: radius * 2, height: radius * 2))
            // Lit, the whole wedge is already the colour, so a swatch in that same colour
            // would disappear into it - and a white one would disappear into white. A dark
            // disc reads against every one of the six.
            (lit ? NSColor.black.withAlphaComponent(0.3) : tint).setFill()
            swatch.fill()
            swatch.lineWidth = 1.5
            NSColor.white.withAlphaComponent(lit ? 0.9 : 0.45).setStroke()
            swatch.stroke()
            label.draw(at: NSPoint(x: seat.x - labelSize.width / 2,
                                   y: seat.y - radius + 7 - labelSize.height - 3))
            return
        }

        // The eraser's size is a hole, so it is drawn as one: a ring of what it takes out,
        // scaled down to fit the sector but honest about which is bigger.
        if let disc = item.disc {
            let radius = disc
            let ring = NSBezierPath(ovalIn: NSRect(x: seat.x - radius, y: seat.y - radius + 6,
                                                   width: radius * 2, height: radius * 2))
            ring.lineWidth = 2
            ink.setStroke()
            ring.stroke()
            label.draw(at: NSPoint(x: seat.x - labelSize.width / 2,
                                   y: seat.y + 6 - radius - labelSize.height - 3))
            return
        }

        // A thickness draws itself: a bar of exactly the line it will put on the screen.
        if let rule = item.rule {
            let bar = NSBezierPath()
            let half: CGFloat = 17
            bar.move(to: NSPoint(x: seat.x - half, y: seat.y + 7))
            bar.line(to: NSPoint(x: seat.x + half, y: seat.y + 7))
            bar.lineWidth = min(rule, 20)
            bar.lineCapStyle = .round
            ink.setStroke()
            bar.stroke()
            label.draw(at: NSPoint(x: seat.x - labelSize.width / 2,
                                   y: seat.y + 7 - min(rule, 20) / 2 - labelSize.height - 4))
            return
        }

        if let symbol = tinted(item.symbol, described: item.label, with: ink) {
            let box = NSRect(x: seat.x - symbol.size.width / 2,
                             y: seat.y - symbol.size.height / 2 + 7,
                             width: symbol.size.width, height: symbol.size.height)
            symbol.draw(in: box, from: .zero, operation: .sourceOver, fraction: 1)
            label.draw(at: NSPoint(x: seat.x - labelSize.width / 2, y: box.minY - labelSize.height - 2))
            return
        }

        // No symbol on this system: the word alone still says which wedge this is.
        label.draw(at: NSPoint(x: seat.x - labelSize.width / 2, y: seat.y - labelSize.height / 2))
    }

    // Painted, not drawn plain: a template image takes the appearance of wherever it lands
    // rather than the current fill colour, which inside a bitmap is black on black. Glyph
    // keeps the one copy of that, and the cache with it.
    private func tinted(_ symbol: String, described: String, with colour: NSColor) -> NSImage? {
        Glyph.symbol(symbol, pointSize: 21, colour: colour)
    }
}
