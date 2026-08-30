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
    // rather than a decision. The curve itself is handed to Core Animation as a keyframed
    // opacity, so nothing in this app computes it per frame any more.
    static let fadeDuration: TimeInterval = 3
    static let fadeHold = 0.55

    // Identity, because the history has to name a stroke rather than point at a position.
    // Undo used to take back "the last one added", which is the same thing right up until
    // temporary ink fades out from under an entry still sitting in the stack - and then it
    // silently takes back somebody else's line.
    let id: UUID

    var points: [NSPoint]
    let path: NSBezierPath
    let color: NSColor
    let width: CGFloat
    let style: StrokeStyle
    // nil for ink that stays. Set for a temporary stroke, which is what a presenter wants
    // for "look here" marks that should not pile up on the slide.
    let createdAt: Date?

    // Shapes are two points and a generated path - a rectangle's outline is not its
    // polyline - so there is nothing sensible to cut in half. The eraser takes those whole
    // and splits the freehand ones.
    let isShape: Bool

    var renderColor: NSColor {
        color.withAlphaComponent(style.alpha)
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

    // Spelled out rather than synthesised, because a memberwise initialiser leaves out a
    // `let` that already has a value - which would make the identity impossible to carry
    // when a stroke is rebuilt.
    init(id: UUID = UUID(), points: [NSPoint], path: NSBezierPath, color: NSColor,
         width: CGFloat, style: StrokeStyle, createdAt: Date?, isShape: Bool = false) {
        self.id = id
        self.points = points
        self.path = path
        self.color = color
        self.width = width
        self.style = style
        self.createdAt = createdAt
        self.isShape = isShape
    }

    // What the eraser leaves behind: the same pen, colour and life, a shorter line, and a
    // new identity - because it is a different mark now and the history has to be able to
    // tell the two apart.
    func piece(of points: [NSPoint]) -> Stroke? {
        guard points.count > 1 else {
            return nil
        }

        let rebuilt = NSBezierPath()
        rebuilt.lineWidth = width
        rebuilt.lineCapStyle = style.lineCapStyle
        rebuilt.lineJoinStyle = .round
        rebuilt.move(to: points[0])
        for point in points.dropFirst() {
            rebuilt.line(to: point)
        }

        return Stroke(points: points, path: rebuilt, color: color, width: width,
                      style: style, createdAt: createdAt, isShape: isShape)
    }

    // The lengths of this stroke that survive the eraser passing over a point. A freehand
    // stroke is a polyline, so this is a circle against each segment in turn: a segment
    // keeps whatever of itself lies outside the circle, and consecutive survivors join back
    // up into one shorter stroke.
    //
    // Testing the segment rather than its endpoints matters. Mouse moves are dense while
    // drawing slowly and sparse while drawing fast, and an eraser that only looked at
    // endpoints would pass straight through a fast line without touching it.
    func surviving(_ centre: NSPoint, radius: CGFloat) -> [[NSPoint]] {
        guard points.count > 1 else {
            let alone = points.first.map { hypot($0.x - centre.x, $0.y - centre.y) > radius }
            return alone == true ? [points] : []
        }

        var runs: [[NSPoint]] = []
        var run: [NSPoint] = []

        for index in 1..<points.count {
            let start = points[index - 1]
            let end = points[index]

            guard let (entry, exit) = Stroke.crossing(from: start, to: end,
                                                      centre: centre, radius: radius) else {
                if run.isEmpty {
                    run.append(start)
                }
                run.append(end)
                continue
            }

            if entry > 0 {
                if run.isEmpty {
                    run.append(start)
                }
                run.append(Stroke.point(from: start, to: end, at: entry))
            }

            if run.count > 1 {
                runs.append(run)
            }
            run = exit < 1 ? [Stroke.point(from: start, to: end, at: exit)] : []
        }

        if run.count > 1 {
            runs.append(run)
        }

        // A survivor shorter than the pen that drew it is not a mark, it is a crumb: with a
        // round cap it renders as a dot sitting in the hole the eraser just made, which
        // reads as dirt rather than as ink the user asked to keep.
        return runs.filter { Stroke.length(of: $0) > width }
    }

    private static func length(of points: [NSPoint]) -> CGFloat {
        guard points.count > 1 else {
            return 0
        }

        return (1..<points.count).reduce(CGFloat(0)) { total, index in
            total + hypot(points[index].x - points[index - 1].x,
                          points[index].y - points[index - 1].y)
        }
    }

    // Where a segment enters and leaves a circle, as fractions along it, or nil if it never
    // does. Clamped to the segment, so a segment that starts inside enters at zero.
    private static func crossing(from start: NSPoint, to end: NSPoint,
                                 centre: NSPoint, radius: CGFloat) -> (CGFloat, CGFloat)? {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let fx = start.x - centre.x
        let fy = start.y - centre.y

        let a = dx * dx + dy * dy
        guard a > 0 else {
            return hypot(fx, fy) <= radius ? (0, 1) : nil
        }

        let b = 2 * (fx * dx + fy * dy)
        let c = fx * fx + fy * fy - radius * radius
        let discriminant = b * b - 4 * a * c
        guard discriminant >= 0 else {
            return nil
        }

        let root = sqrt(discriminant)
        let first = (-b - root) / (2 * a)
        let second = (-b + root) / (2 * a)
        guard second > 0, first < 1 else {
            return nil
        }

        return (max(0, first), min(1, second))
    }

    private static func point(from start: NSPoint, to end: NSPoint, at t: CGFloat) -> NSPoint {
        NSPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
    }

    var hasFaded: Bool {
        guard let createdAt else {
            return false
        }

        return Date().timeIntervalSince(createdAt) >= Stroke.fadeDuration
    }
}
