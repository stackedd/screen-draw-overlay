# Decisions, and what they cost

Why the code looks the way it does. Most of these were arrived at by measuring, several by
getting it wrong first. Each entry says what was chosen, what was tried instead, and the
number or the failure that decided it — so nobody has to run the experiment twice.

Ordered roughly by how much they constrain everything else.

---

## 1. The app asks for no system permissions

**Chosen:** Carbon's `RegisterEventHotKey` for global shortcuts, `CGWindowListCopyWindowInfo`
for window geometry, and nothing that triggers a TCC prompt.

**Rejected:** `CGEventTap` and `NSEvent.addGlobalMonitorForEvents` (Accessibility),
`CGWindowListCreateImage` and window titles (Screen Recording), Apple Events (Automation).

Asking for nothing is the app's defining property — it installs and runs without a single
system dialog. Verified rather than assumed: no permission-triggering API appears in the
sources, `Info.plist` carries no usage descriptions, and the binary links only AppKit,
Carbon, CoreGraphics, Foundation and ServiceManagement.

**What it costs**, all of it deliberate:

- Drawings cannot follow content. Scroll offsets and element geometry need Accessibility.
- Drawings cannot be written into another app's document. That needs Automation, per app.
- The Dock still shows app names when the pointer passes over it while drawing: macOS
  reports the cursor position to it whatever window is on top. Suppressing that needs an
  event tap.
- Kept drawings cannot survive a restart: window titles are unreadable without Screen
  Recording, so there is no reliable way to recognise the same window later.
- Real key presses and clicks cannot be injected, so those parts of testing are manual.

**A whole direction was turned down over this.** Making the drawing a real edit in the
target app's document — an annotation written into a PDF, a shape added to a Keynote slide —
needs a coordinate bridge from screen space to document space. There are only three ways to
get one: ask the app (Automation/Accessibility), render the document yourself (become a
viewer), or look at the screen (Screen Recording). Each ends the no-permissions promise, and
the per-app adapters would turn a 2,700-line tool into a product with a maintenance surface
per target app.

## 2. The overlay sits at window level 101 (`.popUpMenu`)

**Measured** on macOS 26.5.1 with Keynote 13.2: a running slideshow puts its windows at
level 9 and its fade at 26; the menu bar is 24, status items 25.

**Tried and rejected:**

- `.floating` (3) — the original. Invisible over a Keynote slideshow, which is the app's
  main use case. This was the bug that started the whole investigation.
- `CGShieldingWindowLevel()` (2147483628) — chosen defensively before anything was measured.
  Works, but the extra two billion levels buy nothing except covering more system UI.
- Level 23, one below the menu bar — chosen deliberately so the menu bar item stayed
  clickable while drawing. It was worse in practice: the menu bar and its status items are
  above 23, so whenever the pointer went near the top of the screen they took both the
  cursor and the clicks. The real pointer flickered back into view and menus could be opened
  mid-stroke.

101 clears everything measured and leaves drawing mode owning the screen. It is only safe
because no way out depends on anything on screen: every shortcut that matters is global, and
the panic key quits the process.

## 3. Escape does nothing while drawing

**Was:** Escape left drawing mode.

**Problem:** it only worked while the panel happened to be the key window — a state nothing
on screen shows — so the same keypress worked or did nothing depending on where the user had
last clicked. And it was actively harmful: Escape is how you leave a slideshow, and pressing
it threw the drawing away.

**Now:** `keyDown` returns without calling `super` (which also stops AppKit's "no responder"
beep), and `cancelOperation` is overridden for the same reason. Switching to click-through
calls `NSApp.deactivate()`, because handing over the mouse was not enough — the panel stayed
key, so Escape was still being swallowed in the one mode whose point is that input belongs to
the app underneath.

**Knock-on:** 82 lines of key-focus reclaiming machinery — a resign-key observer, a settling
timer, a rate limiter, a menu-open flag, an "is any popover on screen" probe — existed only
to keep Escape alive. All of it was deleted.

## 4. `⌃⌥⌘D` hides, `⌃⌥⌘Esc` quits, `C` erases

The two shortcuts used to do nearly the same thing and both destroyed the drawing, so the
everyday shortcut punished a mistyped keystroke with total loss and the panic key was no
more decisive than it.

