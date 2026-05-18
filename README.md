# ScreenDrawOverlay

Minimal native macOS drawing overlay MVP using Swift, AppKit, and Carbon.

## What it does

- Runs as a tiny menu bar app.
- Registers `Control + Option + Command + D` as a global hotkey.
- Registers `Control + Option + Command + Escape` as an emergency force-close hotkey.
- Shows one transparent borderless overlay panel on the main screen while drawing mode is on.
- Shows a tiny semi-transparent `● DRAW` indicator while drawing mode is active; it hides while the pointer is over it.
- Lets you draw red freehand paths with the mouse.
- Press `C` to clear drawings without leaving drawing mode.
- Press `Command + Z` to undo the last completed stroke.
- Clears and removes the overlay when the hotkey is pressed again.
- `Escape` also exits drawing mode and clears the drawing.

## Run in Xcode

1. Open Xcode.
2. Choose `File > Open...`.
3. Open this folder:
   `path/to/ScreenDrawOverlay`
4. Select the `ScreenDrawOverlay` scheme.
5. Press `Run`.
6. Look for the `D` menu bar item.
7. Press `Control + Option + Command + D` to toggle drawing mode.
8. If anything misbehaves, press `Control + Option + Command + Escape` to force-close the overlay.

If the hotkey does not register, another app probably already owns that shortcut. Change the key code or modifiers in `Sources/ScreenDrawOverlay/main.swift`.

## Packaging

There is no packaging script yet. For now, run it from Xcode while the app is still an MVP.

## Notes

This is intentionally v0.1-simple. There is no toolbar, no saving, no redo, no color picker, no screenshot capture, no multi-monitor support, and no fullscreen/Spaces support.
