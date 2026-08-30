// What a mark on the overlay is made of.
//
// A Stroke carries its own colour, width and style, so changing the pen never touches
// strokes already drawn. It keeps its points as well as its path: the eraser has to ask
// "is this stroke near the pointer?", which a path can only answer for its filled area.
//
// DrawingTool is what the pointer does while the button is down; StrokeStyle is how the
// result is painted. They are separate because four tools share one style.

import AppKit
import Foundation

// What the pointer does while the button is down. Freehand tools trail the mouse; shape
// tools are defined by where the drag started and where it is now; the eraser removes
// instead of adding.
enum DrawingTool: Hashable {
    case pen
    case highlighter
    case line
    case arrow
    case rectangle
    case ellipse
    case eraser
    case laser

    var style: StrokeStyle {
        self == .highlighter ? .highlighter : .pen
    }

    var isShape: Bool {
        self == .line || self == .arrow || self == .rectangle || self == .ellipse
    }

    // Tools that leave nothing behind. The laser is a pointer, not a pen.
    var marksTheCanvas: Bool {
        self != .eraser && self != .laser
    }

    // Stable across releases, unlike a case's position, so a stored preference survives
    // the tool list growing.
    var persistedName: String {
        switch self {
        case .pen: return "pen"
        case .highlighter: return "highlighter"
        case .line: return "line"
        case .arrow: return "arrow"
        case .rectangle: return "rectangle"
        case .ellipse: return "ellipse"
        case .eraser: return "eraser"
        case .laser: return "laser"
        }
    }

    init?(persistedName name: String) {
        switch name {
        case "pen": self = .pen
        case "highlighter": self = .highlighter
        case "line": self = .line
        case "arrow": self = .arrow
        case "rectangle": self = .rectangle
        case "ellipse": self = .ellipse
        case "eraser": self = .eraser
        case "laser": self = .laser
        default: return nil
        }
    }

// MARK: - Shape geometry

    // Shapes are two-point figures. Holding Shift snaps a line or arrow to the nearest 45
    // degrees and makes a rectangle square or an ellipse round, which is what every other
    // drawing tool does and what fingers expect.
    func constrainedEnd(from anchor: NSPoint, to point: NSPoint, shiftHeld: Bool) -> NSPoint {
        guard shiftHeld else {
            return point
        }

        let dx = point.x - anchor.x
        let dy = point.y - anchor.y

        if self == .rectangle || self == .ellipse {
            let side = max(abs(dx), abs(dy))
            return NSPoint(x: anchor.x + (dx < 0 ? -side : side), y: anchor.y + (dy < 0 ? -side : side))
        }

        let angle = atan2(dy, dx)
        let step = CGFloat.pi / 4
        let snapped = (angle / step).rounded() * step
        let length = hypot(dx, dy)
        return NSPoint(x: anchor.x + cos(snapped) * length, y: anchor.y + sin(snapped) * length)
    }

    func shapePath(from anchor: NSPoint, to end: NSPoint, width: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        path.lineWidth = width
        path.lineCapStyle = .round
        path.lineJoinStyle = .round

        switch self {
        case .rectangle:
            path.appendRect(NSRect(x: min(anchor.x, end.x), y: min(anchor.y, end.y),
                                   width: abs(end.x - anchor.x), height: abs(end.y - anchor.y)))
        case .ellipse:
            path.appendOval(in: NSRect(x: min(anchor.x, end.x), y: min(anchor.y, end.y),
                                       width: abs(end.x - anchor.x), height: abs(end.y - anchor.y)))
        case .arrow:
            path.move(to: anchor)
            path.line(to: end)
            // Head scaled to the line width so a thick arrow does not end in a pin prick.
            let headLength = max(12, width * 3.5)
            let angle = atan2(end.y - anchor.y, end.x - anchor.x)
            let spread = CGFloat.pi / 7
            for side in [angle + .pi - spread, angle + .pi + spread] {
                path.move(to: end)
                path.line(to: NSPoint(x: end.x + cos(side) * headLength, y: end.y + sin(side) * headLength))
            }
        default:
            path.move(to: anchor)
            path.line(to: end)
        }

        return path
    }

