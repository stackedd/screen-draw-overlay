# How this app is put together

Scrim puts a transparent window over every screen and lets you draw on it. It
has no window of its own, no Dock icon, and asks for no system permissions. That last part
is not an accident and it constrains almost every decision below.

This file is for whoever touches the code next: what each piece owns, what must not be
broken, and what has already been measured. Its companion is
[DECISIONS.md](DECISIONS.md), which says *why* each of those choices was made and what was
tried and rejected on the way; [../CLAUDE.md](../CLAUDE.md) is the short operational
version: commands, conventions and the "never do this" list.

## The map

| File | Owns |
| --- | --- |
| `main.swift` | The four lines that start the app. Nothing else. |
| `AppDelegate.swift` | Launch and terminate, the single-instance refusal, and the wiring between the other two. Little else. |
| `OverlayController.swift` | The mode model, the lifetime of the overlay panels, kept drawings, and the menu bar item. |
| `Shortcuts.swift` | The global shortcuts as one set: what each is, and reporting the ones macOS refused. |
| `MenuBarItem.swift` | The menu bar presence: icon, menu, Open at Login, and the "shortcut unavailable" line. |
| `OverlayPanel.swift` | The transparent window, one per screen: its level, its collection behaviour, and the fact that it swallows key equivalents. |
| `DrawingView.swift` | The view: events in, paint out. It owns four layers - ink, badge, the laser's glow and the pointer - paints nothing through `draw(_:)`, and keeps the timers that follow the pointer and drop ink which has run out of life. |
| `InkPainter.swift` | The ink layer's delegate, which is why the ink is not painted through the view. |
| `Picture.swift` | Painting a bitmap for a layer, at the scale of the display it will appear on. The badge, the glow and fading ink all go through it. |
| `Glyph.swift` | An SF Symbol painted in a colour, cached. The wheel's sectors and the badge's tool column share it. |
| `FadingInk.swift` | Temporary ink on its way out: one self-fading layer each, reconciled against the canvas. |
| `LaserDot.swift` | The laser's glow, and the layer that carries it after the pointer. |
| `Canvas.swift` | The drawing itself: strokes, the eraser, undo/redo, fading. Knows nothing about windows - it returns the rectangles that changed. |
| `Stroke.swift` | What a mark is made of, what each tool does with two points, and how each style is painted - a pen line, a marker, or a beam of light. |
| `ToolSettings.swift` | The pen in hand: colour, width, tool. Shared across screens, remembered between launches. |
| `ModeBadge.swift` | The badge in the corner - the app's entire on-screen interface. It hands over a picture, snapped to whole pixels; the view carries it on a layer. |
| `PointerCursor.swift` | The pointer's picture, one per tool in the colour in hand - painted onto a layer, plus the cursor that shows nothing which the window server is handed instead. |
| `GlobalHotKey.swift` | The global shortcuts, on Carbon, and the ownership rules that keep the callback safe. |
| `Wheel.swift` | A radial menu: its sectors, which one a direction picks, and how it paints itself. |
| `WheelPanel.swift` | The window a wheel appears in, and the hold-push-release that drives it. |
| `NSScreen+Display.swift` | Identifying a display across time. |

The one dependency worth naming: `OverlayController` → `DrawingView` → `Canvas`. Anything that
changes what is drawn belongs in `Canvas`; anything that changes how it appears belongs in
the view. `Canvas` returns dirty rectangles instead of repainting, which is what lets the
drawing rules be tested without a window on screen.

## The model

Three states, and every transition is deliberate:

- **Off** - no panels. Picking a tool from the wheel opens one.
- **Drawing** - panels take the mouse and the keyboard. Nothing underneath can be clicked.
- **Click-through** - panels stay visible but ignore the mouse; the app underneath gets
  everything, including the keyboard.

Five keys sit next to each other on the keyboard, and four of them move between all three
states. `⌥X` holds
open a wheel of tools: push at one and the overlay opens, takes the screen and hands you that
tool; let go in the middle to leave, one step at a time - the screen back to the app
underneath, then the overlay away with the drawing kept. `⌥C` and `⌥V` do the same for colour
and size while the overlay is up, and `⌥B` is the wheel of the rest of what you do *to* a
drawing: redo, clear, temporary ink and hide. `⌥Z` is not a wheel at all - it undoes, one press
for one thing, repeating while it is held (entry 31 in DECISIONS). `⌃⌥⌘Esc` quits the process outright.