- `⌃⌥⌘D` **hides**: strokes are lifted out of the panels before they close, filed by display
  ID, and put back on the next press. From click-through it returns to drawing rather than
  closing, so it never throws away a drawing the user was only stepping aside from.
- `⌃⌥⌘Esc` **quits the process**. Anything short of ending it can in principle still leave
  someone stuck; `applicationWillTerminate` releases the mouse and closes the panels on the
  way out.
- `⌃⌥⌘Z` **takes the last thing back**, `⇧⌃⌥⌘Z` puts it forward again (entry 23).
- `C` (or Delete) is the only thing that erases — and it is undoable.

Kept drawings are tied to the display layout they were made on and dropped when it changes,
rather than restored onto the wrong screen at the wrong scale. What is kept includes the undo
history (entry 23).

## 5. Holding the shortcut draws momentarily

A toggle asks the user to remember they left it on. Holding does not: press, scribble, let
go. That is what makes the app something you leave running rather than something you switch
on for a task.

Tap and hold share `⌃⌥⌘D`, split at **400 ms**. Momentary applies only when the press is what
opened the overlay — holding while already drawing would have to undo the tap action
mid-hold, which reads as the shortcut fighting you. Stepping into click-through during the
hold means you meant to stay, so the release leaves it alone.

This needed `GlobalHotKey` to carry the release half of the keypress
(`kEventHotKeyReleased`). If a system ever fails to deliver it, the hold degrades to a tap —
the old behaviour, not a broken one.

## 6. The pointer is the system arrow with a ring around its tip

**Tried:** `NSCursor.crosshair`. Invisible over a Keynote slideshow — though see below, that
test was run while the overlay itself was at window level 3 and underneath Keynote, so it may
never have been the cursor's fault at all.

**Tried:** `NSCursor.unhide()` + `CGDisplayShowCursor`, then `NSCursor.hide()`. Both
ineffective for the same reason: cursor hiding is per application and only applies while that
application is active, so a background `.accessory` app hides and unhides nothing. The second
attempt put **two pointers** on screen during a presentation.

**Chosen, and then reversed:** a fully transparent cursor (a 16x16 empty `NSImage`) with the
app painting its own crosshair underneath. It worked as long as we owned the window under the
pointer — and that is the flaw. The moment something else takes the cursor, and the menu bar
does it reliably, the real arrow comes back and stays, and from then on there are two
pointers: the system's and ours. A transparent cursor has no failure mode between *invisible*
and *doubled*.

**Now:** one cursor that cannot double. The system arrow, composited with a ring around its
tip, handed over as a single `NSCursor`. The ring carries the tool and its colour; the eraser
gets a ring the size of what it will rub out; the laser gets its glowing dot. Losing cursor
ownership now degrades to a plain arrow instead of to a bug.

Three points have to be the same point — the cursor's hot spot, the middle of the ring, and
where the ink lands — or a stroke appears offset from the arrow the user is aiming with. The
behaviour suite checks it.

**It is also free.** The window server draws the cursor, so following the mouse costs this
process nothing: moving the pointer over a canvas of 200 strokes went 22.5% of a core (paint
it) to 1.6% (move a layer) to **0.5%**, which is what an idle overlay costs anyway.

The image is built through `NSImage(size:flipped:drawingHandler:)` rather than into a bitmap,
so the cursor is redrawn at whatever resolution the display it lands on needs, and cached per
tool, colour and width — a keypress, never a mouse move.

**A crash to not repeat:** the first version called `window.invalidateCursorRects(for:)` from
inside `cursorUpdate`. That re-enters AppKit's tracking machinery and throws — `SIGABRT` the
moment the pointer moved over the panel. Rebuilding cursor rects lives in its own method that
only mode and tool changes call.

**Unverified:** whether a presenting app that hides the pointer can hide this one too. The
original note says a Keynote slideshow did, but that was measured with the overlay at level 3,
underneath Keynote, where Keynote owned the window under the pointer and set the cursor. At
level 101 we own it. If it turns out otherwise, the fallback is in the history: paint the ring
on a layer and accept that it lags the arrow by a frame.

## 7. Repainting is incremental

