# ScreenDrawOverlay

A macOS menu bar app that puts a transparent overlay over every screen and lets you draw on
it — over a presentation, a document, anything. No window of its own, no Dock icon, and
**no system permissions of any kind**.

Three global shortcuts run it — `⌃⌥⌘D` draw (tap to toggle, hold for momentary), `⌃⌥⌘E`
click-through, `⌃⌥⌘Esc` quit — plus `⌃⌥⌘Z` / `⇧⌃⌥⌘Z` to take a mistake back, which are
global for the same reason: a non-activating panel only gets the keyboard while this app is
the active one, so `⌘Z` alone was a no-op whenever the user had clicked anything else.
While the overlay is up, `⌥Z` / `⌥X` / `⌥C` hold open a wheel of tools, colours and widths:
push the mouse at one and let go. The tools wheel's hub is the mode — let go in the middle and
the screen goes back to the app underneath.

## Stack

Swift 5.9, SwiftPM, no third-party dependencies. AppKit, Carbon (global hot keys),
CoreGraphics, ServiceManagement (open at login). Universal binary, macOS 11+.

## Layout

    Sources/ScreenDrawOverlay/
      main.swift              the four lines that start the app
      AppDelegate.swift       launch, terminate, and the wiring between the next two
      OverlayController.swift modes, overlay lifetime, kept drawings, the menu bar item
      Shortcuts.swift         the global shortcuts as one set
      MenuBarItem.swift       menu bar icon, menu, Open at Login
      OverlayPanel.swift      the transparent window, one per screen
      DrawingView.swift       the view: events in, three layers out
      InkPainter.swift        the ink layer's delegate
      FadingInk.swift         temporary ink, on its way out, one layer each
      LaserDot.swift          the laser's glow, following the pointer
      Canvas.swift            the drawing: strokes, eraser, undo/redo, fading
      Stroke.swift            what a mark is made of; what each tool draws
      ToolSettings.swift      the pen in hand, shared and remembered
      ModeBadge.swift         the corner badge
      Wheel.swift             a radial menu: sectors, hit test, painting
      WheelPanel.swift        the window a wheel opens in, and hold-push-release
      PointerCursor.swift     the cursor drawing mode hands over: arrow + a ring at its tip
      GlobalHotKey.swift      Carbon shortcuts and their ownership rules
      NSScreen+Display.swift  identifying a display across time
    Testing/                  the two test suites (see below)
    Packaging/Info.plist      bundle metadata
    build_app.sh              builds dist/ScreenDrawOverlay.app + zip
    docs/ARCHITECTURE.md      what each piece owns, invariants, measurements
    docs/DECISIONS.md         why things are the way they are, and what was rejected

The dependency runs one way: `OverlayController` → `DrawingView` → `Canvas`. What is drawn belongs
in `Canvas`; how it appears belongs in the view. Nothing is painted through `NSView.draw(_:)`
— the ink and the badge each have a `CALayer`, which is worth 4.3x on every repaint, and the
pointer is a cursor the window server draws for us.

## Commands

    swift build -c release        # must be warning-free
    ./build_app.sh                # also compiles x86_64 - it catches what the line above misses
    ./Testing/run.sh              # every suite; behaviour must be 32/32
    open dist/ScreenDrawOverlay.app

`./Testing/run.sh behaviour` drives the real app and checks the mode matrix, hide/show,
tool keys, undo/redo and tap-versus-hold. `./Testing/run.sh rendering` paints a session
incrementally and in one pass and compares the pixels. `./Testing/run.sh cost` times the
painting of real sessions — and measures painting only, which is the smaller half of the
bill. `Testing/experiments/` holds the on-screen measurement of what a repaint costs; it is
run by hand. Read `Testing/README.md` before writing a new probe — two mistakes in there are
easy to repeat.

## Conventions

- **Every tool brings its own context.** The width wheel shows widths, the eraser's cursor is
  the size of what it rubs out, and the text tool will take the pen's colour as its colour and
  its width as a point size. The same way the menu bar changes with the app in front: what is
  in hand decides what the interface offers, rather than one interface offering everything.
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
5. **Never repaint the whole drawing on a mouse move.** Invalidate the rect you changed.
   Repainting everything cost 26x more, and the suite fails on `fullInkInvalidations > 0`.
   Better still, do not repaint at all: **the badge is a layer and the pointer is a real
   cursor**. Painting either put a repaint on every mouse move — 22.5% of a core against the
   0.5% it costs now.
6. **Never call `invalidateCursorRects` from inside `cursorUpdate`.** It re-enters AppKit's
   tracking machinery and crashes — this was a shipped `SIGABRT` once.
7. **Never put a modal dialog in front of the user.** `runModal` blocks a background app and
   can sit behind every window; failures are said in the menu.
8. **Never leave a timer running when the overlay is idle.** Idle is 0.0% CPU and that is a
   tested property. The fade timer starts with temporary ink and stops with it — and it no
   longer drives the fade, which Core Animation does; it only drops ink that has expired.
9. **Never make drawing mode interact with anything** — no key should escape it, no click
   should reach what is underneath. Interaction is what click-through is for.
10. **Never let hiding erase.** `⌃⌥⌘D` keeps the strokes **and the undo history**; `C` is
    the only thing that erases, and even that is undoable.
11. **Never let an edit point at a position.** Undo names strokes by `id`. `removeLast()`
    took back the wrong line whenever temporary ink faded out from under the history.

## Current focus

The app is feature-complete for v0.2 and stable. What is open is **performance**, and it has
now been measured rather than guessed (`docs/ARCHITECTURE.md`, "Where the drawing bill
actually goes"). Three numbers govern everything:

- Asking this overlay to repaint 60 times a second through `NSView` costs **15.7% CPU**,
  whatever the dirty rect's size. The bill is the number of repaints.
- The same repaint asked for through a **`CALayer` costs 3.8%** — 4x less, for identical
  output — **but only while the dirty rect is small.** A layer repaint costs 21.0% at
  400x400 and 50.7% for the whole screen, where the view path stays flat. Small rects: use a
  layer. Whole-screen ones: do not repaint at all.
- Moving a sublayer, which is not a repaint, costs **1.6%**. A cursor the window server draws
  costs nothing.
- Actually painting a drag costs **0.3–0.5%**. Optimising the painting is bidding for half a
  point out of twenty-three.

That route has now been walked, and one step of it had to be walked back. Ink and badge are
layers; the pointer turned out to belong to the window server instead; and the fade, which is
the one thing whose dirty rect is *not* small, had to come off the repaint path altogether.
Measured end to end on a real panel — moving the pointer over 200 strokes went from **22.9%
to 0.5%**, drawing over them from **23.4% to 5.4%**, fifty strokes fading from 3.8% to 0.7%,
and idle stayed at 0.5%.

**What is still open**, in order:

1. The **quadratic in-progress stroke** — the stroke under the mouse is re-stroked in full on
   every move, so the last tenth of a 5000-point line costs 13x its first tenth. Now the
   largest thing left in the painting half.
2. **Coalescing repaints to the display refresh.** Worth exactly what the real event rate
   exceeds the refresh rate, which has not been measured yet. Measure that first.
3. Cheap and correct either way: caching `Stroke.repaintBounds`, and thinning points that
   land less than about 1.5pt from the last one.

WindowServer is not involved in any of this; it does not move when the overlay repaints.