All of them are Carbon global hot keys, which is what makes them work whatever has the
keyboard. The app has no other keys: the bare letters it used to have only worked while these
non-activating panels happened to be key, which is a state the user cannot see.

`⌥X` is registered for the life of the app rather than with the overlay, because it is the
only thing that opens one. The menu bar item is the way in if it is ever taken.

**Hiding is not erasing.** Leaving drawing mode lifts the strokes out of the panels and
files them by display, together with the undo history; the next tool picked from the wheel
puts both back. `CLEAR` on the `⌥B` wheel is the only thing that erases, and even that is
undoable.

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
   because closed panels linger in `NSApp.windows` and counting them made hiding close an
   overlay that was already gone - taking the drawing with it.
4. **`⌃⌥⌘Esc` ends the process.** Anything less can, in principle, still leave someone
   stuck. It is the one recovery that cannot fail.
5. **`.accessory` activation policy** - no Dock icon, no app switcher entry.
6. **Idle costs nothing.** No timers, no polling while the overlay is closed. Every timer
   that exists while it is open is tied to something being true: the fade tick (only while
   temporary ink is on screen), the pointer poll at 60Hz (only while drawing mode is taking
   the mouse - it is what carries the pointer and the laser's glow), and the cursor hold at
   60Hz, 0.3% of a core (the same condition). Two more are short-lived: the burst that takes
   the cursor back for a third of a second after a panel appears, and the badge's notice.
   Each stops with the thing that started it.
7. **Drawing mode interacts with nothing.** Every key is swallowed (no beeps, no `⌘Q`, and
   nothing of its own either - the app's own commands are global hot keys), and clicks never
   reach what is underneath. Interaction is what click-through is for.

## What has been measured

Numbers, not guesses. Re-measure before contradicting any of them.

**Window levels** (macOS 26.5.1, Keynote 13.2). A Keynote slideshow puts its windows at
level 9, its fade at 26; the menu bar is 24 and status items 25. The overlay sits at
`.popUpMenu` (101), above all of it. It was at 23 for a while so the menu bar item stayed
clickable, and that turned out worse in use: the menu bar took the pointer and the clicks
whenever the cursor went near the top of the screen.

**Cost.** Idle with the overlay closed: 0.0% CPU, ~41MB, and 0.11s of CPU total since
launch. 200 open/draw/hide cycles leave memory flat at ~45MB and no leaked panels. What the
overlay costs while it is being used is measured below, and has moved a long way: drawing
over a canvas of 200 strokes cost 23.4% of a core before anything moved onto a layer and
costs 5.9% now; moving the pointer over the same cost 22.9% and costs 1.7% - it went down to
0.5% when the pointer was a cursor and back up when it became a layer again, which is the
trade in entry 6 of DECISIONS and the reason a pointer is visible during a presentation.

**Repainting.** A drag invalidates only the new segment and `draw(_:)` skips strokes that
do not meet `dirtyRect`; repainting the whole view per mouse move was 26x more expensive
(0.325s against 0.012s for the same 960-event session). Incremental and full repaints agree
exactly at 2x and 3x backing scale; at 1x a handful of pixels differ by 1-10/255 along clip
boundaries. Those last differences were the crosshair, not the ink: once the pointer moved
onto a layer of its own the two passes agree **exactly, at 1x, 2x and 3x**.

**Where the drawing bill actually goes** (2026-08-30, 1512x982 at 2x,
`Testing/experiments/repaint_paths.swift`, a trivial paint so that only the asking is being
measured). Per second of one core:

| what is asked for | dirty rect | 15 a second | 60 a second | 120 a second |
| --- | --- | --- | --- | --- |
| nothing | - | - | 0.1% | - |
| `NSView.setNeedsDisplay` | 40x40 | - | **15.7%** | 25.9% |
| `NSView.setNeedsDisplay` | 400x400 | - | 15.3% | - |
| `NSView.setNeedsDisplay` | whole screen | 4.2% | - | - |
| `CALayer.setNeedsDisplay` | 40x40 | - | **3.8%** | 4.8% |
| `CALayer.setNeedsDisplay` | 400x400 | - | 21.0% | - |
| `CALayer.setNeedsDisplay` | whole screen | 19.9% | 50.7% | - |
| moving a sublayer (not a repaint) | - | - | **1.6%** | 2.6% |

Four things follow, and they govern every performance question in this app:

1. **The two paths have opposite shapes.** Asked for through `NSView`, a repaint costs about
   the same whatever its dirty rect - 15.7% for 40x40 and 15.3% for a rect a hundred times
   larger. Asked for through a `CALayer`, the fixed cost is a quarter of that but the area is
   not free: 3.8% small, 21.0% at 400x400, 50.7% for the whole screen.
2. **So the layer path wins by about 4x on small dirty rects and loses by about 4x on
   whole-screen ones.** Everything this app repaints is small - a stroke segment - which is
   why the ink moved to a layer. The one thing that was not small was the fade, and it had
   to stop being a repaint at all.
3. **Not repainting beats both.** Moving a layer costs 1.6%, and a cursor the window server
   draws costs nothing measurable.
4. **WindowServer is not the payer.** It sat between 44% and 55% in every run including the
   one that repaints nothing at all. Compositing a full screen transparent surface is not
   what this app spends its time on.

**What painting itself costs** (`./Testing/run.sh cost`, offscreen, painting only). Small,
next to the numbers above:

- A 60-point drag costs **0.054 ms an event** on an empty canvas and **0.087 ms** with 200
  strokes already down. At 60 events a second that is 0.3-0.5% CPU. So the reported symptom
  - it gets worse as the screen fills - is real (+61%) but it is 61% of a very small number.
- One unbroken stroke used to be **quadratic**: painting means rasterising every segment, so
  a 5000-point line cost five thousand segments' worth of work on every mouse move - including
  the moves that only touched its last inch. A stroke now paints only the segments whose ink
  could land inside the rectangle being repainted, which is a walk over its points instead:
  arithmetic against rasterisation. Measured on the same 5000-point session: the last tenth
  went from **0.309 ms an event to 0.025**, the ratio between first tenth and last from
  **13.5x to 3.1x**, and the whole session from **833 ms to 83**. Below 48 points a stroke is
  painted whole, because the walk costs more than it saves.
- A fade paints **nothing at all** now, which is what the cost suite's fourth sweep exists
  to keep true.
- **A slow hand** - 1500 events less than a point apart, which is what drawing carefully at
  sixty events a second actually produces - costs **0.0151 ms an event**, of which 0.0008 is
  handling the event and the rest is paint. This is the sweep two rejected optimisations were
  measured against; see below.
- **A wide marker asks for the area it draws on**, not twice it. The rectangle a mouse move
  invalidates is the segment grown by the pen's own reach - half its width and a point of
  antialiasing - where it used to be a whole width either side. Measured on the marker at its
  widest (56pt), 300 moves over a canvas of 50 strokes: **4.01 Mpx and 0.297 ms an event
  before, 1.13 Mpx and 0.126 ms after**. A layer repaint costs with its area, so this is the
  part of "the fat marker feels coarse" that was the app's own fault.
- **The laser's trail** costs 0.013 ms an event while it is only extending, and 0.074 ms on
  the event that cuts a piece off and paints it into a layer of its own - three passes of the
  path now that a beam is painted as light rather than as a line, up from 0.038 ms for the
  single pass. It happens ten times a second, so about 0.07% of a core with sixty pieces
  alive.

Put together: of the ~23% a drag used to cost, painting was roughly half a point and the
repaints were the rest.

**End to end, before and after** (`Testing/probes/onscreen.swift`: a real `OverlayPanel` on a
real screen, driven at 60 events a second, this process's own CPU). Ink, badge and pointer
each moved onto a `CALayer`; nothing about what is painted changed.

| what the user is doing | strokes on screen | before | after |
| --- | --- | --- | --- |
| nothing, the overlay is just up | 200 | 0.5% | 0.5% |
| moving the pointer, drawing nothing | 0 | 23.1% | **0.5%** |
| moving the pointer, drawing nothing | 200 | 22.9% | **0.5%** |
| drawing one long unbroken stroke | 0 | 22.5% | **4.1%** |
| drawing over a canvas that already has ink | 200 | 23.4% | **5.4%** |
| 3 temporary strokes fading | - | 2.8% | **0.3%** |
| 10 temporary strokes fading | - | 3.1% | **0.3%** |
| 50 temporary strokes fading | - | 3.8% | **0.7%** |

Both columns are single runs of the same probe on the same machine; run to run these move by
a point or two, which is smaller than anything the table is being used to claim.

**And then the pointer went back onto a layer** (entry 6 in DECISIONS, the presentation case),
which is the one change in this whole round that costs something. Same probe, same machine:

| what the user is doing | as a cursor | as a layer |
| --- | --- | --- |
| nothing, the overlay is just up | 0.4% | **0.9%** |
| moving the pointer, drawing nothing (200 strokes) | 0.5% | **1.7%** |
| drawing one long unbroken stroke | 4.1% | 4.5% |
| drawing over a canvas that already has ink | 5.2% | 5.9% |
| 50 temporary strokes fading | 0.6% | 1.3% |
| a wheel open and being swept | 10.3% | **6.8%** (4.7% of it the wheel) |

A point and a bit of a core to have a pointer at all during a presentation, which is what the
app is for. It is still eight times cheaper than the version that painted the pointer through
`draw(_:)` (22.9%), and two things were measured on the way to that number rather than
guessed: moving only the layer that is actually visible instead of both, and letting the mouse
events outrank the 60Hz poll instead of both doing the work, took it from 2.6% to 1.7%. The
wheel got cheaper at the same time, because its dot is a layer too - following the hand by
repainting the whole wheel was 13.7%.

Two more from the same probe, measured while the pointer was still a cursor, which the first
table never covered:

- **The laser following the pointer costs 0.0%** - a layer move and no repaint, as designed.
- **A wheel that is open and being swept cost 10.1%**, 9.4% of it the wheel itself: it
  repaints its own 312pt view every time the highlight crosses into another sector. It is
  6.8% now (4.7% the wheel) because the dot that follows the hand became a layer. That is the
  price of a key held for well under a second, and it is the one thing in this app that is
  allowed to be expensive, because nothing else is happening while it is up.

In the first table, the first row is the invariant holding: an overlay that is up and not
being used costs nothing either way. The second and third are the ones worth staring at -
**moving the mouse without drawing anything used to cost as much as drawing** (23.1% against
22.5%), because the crosshair was paint and paint meant a repaint of the whole overlay. It is
a layer move now: 0.5% for the round in which the window server drew the cursor, 1.7% since
the pointer went back onto a layer of our own.

**Cursor.** `NSCursor.hide()` is per application and only applies while that application is
active, so a background app hides nothing - that attempt left two pointers on screen during a
presentation. A cursor per tool, handed to the window server, replaced it and worked
everywhere except the case this app is for: **an app that is presenting hides the pointer, and
then a cursor of ours is not drawn at all.** Measured against a stand-in for a slideshow, we
can neither detect that (`NSCursor.currentSystem` reports a visible cursor either way, in the
hiding process too) nor undo it (`CGDisplayShowCursor` from another process does nothing).

So the pointer is a picture on a layer, the window server is handed a cursor that shows
nothing, and the cursor hold re-sets that sixty times a second so a lost cursor cannot leave
an arrow standing next to ours for more than about a frame. It was twenty a second first, and
a gap of up to 50ms - three frames - was still being reported as a flicker.

Setting it is not the same as keeping it. A panel that appears under a stationary pointer is
handed the plain arrow by the window server about 25ms later, whatever the app set before
that, and nothing asks the app again until the mouse moves - so the pick that opens the
overlay used to leave an arrow on the screen until the user moved. `takeCursorBack()` re-sets
it every 120th of a second for a third of a second after a panel appears, then stops.
Measured with `Testing/probes/cursorflash.swift`, which samples `NSCursor.currentSystem` - what
the screen shows, rather than what the app believes - every 4ms.

**Two optimisations that were planned, measured and dropped.** Both were on the open list for
months and both turned out to be worth nothing once measured:

- **Caching `Stroke.repaintBounds`.** `NSBezierPath.bounds` is already cached by AppKit and
  maintained incrementally: asking a 5000-point path for its bounds costs **0.00004 ms**, and
  asking again right after appending a point costs **0.0001 ms**, whatever its length. There
  was nothing to cache.
- **Thinning points closer together than 1.5pt.** It works - a slow hand keeps 751 points
  instead of 1501 and paints 0.2 Mpx instead of 0.5 - and it still made things slower, because
  it overlaps with painting only the segments a repaint asked for. Measured four ways on the
  same session: without trimming, thinning takes an event from 0.0504 ms to 0.0313; with
  trimming, it takes it from **0.0151 to 0.0229**. Trimming already removes what thinning was
  aimed at, and thinning then makes each remaining paint cover more ground. The cheaper one
  wins alone.

**And a third: making the pointer poll adaptive.** One tick of it - `NSEvent.mouseLocation`,
converted into the view, compared with the last one - costs **0.00008 ms**, which at 60Hz is
five thousandths of a percent of a core. The 0.9% an idle overlay costs is not the poll; the
largest measurable piece of it is the cursor hold, at 60 x 0.049 ms = 0.3%, and that is the
price of a pointer that does not blink (entry 6 in DECISIONS).

**`needsToDraw(_:)` is not a lever here.** It looked like a free win - AppKit hands
`draw(_:)` the bounding box of every invalid rectangle, so a pointer that invalidates where
it left and where it arrived can union into a band across the screen. Measured: a
layer-backed view gets **one** rect being drawn, and `needsToDraw` returns `true` for a
rectangle that touches neither invalidation. There is no finer region to consult. The fix
for the band is to stop the pointer invalidating at all, not to ask a better question.

**Hot keys.** Two different processes can register the same shortcut and both succeed, so a
clash with another app is silent - the app can only report the case macOS refuses outright
(`-9878`, which is a second registration inside one process). This is also why the app quits
on launch if another copy is already running: two copies would both answer the shortcut.


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
that drives the real code and prints what happened. One builder, `make_probe.py`, makes every
one of them: it copies every source file and widens `private` so the probe can see internals,
then either splices the probe into `applicationDidFinishLaunching` (the behaviour suite, which
runs inside the real app) or lets the probe stand in for `main.swift` (all the others, which
drive a view or a panel directly).

Three suites run in `run.sh`; the rest of `probes/` is run by hand and described in
`Testing/README.md`.

- **Behaviour** - the mode matrix, hide/show keeping strokes with their tool attributes, the
  unfinished-stroke commit, every wheel and what its sectors and hub do, that the bare keys
  the app used to have now do nothing, `⌘Q` being swallowed, clear/undo/redo, undo across a
  hide, undo stepping over faded temporary ink, the cursor's hot spot, tap versus hold.
  **91 checks.** Every refactor is judged by whether its output is identical line for line.
- **Rendering** - the same session painted incrementally and in one pass, compared pixel by
  pixel at 1x, 2x and 3x. **0 differing bytes** at every scale.
- **Cost** - the same view driven through real sessions with every repaint it asks for
  painted and timed. Seven sweeps: one long unbroken stroke, pointer moves over a canvas
  holding 0, 50 and 200 strokes, a short drag over the same, a fade tick, the laser's trail,
  a drag with the marker at its widest, and a slow hand. It measures painting only, which
  is the point: it is how "does this get more expensive as the screen fills up?" gets an
  answer instead of an opinion.

`Testing/experiments/` holds the one measurement that needs a real window on a real screen
(what a repaint costs and who pays for it) and is run by hand.

Anything that cannot be injected without Accessibility - real key presses, real clicks,
the wallpaper click, a second monitor - is a manual check, and the report should say so
rather than claim it was tested.