A drag invalidates only the rectangle the new segment covers, and `draw(_:)` skips strokes
whose bounds do not meet `dirtyRect`. Repainting the whole view per mouse move made the cost
of a drag grow with everything already drawn: the same 960-event session took **0.325s that
way against 0.012s this way — 26x**.

**On the differences the rendering suite used to report:** a handful of pixels differed by
1–15/255, and the explanation on file was antialiasing where a clip boundary crosses a
stroke. That was wrong. It was the **crosshair**, composited over the ink against different
clip rectangles in the incremental pass than in the single pass. With the pointer on a layer
of its own (entry 20) the suite reports **0 differing bytes at 1x, 2x and 3x**.

The related measurement still stands on its own: **expanding every dirty rect makes seams
worse, not better** — 275 bytes at 2x became 733 at +20pt and 4,482 at +60pt, with the
per-pixel error unchanged. More repainting means more seams.

## 8. Temporary ink fades itself, on a layer

Temporary ink (`T`) holds full strength for the first 55% of three seconds, then goes.

**How it used to work:** a timer at 15 Hz walked the strokes, worked out each one's opacity,
and asked for a repaint of the region covering all of them. Two costs were found and fixed
along the way — invalidating each stroke separately made the cost grow with the square of
what was on screen (12.5% CPU with fifty of them, 5.0% invalidating the union once), and the
tick rate was settled at 15 because 20/s cost 5.1%, 15/s 4.4% and 12/s 4.3%. End to end that
came to 2.8% of a core with three strokes fading and 3.8% with fifty.

**Then the ink moved to a `CALayer` (entry 21) and that arithmetic inverted.** A layer repaint
is four times cheaper than a view repaint for a small dirty rect and about four times dearer
for a whole-screen one — and the union of every fading stroke *is* most of the screen once
there are a few. Measured after the move: **29.8% of a core** with fifty strokes fading,
against 3.8% for the same thing before it. A regression, straight out of an optimisation.

**Now:** each temporary stroke is painted once into a picture, put on a layer of its own, and
handed the rest of its life as a keyframed `opacity` animation. Core Animation takes it down.
Nothing is repainted, nothing is computed per frame, and the cost stops depending on how many
there are:

| strokes fading | painted through the view | painted on a layer | on their own layers |
| --- | --- | --- | --- |
| 3 | 2.8% | 4.0% | **0.3%** |
| 10 | 3.1% | 9.7% | **0.3%** |
| 50 | 3.8% | 29.8% | **0.7%** |

The middle column is the regression: four to eight times worse than what it replaced, and
growing with the number of strokes because their union grows with it. The last column does
not grow, because there is nothing there to grow.

The timer survives, at 2 Hz, doing something else entirely: dropping strokes that have run
out of life so the model agrees with the screen — the eraser, undo and "is anything still
fading" all read the canvas, not the layers. Nothing waits on it, so it can be slow. It still
starts with the first temporary stroke and stops with the last, so idle is still 0.0%.

The layers are reconciled against the canvas after anything that changes it, rather than each
of erase, undo, redo, clear and restore knowing about them. That is what keeps the eraser
working on temporary ink without the eraser knowing where temporary ink lives.

`Stroke.opacity(at:)` went with the old scheme. Nothing computes a fade curve any more.

## 9. The menu bar icon is never tinted

**Measured:** rendering the status button with `contentTintColor` set gives mean luminance
**0.000** — black, on a dark menu bar, which is invisible. Untinted it renders at 0.791.
The cause is visible in the same measurement: the button's effective appearance resolves to
`VibrantDark` independently of the app's own appearance, so a colour resolved in the app's
context lands on a bar that is not in that context.

So the mode is carried by the **symbol** and never by a colour: `scribble` idle,
`pencil.tip.crop.circle.fill` drawing, `pencil.slash` click-through, all templates. The item
is `variableLength` because a crowded menu bar drops what does not fit (38pt as a fixed
square, 34pt as an icon, 30pt as the `D` fallback).

## 10. Only one copy runs

**Measured:** launching the bundle twice really did leave two processes, and macOS lets both
register the same global hot keys. One press then opens two overlays stacked on each other,
and the one the user cannot see is the one still taking their clicks.

