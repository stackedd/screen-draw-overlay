# ScreenDrawOverlay

A macOS menu bar app that puts a transparent overlay over every screen and lets you draw on
it — over a presentation, a document, anything. No window of its own, no Dock icon, and
**no system permissions of any kind**.

Three global shortcuts are the whole interface: `⌃⌥⌘D` draw (tap to toggle, hold for
momentary), `⌃⌥⌘E` click-through, `⌃⌥⌘Esc` quit.

## Stack

Swift 5.9, SwiftPM, no third-party dependencies. AppKit, Carbon (global hot keys),
CoreGraphics, ServiceManagement (open at login). Universal binary, macOS 11+.

## Layout

    Sources/ScreenDrawOverlay/
      main.swift              the four lines that start the app
      AppDelegate.swift       modes, overlay lifetime, kept drawings, hot keys
      MenuBarItem.swift       menu bar icon, menu, Open at Login
      OverlayPanel.swift      the transparent window, one per screen
      DrawingView.swift       the view: events in, paint out
      Canvas.swift            the drawing: strokes, eraser, undo/redo, fading
      Stroke.swift            what a mark is made of; what each tool draws
      ToolSettings.swift      the pen in hand, shared and remembered
      ModeBadge.swift         the corner badge - the only on-screen UI
      PointerCursor.swift     transparent system cursor + the drawn crosshair
      GlobalHotKey.swift      Carbon shortcuts and their ownership rules
      NSScreen+Display.swift  identifying a display across time
    Testing/                  the two test suites (see below)
    Packaging/Info.plist      bundle metadata
    build_app.sh              builds dist/ScreenDrawOverlay.app + zip
    docs/ARCHITECTURE.md      what each piece owns, invariants, measurements
    docs/DECISIONS.md         why things are the way they are, and what was rejected

The dependency runs one way: `AppDelegate` → `DrawingView` → `Canvas`. What is drawn belongs
in `Canvas`; how it appears belongs in the view.

## Commands

    swift build -c release        # must be warning-free
    ./Testing/run.sh              # every suite; behaviour must be 19/19
    ./build_app.sh                # universal, ad-hoc signed bundle in dist/
    open dist/ScreenDrawOverlay.app

`./Testing/run.sh behaviour` drives the real app and checks the mode matrix, hide/show,
tool keys, undo/redo and tap-versus-hold. `./Testing/run.sh rendering` paints a session
incrementally and in one pass and compares the pixels. `./Testing/run.sh cost` times the
painting of real sessions — and measures painting only, which is the smaller half of the
bill. `Testing/experiments/` holds the on-screen measurement of what a repaint costs; it is
run by hand. Read `Testing/README.md` before writing a new probe — two mistakes in there are
easy to repeat.

## Conventions

- **Measure, do not assume.** Every performance or platform claim in this repo has a number
  behind it. If you change something for speed, show the before and after; if you cannot
  measure it, say so instead of asserting it.
- **One change per commit**, with a message that says what changed, why, and what was
  measured. The history is meant to be read.
- **Comments say why, not what.** The code says what. Comments that survive here explain a
  decision, a trade-off, or a bug that would otherwise be reintroduced.
- **Behaviour is proved unchanged, not assumed.** Refactors are judged by the behaviour
  suite's output being identical line for line, and by the rendering comparison not moving.
- No third-party dependencies. No new frameworks without a reason worth writing down.
- Anything that cannot be injected without Accessibility — real key presses, real clicks, a
  second monitor, the wallpaper click — is a **manual** check. Report it as such.

## Never

1. **Never add a system permission.** No Accessibility, no Screen Recording, no Automation,
   no event taps, no `AXUIElement`. Asking for nothing is the app's defining property; a
   feature that needs a prompt is a feature this app does not have. (`docs/DECISIONS.md`
   lists what that costs and what was turned down because of it.)
2. **Never close the overlay without releasing the mouse first.** `forceCloseOverlay` sets
   `ignoresMouseEvents = true` before it closes anything. An overlay that is half torn down
   and still eating clicks is the worst thing this app can do to someone.
3. **Never remove the `NSApp.windows` re-scan** in `overlayWindowSnapshot()`. It finds
   panels that are on screen but have fallen out of our own arrays. It filters on
   `isVisible` — closed panels linger, and counting them once made `⌃⌥⌘D` destroy a drawing.
4. **Never make `⌃⌥⌘Esc` anything less than quitting the process.** It is the panic key;
   the guarantee is that it always works.
5. **Never repaint the whole view on a mouse move.** Invalidate the rect you changed.
   Whole-view repaints cost 26x more, and the suite fails on `fullViewInvalidations > 0`.
6. **Never call `invalidateCursorRects` from inside `cursorUpdate`.** It re-enters AppKit's
   tracking machinery and crashes — this was a shipped `SIGABRT` once.
7. **Never put a modal dialog in front of the user.** `runModal` blocks a background app and
   can sit behind every window; failures are said in the menu.
8. **Never leave a timer running when the overlay is idle.** Idle is 0.0% CPU and that is a
   tested property. The fade timer starts with temporary ink and stops with it.
9. **Never make drawing mode interact with anything** — no key should escape it, no click
   should reach what is underneath. Interaction is what click-through is for.
10. **Never let hiding erase.** `⌃⌥⌘D` keeps the strokes; `C` is the only thing that erases,
    and even that is undoable.

## Current focus

The app is feature-complete for v0.2 and stable. What is open is **performance**, and it has
now been measured rather than guessed (`docs/ARCHITECTURE.md`, "Where the drawing bill
actually goes"). Three numbers govern everything:

- Asking this overlay to repaint 60 times a second costs **15.2% CPU**, whatever the dirty
  rect's size. The bill is the number of repaints.
- The same repaint asked for through a **`CALayer` delegate instead of `NSView.draw(_:)`
  costs 3.5%** — 4.3x less, for identical output. Moving a sublayer, which is not a repaint,
  costs 1.5%.
- Actually painting a drag costs **0.3–0.5%**. Optimising the painting is bidding for half a
  point out of twenty-three.

So the route is: get everything that is not ink (the pointer, the badge) out of the repaint
path and onto its own layer, then move the ink itself off `NSView.draw(_:)`, and only then
look at painting — where the one real finding is that an unbroken stroke is redrawn in full
on every mouse move, which is quadratic. WindowServer is not involved in any of this; it
does not move when the overlay repaints.
