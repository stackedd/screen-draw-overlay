# How this app is put together

ScreenDrawOverlay puts a transparent window over every screen and lets you draw on it. It
has no window of its own, no Dock icon, and asks for no system permissions. That last part
is not an accident and it constrains almost every decision below.

This file is for whoever touches the code next. It says what each piece owns, what must not
be broken and why, and what has already been measured — so nobody has to rediscover it.

## The map

| File | Owns |
| --- | --- |
| `main.swift` | The four lines that start the app. Nothing else. |
| `AppDelegate.swift` | The mode model, the lifetime of the overlay panels, kept drawings, and the hot keys. The coordinator. |
| `MenuBarItem.swift` | The menu bar presence: icon, menu, Open at Login, and the "shortcut unavailable" line. |
| `OverlayPanel.swift` | The transparent window, one per screen: its level, its collection behaviour, and the fact that it swallows key equivalents. |
| `DrawingView.swift` | The view: events in, paint out, plus the timer that drives the fade. |
| `Canvas.swift` | The drawing itself: strokes, the eraser, undo/redo, fading. Knows nothing about windows — it returns the rectangles that changed. |
| `Stroke.swift` | What a mark is made of, and what each tool does with two points. |
| `ToolSettings.swift` | The pen in hand: colour, width, tool. Shared across screens, remembered between launches. |
| `ModeBadge.swift` | The badge in the corner — the app's entire on-screen interface. |
| `PointerCursor.swift` | The transparent system cursor and the crosshair or laser dot drawn in its place. |
| `GlobalHotKey.swift` | The three shortcuts, on Carbon, and the ownership rules that keep the callback safe. |
| `NSScreen+Display.swift` | Identifying a display across time. |

The one dependency worth naming: `AppDelegate` → `DrawingView` → `Canvas`. Anything that
changes what is drawn belongs in `Canvas`; anything that changes how it appears belongs in
the view. `Canvas` returns dirty rectangles instead of repainting, which is what lets the
drawing rules be tested without a window on screen.

## The model

Three states, and every transition is deliberate:

- **Off** — no panels. `⌃⌥⌘D` opens.
- **Drawing** — panels take the mouse and the keyboard. Nothing underneath can be clicked.
- **Click-through** — panels stay visible but ignore the mouse; the app underneath gets
  everything, including the keyboard.

`⌃⌥⌘D` toggles off/drawing and brings click-through back to drawing — it never throws a
drawing away. Held down rather than tapped, it is momentary: draw while held, gone on
release. `⌃⌥⌘E` flips drawing and click-through. `⌃⌥⌘Esc` quits the process outright.

**Hiding is not erasing.** Leaving drawing mode lifts the strokes out of the panels and
files them by display; the next `⌃⌥⌘D` puts them back. `C` (or Delete) is the only thing
that erases, and even that is undoable.

## Invariants

These exist because something went wrong once. Do not remove them without reading why.

1. **No TCC permissions, ever.** No Accessibility, no Screen Recording, no Automation. This
   is why the shortcuts are Carbon `RegisterEventHotKey` and why the app cannot do certain
   things (see *Known walls*). Verified by grepping for the APIs that would trigger a
   prompt: there are none, and `Info.plist` carries no usage descriptions.
2. **`forceCloseOverlay` sets `ignoresMouseEvents = true` before it closes anything.**
   Order matters: release the user's clicks first, tidy up second. A half-torn-down overlay
   that still eats clicks is the worst failure this app can have.
3. **`overlayWindowSnapshot()` re-scans `NSApp.windows`.** It is insurance against a panel
   that is on screen but has fallen out of our own arrays. It filters to `isVisible`,
   because closed panels linger in `NSApp.windows` and counting them made `⌃⌥⌘D` hide an
   overlay that was already gone — taking the drawing with it.
4. **`⌃⌥⌘Esc` ends the process.** Anything less can, in principle, still leave someone
   stuck. It is the one recovery that cannot fail.