The second copy now quits on launch. Run unbundled there is no bundle identifier to compare,
so the check stands down rather than guessing.

Related, and the reason a shortcut clash cannot be reported properly: **two different
processes registering the same combination both succeed**. Only a second registration inside
one process fails (`-9878`). So "another app is using this shortcut" is precisely the case
that never produces an error, and the app can only report the case macOS refuses outright.

## 11. Failures are said in the menu, never in a dialog

`NSAlert.runModal` blocks the main thread, and an accessory app's dialog can sit behind every
other window — a failure at login would look exactly like a hang, menu bar icon present and
nothing responding. Unregistered shortcuts show as a disabled line at the top of the menu
instead. `NSAlert` does not appear in the app at all.

## 12. Leaving drawing mode on a display change, but only a real one

`didChangeScreenParametersNotification` fires for more than displays coming and going. It
fires when the Dock or the menu bar hides — which is what happens when a presentation
starts. Measured during a Keynote slideshow: it fired at 2.4s (Keynote coming forward) and
again at 14.0s (slideshow ending), both times with the screen frame unchanged at 1512x982
and only `visibleFrame` moving a few points. Reacting to it tore the overlay down at the
exact moment the user started presenting.

The display layout (display ID + frame, neither affected by the Dock) is recorded on entry
and compared on each notification. Same layout, nothing happens.

## 13. Closed panels do not count as an overlay

`overlayWindowSnapshot()` re-scans `NSApp.windows` as insurance against a panel that is on
screen but has fallen out of our arrays. It filters on `isVisible`, because closed panels
linger in `NSApp.windows` until they are deallocated — and counting those meant that right
after hiding, the app still believed an overlay was open. The next `⌃⌥⌘D` took the hide
branch again, captured strokes from an emptied panel, and the drawing was gone.

Found by a stress test: 60 rapid mode switches ended in the impossible state "off, 1 panel",
and 10 hide/show cycles with 300 strokes ended with 0 strokes.

## 14. Drawing mode owns the keyboard

Every key is swallowed. Unhandled keys used to travel up the responder chain into AppKit's
"no responder" beep, so typing while drawing beeped on every letter; and Command shortcuts
were dispatched as key equivalents before `keyDown` ever ran, so `⌘Q` quit the app in the
middle of a stroke. `performKeyEquivalent` now returns true for everything and forwards only
`⌘Z` and `⇧⌘Z` to the view.

A bug worth remembering: the first version compared the modifier flags to `.command` by
equality, which silently dropped `⇧⌘Z`. Redo looked implemented and did nothing.

## 15. The tools are keyboard-only

**Rejected:** an on-screen palette or toolbar. A tool that occupies screen space is not one
people leave running in the background, and drawing mode is supposed to interact with
nothing — a clickable palette would need an exception to that.

So: bare letters and digits, no modifiers to hold while the other hand draws. `P H L A R O E`
for tools, `1`–`6` colours, `[` `]` width, `Space` laser, `T` temporary ink. The corner badge
is the only readout, showing the tool, its width and a dot in the current colour.

## 16. A stroke carries its own attributes, and its points

`Stroke` holds the colour, width and style it was drawn with, so changing the pen never
touches what is already on screen. It keeps its points as well as its `NSBezierPath` because
the eraser has to answer "is this stroke near the pointer?", which a path can only answer for
its filled area, not for the line itself.

The eraser removes whole strokes rather than splitting them: on an annotation overlay, "take
that line away" is what people mean.

Undo records edits (a stroke added, or strokes removed with the indices they came from)
rather than inferring them from the stroke list, which is what lets it put back what the
eraser and Clear took away, at the right depth. Each stroke carries a `UUID`, so an edit
names a stroke rather than pointing at a position — see entry 23 for what that fixed.

## 17. Temporary ink is not kept across a hide

It was drawn to vanish. Bringing it back mid-fade on the next show would be a surprise, and
its disappearance is not an edit, so undo has nothing to say about it either — which means
the entry that put it there goes when it does (entry 23).

## 18. macOS 11 is the floor

