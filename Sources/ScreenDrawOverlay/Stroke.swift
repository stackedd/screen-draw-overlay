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
        switch self {
        case .highlighter: return .highlighter
        case .laser: return .beam
        default: return .pen
        }
    }

    var isShape: Bool {
        self == .line || self == .arrow || self == .rectangle || self == .ellipse
    }

    // Tools that put something on the canvas when dragged. The laser does - a beam that
    // fades in half a second - which is what makes it read as pointing rather than as a
    // dot sliding about.
    var marksTheCanvas: Bool {
        self != .eraser
    }

    // Tools worth coming back to. The eraser and the laser are picked up for a moment, so
    // neither is what the app hands you next time.
    var isKeptInHand: Bool {
        self != .eraser && self != .laser
    }

    // How long what it draws lasts. Only the laser is different, and it is different by a
    // lot: a beam is gone before you have finished the sentence.
    var inkLife: TimeInterval {
        self == .laser ? 0.55 : Stroke.fadeDuration
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

    // What the tool is called, written the way macOS writes things. The wheel shouts it -
    // eight of them read at a glance, across a room, in the second a wheel is up - and the
    // badge does not, because a permanent sign in the corner of somebody's screen that shouts
    // is the thing that makes an app look like it came from somewhere else.
    var name: String {
        switch self {
        case .pen: return "Pen"
        case .highlighter: return "Marker"
        case .line: return "Line"
        case .arrow: return "Arrow"
        case .rectangle: return "Rect"
        case .ellipse: return "Oval"
        case .eraser: return "Eraser"
        case .laser: return "Laser"
        }
    }

    var label: String {
        name.uppercased()
    }

    // The picture of the tool, in one place: the wheel puts it in a sector and the badge puts
    // it in the corner, and neither of them should be holding its own list of symbol names.
    var symbolName: String {
        switch self {
        case .pen: return "pencil.tip"
        case .highlighter: return "highlighter"
        case .line: return "line.diagonal"
        case .arrow: return "arrow.up.right"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .eraser: return "eraser"
        case .laser: return "dot.circle.and.hand.point.up.left.fill"
        }
    }
}

// What a stroke is drawn with, and how it is painted.
//
// The geometry is the same for all three - a path and a width - and the difference is the
// passes. A pen is one line. A highlighter is the same line four times wider, softer and
// see-through, which is what makes it read as a marker over content. A beam is light: a halo
// that falls away, the colour inside it, and a white core down the middle, which is what the
// laser's dot already looked like and its trail did not.
//
// The laser used to draw an ordinary pen line that happened to disappear. That is not a laser,
// it is a pen with a short memory - which is exactly how it was described.
enum StrokeStyle {
    case pen
    case highlighter
    case beam

    var widthMultiplier: CGFloat {
        self == .highlighter ? 4 : 1
    }

    var alpha: CGFloat {
        self == .highlighter ? 0.35 : 1
    }

    var lineCapStyle: NSBezierPath.LineCapStyle {
        self == .highlighter ? .square : .round
    }

    // How far the paint reaches past the path, as a multiple of the width. A beam's halo is
    // wider than its line, so the rectangle to repaint has to be wider too - and the picture a
    // fading beam is painted into has to have room for it, or the glow is clipped square.
    var reach: CGFloat {
        self == .beam ? 1.4 : 1
    }

    var label: String {
        switch self {
        case .pen: return "PEN"
        case .highlighter: return "MARKER"
        case .beam: return "BEAM"
        }
    }

    // Light, in three passes: a halo that falls away, the colour inside it, and a white core
    // down the middle. Static, and not private, because the size wheel paints one too - a
    // sector that says what the laser will look like beats a bar that stands for it.
    static func paintBeam(_ path: NSBezierPath, width: CGFloat, colour: NSColor) {
        let halo = path.copy() as! NSBezierPath
        // The glow around the line, not a multiple of it: at 2.6x the widest setting was a
        // 55pt capsule of light with a beam somewhere inside it. A fixed-ish spill keeps a
        // thin beam glowing and a thick one from turning into a cloud.
        halo.lineWidth = width + max(6, width * 0.8)
        halo.lineCapStyle = .round
        halo.lineJoinStyle = .round
        colour.withAlphaComponent(0.22).setStroke()
        halo.stroke()

        let body = path.copy() as! NSBezierPath
        body.lineWidth = width
        body.lineCapStyle = .round
        body.lineJoinStyle = .round
        colour.withAlphaComponent(0.85).setStroke()
        body.stroke()

        let core = path.copy() as! NSBezierPath
        core.lineWidth = max(1, width * 0.34)
        core.lineCapStyle = .round
        core.lineJoinStyle = .round
        NSColor.white.withAlphaComponent(0.8).setStroke()
        core.stroke()
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

    // How long one piece of the laser's trail is drawn for before it is finished and the next
    // one starts. The beam is a run of short strokes rather than one long one, because a trail
    // has to fade behind the hand while the hand is still moving: one stroke has one age, so
    // it holds at full strength until the button comes up and then goes all at once. A tenth
    // of a second thins evenly and makes a second of drawing ten layers rather than sixty.
    static let beamPiece: TimeInterval = 0.1

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
    // How long this one lives once it is finished. Temporary ink gets three seconds; the
    // laser gets a fraction of that, which is what makes it read as a beam rather than as
    // something drawn.
    let life: TimeInterval

    // Shapes are two points and a generated path - a rectangle's outline is not its
    // polyline - so there is nothing sensible to cut in half. The eraser takes those whole
    // and splits the freehand ones.
    let isShape: Bool

    var renderColor: NSColor {
        color.withAlphaComponent(style.alpha)
    }

    // NSBezierPath.bounds covers the path geometry only, so grow it by this stroke's own
    // line width to include the drawn line, its caps and antialiasing - and by more than that
    // for a beam, whose halo is wider than the line it surrounds.
    var repaintBounds: NSRect {
        let reach = width * style.reach
        return path.bounds.insetBy(dx: -reach, dy: -reach)
    }

    // The one place a stroke is put on a surface, whether that is the ink layer, a fading
    // layer of its own, or a test's bitmap. It was two identical lines in two files, which is
    // how a beam could be given its own look in one of them and not the other.
    func paint() {
        guard style == .beam else {
            renderColor.setStroke()
            path.stroke()
            return
        }

        StrokeStyle.paintBeam(path, width: width, colour: color)
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
         width: CGFloat, style: StrokeStyle, createdAt: Date?, isShape: Bool = false,
         life: TimeInterval = Stroke.fadeDuration) {
        self.id = id
        self.points = points
        self.path = path
        self.color = color
        self.width = width
        self.style = style
        self.createdAt = createdAt
        self.isShape = isShape
        self.life = life
    }

    // The same mark, with its life starting now.
    //
    // Temporary ink is timed from the moment it is finished, not from the moment it was begun.
    // A stroke that took longer to draw than it was meant to last had already expired when the
    // mouse came up: it vanished instead of fading, which is what "the fade does not work"
    // was. The laser, which lives half a second, did it every time somebody held the button
    // down for longer than that.
    func startingNow() -> Stroke {
        guard createdAt != nil else {
            return self
        }

        return Stroke(id: id, points: points, path: path, color: color, width: width,
                      style: style, createdAt: Date(), isShape: isShape, life: life)
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
                      style: style, createdAt: createdAt, isShape: isShape, life: life)
    }

