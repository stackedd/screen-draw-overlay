// The transparent window the drawing lives on: one per screen.
//
// Two decisions carry the whole thing. The window level, which is measured rather than
// guessed and decides what the overlay can cover, and .nonactivatingPanel, which lets the
// panel take the mouse and keyboard without yanking the front app out from under the user.
//
// It also swallows every key equivalent, because drawing mode interacts with nothing: a stray
// Command+Q in the middle of a stroke is not what anyone meant, and this app's own commands
// arrive as global hot keys, outside this path entirely.

import AppKit

final class OverlayPanel: NSPanel {
    // The one place the overlay's stacking is decided. Drawing mode owns the screen:
    // above the menu bar, above status items, above anything a click could land on.
    //
    // This used to sit one below the menu bar (23) so the menu bar item stayed clickable
    // while drawing. That turned out to be worse in use: the menu bar and its extras kept
    // the pointer and the clicks whenever they were under the cursor, so the real arrow
    // flickered back into view at the top of the screen and menus could be opened by
    // accident in the middle of a stroke. Drawing mode is supposed to interact with
    // nothing; click-through is where interaction happens.
    //
    // Measured 2026-08-26 on macOS 26.5.1: menu bar 24, status items 25, another
    // full-width strip at 26, a Keynote 13.2 slideshow at 9 with its fade at 26.
    // .popUpMenu (101) clears all of them.
    //
    // Being above the menu bar is only safe because nothing on screen is needed to get out:
    // ⌥Z opens the wheel wherever the pointer is and its middle hands the screen back and then
    // puts the overlay away, and ⌃⌥⌘Esc quits the app outright. Both are global hot keys that
    // do not depend on anything the overlay is showing.
    private static let overlayLevel = NSWindow.Level.popUpMenu

    let drawingView: DrawingView

    let screenKey: String

    init(screen: NSScreen, showsBadge: Bool, tools: ToolSettings) {
        screenKey = screen.displayIdentifier
        let screenFrame = screen.frame
        let visibleFrame = screen.visibleFrame
        let localVisibleFrame = NSRect(x: visibleFrame.minX - screenFrame.minX,
                                       y: visibleFrame.minY - screenFrame.minY,
                                       width: visibleFrame.width,
                                       height: visibleFrame.height)
        drawingView = DrawingView(frame: NSRect(origin: .zero, size: screenFrame.size),
                                  badgeBounds: localVisibleFrame,
                                  showsBadge: showsBadge,
                                  tools: tools)

        // NSPanel subclasses must call a designated initializer. The panel is
        // non-activating so drawing does not fully steal focus from other apps.
        super.init(contentRect: screenFrame,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        setFrame(screenFrame, display: false)

        // These are the important overlay bits: no chrome, no backing fill, and a z-order
        // above full screen apps.
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = OverlayPanel.overlayLevel

        // .canJoinAllSpaces keeps the overlay with the user when they switch Spaces, and
        // .fullScreenAuxiliary lets it join another app's full screen Space instead of
        // forcing a Space switch. Both are needed to draw over a presentation.
        //
        // .stationary keeps the overlay out of Exposé-style sweeps: without it, clicking
        // the wallpaper ("Click wallpaper to reveal desktop") shoves the panels aside like
        // ordinary windows and the drawing appears to vanish. .ignoresCycle keeps the
        // panels out of window cycling, where a full screen transparent panel is never
        // something the user meant to pick.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        hidesOnDeactivate = false
        isMovable = false
        isReleasedWhenClosed = false

        contentView = drawingView
        makeFirstResponder(drawingView)
    }

    // Borderless panels do not normally become key windows. We opt in so that keystrokes come
    // here and stop, rather than reaching the app underneath while the overlay covers it.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // Key equivalents are dispatched before keyDown, so without this a Command shortcut
    // pressed while drawing would still reach this app's menu - Command+Q would quit the app
    // in the middle of a stroke - or be handed to the app underneath. Drawing mode interacts
    // with nothing, so they stop here, all of them: the things this app does are on global
    // hot keys, which Carbon delivers outside this path entirely.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        true
    }
}