The newest API in the app is `NSImage(systemSymbolName:)` (macOS 11), and the menu bar item
already falls back to a plain `D` if a symbol will not load. macOS 11 is also the real floor
rather than an arbitrary one: Apple Silicon has no macOS before Big Sur, so a universal
binary cannot target lower on the arm64 side. Open at Login (`SMAppService`) is 13+, so that
menu item is simply absent on 11 and 12 rather than present and broken.

## 19. The repaint, not the painting, is what a drag costs

Performance work here started from the wrong end twice, so this entry is the map.

**Measured** (2026-08-30, `Testing/experiments/repaint_paths.swift`, and
`./Testing/run.sh cost`). Asking a full screen transparent overlay to repaint 60 times a
second costs **15.7% of a core** through `NSView`, whatever the dirty rect's size. Actually
painting what a drag puts on screen costs **0.3–0.5%**. The ratio is about thirty to one, and
every idea that makes painting cheaper is bidding for that half point.

The same repaint asked for through a `CALayer` delegate costs **3.8%** — 4x less for
identical output — and moving a sublayer, which is not a repaint, costs **1.6%**. WindowServer
does not move in any of these runs, so this is our own process and not the compositor.

**The one caveat, and it has already bitten once:** the layer path is only cheaper for small
dirty rects. Its fixed cost is a quarter of the view path's but its cost grows with area,
where the view path's does not — 3.8% at 40x40, 21.0% at 400x400, 50.7% for the whole screen,
against a flat ~15% for the view path. Everything a drag repaints is small. The fade was not,
and moving it to a layer made it four times *worse* before it was taken off the repaint path
altogether (entry 8).

**So the order of work is:** stop repainting for things that are not ink (the pointer, the
badge), then move the ink off the `NSView` display path, and only then make painting itself
cheaper.

**Rejected on the measurement:**

- **`needsToDraw(_:)` in place of `dirtyRect.intersects(_:)`.** The premise was that AppKit
  hands `draw(_:)` a bounding box and the real dirty region is finer. For a layer-backed
  view it is not: `getRectsBeingDrawn` returns **one** rect, and `needsToDraw` answers `true`
  for a rectangle sitting between two far-apart invalidations, touching neither. Nothing to
  gain.
- **A bitmap cache of the finished strokes, as the first move.** It is a real optimisation of
  the wrong quantity: it buys part of the half point that painting costs, at a full screen
  bitmap per display in memory. It stays on the table only for the quadratic case below, and
  only with a number behind it.

**Confirmed on the measurement, and worth fixing in its own right:** the stroke under the
mouse is re-stroked in full on every mouse move, so a single unbroken line is quadratic —
the last tenth of a 5000-point line costs **5.5x** what its first tenth did. It is small in
absolute terms until a line gets very long, which is exactly when someone notices.

## 20. The badge is a layer, not paint

The crosshair used to be painted in `draw(_:)`, and following the mouse meant invalidating
where it had been and where it had arrived. Both rectangles are about 26pt square, which
sounded free and was not: a repaint of a full screen transparent overlay costs the same
whatever its dirty rect, so **painting the crosshair cost as much as painting everything**.
On a canvas with ink on it, more — the two rectangles union into one region and every stroke
that region touches is re-stroked, while the user is drawing nothing at all. Measured at 60
moves a second: **22.5% of a core**.

Moving it to a layer took that to 1.6%. It has since gone further and left the app entirely —
the pointer is a real cursor now (entry 6), which costs 0.5%, which is nothing. The layer
version is worth recording anyway, because the reasoning is what carried over to the badge.

**The badge went the same way, and for a sharper reason.** It changes when the tool, the
colour or the mode changes — a few times a session — but it was painted inside `draw(_:)`,
and the first thing it did there was measure itself, which meant building two
`NSAttributedString`s and laying both out **before** the check that would have skipped it.
So every repaint, for any reason anywhere on screen, laid out the badge's text.

With the pointer already off the repaint path, that layout was all that a mouse move cost:
**0.059 ms an event, painting nothing**. As a picture on a layer it is **0.029 ms**, and a
60-point drag over a canvas of 200 strokes went from 0.065 ms an event to **0.033 ms**.

Its old repaint machinery went with it — `repaintRegionAfterToolChange`, the repaint margin,
and the "old rect union new rect" rule that existed because a badge growing leftwards out of
the corner would otherwise be left half drawn. A layer that is given a new picture and a new
frame has no such problem. The whole-view repaint on a mode switch went too.