    // The stroke as polylines - what anything that walks it rather than paints it needs.
    //
    // A freehand stroke is already one. A shape is a path, and its `points` are only the two
    // corners the drag was defined by: measuring to those means measuring to a rectangle's
    // diagonal instead of its outline, which is why the eraser sometimes did nothing over a
    // shape and sometimes took the whole thing. Flattened, a shape erases like everything
    // else - and what is left of it is no longer a shape, which is correct: you rubbed a
    // piece out of it.
    func outline() -> [[NSPoint]] {
        guard isShape else {
            return [points]
        }

        var runs: [[NSPoint]] = []
        var run: [NSPoint] = []
        let flat = path.flattened
        var corners = [NSPoint](repeating: .zero, count: 3)

        for index in 0..<flat.elementCount {
            switch flat.element(at: index, associatedPoints: &corners) {
            case .moveTo:
                if run.count > 1 {
                    runs.append(run)
                }
                run = [corners[0]]
            case .lineTo:
                run.append(corners[0])
            case .closePath:
                if let first = run.first {
                    run.append(first)
                }
                if run.count > 1 {
                    runs.append(run)
                }
                run = []
            default:
                break
            }
        }

        if run.count > 1 {
            runs.append(run)
        }

        return runs
    }

    // The lengths of this stroke that survive the eraser passing over a point. A freehand
    // stroke is a polyline, so this is a circle against each segment in turn: a segment
    // keeps whatever of itself lies outside the circle, and consecutive survivors join back
    // up into one shorter stroke.
    //
    // Testing the segment rather than its endpoints matters. Mouse moves are dense while
    // drawing slowly and sparse while drawing fast, and an eraser that only looked at
    // endpoints would pass straight through a fast line without touching it.
    static func surviving(_ points: [NSPoint], centre: NSPoint, radius: CGFloat,
                          shorterThan crumb: CGFloat) -> [[NSPoint]] {
        guard points.count > 1 else {
            let alone = points.first.map { hypot($0.x - centre.x, $0.y - centre.y) > radius }
            return alone == true ? [points] : []
        }

        var runs: [[NSPoint]] = []
        var run: [NSPoint] = []

        for index in 1..<points.count {
            let start = points[index - 1]
            let end = points[index]

            guard let (entry, exit) = crossing(from: start, to: end,
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
                run.append(point(from: start, to: end, at: entry))
            }

            if run.count > 1 {
                runs.append(run)
            }
            // The rest of *this* segment survives too, so the new run starts with both the
            // point where the circle lets go and the segment's own end. Recording only the
            // exit lost the segment's end point - and where the exit fell on the last
            // segment of all, it left a one-point run, which is dropped, which is how a
            // whole tail of a line could disappear.
            run = exit < 1 ? [point(from: start, to: end, at: exit), end] : []
        }

        if run.count > 1 {
            runs.append(run)
        }

        // A survivor shorter than the pen that drew it is not a mark, it is a crumb: with a
        // round cap it renders as a dot sitting in the hole the eraser just made, which
        // reads as dirt rather than as ink the user asked to keep.
        return runs.filter { length(of: $0) > crumb }
    }

    static func totalLength(of runs: [[NSPoint]]) -> CGFloat {
        runs.reduce(0) { $0 + length(of: $1) }
    }

    private static func length(of points: [NSPoint]) -> CGFloat {
        guard points.count > 1 else {
            return 0
        }

        // Written out rather than reduced: the one-expression version made the type checker
        // give up on the x86_64 slice of the universal build, which swift build alone does
        // not compile and so does not catch.
        var total: CGFloat = 0
        for index in 1..<points.count {
            let dx = points[index].x - points[index - 1].x
            let dy = points[index].y - points[index - 1].y
            total += hypot(dx, dy)
        }

        return total
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

        return Date().timeIntervalSince(createdAt) >= life
    }
}