    var label: String {
        switch self {
        case .pen: return "PEN"
        case .highlighter: return "MARKER"
        case .line: return "LINE"
        case .arrow: return "ARROW"
        case .rectangle: return "RECT"
        case .ellipse: return "OVAL"
        case .eraser: return "ERASER"
        case .laser: return "LASER"
        }
    }
}

// What a stroke is drawn with. Highlighter is the same geometry with a wider, softer,
// see-through pass, which is what makes it read as a marker over content.
enum StrokeStyle {
    case pen
    case highlighter

    var widthMultiplier: CGFloat {
        self == .highlighter ? 4 : 1
    }

    var alpha: CGFloat {
        self == .highlighter ? 0.35 : 1
    }

    var lineCapStyle: NSBezierPath.LineCapStyle {
        self == .highlighter ? .square : .round
    }

    var label: String {
        self == .highlighter ? "MARKER" : "PEN"
    }
}

// One finished (or in-progress) mark on the overlay.
//
// The points are kept alongside the path on purpose: an eraser has to answer "is this
// stroke near the pointer?", and NSBezierPath can only answer that for its filled area,
// not for the line itself. Keeping the polyline makes that a distance test.
struct Stroke {
    // How long a temporary stroke lives, and how much of that it spends at full strength
    // before it starts going. Fading from the first instant reads as a rendering fault
    // rather than a decision.
    static let fadeDuration: TimeInterval = 3
    static let fadeHold = 0.55

    var points: [NSPoint]
    let path: NSBezierPath
    let color: NSColor
    let width: CGFloat
    let style: StrokeStyle
    // nil for ink that stays. Set for a temporary stroke, which is what a presenter wants
    // for "look here" marks that should not pile up on the slide.
    let createdAt: Date?

    var renderColor: NSColor {
        color.withAlphaComponent(style.alpha)
    }

    func opacity(at date: Date) -> CGFloat {
        guard let createdAt else {
            return 1
        }

        let age = date.timeIntervalSince(createdAt) / Stroke.fadeDuration
        guard age > Stroke.fadeHold else {
            return 1
        }

        return max(0, CGFloat(1 - (age - Stroke.fadeHold) / (1 - Stroke.fadeHold)))
    }

    // NSBezierPath.bounds covers the path geometry only, so grow it by this stroke's own
    // line width to include the drawn line, its caps and antialiasing.
    var repaintBounds: NSRect {
        path.bounds.insetBy(dx: -width, dy: -width)
    }

    // Distance from a point to the stroke's polyline. This is why a Stroke keeps its
    // points: NSBezierPath can only answer this for its filled area, not for the line.
    func distance(to point: NSPoint) -> CGFloat {
        guard let first = points.first else {
            return .greatestFiniteMagnitude
        }

        guard points.count > 1 else {
            return hypot(point.x - first.x, point.y - first.y)
        }

        var best = CGFloat.greatestFiniteMagnitude
        for index in 1..<points.count {
            best = min(best, Stroke.distance(from: point, toSegmentFrom: points[index - 1], to: points[index]))
        }

        return best
    }

    private static func distance(from point: NSPoint, toSegmentFrom start: NSPoint, to end: NSPoint) -> CGFloat {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy

        guard lengthSquared > 0 else {
            return hypot(point.x - start.x, point.y - start.y)
        }

        let t = max(0, min(1, ((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared))
        return hypot(point.x - (start.x + t * dx), point.y - (start.y + t * dy))
    }

    var hasFaded: Bool {
        guard let createdAt else {
            return false
        }

        return Date().timeIntervalSince(createdAt) >= Stroke.fadeDuration
    }
}