## 21. The ink is painted through a layer, not through `NSView.draw(_:)`

The measurement in entry 19 said the same repaint of the same full screen transparent layer
costs **15.7% of a core through AppKit's view display machinery and 3.8% through a
`CALayer`** — 4x, for identical output. Nothing about what is painted changes; the difference
is the path the repaint is asked through. The catch, which entry 8 paid for, is that this
holds for small dirty rects: a layer repaint costs more as its rect grows, and a view repaint
does not.

So `DrawingView` now owns three layers, bottom to top — ink, badge, pointer — and paints
nothing through `draw(_:)` at all. The `draw(_:)` override is gone. The painting code did not
change: the ink layer's delegate makes an unflipped `NSGraphicsContext` current and calls the
same body, so `NSBezierPath` and `NSColor` work exactly as before.

**The delegate cannot be the view.** An `NSView` is already the delegate of its own backing
layer and AppKit's implementations of those methods assume that is the layer being asked
about. `InkPainter` exists for that reason and no other.

**Measured end to end** (`Testing/probes/onscreen.swift`, a real panel at 60 events a
second), with the pointer and badge layers of entry 20:

| | before | after |
| --- | --- | --- |
| moving the pointer over 200 strokes, drawing nothing | 22.5% | **1.6%** |
| drawing one long unbroken stroke | 21.9% | **4.2%** |
| drawing over a canvas of 200 strokes | 20.4% | **5.4%** |
| overlay up, idle | 0.5% | 0.5% |

The old shape of the thing is in that table: **moving the mouse cost as much as drawing**,
because the crosshair was paint and paint meant repainting the whole overlay.

**What is left.** Painting a drag is now about 0.2% of a core, so the remaining 4–5% is the
repaints themselves, one per mouse event. Two directions, in order: coalesce the repaints to
the display's refresh rate (worth only what the event rate exceeds it — unmeasured), and the
quadratic in-progress stroke, which is now the largest thing in the painting half.

## 22. The badge is snapped to whole pixels, and the plate is dark

Two things were wrong with it, one of them freshly introduced.

**Blurry.** Moving the badge onto a layer (entry 20) meant its picture became a bitmap of a
whole number of pixels shown inside a frame that was a fraction of one: the text measured
87.34pt wide, so 175 pixels of picture were resampled onto 174.68 pixels of screen, at a
fractional origin as well. Ten point text resampled by a third of a pixel is exactly as
blurry as it sounds, and small blurry text reads as a badly made thing. The frame is now
snapped out to whole device pixels and its origin snapped down to one.

**Cramped.** 11pt over 9pt with 8x5 padding, unchanged since the first version. It is the
app's entire on-screen interface and it looked like a debug overlay. Now 13pt semibold over
10pt medium, 11x8 padding, an 8pt corner, and the colour swatch is a drawn circle in its own
column rather than a "●" typed into the string and recoloured — the glyph was at the mercy
of the font and looked like a typo at that size.

**The plate is dark, and the mode is a red stripe down its left edge.** A red plate was
tried first and it cost the badge the thing it exists for: the swatch is the only place the
pen's colour appears anywhere on screen, the first pen is red, and on a red plate the swatch
vanished into the plate. Dark plate, red stripe: every colour reads, and the stripe still
says clicks are being captured. Click-through drops the stripe, because nothing is.

Both were found by rendering the badge offscreen to a PNG and looking at it, which is worth
doing again before changing it — the suites will not catch blurry.

## 23. Undo works from anywhere, names strokes, and survives a hide

Three faults, reported as one. All of them made undo do nothing, or the wrong thing, in a
state nothing on screen distinguishes from the working one.

**`⌘Z` only worked while the panel had the keyboard.** The panels are `.nonactivatingPanel`
on purpose — drawing over a presentation must not pull focus out from under the presenter —
and the price is that they only get key events while this app is the active one. Click
anything at all in another app and `⌘Z` inside the overlay is a silent no-op.

