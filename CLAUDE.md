# ScreenDrawOverlay

A macOS menu bar app that puts a transparent overlay over every screen and lets you draw on
it — over a presentation, a document, anything. No window of its own, no Dock icon, and
**no system permissions of any kind**.

**The Option row is the whole interface.** Hold one of four keys, push the mouse at what you
want, let go. `⌥Z` is the tools — a tool opens the overlay and hands it to you, and the middle
is the way out, one step at a time. `⌥X` is colour, `⌥C` is size, and `⌥V` is what you do *to*
a drawing: its middle undoes, so a tap of it takes one thing back, and its sectors are redo,
clear, temporary ink and hide. `⌃⌥⌘Esc` quits.

Every one of them is a global hot key, and that is the point: a non-activating panel only gets
the keyboard while this app is the active one, so the bare keys this app used to have (`P` for
pen, `C` to clear, `⌘Z` to undo) worked only sometimes — which is worse than not existing
(`docs/DECISIONS.md` 30). There are none left. The menu bar item is the way in if `⌥Z` is ever
taken by another app.

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
      Picture.swift           one way to paint a picture for a layer, at the right scale
      Glyph.swift             an SF Symbol in a colour, cached
      FadingInk.swift         temporary ink, on its way out, one layer each
      LaserDot.swift          the laser's glow, following the pointer
      Canvas.swift            the drawing: strokes, eraser, undo/redo, fading
      Stroke.swift            what a mark is made of; what each tool draws
      ToolSettings.swift      the pen in hand, shared and remembered
      ModeBadge.swift         the corner badge
      Wheel.swift             a radial menu: sectors, hit test, painting
      WheelPanel.swift        the window a wheel opens in, and hold-push-release
      PointerCursor.swift     one cursor per tool, in the colour in hand
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
pointer is a picture on a layer, because a presenting app can hide a cursor.

## Commands

    swift build -c release        # must be warning-free
    ./build_app.sh                # also compiles x86_64 - it catches what the line above misses
    ./Testing/run.sh              # every suite; behaviour must be 50/50
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
   `isVisible` — closed panels linger, and counting them once made hiding destroy a drawing.
4. **Never make `⌃⌥⌘Esc` anything less than quitting the process.** It is the panic key;
   the guarantee is that it always works, and everything else leans on it.
5. **Never repaint the whole drawing on a mouse move.** Invalidate the rect you changed.
   Repainting everything cost 26x more, and the suite fails on `fullInkInvalidations > 0`.
   Better still, do not repaint at all: **the badge and the pointer are layers**, moved rather
   than painted. Painting the pointer through `draw(_:)` put a repaint on every mouse move —
   22.5% of a core against a layer move.
6. **Never call `invalidateCursorRects` from inside `cursorUpdate`.** It re-enters AppKit's
   tracking machinery and crashes — this was a shipped `SIGABRT` once.
7. **Never put a modal dialog in front of the user.** `runModal` blocks a background app and
   can sit behind every window; failures are said in the menu.
8. **Never leave a timer running when the overlay is closed.** Closed is 0.0% CPU and that
   is a tested property. Three timers run while it is open, each tied to something being
   true and each stopping with it: the fade tick (temporary ink on screen), the laser's poll
   (the laser in hand), and the cursor hold (drawing mode taking the mouse, 0.1% of a core).
9. **Never make drawing mode interact with anything** — no key should escape it, no click
   should reach what is underneath. Interaction is what click-through is for.
10. **Never let hiding erase.** The wheel's `HIDE` keeps the strokes **and the undo
    history**; `C` is the only thing that erases, and even that is undoable.
11. **Never let an edit point at a position.** Undo names strokes by `id`. `removeLast()`
    took back the wrong line whenever temporary ink faded out from under the history.
12. **Never make a bitmap by hand.** `Picture.drawn(size:scale:)` is the one place that gets
    the order right — an `NSBitmapImageRep` measures itself in pixels until it is told
    otherwise, and the graphics context takes that measurement when it is made. Three copies
    of this code each set the size afterwards, and everything they painted came out at half
    scale in the corner of its own frame (`docs/DECISIONS.md` 28).

## Current focus

**Working towards the first release.** The app does what it is for; the round in progress is
about making it one thing to learn and one thing to trust.

- **One mechanic.** Four keys on the Option row — `⌥Z` tools, `⌥X` colour, `⌥C` size, `⌥V`
  what you do *to* a drawing — all of them global, all of them hold-push-release, and nothing
  underneath them. The bare keys are gone (`docs/DECISIONS.md` 30): they only worked while a
  non-activating panel happened to be key, which is a state the user cannot see. `⌥V`'s hub is
  undo, so a tap takes one thing back; a wheel only appears if the key is held past 180ms.
- **The pointer is drawn, not handed over.** An app that is presenting hides the system
  cursor, and nothing this app may do can detect or undo that, so the pointer is a layer and
  the window server gets a cursor that shows nothing (`docs/DECISIONS.md` 6). The cursor hold
  runs at 60Hz while drawing mode has the mouse, which is what stops the arrow coming back.
- **Painting asks for what it needs.** A stroke paints only the segments whose ink could land
  in the rectangle being repainted, which took a 5000-point line's last tenth from 0.309 ms an
  event to 0.025 and the whole session from 833 ms to 83. The two other items that were on
  this list — caching `repaintBounds` and thinning points — were measured and **dropped**:
  AppKit already caches bounds, and thinning overlaps with the trimming above and loses to it
  (`docs/ARCHITECTURE.md`).
- **Still open:** the pointer poll could fall back to a slower rate while the hand is still
  (idle is 0.9% of a core). Measure it before changing it.

**Performance is measured rather than guessed** (`docs/ARCHITECTURE.md`, "Where the drawing
bill actually goes"). Three numbers govern everything:

- Asking this overlay to repaint 60 times a second through `NSView` costs **15.7% CPU**,
  whatever the dirty rect's size. The bill is the number of repaints.
- The same repaint asked for through a **`CALayer` costs 3.8%** — 4x less, for identical
  output — **but only while the dirty rect is small.** A layer repaint costs 21.0% at
  400x400 and 50.7% for the whole screen, where the view path stays flat. Small rects: use a
  layer. Whole-screen ones: do not repaint at all. This is also why a stroke asks to repaint
  its own reach and not twice it: a fat marker went from 4.01 Mpx to 1.13 Mpx a drag.
- Moving a sublayer, which is not a repaint, costs **1.6%**. Drawing the pointer that way
  costs about a point of a core against a cursor the window server draws — and it is the only
  pointer that survives a presentation.

Measured end to end on a real panel (`Testing/probes/onscreen.swift`): idle 0.9%, moving the
pointer 1.7%, drawing over 200 strokes 5.9%, a wheel open and being swept 6.8%. Everything
except the pointer's own cost came down from the 22.9%/23.4% the painted version cost.