5. **`.accessory` activation policy** — no Dock icon, no app switcher entry.
6. **Idle costs nothing.** No timers, no polling while the overlay is closed. The one timer
   in the app runs only while temporary ink is fading and stops with it.
7. **Drawing mode interacts with nothing.** Keys are swallowed (no beeps, no `⌘Q`), clicks
   never reach what is underneath. Interaction is what click-through is for.

## What has been measured

Numbers, not guesses. Re-measure before contradicting any of them.

**Window levels** (macOS 26.5.1, Keynote 13.2). A Keynote slideshow puts its windows at
level 9, its fade at 26; the menu bar is 24 and status items 25. The overlay sits at
`.popUpMenu` (101), above all of it. It was at 23 for a while so the menu bar item stayed
clickable, and that turned out worse in use: the menu bar took the pointer and the clicks
whenever the cursor went near the top of the screen.

**Cost.** Idle with the overlay closed: 0.0% CPU, ~41MB, and 0.11s of CPU total since
launch. 200 open/draw/hide cycles leave memory flat at ~45MB and no leaked panels. Drawing
by hand at 60 mouse moves a second costs 23.2% CPU; a fade costs 4.3%. The reason both are
what they are: **each repaint of a full screen transparent layer costs about 0.4% CPU
regardless of the dirty rect's size**, so the bill is the number of repaints, not their
area. That single fact is the starting point for any performance work.

**Repainting.** A drag invalidates only the new segment and `draw(_:)` skips strokes that
do not meet `dirtyRect`; repainting the whole view per mouse move was 26x more expensive
(0.325s against 0.012s for the same 960-event session). Incremental and full repaints agree
exactly at 2x and 3x backing scale; at 1x a handful of pixels differ by 1–10/255 along clip
boundaries, which is antialiasing at the seam and not a missed repaint — expanding every
dirty rect makes it worse, not better.

**Hot keys.** Two different processes can register the same shortcut and both succeed, so a
clash with another app is silent — the app can only report the case macOS refuses outright
(`-9878`, which is a second registration inside one process). This is also why the app quits
on launch if another copy is already running: two copies would both answer the shortcut.

**Cursor.** `NSCursor.hide()` is per application and only applies while that application is
active, so a background app hides nothing — that attempt left two pointers on screen during
a presentation. Handing the window a fully transparent cursor is what actually removes the
system one.

## Known walls

Things that cannot be done without giving up the no-permissions promise:

- **Drawings cannot follow content.** Scroll position and element geometry need
  Accessibility. Window positions do not, so anchoring to a *window* is possible; anchoring
  to what is inside it is not.
- **Writing into another app's document** needs Automation, per target app.
- **The Dock still reacts to the pointer.** macOS reports the cursor position to it whatever
  window is on top, so passing over the Dock while drawing still pops up app names.
  Suppressing that needs an event tap.
- **Window titles are unreadable** without Screen Recording, which is why kept drawings
  cannot survive a restart: there would be no reliable way to recognise the same window.

## Testing

There is no XCTest target. Tests are built by compiling the app's own sources into a probe
that drives the real code and prints what happened. `mkprobe.py` copies every source file,
splices a probe body into `applicationDidFinishLaunching`, and widens `private` so the probe
can see internals; `mkpix.py` does the same for offscreen rendering comparisons.

Two suites carry the weight:

- **Behaviour** — the mode matrix, hide/show keeping strokes with their tool attributes, the
  unfinished-stroke commit, tool keys, `⌘Q` being swallowed, clear/undo/redo, tap versus
  hold. 19 checks. Every refactor is judged by whether its output is byte-identical.
- **Rendering** — the same session painted incrementally and in one pass, compared pixel by
  pixel at 1x, 2x and 3x.

Anything that cannot be injected without Accessibility — real key presses, real clicks,
the wallpaper click, a second monitor — is a manual check, and the report should say so
rather than claim it was tested.