**Chosen:** a fourth global shortcut, `⌃⌥⌘Z`, on Carbon like the other three, so it works
whatever has focus. `⇧⌃⌥⌘Z` redoes, and comes with it rather than after it: an undo that
always works next to a redo that only sometimes does is a trap, because one press too many
leaves the way back depending on a focus state the user cannot see. `⌘Z` still works when the
panel is key. **Rejected:** making drawing mode activate the app. It would fix the shortcut
and break the reason the panels are non-activating.

With one canvas per display, the shortcut applies to the screen the pointer is on, falling
back to the screen carrying the badge.

**Undo took back the wrong stroke.** `Edit.added` was applied with `strokes.removeLast()` —
the same thing as the stroke that was added, right up until it is not. Temporary ink is
recorded like anything else but removed when it fades, without an edit, so a faded stroke
could leave its entry behind; the next undo then took back somebody else's line and offered
the expired one back on redo. Now every `Stroke` carries a `UUID` and an edit names one:
undo removes *that* stroke, steps over an entry whose stroke is no longer there, and
`advanceFade` drops the entries naming ink it has just taken away.

**Hiding the overlay threw the history away.** `restore` cleared both stacks, on the reasoning
that undoing into a drawing you did not make is worse than not undoing at all. True in
general, and wrong here: this is the same drawing, in the same session, going back on the same
screen. What the rule produced was `⌃⌥⌘D` twice and no way to take back the last five minutes.
The history now travels with the ink, minus the entries naming temporary strokes, which do
not travel.

Both of the last two are regression checks in the behaviour suite, and both were run against
the old code first to confirm they fail: 2 where 1 is wanted, and 1 where 2 is wanted.

## 24. Tools are picked by pushing the mouse, not by remembering a letter

The tool keys work and are not going anywhere, but they ask the user to remember seven
letters. A radial menu asks them to remember one key and a direction, and the direction is a
forty-five degree wedge of the whole screen rather than a target to hit — so it can be driven
at speed, without looking, in the middle of talking to a room. That is the difference between
a tool you use while presenting and a tool you stop presenting to use.

**Hold, push, let go.** `⌥Z` opens the tools, `⌥X` the colours, `⌥C` the widths. The wheel
appears where the pointer already is. Letting go picks whatever the pointer is pushing
towards; letting go in the dead zone in the middle picks nothing, which is the only way out
of a wheel opened by mistake and so has to be exactly nothing. Sector zero is due right and
they run clockwise, which puts the two that need no thought — the pen and the eraser — a
flick right and a flick left.

**Three decisions worth the words:**

- **The wheel keys are registered only while the overlay is up.** `⌥Z` types something. Taking
  it system-wide for a tool picker that means nothing without a canvas would be rude, so it
  is registered on entering drawing mode and unregistered on leaving.
- **The pointer is polled, not received.** `NSEvent.mouseLocation` on a timer, rather than
  taking mouse events. That is what lets a wheel work in drawing mode, in click-through and
  over any app, without the panel having to take the mouse away from what is underneath —
  and it needs no permission. The poll runs only while a wheel is open. It also made the
  gesture testable: the tracking takes the pointer as an argument, so the behaviour suite
  drives the whole thing without a hand on the mouse.
- **The wheel has its own small panel.** A repaint costs more the larger its rectangle and the
  overlay's is the whole screen; the wheel is three hundred points across and repaints its
  own backing store, never the ink.

**Measured** (`Testing/probes/onscreen.swift`, warping the pointer in a circle once a second,
against a control that warps with nothing open): open with the pointer still, **1.0%** of a
core — that is the poll and nothing else. Open and being swept, **3.8%**, which is eight full
repaints a second while the highlight moves. A wheel is up for about a second at a time, so
this is small in the only sense that matters; it is recorded because the claim was that it
would be free and it is not quite.

Most of it was worse. Building the tinted glyphs on every repaint — eight `NSImage`s a frame,
because a template image does not take the current fill colour — cost **6.6%**. They are
cached now; there are only ever sixteen.

**The eighth tool is the laser and will be the text tool.** Nine tools do not fit in eight
sectors. The laser holds the slot until there is a text tool, and keeps `Space` either way,
which is where a momentary thing belongs. Changing what a sector means is a real cost to
someone who has learned it, so it is one slot, once, and written down here first.
