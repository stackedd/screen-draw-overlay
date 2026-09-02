// The pen currently in hand, shared by every screen's panel.
//
// One instance lives in AppDelegate and is handed to each DrawingView, so picking a colour
// on one display applies on all of them, and the badge that shows it (drawn on one panel
// only) can be repainted through onChange.
//
// Settings are remembered between launches. The eraser and the laser are not: they are
// picked up for a moment, so what comes back is the last tool that actually drew.

import AppKit
import Foundation

final class ToolSettings {
    static let colors: [NSColor] = [.systemRed, .systemOrange, .systemYellow,
                                    .systemGreen, .systemBlue, .white]
    static let widths: [CGFloat] = [2, 3, 4, 6, 9, 14]

    // Remembered between launches. Someone who always marks up in a thick yellow
    // highlighter should not have to say so every morning.
    private enum Key {
        static let colorIndex = "toolColorIndex"
        static let widthIndex = "toolWidthIndex"
        static let tool = "toolName"
        static let temporaryInk = "toolTemporaryInk"
    }

    private(set) var colorIndex = 0
    private(set) var widthIndex = 2
    private(set) var tool: DrawingTool = .pen
    private(set) var drawsTemporaryInk = false
    private var lastDrawingTool: DrawingTool = .pen

    init() {
        let defaults = UserDefaults.standard
        if let stored = defaults.object(forKey: Key.colorIndex) as? Int,
           ToolSettings.colors.indices.contains(stored) {
            colorIndex = stored
        }

        if let stored = defaults.object(forKey: Key.widthIndex) as? Int,
           ToolSettings.widths.indices.contains(stored) {
            widthIndex = stored
        }

        // The eraser and the laser are things you pick up for a moment, not a pen to
        // start the day with, so they are never what comes back.
        if let name = defaults.string(forKey: Key.tool),
           let stored = DrawingTool(persistedName: name), stored.isKeptInHand {
            tool = stored
            lastDrawingTool = stored
        }

        drawsTemporaryInk = defaults.bool(forKey: Key.temporaryInk)
    }

    private func persist() {
        let defaults = UserDefaults.standard
        defaults.set(colorIndex, forKey: Key.colorIndex)
        defaults.set(widthIndex, forKey: Key.widthIndex)
        // The eraser and the laser are momentary; what comes back next launch is the last
        // thing that actually drew.
        defaults.set(lastDrawingTool.persistedName, forKey: Key.tool)
        defaults.set(drawsTemporaryInk, forKey: Key.temporaryInk)
    }

    var style: StrokeStyle {
        tool.style
    }

    // Set by AppDelegate so every panel repaints its badge when the tool changes.
    var onChange: (() -> Void)?

    var color: NSColor {
        ToolSettings.colors[colorIndex]
    }

    // The width a stroke is actually drawn with, multiplier included.
    //
    // The laser used to be pinned at 6, which made the size wheel a wheel of six things that
    // did nothing - the same fault the eraser had before its size started to mean something
    // (docs/DECISIONS.md 27). It is one and a half times the width in hand now, so the middle
    // setting is still the 6 it has always been and the ends are a thin pointer and a fat one.
    var renderWidth: CGFloat {
        tool == .laser
            ? ToolSettings.laserWidth(at: widthIndex)
            : ToolSettings.widths[widthIndex] * style.widthMultiplier
    }

    // Half again as wide as the same setting in a pen, so the middle one is the 6pt beam the
    // laser has always drawn and the ends are a fine pointer and one that carries to the back
    // of a room.
    static func laserWidth(at index: Int) -> CGFloat {
        widths[min(max(index, 0), widths.count - 1)] * 1.5
    }

    // Ink that goes away by itself: the laser always, and anything else when temporary ink
    // is switched on.
    var drawnInkLife: TimeInterval? {
        guard tool == .laser else {
            return drawsTemporaryInk ? Stroke.fadeDuration : nil
        }

        return tool.inkLife
    }

    func selectColor(_ index: Int) {
        guard ToolSettings.colors.indices.contains(index), index != colorIndex else {
            return
        }

        colorIndex = index
        persist()
        onChange?()
    }

    func selectWidth(_ index: Int) {
        guard ToolSettings.widths.indices.contains(index), index != widthIndex else {
            return
        }

        widthIndex = index
        persist()
        onChange?()
    }

    func stepWidth(by delta: Int) {
        let next = min(max(widthIndex + delta, 0), ToolSettings.widths.count - 1)
        guard next != widthIndex else {
            return
        }

        widthIndex = next
        persist()
        onChange?()
    }

    func select(tool newTool: DrawingTool) {
        guard newTool != tool else {
            return
        }

        tool = newTool
        if newTool.isKeptInHand {
            lastDrawingTool = newTool
        }
        persist()
        onChange?()
    }

    // Space is a switch, not a one-way trip: it drops the laser and hands back whatever
    // was in hand before.
    func toggleLaser() {
        select(tool: tool == .laser ? lastDrawingTool : .laser)
    }

    func toggleTemporaryInk() {
        drawsTemporaryInk.toggle()
        persist()
        onChange?()
    }

    // How much the eraser takes out: 13 to 43 points across.
    //
    // Two versions ago it was max(12, width), which gave five of the six settings the same
    // eraser. The version after that, 6 + width * 2, went the other way - 20 to 68 points, a
    // rubber the size of a thumb at the top end. An eraser that big is answering a question
    // the wheel's own CLEAR already answers in one gesture; what is left for it is the small
    // correction, the word that came out wrong, the arrow pointing at the wrong box. So the
    // range starts finer and grows more slowly.
    static func eraserRadius(at index: Int) -> CGFloat {
        4 + widths[min(max(index, 0), widths.count - 1)] * 1.25
    }

    var eraserRadius: CGFloat {
        ToolSettings.eraserRadius(at: widthIndex)
    }
}
