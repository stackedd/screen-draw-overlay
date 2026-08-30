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
enum DrawingTool {
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

    var hasFaded: Bool {
        guard let createdAt else {
            return false
        }

        return Date().timeIntervalSince(createdAt) >= Stroke.fadeDuration
    }
}
