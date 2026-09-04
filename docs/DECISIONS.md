# Decisions, and what they cost

Why the code looks the way it does. Most of these were arrived at by measuring, several by
getting it wrong first. Each entry says what was chosen, what was tried instead, and the
number or the failure that decided it - so nobody has to run the experiment twice.

Ordered roughly by how much they constrain everything else.

---

## 1. The app asks for no system permissions

**Chosen:** Carbon's `RegisterEventHotKey` for global shortcuts, `CGWindowListCopyWindowInfo`
for window geometry, and nothing that triggers a TCC prompt.

**Rejected:** `CGEventTap` and `NSEvent.addGlobalMonitorForEvents` (Accessibility),
`CGWindowListCreateImage` and window titles (Screen Recording), Apple Events (Automation).

Asking for nothing is the app's defining property - it installs and runs without a single
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
target app's document - an annotation written into a PDF, a shape added to a Keynote slide -
needs a coordinate bridge from screen space to document space. There are only three ways to
get one: ask the app (Automation/Accessibility), render the document yourself (become a
viewer), or look at the screen (Screen Recording). Each ends the no-permissions promise, and
the per-app adapters would turn a 2,700-line tool into a product with a maintenance surface
per target app.

## 2. The overlay sits at window level 101 (`.popUpMenu`)

**Measured** on macOS 26.5.1 with Keynote 13.2: a running slideshow puts its windows at
level 9 and its fade at 26; the menu bar is 24, status items 25.

**Tried and rejected:**

- `.floating` (3) - the original. Invisible over a Keynote slideshow, which is the app's
  main use case. This was the bug that started the whole investigation.
- `CGShieldingWindowLevel()` (2147483628) - chosen defensively before anything was measured.
  Works, but the extra two billion levels buy nothing except covering more system UI.
- Level 23, one below the menu bar - chosen deliberately so the menu bar item stayed
  clickable while drawing. It was worse in practice: the menu bar and its status items are
  above 23, so whenever the pointer went near the top of the screen they took both the
  cursor and the clicks. The real pointer flickered back into view and menus could be opened
  mid-stroke.

101 clears everything measured and leaves drawing mode owning the screen. It is only safe
because no way out depends on anything on screen: every shortcut that matters is global, and
the panic key quits the process.

## 3. Escape does nothing while drawing

**Was:** Escape left drawing mode.

**Problem:** it only worked while the panel happened to be the key window - a state nothing
on screen shows - so the same keypress worked or did nothing depending on where the user had
last clicked. And it was actively harmful: Escape is how you leave a slideshow, and pressing
it threw the drawing away.

**Now:** `keyDown` returns without calling `super` (which also stops AppKit's "no responder"
beep), and `cancelOperation` is overridden for the same reason. Switching to click-through
calls `NSApp.deactivate()`, because handing over the mouse was not enough - the panel stayed
key, so Escape was still being swallowed in the one mode whose point is that input belongs to
the app underneath.

**Knock-on:** 82 lines of key-focus reclaiming machinery - a resign-key observer, a settling
timer, a rate limiter, a menu-open flag, an "is any popover on screen" probe - existed only
to keep Escape alive. All of it was deleted.

## 4. `⌃⌥⌘D` hides, `⌃⌥⌘Esc` quits, `C` erases *(reversed - see 30)*

**None of these keys exist any more except `⌃⌥⌘Esc`.** Hiding is the middle of the `⌥Z`
wheel, erasing is `CLEAR` on `⌥V`, and undo is that wheel's hub. What is still true is the
shape of the reasoning below, which is why it is kept: the everyday way out must not destroy
a drawing, and the panic key must end the process.

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
- `C` (or Delete) is the only thing that erases - and it is undoable.

Kept drawings are tied to the display layout they were made on and dropped when it changes,
rather than restored onto the wrong screen at the wrong scale. What is kept includes the undo
history (entry 23).

## 5. Holding the shortcut draws momentarily *(reversed - see 26 and 30)*

**There is no momentary overlay now.** The key that would have been held opens a wheel
instead, and the gesture that used to mean "hold to draw" means "hold, push, let go".

A toggle asks the user to remember they left it on. Holding does not: press, scribble, let
go. That is what makes the app something you leave running rather than something you switch
on for a task.

Tap and hold share `⌃⌥⌘D`, split at **400 ms**. Momentary applies only when the press is what
opened the overlay - holding while already drawing would have to undo the tap action
mid-hold, which reads as the shortcut fighting you. Stepping into click-through during the
hold means you meant to stay, so the release leaves it alone.

This needed `GlobalHotKey` to carry the release half of the keypress
(`kEventHotKeyReleased`). If a system ever fails to deliver it, the hold degrades to a tap -
the old behaviour, not a broken one.

## 6. Each tool draws its own pointer

This has been walked round twice, so the whole loop is here.

**Tried:** `NSCursor.crosshair`, then `NSCursor.hide()` with `CGDisplayShowCursor`. Hiding is
per application and only applies while that application is active, so a background
`.accessory` app hides nothing; the attempt put two pointers on screen during a presentation.

**Tried:** a fully transparent cursor with the app painting its own crosshair underneath. It
holds only while we own the window under the pointer, and the moment something else takes the
cursor - the menu bar does it reliably - the real arrow is back for good with our crosshair
still painted beside it. There is no failure mode between invisible and doubled.

**Tried:** the system arrow with a coloured ring composited around its tip. Safe, and nobody
liked it: an arrow is what you get when nothing is happening, so an overlay taking every click
on the screen looked exactly like one that was not.

**Now:** each tool draws its own pointer in the colour it will draw with. A pen is a nib, a
highlighter is a chisel, the shape tools are a fine crosshair with the shape they make beside
it, the eraser is a ring the size of the hole it leaves - the only cursor that changes size,
because its size is the whole point of it - and the laser has none at all, since its glow is
on the overlay and two marks are worse than one. Losing cursor ownership degrades to the plain
system arrow: something a user can see and understand, rather than a bug.

Everything is drawn light-cased over a dark core so it reads on a white slide and a black one,
which is checked by rendering the set over both (`Testing/probes/cursor.swift`).

**The wheel has to wear it too.** The wheel panel sits above the overlay, and a window with no
cursor rect is a window that shows the system arrow: opening a wheel put the arrow there, and
closing it did not necessarily take it away, because the pointer had not moved and so nothing
asked for a cursor again. That is the arrow people saw after picking a size and going back to
drawing. The wheel is handed the tool's cursor when it opens, and asked for one again *after* a pick
has been applied and *before* the panel goes away - otherwise there is a moment with no window
under the pointer that has an opinion, and what shows in that moment is the system arrow. That
moment is the flash of an arrow people saw between letting go of the wheel and the new tool
appearing.

**It has to be taken back, repeatedly.** Owning the cursor rect is not the same as keeping the
cursor. Anything that owns it for a moment leaves the plain arrow behind, and `cursorUpdate`
does not necessarily fire again on the way back in. The view re-sets the cursor as the pointer
moves - and while it is being dragged, which delivers `mouseDragged` and never `mouseMoved`,
so a whole stroke could otherwise be drawn under a system arrow - but only **eight times a
second**: measured, setting it on every move costs 2.3% of a
core, more than everything else a mouse move does put together, and eight times a second costs
a tenth of that and heals inside 150ms.

**And the arrow that was left was the window server's, not ours.** The report was "picking a
tool shows the system arrow for a moment first", and every offscreen test disagreed, because
`NSCursor.current` - this app's own idea of the cursor - was right the whole time.
`Testing/probes/cursorflash.swift` samples `NSCursor.currentSystem`, which is what is actually
on the screen, every four milliseconds through the whole gesture, and the answer was plain:

- **A panel that appears under a stationary pointer is handed the plain arrow**, by the window
  server, about 25ms after it appears - whatever the app set before that. Nothing asks the app
  again until the mouse next moves, so picking the *first* tool, the pick that creates the
  panels, left the system arrow on the screen for as long as the user held still.
- **Closing the wheel over an overlay that already exists does not do it.** Only a window
  arriving does, which is why the second tool picked in a session looked fine.

So `takeCursorBack()` keeps asking: every 120th of a second for a third of a second after a
panel appears, then it stops. Measured: no arrow at all in a 4ms sampler, against 24ms of it
at 30Hz and "until the mouse moves" before. Forty-two cursor sets is a millisecond and a half
of CPU, once; the bound is what keeps an idle overlay at nothing.

**And then it was reported again**, with every path this repo can drive measuring clean: the
probe fires the real hot keys through the real handlers and walks all seven ways in and out,
and none of them leaves an arrow. A symptom that survives a fix nobody can reproduce is worth
answering at the symptom, so there is a second, slower half: `holdCursor()` re-sets the tool's
cursor **a hundred and twenty times a second for as long as drawing mode is on**, and stops on
click-through and when the overlay goes away. Whatever hands the arrow out, it holds for less
than a frame - the rate got there in three steps, and entry 38 has the measurements.

That is a poll, and this app does not like polls, so it was measured before it was written:
`NSCursor.set()` costs **0.049ms**, which is 0.6% of a core at 120Hz - and setting it blind is
three times cheaper than asking `NSCursor.currentSystem` what is on screen first (0.157ms) and
only setting it when it differs. The per-move version this replaces did the same work eight
times a second but *only while the mouse was moving*, which is exactly the case that was not
being reported. It is gone from the event path, so a mouse move is one `Date()` and one
comparison cheaper than it was.

**A crash to not repeat:** the first version called `window.invalidateCursorRects(for:)` from
inside `cursorUpdate`. That re-enters AppKit's tracking machinery and throws - `SIGABRT` the
moment the pointer moved over the panel. Rebuilding cursor rects lives in its own method that
only mode and tool changes call.

**And then the whole thing was reversed, because of the one case this app exists for.** The
note that used to sit here said it was *unverified* whether a presenting app that hides the
pointer hides ours too. It does. Reported from a real presentation: the wheel opened, no
pointer was visible anywhere, and of all the tools only the laser could be seen - which is
exactly the shape of the answer, because the laser's glow was always a layer on the overlay
and every other tool was a cursor.

Two things were measured before changing anything, with a stand-in for a slideshow (a
frontmost app that hides the pointer, and a background app that tries to see and undo it):

- **We cannot tell.** `NSCursor.currentSystem` reports a perfectly visible cursor while the
  pointer is hidden - in the hiding process as well as in the watching one. There is no public
  way to detect it, so there is no way to fall back only when it happens.
- **We cannot undo it.** `CGDisplayShowCursor` and `NSCursor.unhide()` from another process
  change nothing. Hiding is per application, and so is unhiding.

So the pointer is a **picture on a layer** now, like the laser's glow, and the window server is
handed `PointerCursor.invisible` - a cursor that exists so nothing else claims the pointer and
draws an arrow beside ours, and that shows nothing. What is drawn is unchanged: the same nib,
chisel, crosshair and ring, from the same code, at the display's own scale.

**What it costs is latency, and that is the honest part.** A cursor is composited by the
window server the instant the mouse moves; a layer waits for a commit and the next frame. The
pointer's position is therefore set inside its own `CATransaction` and committed at once
rather than left to the end of the run loop's turn - which is standard practice for a layer
that follows a hand, and whose effect **could not be measured here**: back to back on a busy
machine, with and without, the difference in every row of `probes/onscreen.swift` was smaller
than the run-to-run noise (±1 point). It is kept because it cannot hurt and the reasoning is
sound; it is written down as reasoning rather than as a number, which is the rule in this repo.

Turning **mouse coalescing off** was considered for the same reason and rejected: the pointer
is drawn by us now, so it cannot appear more often than the screen refreshes, and coalescing
is exactly what keeps the event rate at the refresh rate. More events would be more work per
frame for a pointer that can only move once per frame.

The failure this design had the first time - lose the cursor once and there are two pointers
with no way back - is what the cursor hold above is for: the invisible cursor is re-set sixty
times a second, so the worst case is about a frame of a second pointer, against a pointer that
was missing for an entire presentation. The wheel wears the same nothing and draws its own dot at
the pointer, because it sits above the overlay and, with no overlay open at all, there is
nothing else to draw one. And `takeCursorBack()` puts the ordinary arrow back whenever drawing
mode is not on, which is the line that stops a wheel closing over no overlay from leaving
somebody with no pointer at all. The behaviour suite checks that last one by name.

## 7. Repainting is incremental

A drag invalidates only the rectangle the new segment covers, and `draw(_:)` skips strokes
whose bounds do not meet `dirtyRect`. Repainting the whole view per mouse move made the cost
of a drag grow with everything already drawn: the same 960-event session took **0.325s that
way against 0.012s this way - 26x**.

**On the differences the rendering suite used to report:** a handful of pixels differed by
1-15/255, and the explanation on file was antialiasing where a clip boundary crosses a
stroke. That was wrong. It was the **crosshair**, composited over the ink against different
clip rectangles in the incremental pass than in the single pass. With the pointer on a layer
of its own (entry 20) the suite reports **0 differing bytes at 1x, 2x and 3x**.

The related measurement still stands on its own: **expanding every dirty rect makes seams
worse, not better** - 275 bytes at 2x became 733 at +20pt and 4,482 at +60pt, with the
per-pixel error unchanged. More repainting means more seams.

## 8. Temporary ink fades itself, on a layer

Temporary ink (`T`) holds full strength for the first 55% of three seconds, then goes.

**How it used to work:** a timer at 15 Hz walked the strokes, worked out each one's opacity,
and asked for a repaint of the region covering all of them. Two costs were found and fixed
along the way - invalidating each stroke separately made the cost grow with the square of
what was on screen (12.5% CPU with fifty of them, 5.0% invalidating the union once), and the
tick rate was settled at 15 because 20/s cost 5.1%, 15/s 4.4% and 12/s 4.3%. End to end that
came to 2.8% of a core with three strokes fading and 3.8% with fifty.

**Then the ink moved to a `CALayer` (entry 21) and that arithmetic inverted.** A layer repaint
is four times cheaper than a view repaint for a small dirty rect and about four times dearer
for a whole-screen one - and the union of every fading stroke *is* most of the screen once
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
out of life so the model agrees with the screen - the eraser, undo and "is anything still
fading" all read the canvas, not the layers. Nothing waits on it, so it can be slow. It still
starts with the first temporary stroke and stops with the last, so idle is still 0.0%.

The layers are reconciled against the canvas after anything that changes it, rather than each
of erase, undo, redo, clear and restore knowing about them. That is what keeps the eraser
working on temporary ink without the eraser knowing where temporary ink lives.

`Stroke.opacity(at:)` went with the old scheme. Nothing computes a fade curve any more.

**A fade starts when the mark is finished, not when it was begun.** `createdAt` was stamped on
the mouse going down, so anything that took longer to draw than it was meant to last had
already expired by the time it landed: the layer was never made, the next tick dropped the
stroke, and what the user saw was ink vanishing the instant they lifted the pen. Three seconds
is long enough that most drawings escaped it; half a second is not, so the laser did it every
single time. `Stroke.startingNow()` re-stamps the clock in `finishStroke()`, which is the one
place a mark stops being drawn and starts being kept.

## 9. The menu bar icon is never tinted

**Measured:** rendering the status button with `contentTintColor` set gives mean luminance
**0.000** - black, on a dark menu bar, which is invisible. Untinted it renders at 0.791.
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
other window - a failure at login would look exactly like a hang, menu bar icon present and
nothing responding. Unregistered shortcuts show as a disabled line at the top of the menu
instead. `NSAlert` does not appear in the app at all.

## 12. Leaving drawing mode on a display change, but only a real one

`didChangeScreenParametersNotification` fires for more than displays coming and going. It
fires when the Dock or the menu bar hides - which is what happens when a presentation
starts. Measured during a Keynote slideshow: it fired at 2.4s (Keynote coming forward) and
again at 14.0s (slideshow ending), both times with the screen frame unchanged at 1512x982
and only `visibleFrame` moving a few points. Reacting to it tore the overlay down at the
exact moment the user started presenting.

The display layout (display ID + frame, neither affected by the Dock) is recorded on entry
and compared on each notification. Same layout, nothing happens.

## 13. Closed panels do not count as an overlay

`overlayWindowSnapshot()` re-scans `NSApp.windows` as insurance against a panel that is on
screen but has fallen out of our arrays. It filters on `isVisible`, because closed panels
linger in `NSApp.windows` until they are deallocated - and counting those meant that right
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

## 15. The tools are keyboard-only *(reversed - see 30)*

**Rejected:** an on-screen palette or toolbar. A tool that occupies screen space is not one
people leave running in the background, and drawing mode is supposed to interact with
nothing - a clickable palette would need an exception to that.

So: bare letters and digits, no modifiers to hold while the other hand draws. `P H L A R O E`
for tools, `1`-`6` colours, `[` `]` width, `Space` laser, `T` temporary ink. The corner badge
is the only readout, showing the tool, its width and a dot in the current colour.

## 16. A stroke carries its own attributes, and its points

`Stroke` holds the colour, width and style it was drawn with, so changing the pen never
touches what is already on screen. It keeps its points as well as its `NSBezierPath` because
the eraser has to answer "is this stroke near the pointer?", which a path can only answer for
its filled area, not for the line itself.

The eraser used to remove whole strokes rather than splitting them, on the grounds that "take
that line away" is what people mean on an annotation overlay. It was wrong, and the way it was
wrong is instructive: **it made the eraser's own size meaningless.** One touch anywhere on a
line took the entire line, so a two point eraser and a thirty point one did exactly the same
thing, and the width control did nothing at all.

It cuts now. A freehand stroke keeps whatever of itself the eraser did not pass over, and the
size is the width of the hole it leaves. The geometry is a circle against each segment in
turn rather than against each point, because mouse moves are dense while drawing slowly and
sparse while drawing fast, and an endpoint test would let a fast line straight through.
Survivors shorter than the pen that drew them are dropped: with a round cap they render as a
dot sitting in the hole, which reads as dirt.

**Shapes are cut too**, and getting there took a second pass. A shape's `points` are only the
two corners its drag was defined by, so measuring the eraser against them measured against a
rectangle's *diagonal* rather than its outline: over most of a shape the eraser did nothing,
and where it did reach it took the whole thing. That is the "sometimes it erases, sometimes it
does nothing, sometimes it destroys it" that was reported. Shapes are flattened into polylines
now and cut like anything else. What is left is no longer a shape, which is right - a piece
was rubbed out of it.

**And it rubs along the way, not just where the events land.** A mouse move can jump a hundred
points when the hand is quick, and cutting a circle only at each sample skipped whatever lay
between two of them. Overlapping circles along the segment cover it, which reuses the one
piece of geometry that is already tested instead of inventing a capsule.

**One bug worth naming**, because it hid inside a correct-looking algorithm: when a segment
*left* the circle, only the exit point was recorded, not the segment's own end. On a middle
segment that dropped a point; on the last segment of a stroke it left a one-point run, and a
one-point run is discarded - so the entire tail of a line past the hole vanished. It looked
exactly like an eraser that sometimes deletes too much.

**The rendering suite's stroke count moved with this**, from 5 to 7. Its session rubs the
eraser across a straight line, which used to be a shape and so was removed whole; now it is cut
and leaves two pieces. `differingBytes` stayed at 0 at every scale, which is the number that
suite exists to hold - the count is a description of the session, not a result.

**One drag is one undo.** Each mouse move that touches ink would otherwise be its own edit,
and taking back an eraser drag would mean pressing undo a hundred times to get a line back.
The drag records what it took away and what it left, once, on release.

Undo records edits (a stroke added, or strokes removed with the indices they came from)
rather than inferring them from the stroke list, which is what lets it put back what the
eraser and Clear took away, at the right depth. Each stroke carries a `UUID`, so an edit
names a stroke rather than pointing at a position - see entry 23 for what that fixed.

## 17. Temporary ink is not kept across a hide

It was drawn to vanish. Bringing it back mid-fade on the next show would be a surprise, and
its disappearance is not an edit, so undo has nothing to say about it either - which means
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
painting what a drag puts on screen costs **0.3-0.5%**. The ratio is about thirty to one, and
every idea that makes painting cheaper is bidding for that half point.

The same repaint asked for through a `CALayer` delegate costs **3.8%** - 4x less for
identical output - and moving a sublayer, which is not a repaint, costs **1.6%**. WindowServer
does not move in any of these runs, so this is our own process and not the compositor.

**The one caveat, and it has already bitten once:** the layer path is only cheaper for small
dirty rects. Its fixed cost is a quarter of the view path's but its cost grows with area,
where the view path's does not - 3.8% at 40x40, 21.0% at 400x400, 50.7% for the whole screen,
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
mouse is re-stroked in full on every mouse move, so a single unbroken line is quadratic -
the last tenth of a 5000-point line costs **5.5x** what its first tenth did. It is small in
absolute terms until a line gets very long, which is exactly when someone notices.

## 20. The badge is a layer, not paint

The crosshair used to be painted in `draw(_:)`, and following the mouse meant invalidating
where it had been and where it had arrived. Both rectangles are about 26pt square, which
sounded free and was not: a repaint of a full screen transparent overlay costs the same
whatever its dirty rect, so **painting the crosshair cost as much as painting everything**.
On a canvas with ink on it, more - the two rectangles union into one region and every stroke
that region touches is re-stroked, while the user is drawing nothing at all. Measured at 60
moves a second: **22.5% of a core**.

Moving it to a layer took that to 1.6%. It has since gone further and left the app entirely -
the pointer is a real cursor now (entry 6), which costs 0.5%, which is nothing. The layer
version is worth recording anyway, because the reasoning is what carried over to the badge.

**The badge went the same way, and for a sharper reason.** It changes when the tool, the
colour or the mode changes - a few times a session - but it was painted inside `draw(_:)`,
and the first thing it did there was measure itself, which meant building two
`NSAttributedString`s and laying both out **before** the check that would have skipped it.
So every repaint, for any reason anywhere on screen, laid out the badge's text.

With the pointer already off the repaint path, that layout was all that a mouse move cost:
**0.059 ms an event, painting nothing**. As a picture on a layer it is **0.029 ms**, and a
60-point drag over a canvas of 200 strokes went from 0.065 ms an event to **0.033 ms**.

Its old repaint machinery went with it - `repaintRegionAfterToolChange`, the repaint margin,
and the "old rect union new rect" rule that existed because a badge growing leftwards out of
the corner would otherwise be left half drawn. A layer that is given a new picture and a new
frame has no such problem. The whole-view repaint on a mode switch went too.

## 21. The ink is painted through a layer, not through `NSView.draw(_:)`

The measurement in entry 19 said the same repaint of the same full screen transparent layer
costs **15.7% of a core through AppKit's view display machinery and 3.8% through a
`CALayer`** - 4x, for identical output. Nothing about what is painted changes; the difference
is the path the repaint is asked through. The catch, which entry 8 paid for, is that this
holds for small dirty rects: a layer repaint costs more as its rect grows, and a view repaint
does not.

So `DrawingView` now owns three layers, bottom to top - ink, badge, pointer - and paints
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

**What is left.** Painting a drag is now about 0.2% of a core, so the remaining 4-5% is the
repaints themselves, one per mouse event. Two directions, in order: coalesce the repaints to
the display's refresh rate (worth only what the event rate exceeds it - unmeasured), and the
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
column rather than a "●" typed into the string and recoloured - the glyph was at the mercy
of the font and looked like a typo at that size.

**The plate is dark, and the mode is a red stripe down its left edge.** A red plate was
tried first and it cost the badge the thing it exists for: the swatch is the only place the
pen's colour appears anywhere on screen, the first pen is red, and on a red plate the swatch
vanished into the plate. Dark plate, red stripe: every colour reads, and the stripe still
says clicks are being captured. Click-through drops the stripe, because nothing is.

Both were found by rendering the badge offscreen to a PNG and looking at it, which is worth
doing again before changing it - the suites will not catch blurry.

**And then it was set the wrong size for two months.** Everything above was decided while the
badge was being painted at half scale by the bug in entry 28, including the type: 11 over 9 was
raised to 13 over 10 because it "looked like a debug overlay" in a picture where it was being
shown at half the size it is on screen. Once the scale was fixed, the placard that came back
was the compensation, not the design. It is 12 over 10 with 12x7 padding and a 10pt corner
now - 46pt tall down to 40 - and it is the picture in `probes/badge.swift` that says whether
that is right, at the scale it is actually shown at.

**The swatch became the tool.** A coloured disc said which colour and left the tool to the
words next to it. The same column now carries the tool's own SF Symbol, painted in the colour
it draws with: one mark, both facts, and it matches the wheel sector the tool was picked from
because both take the symbol from `DrawingTool` rather than keeping a list of their own.

**And it stopped shouting.** `PEN 4` became `Pen 4`, `CLICK-THROUGH` became `Click-through`,
and the notice is a sentence. The wheel still shouts, deliberately - eight labels read at a
glance across a room, in the second a wheel is up - but a sign that sits in the corner of
somebody's screen all day in capitals is one of the things that makes an app look like it
came from somewhere else.

## 23. Undo works from anywhere, names strokes, and survives a hide

Three faults, reported as one. All of them made undo do nothing, or the wrong thing, in a
state nothing on screen distinguishes from the working one.

**`⌘Z` only worked while the panel had the keyboard.** The panels are `.nonactivatingPanel`
on purpose - drawing over a presentation must not pull focus out from under the presenter -
and the price is that they only get key events while this app is the active one. Click
anything at all in another app and `⌘Z` inside the overlay is a silent no-op.

**Chosen:** a fourth global shortcut, `⌃⌥⌘Z`, on Carbon like the other three, so it works
whatever has focus. (Both of these keys are gone: undo is now the hub of `⌥V` and redo one of
its sectors - entry 30. What follows is why undo had to leave the keyboard's focus behind at
all, which is still the reason it sits on a global hot key.) `⇧⌃⌥⌘Z` redoes, and comes with
it rather than after it: an undo that
always works next to a redo that only sometimes does is a trap, because one press too many
leaves the way back depending on a focus state the user cannot see. `⌘Z` still works when the
panel is key. **Rejected:** making drawing mode activate the app. It would fix the shortcut
and break the reason the panels are non-activating.

With one canvas per display, the shortcut applies to the screen the pointer is on, falling
back to the screen carrying the badge.

**Undo took back the wrong stroke.** `Edit.added` was applied with `strokes.removeLast()` -
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
wedge of the whole screen rather than a target to hit - forty degrees of it with nine tools on
the wheel - so it can be driven
at speed, without looking, in the middle of talking to a room. That is the difference between
a tool you use while presenting and a tool you stop presenting to use.

**Hold, push, let go.** `⌥Z` opens the tools, `⌥X` the colours, `⌥C` the widths. The wheel
appears where the pointer already is. Letting go picks whatever the pointer is pushing
towards. Sector zero is due right and they run clockwise, which puts the two that need no
thought - the pen and the eraser - a flick right and a flick left.

**The hub of the tools wheel is the mode.** Letting go in the middle hands the screen back to
whatever is underneath; pushing at a tool takes it again and puts that tool in your hand. So
one gesture carries both, and there is no separate mode shortcut to remember alongside a tool
picker - which is the whole point, and why the hub says `CLICK-THROUGH` rather than `CANCEL`.
`⌃⌥⌘E` still does the same thing and is left registered as a way back that does not depend on
the wheel; it is one line to remove when the wheel has been lived with for a while.

The colour and width wheels keep a plain cancel in the middle. Reaching for a colour and
landing in the centre should not move the mode.

**Each wheel shows its own thing.** The colour sectors are swatches in the colour, not a
tinted icon. The width sectors are bars of exactly the line they will draw, not the same icon
six times with a number underneath. A menu that makes you read is a menu you cannot use
without looking.

**Three decisions worth the words:**

- **The wheel keys are registered only while the overlay is up.** `⌥Z` types something. Taking
  it system-wide for a tool picker that means nothing without a canvas would be rude, so it
  is registered on entering drawing mode and unregistered on leaving.
- **The pointer is polled, not received.** `NSEvent.mouseLocation` on a timer, rather than
  taking mouse events. That is what lets a wheel work in drawing mode, in click-through and
  over any app, without the panel having to take the mouse away from what is underneath -
  and it needs no permission. The poll runs only while a wheel is open. It also made the
  gesture testable: the tracking takes the pointer as an argument, so the behaviour suite
  drives the whole thing without a hand on the mouse.
- **The wheel has its own small panel.** A repaint costs more the larger its rectangle and the
  overlay's is the whole screen; the wheel is three hundred points across and repaints its
  own backing store, never the ink.

**Measured** (`Testing/probes/onscreen.swift`, warping the pointer in a circle once a second,
against a control that warps with nothing open): open with the pointer still, **1.0%** of a
core - that is the poll and nothing else. Open and being swept, **3.8%**, which is eight full
repaints a second while the highlight moves. A wheel is up for about a second at a time, so
this is small in the only sense that matters; it is recorded because the claim was that it
would be free and it is not quite.

Most of it was worse. Building the tinted glyphs on every repaint - eight `NSImage`s a frame,
because a template image does not take the current fill colour - cost **6.6%**. They are
cached now; there are only ever sixteen.

**The eighth tool is the laser and will be the text tool.** Nine tools do not fit in eight
sectors. The laser holds the slot until there is a text tool, and keeps `Space` either way,
which is where a momentary thing belongs. Changing what a sector means is a real cost to
someone who has learned it, so it is one slot, once, and written down here first.

## 25. The laser is a light on the overlay, not a mark on the cursor

It was drawn as part of the pointer: a glowing dot composited into the cursor image. Reported
as not working, and it is easy to see why. A cursor is only ours while we own the window under
the pointer, and being there is the one thing a laser has to do - in the middle of a
presentation, over anything, on whatever the audience is looking at.

**Now:** a layer on the overlay that follows the pointer, with a halo that falls off to
nothing and a hot core inside it, so it reads as light rather than as a drawn circle. It costs
a layer move and no repaint - 1.5% of a core at sixty moves a second, against 15.2% for
asking the overlay to repaint instead - and it does not care who owns the cursor.

The cursor's laser accessory went with it. Two spots of light an inch apart, one of which the
audience may not be able to see, is worse than one.

It goes out in click-through, because a laser dot on top of an app the user has just been
handed back is something in the way.

**It is light, not a pen line that disappears.** That is how it was reported - "the laser
does what the pen does, only rubbed out; it has no design of its own" - and it was exactly
right: a beam was an ordinary stroke in the pen's colour at a fixed six points, and the only
thing that made it a laser was that it went away. A beam is its own `StrokeStyle` now, painted
in three passes: a halo that spills past the line and falls away, the colour inside it, and a
white core down the middle - which is what the glow at the pointer had always looked like and
what its trail never did. The spill is `width + max(6, width * 0.8)` rather than a multiple of
the width, because at 2.6x the widest setting was a 55pt capsule of light with a beam
somewhere inside it.

Painting lives on `Stroke.paint()`, one place, because it used to be the same two lines in the
view and in the fading layer - which is how a beam could have got its own look in one of them
and not the other. `StrokeStyle.paintBeam` is public to the size wheel for the same reason:
the sector that offers a width paints the beam it is offering.

**And its size is a setting.** It was pinned at 6pt, so the size wheel offered the laser six
sectors that did nothing - the same fault the eraser had before its size started to mean
something (entry 27). A beam is one and a half times the width in hand, so the middle setting
is still the 6pt it always was, and the glow at the pointer grows with it, capped at 96pt
because past that it stops pointing at anything. `Testing/probes/laser.swift` renders the
trail, the sizes and the glow over a dark slide and a light one; the behaviour suite checks
that the core is white, that the halo reaches past the line, and that the size wheel moves
both the beam and the glow.

**The trail is a run of short pieces, not one stroke.** One stroke has one age and one layer,
so a beam drawn over two seconds held at full strength for all of it and then went out in one
go when the button came up - which is the opposite of what a laser trail does, and it is what
was reported as the fade not working. The beam is cut every tenth of a second now
(`Stroke.beamPiece`): each piece is finished, handed its own fading layer, and continued from
the point the last one ended, so the light thins out behind the hand while the hand is still
moving. A second of drawing is ten pieces of which about five are alive, against sixty if it
were cut per event.

**What it leaves behind is drawn by holding the button**, not by passing over. The first
version dropped a little dot every thirtieth of a second as the pointer moved, pressed or
not; it looked like beads, it drew things nobody had asked for, and it cost more than the
laser itself. Holding the button now draws an ordinary stroke that happens to live half a
second - the fading-ink machinery doing its job, with the life carried on the stroke rather
than fixed at three seconds for everything. It is smooth, because it is a stroke, and it
costs what drawing costs, only while the button is down. Following the pointer with nothing
held is **1.3% of a core**.

**How it went wrong three times**, because the pattern is worth recognising: a decoration on
the cursor (invisible whenever something else owned the cursor), then a layer moved by
`mouseMoved` (which only reaches the key window, so it froze the moment the user had clicked
another app), then a trail of dots dropped whether or not anyone had pressed anything. The
first two were fixed by the answer the wheel already needed - poll the pointer - and the
third by not inventing a mechanism where one already existed.

## 26. The wheel is the whole interface

`⌃⌥⌘D` and `⌃⌥⌘E` are gone. One key opens a wheel, and the wheel does everything the two of
them did:

- push at a tool - the overlay opens if it was not open, takes the screen, and hands you that
  tool;
- let go in the middle - you leave, one step at a time. From drawing, the screen goes back to
  the app underneath (what `⌃⌥⌘E` did). From there, again, and the overlay goes away with the
  drawing kept (what `⌃⌥⌘D` did).

**Leaving is the hub's job, not a sector's.** HIDE had a sector for a day and it was wrong
twice over: it spent one of eight tool slots on something that is not a tool, and it made two
different ways out of a wheel whose middle already meant "out". One direction, two steps, and
the hub says which step it is about to take - `CLICK-THROUGH`, then `HIDE`. The eighth sector
went back to the laser.

The point is not that it is fewer keys. It is that there is one thing to learn and it is
visible while you are using it: the wheel says what its middle does, and it says HIDE, so
nobody has to remember a combination that is written down somewhere else.

**`⌥Z` is registered for the life of the app**, not with the overlay, because it is now the
only thing that opens one. That costs `⌥Z` system-wide - it types a character otherwise - and
it is the strongest argument yet for the settings window and custom shortcuts. The menu bar
item stays as the way in if `⌥Z` is ever taken by something else; it always was, and now it
matters.

**What went with them:**

- **Hold-to-draw** (entry 5). Holding `⌃⌥⌘D` gave a momentary overlay - press, scribble, let
  go, gone - and there is nowhere for it on a wheel, because on a wheel letting go is how you
  choose. It was liked and it is a real loss. If it comes back it will be as its own key.
- **The laser's sector.** Nine tools do not fit in eight, and the eighth is now the way out.
  The laser keeps `Space`, which is where a momentary thing belongs anyway. A text tool will
  need a ninth sector rather than someone else's.

`⌃⌥⌘Esc` is untouched, and so is undo. The panic key still ends the process from any state,
which is the guarantee everything else is allowed to lean on.

## 27. Every wheel and every cursor shows what the tool in hand means by it

The principle was written down and then not applied, which the first version of the wheels
showed plainly: with the eraser in hand, the width wheel offered six horizontal bars - the
picture of a *line*, for a tool that does not draw one - and the colour wheel opened to offer
six colours to a tool that has no colour.

- **Width, for the tool in hand.** The pen's sectors are lines of what it will draw. The
  marker's are the same lines four times wider, which is what it will actually put down. The
  eraser's are rings of the hole it will take out, scaled into the sector but scaled rather
  than clamped, so the six still read in order.
- **Colour, with the eraser in hand,** does not open a wheel. Handing the pen back instead was
  tried for a day and was worse: it answered a question nobody had asked and changed the tool
  in your hand while you were still using the one you had. The badge says `THE ERASER HAS NO
  COLOUR` for a second and a half instead - which is what the badge is for, being the only
  place on screen this app can say anything at all.
- **The eraser's size actually varies, and it is not a thumb.** It was `max(12, width)`,
  which gave the same eraser for five of the six widths: the size control did nothing for four
  steps out of five, the same fault the eraser itself had before it started cutting. Then it
  was `6 + width * 2` - 20 to 68 points across - which overshot the other way: an eraser that
  big is answering the question the wheel's `CLEAR` already answers in one gesture. What is
  left for an eraser is the small correction, so it is `4 + width * 1.25` now, **13 to 43
  points across**, and its pointer is drawn true size as it always was.
- **The laser's sizes are beams.** The wheel paints each one the way the laser will paint it,
  in the colour in hand, because a flat bar is not what it will put on the screen - and
  because the laser's width was a setting that did nothing until entry 25 gave it one.
- **A fat marker does not get a fat pen for a pointer.** The drawing grew one for one with
  the width, and the marker is four times the width in hand, so at the widest setting the
  pointer was a 148pt pen following the mouse - clumsy however well it is drawn. Past a dozen
  points the barrel grows at a fifth of the rate (about 90pt at the widest) and the reach is
  capped; the six settings still read in order, which is all the pointer has to say. The
  eraser is the exception and stays true size, because its size *is* what it does.
- **The cursors are the tools.** A pen is a pen, a nib and a barrel held at forty-five degrees
  with its point on the hot spot, and it gets visibly fatter as the pen does. A marker is a
  chisel. An eraser is a ring the size of the hole. The four tools that place a corner share
  one clean crosshair, because they do the same thing with the mouse and a crosshair with a
  little picture beside it was two cursors in one place.

`Testing/probes/cursor.swift` and `probes/wheel.swift` render all of it, because none of this
is visible from a passing test.

**And the wheel highlights in the accent colour, not in ours.** The lit sector was this app's
own red, which is a choice a Mac app does not get to make: every other selection on the screen
is the colour the user chose in System Settings, and one thing that quietly says "this was
built somewhere else" is an interface that picks its own. Sectors that *are* a colour still
light in their own - choosing blue must not light up the accent - and the lit wedge keeps a
white edge whatever the accent is, so a graphite or a yellow one still reads as selected.

**It fades in and out, over a tenth of a second and a twelfth.** A HUD that snaps on is the
same kind of tell. The panel takes no clicks, so the fade on the way out is in nobody's way,
and the cursor underneath is being held for a third of a second anyway (entry 6).

## 28. Every picture a layer gets is painted in one place

Three things hand a layer a finished picture instead of painting each frame: the badge, the
laser's glow, and each piece of temporary ink on its way out. All three made their own bitmap,
and all three made the same mistake:

```swift
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 108, pixelsHigh: 108, ...)
let context = NSGraphicsContext(bitmapImageRep: rep)   // takes the size as it is now: 108pt
rep.size = NSSize(width: 54, height: 54)               // too late, the context is made
```

`NSBitmapImageRep` measures itself in pixels until it is told otherwise, and
`NSGraphicsContext` takes that measurement when the context is created. Setting `size`
afterwards renames the picture and leaves the context at 1x, so on a Retina display everything
was painted into the bottom left quarter of the bitmap and then stretched back over the whole
frame. Measured: a 20x20pt fill covered 400 of 1600 pixels at 2x and 400 of 3600 at 3x.

What that was on screen, and it is the whole of two of the three faults that were reported:

- **The badge at half size**, sitting inside a hover rectangle four times its area - so it
  also stopped drawing where the pointer was nowhere near it.
- **The laser's glow thirteen points down and to the left of the pointer**, at half its
  intended width. "It does not point at what I am pointing at."
- **Temporary ink jumping** down-left and shrinking to half size the instant the mouse came
  up, which is the moment the stroke is handed from the ink layer to a fading layer of its
  own. The fade was working; what people saw was the jump in front of it.

It is one function now, `Picture.drawn(size:scale:)`, with the order that matters on one line
and the reason next to it, and nothing else in the app makes a bitmap by hand. The behaviour
suite checks the coverage at 1x, 2x and 3x and checks that the glow's centre of mass is on its
hot spot; all four checks fail if the two lines are swapped back.

Fading ink also snaps its frame out to whole device pixels now, for the reason the badge
already did (entry 22): the stroke changes layers at the moment the mouse comes up, and a
picture resampled by a fraction of a pixel reads as the ink shifting under the hand.

## 29. The marker's line stops where the hand does

Reported as "the marker cannot keep up with the mouse, it moves coarsely, especially when it
gets thick". It was not the tracking. It was the cap.

Every `NSBezierPath` cap style except `.butt` extends the line *past* its last point by half
the line width. The marker is four times the width in hand - 56pt at the widest - so its ink
ran up to **28 points ahead of the pointer**, and because the overshoot points along the last
segment, it swung around every time the hand changed direction. At 2pt the same fault is a
one-point overhang nobody can see; at 56 it is a slab.

The marker's cap is `.butt` now, which is also what a real chisel tip does. What it costs is
the one case a butt cap cannot draw: a tap has no length, and a line of no length with butt
caps paints nothing at all. `Stroke.paint()` draws that dab explicitly - the square a chisel
would leave - and the behaviour suite checks both halves: that there is no ink past the end of
a line, and that a tap still leaves a mark. Swap the cap back and the first one fails.

**Smoothing was considered and not done.** The obvious next thought is that the chords between
mouse samples are what looks coarse, so the polyline should become a curve. Rendered side by
side at fifteen samples and at sixty (`Testing/probes/ink.swift`), the difference is small at
2pt and invisible at 56pt - a wide line hides its own chords. It would also cost the thing the
report was about: a midpoint curve ends half a segment behind the hand, so the ink would lag
the pointer unless a separate tail were drawn every frame. Not worth it for what it buys.

## 30. Everything is on the Option row, and none of it depends on focus

`⌥Z` tools, `⌥X` colour, `⌥C` size - and now `⌥V`, the things you do *to* a drawing rather
than with it: undo, redo, clear, temporary ink, hide. Four keys in a row under the left hand,
one family, and every one of them a global hot key, which is the part that matters.

**The hub of this one does something.** Every other wheel's middle is a cancel; this one's is
`UNDO`, so a tap of `⌥V` takes one thing back and a run of taps takes back a run of them.
Taking things back is the only job here that is done over and over, and a push-and-release
gesture for each would be the wrong shape for it - while `REDO`, `CLEAR`, `TEMP INK` and
`HIDE` are all things you do once and are worth a deliberate push.

**Temporary ink says so three times.** Ink that fades on its own is alarming if you did not
mean to switch it on - "why is my drawing disappearing?" is not a quiet question, and the
answer used to be a quiet word: the badge read `Temp Pen 4` and that was all. Now the badge
carries an orange `TEMP` mark beside the tool, the wheel's own sector reads `TEMP INK ✓` while
it is on, and switching it says out loud what it did - "strokes fade after 3 seconds" - for a
second and a half. The badge's second line, which is the only thing on screen telling somebody
whose clicks have stopped working what to press, is untouched: the mark fits in the width the
hint line already needed.

**A wheel only appears if you hold the key**, and under a tenth of a second it is a tap.
Pushing the mouse out of the dead zone shows it at once however short the press has been,
because at that point the user is plainly aiming at something. The threshold was 180ms first
and that was reported as slow; 110ms is long enough that a tap does not flash a wheel and short
enough that holding one feels like it opened rather than thought about it.

**The gesture is measured from the pointer, not from the wheel.** A wheel opens centred on the
pointer, except near a screen edge, where the panel is pushed back on screen so that no sector
is drawn off it. The offset the selection is read from used to be taken from that panel's
centre - so with the pointer resting near an edge it was already outside the dead zone before
the hand moved: the wheel came up on its own with a sector lit, and letting go chose it. A tap
of `⌥X` in the corner of a screen changed the colour. The origin is now the pointer's own
position when the key went down, and the panel is only *drawn* where it fits; the dot moves in
the ring exactly as the hand pushes. Pushing towards an edge is still limited by how far the
pointer can travel, which no choice of origin can help with. This is what made the behaviour
suite's two tap checks depend on where the mouse happened to be resting when it ran.

**And a tap does nothing on any of them.** Their hubs mean "leave" and "cancel", these are keys
the whole system now gives up to this app, and a key hit by accident must not move somebody's
mode or their colour: leaving is worth the deliberate gesture of holding the wheel open and
pushing at its middle. Undo was the exception here for a while - a tap of `⌥V` took one thing
back - and entry 31 says why it stopped being one.

**Why `CLEAR` moved onto a wheel.** It was the bare letter `C`, and that was wrong twice over:
it is easy to hit by accident for something that erases a whole drawing, and it only worked
while this app happened to have the keyboard - which is a state the user cannot see. A push on
a wheel is deliberate, and it works from anywhere.

**And the rest of the bare keys went with it** - `P` `H` `L` `A` `R` `O` `E`, `1`-`6`, `[` `]`,
`Space`, `T`, `⌘Z`, `⇧⌘Z`, `Delete`. Every one of them had the same fault: they were dispatched
to a non-activating panel, so they worked while this app was the one being typed at and
silently did nothing the moment the user clicked anything else. That is worse than not
existing, because the user cannot see which of the two states they are in. Entry 15 said the
tools were keyboard-only; that is now reversed, and what replaced it is one mechanic with
nothing underneath it. `⌃⌥⌘Z` and `⇧⌃⌥⌘Z` went too, first onto the hub of `⌥V` and then onto
`⌥Z` (entry 31), which is one hand and one key either way.

The keyboard is still *swallowed* in drawing mode, for the reason it always was: an unhandled
key travels up the responder chain and ends in a system beep, and `⌘Q` in the middle of a
stroke is not what anybody meant.


## 31. Undo is a key of its own, on `⌥Z`, and the row moved right *(the row moved again - see 36)*

**Was:** undo was the hub of the `⌥V` wheel. A tap of that key took one thing back, which
worked and was measurably fast, but it had to be learned twice over - that a tap is different
from a hold, and that this one wheel's middle does something where the other three cancel.

**Now:** `⌥Z` undoes and opens nothing. The rest of the row shifted one letter right:

| Key | Was | Is |
| --- | --- | --- |
| `⌥Z` | tools wheel | **undo** |
| `⌥X` | colour wheel | tools wheel |
| `⌥C` | size wheel | colour wheel |
| `⌥V` | actions wheel | size wheel |
| `⌥B` | - | actions wheel: redo, clear, temporary ink, hide |

**Why `Z`.** Every application on this machine puts undo on `Z`, and the finger goes there
before the head does. A shortcut that agrees with the rest of the system is one fewer thing to
learn, and undo is the thing a drawing tool asks for most often after the pen itself.

**One thing in one place.** The actions wheel's hub is a plain cancel now, like the colour and
size wheels. Undo living in two places meant two answers to "how do I take that back?", and
the wheel's answer was the one that needed explaining. `WheelPanel` lost `actsOnTap` with it:
all four wheels now do nothing at all on a tap, which is one rule instead of two.

**Holding it repeats**, after 400ms and then every 100ms, because `⌘Z` repeats everywhere else
and taking back five things should not be five deliberate presses. It is a timer, so it obeys
the rule every timer here obeys: it exists only while the key is down, and the overlay closing
mid-press ends it. The behaviour suite checks both ends.

**What it costs.** `⌥X` is now the key registered for the life of the app - the way in - so it
is `⌥X` rather than `⌥Z` that is taken from every other application on the machine. `⌥Z` and
the other three come and go with the overlay, because with no overlay open there is nothing to
undo and no wheel worth opening.


## 32. The shortcuts are settings, and each wheel's delay with them

**The problem is one macOS will not solve.** Two applications can register the same global
shortcut and both succeed; neither is told, and the one that registered first wins (entry 1).
So a user whose `⌥X` already belongs to something else has a key that does nothing, no way to
find out why, and - until now - nothing to do about it. The menu bar item was the whole
answer, and it is a poor one: it is a way to work *without* the shortcut, not a way to have it.

**Chosen:** five bindings in `UserDefaults`, read on launch and re-registered when they change,
and one window to change them in. The window is built in code, is not modal, and is only on
screen when somebody has opened it from the menu.

**Three rules the settings enforce**, because a setting that can be wrong is worse than no
setting:

- **Every binding needs `⌘`, `⌥` or `⌃`.** A global hot key with no modifier takes that letter
  from every application on the machine - typing `z` in a text field would undo instead. The
  check is on the way in as well as on the way out, because a defaults file can be edited by
  hand.
- **No two of ours on one combination.** macOS would accept it and leave one of them dead.
- **The panic key is not in the list.** `⌃⌥⌘Esc` has to be true whatever else has been
  changed, including by somebody who has changed everything else (CLAUDE.md, never number 4).
  It is shown in the window, greyed, so that it is knowable.

**Recording needs the hot keys down.** They are global: pressing `⌥X` to record it would open
the tools wheel over the settings window. So arming a recorder unregisters everything and
disarming puts it back - which is also what happens when the window is closed with a recorder
still armed, because an app with no shortcuts at all is the worst state this window could
produce. Keys are read with `keyDown` on the recorder itself rather than a global monitor: a
global monitor needs Accessibility, and this app does not ask for it. `performKeyEquivalent`
is overridden too, or nothing with `⌘` in it could ever be recorded - AppKit offers those to
the window before they are ever a `keyDown`.

**The delay is per wheel.** 110ms is where the threshold has been since it was measured (entry
30), and it is a compromise: long enough that a tap does not flash a wheel, short enough that a
hold does not feel like a wait. Which side of that people fall on differs, so it is a number in
the window, 0 to 500ms. **Zero has a meaning**: the wheel is on screen the moment the key goes
down, and there is no tap to speak of.

**What is deliberately not in this window:** colour, width, the tool, temporary ink. Every one
of those is a wheel already, in the hand, where the drawing is - moving them into a window
would be moving them away from the work (entry 24). The window holds the things you set once
and forget.

**Testing it.** The rules are behaviour checks; the layout is a by-hand report rather than a
picture, because the window's controls are hosted views and `cacheDisplay(in:to:)` draws
nothing for them - see `Testing/README.md`.


## 33. The app says so when there is no way into it

**The failure.** macOS hides a status item when the menu bar has no room, and tells the app
nothing. For an app whose entire interface is a menu bar icon and a global shortcut, that plus
a shortcut another application already owns (entry 32) is indistinguishable from an app that
did not launch: nothing on screen, nothing in the Dock, nothing answering the keyboard.

**Measured first, because the fields lie** (`Testing/probes/statusitem.swift`, which crowds the
menu bar with forty items of its own rather than waiting for a busy machine):

| field | fits | does not fit |
| --- | --- | --- |
| `statusItem.isVisible` | true | **true** |
| `button.window.isVisible` | true | **true** |
| `window.occlusionState` contains `.visible` | **false** | false |
| `button.window.frame` | (958, 949, 38, 33) | **(-68, 949, 38, 33)** |

Only the frame moves: an item that does not fit is given a place off the left of the screen.
So `MenuBarItem.isOnScreen` asks whether the button's window frame intersects any screen, and
nothing else. `occlusionState` is worth naming because it looks like the right question and
is not - it reports `.visible` for no status item at all, fitting or not.

**What it does about it.** Two seconds after launch - the menu bar is still arranging itself
before that - it asks the question once, and if there is no way in it puts a card under the
menu bar saying which it is and what to press. Three messages, because the two failures can
happen together and the advice differs: with the shortcut working, hold it and draw; with both
gone, `⌃⌥⌘⎋` quits and that always works.

**Why a card and not a notification.** A notification asks for permission, and this app asks
for none (entry 1). A dialog blocks and can sit behind everything (entry 11). The card is a
click-through panel that takes itself away after seven seconds: it cannot eat a click, which
matters because it appears uninvited, and it is the one thing this app already knows how to do
well - put a picture on the screen without owning any of it.

**The timer is one-shot.** It runs once, two seconds in, and nothing is left behind; the
behaviour suite checks that it is gone.


## 34. The text tool, and the one thing it needs that nothing else here does

**What it is.** Click where the words go, type them, `Return` finishes. `Escape` throws it
away, clicking somewhere else finishes one and starts the next. The colour is the colour in
hand and the size wheel becomes six point sizes - 14 to 60 - because "every tool brings its own
context" is the rule this app has been following since the eraser's wheel started showing
holes instead of lines (entry 27).

**It is an ordinary stroke.** One point, where the caret went; a path that is the box the
glyphs fill; a string. Undo, redo, the fade, hiding, the incremental repaint and the kept
drawing all work on it without knowing what text is - the rendering suite paints one in its
session now and the two passes still agree byte for byte at 1x, 2x and 3x.

**The eraser takes it away whole.** A line can be cut in half and still be a line; half a word
is not a word. This is what shapes used to do before they were cut (entry 16), and it is the
one place in `Canvas.erase` that asks what kind of stroke it is looking at.

**The thing it needs: the keyboard.** These panels are `nonactivatingPanel` on purpose - a
presenter must not lose their focus to us - and the price is that they get no keystrokes while
another application is in front. That is the whole of entry 30 and the reason there are no bare
keys left. Typing cannot be done with a global hot key, so the app **comes forward while
somebody is typing and hands the front back when they finish**: `NSApp.activate` on the click
that puts the caret down, and the application that was in front is remembered and reactivated
on `Return`, on `Escape`, and on anything else that finishes the text.

**What that cost, and what happened next.** For as long as a caret was on screen, this app was
the active one - and a real Keynote slideshow did not survive it. Entry 39 is the answer; this
paragraph is left here because the reasoning that led to activation was sound and the thing
that made it wrong is worth seeing next to it.

**No blinking caret.** A blink is a timer running for as long as somebody is thinking about
what to write, and this app does not leave timers running for decoration (CLAUDE.md, never
number 8). The caret is drawn once, with the text, and moves when a letter does.

**What is deliberately missing:** choosing a typeface, editing text after it is finished, and
selecting words with the mouse. Each is a text editor, and this is a tool for putting three
words on a slide in the middle of a sentence.

**The ninth sector.** Adding text made the tools wheel nine sectors of forty degrees rather
than eight of forty-five, and with an odd number nothing sits exactly opposite the pen. A flick
straight left lands on the boundary between two sectors, so the eraser takes the side that a
dead-left push resolves to and text takes the other: a caret put down by accident is nothing
until somebody types into it, and an eraser reached by accident takes a line away.


## 35. A wheel holds the pointer only if this app owns the window under it

**The report, for the third time:** "picking something still flashes the system arrow." Twice
before, the answer was to set the cursor more often - twenty times a second, then sixty, then a
burst at a hundred and twenty after a panel appears - and each time the probe measured clean
and the symptom came back.

**What the probe had never done was move the mouse.** `probes/cursorflash.swift` warped once
and held still, because holding still was the case the earlier reports described. Pushing the
mouse the way a hand pushes it - twenty steps over a third of a second, which is what opening a
wheel actually is - measured this (2026-09-04, 0.9, Mac15,6, macOS 26.6.2):

| gesture | what the screen showed |
| --- | --- |
| a colour, overlay drawing | `8x8` throughout - ours, no arrow |
| the first tool, no overlay open yet | **`SYSTEM ARROW` for 627ms**, the whole gesture |
| a colour, in click-through | **`SYSTEM ARROW` throughout** |

**The reason is one line of AppKit's behaviour that nothing here had written down:**
`NSCursor.set()` only reaches the screen while the window under the pointer belongs to this
app. Setting it a hundred and twenty times a second changes nothing when the window under the
pointer is somebody else's. And the wheel panel set `ignoresMouseEvents = true`, so it was
never the window under the pointer - its `resetCursorRects` had been dead code since the day it
was written. With an overlay up nobody noticed, because the overlay owns the pointer and the
wheel was riding on that. With no overlay - the first pick of a session, or any pick after
hiding - and in click-through, where the overlay hands the mouse away on purpose, there was
nothing of ours under the pointer at all.

**So the wheel takes the mouse, but only when nothing else of ours has it.** Three things had
to be true together, and each one was measured on its own before the next was added:

1. `ignoresMouseEvents = false` while the app does not own the pointer - the panel has to be
   the window under it.
2. `acceptsMouseMovedEvents = true` - a window that is told nothing when the mouse moves never
   applies its cursor rects. This alone changed nothing, which is how it was ruled out.
3. **Key.** A window's cursor rects are honoured while it is the key window, and a borderless
   panel cannot become key unless it says so. With `canBecomeKey` and `makeKeyAndOrderFront`,
   the arrow window fell from 627ms to 15ms. The panel is non-activating either way, so the
   application in front stays in front - the presenter keeps their slideshow.

**And the last 15ms** is the one the burst was invented for: a window that appears under a
stationary pointer is handed the plain arrow by the window server about 25ms later (entry 6).
The wheel now runs the same burst the overlay does - 120 a second for a third of a second -
which takes it to about one frame. That is the floor without owning the cursor before the
window exists.

**Where it deliberately does nothing:** while the overlay is drawing, the wheel leaves the
mouse alone. The overlay already owns the pointer, and taking the keyboard off it would take it
off the text tool mid-word.

**After** (same probe, same machine, same day): no arrow at all on any pick over a drawing;
about a frame as a wheel appears with nothing of ours underneath; and in click-through the
wheel holds the cursor while it is up and gives it back to the app underneath when it goes,
which is what click-through means.


## 36. Two rows under the left hand, and clear is a press

**The complaint:** clearing the screen was a sector of a wheel, which is hold, push, release -
two deliberate steps for the thing you do when a slide is finished and the next one is already
up. It used to be the bare letter `C`, and that was worse for the reason entry 30 gives, but
"deliberate" had gone too far in the other direction.

**Now**, six keys in two rows, and the rows mean something:

| | | |
| --- | --- | --- |
| `⌥A` tools | `⌥S` size | `⌥D` colour |
| `⌥Z` undo | `⌥X` redo · temporary ink · hide | `⌥C` clear |

The top row is **what you draw with**; the bottom row is **what happens to what you have
drawn**. Every one of them is under the left hand without moving it, and the fingers that find
`Z X C` for undo, cut and copy everywhere else find them here for undo, the actions wheel and
clear.

**Clear left the wheel** for the reason undo left it (31): one thing in two places is one place
too many, and the wheel's answer was the one that needed explaining. The `⌥X` wheel is three
sectors now - redo, temporary ink, hide - which the wheel drew without a line of code changing,
because it has always taken its angle from how many items it was given.

**Against clearing by accident**, which is the argument that put clear on a wheel in the first
place: it is undoable, and it says so. Pressing it flashes **"Cleared · ⌥Z puts it back"** on
the badge for a second and a half, through the same `flash(_:)` that says what switching
temporary ink did. Somebody who has just watched a slide's worth of annotation vanish is not in
a state to remember a rule; the screen tells them. And if `⌥C` still feels too close to `⌥Z`
for comfort, it is one of six rows in Settings and can be moved to anything (32).

**What it costs.** The key registered for the life of the app is now `⌥A` rather than `⌥X`, so
that is the combination taken from every other application on the machine. The other five come
and go with the overlay - including clear, because with nothing on screen there is nothing to
clear.

**Muscle memory.** This is the third arrangement in a fortnight: `⌃⌥⌘D` and bare letters (4, 5),
then `⌥Z X C V` with the wheels (30), then `Z X C V B` when undo took `Z` (31), and now two
rows. Nothing has been released, so the cost is one person's fingers - and the reason it kept
moving is worth writing down: each arrangement was right for the number of things the app had
at the time, and the app kept growing. Six is where it stops without a modifier: the row below
the home row is full.


## 37. Nothing rebuilds a cursor rect on a pick

**The report, a fourth time, and this time with the moment in it:** "right after picking
something, the system cursor blinks and goes." Entry 35 had just fixed the other half - the
wheel coming *up* next to a plain arrow - and this one is the other end of the same gesture.

**Why no probe could see it.** A probe warps the pointer; `CGWarpMouseCursorPosition` moves it
without a hand's stream of events, and the window server does not re-ask a window for its
cursor in the same way. Every measurement of the moment after a pick came back clean, four
rounds running. So this one was found by reading the code with the timing of the report in
mind: what happens *at the moment a pick completes*, that would only show on a pointer that is
moving?

**`invalidateCursorRects` happened on every pick, twice.** `toolSettingsChanged()` rebuilt the
view's cursor rects on every tool, colour and width change, and `setDrawingCursor()` did it
again from `takeCursorBack()`, which runs whenever a wheel closes. Rebuilding means AppKit
throws the rect away and asks for it again - and a window with no cursor rect is a window the
window server answers for, with the arrow, the moment the pointer moves.

**And there was nothing to rebuild.** The rect holds `PointerCursor.invisible` and has held it
for every tool since the pointer became a layer (entry 6): what changes with the tool is the
*picture on the layer*, not the cursor the window server is handed. The rebuild was left over
from the round when each tool really did hand over a different cursor. It was doing no work and
opening a gap.

**Now** the rect is rebuilt only where what it holds actually changes - `isInteractionMode`,
which decides whether there is a rect at all - and a pick sets the cursor without touching the
rects. `probes/behaviour.swift` counts `resetCursorRects` calls across a tool, a colour and a
width change and requires zero; run against the old code it reports one, which is how it is
known the check has teeth.

**How to see it happen on a machine where it still does**, because a fourth fix deserves the
same doubt as the first three:

    SCRIM_CURSOR_LOG=1 dist/Scrim.app/Contents/MacOS/Scrim

Every change of what the screen is showing, with how long the last one lasted and what the app
thought it was doing, and a summary on the way out of every moment the screen showed something
that was not ours while the overlay had the mouse.


## 38. The rate of the cursor hold is the length of the flash

**The fourth round of the same report**, and the one that ended it. Entry 35 stopped the arrow
appearing while a wheel is up; entry 37 stopped a cursor rect being thrown away on every pick.
Both were real, both were measured, and afterwards there was still a blink the instant after
picking something.

**What the app's own log said** (`SCRIM_CURSOR_LOG=1`, which prints every change of what the
screen is showing next to what the app was doing, 2026-09-04, 0.9, Mac15,6, macOS 26.6.2).
Seven picks, and every flash landed in the same place:

| from | to the flash |
| --- | --- |
| the wheel's window being ordered out | 273-276 ms |
| `takeCursorBack()` starting its burst | 357-365 ms |

The burst is 42 ticks at 1/120 of a second: **350ms**. So the arrow arrived within about ten
milliseconds of the burst's last tick, seven times out of seven. While the cursor was being
re-set 120 times a second nothing got through; the moment that dropped to the 60Hz hold, one
flash of 3-11ms appeared and was taken back.

**So it is a race, not an event.** Something outside this app puts the arrow up once after each
pick - and it is not this app, because nothing here sets `NSCursor.arrow` on that path. Our
timer takes it back on its next tick, which makes **the rate of the hold the length of the
flash**. Two runs, same build, one variable:

| hold | flashes per run | longest | seen by eye |
| --- | --- | --- | --- |
| 60 a second | 5 | **7 ms** | "very clear" |
| 120 a second | 6 | **4 ms** | not seen at all |

The count did not change, which is the point: the same number of lost races, each one half as
long. A 120Hz display draws a frame every 8.3ms, so at 60 the arrow could span two frames and
at 120 it usually spans none.

**Now:** the hold runs at 120Hz while the overlay has the mouse. It costs 120 x 0.049ms =
**0.6% of a core**, against 0.3% before, and only while drawing mode is on - a closed overlay
still costs nothing. `SCRIM_CURSOR_HOLD` takes a rate rather than only 0 or 1, so the next
person to ask "is this fast enough?" can answer it in twenty seconds instead of reasoning about
it, and the behaviour suite fails if anybody slows it back down.

**What this cost to find**, worth writing down because the same shape will come again: three
rounds were spent making the app set the cursor more often on the strength of reasoning, and
each one helped without finishing the job. The fourth found it by making the app say what the
screen was showing next to what it was doing, at 4ms, on the machine where it happened - and
then by changing one variable between two runs. The probes could not have found it: they warp
the pointer, and the window server does not answer a warp the way it answers a hand.


## 39. Typing takes the keyboard without taking the front

**Reported:** clicking with the text tool throws the presenter out of their slideshow. Entry 34
said this might happen, said it would be tested by hand, and wrote down the fallback. It
happened.

**What was doing it:** placing a caret called `NSApp.activate(ignoringOtherApps: true)`. The
reasoning was that a non-activating panel gets no keystrokes while another application is in
front, which is the whole of entry 30 - so typing seemed to need the front.

**But it does not, and the style mask says so.** `.nonactivatingPanel` exists to let a window
take keyboard input **without** activating its application - a character palette is one. Entry
30's bare keys failed for a different reason: nothing was making the overlay the key window at
the time, so keys went wherever the user had last clicked. Drawing mode makes the panel key on
purpose, and in drawing mode nothing else can be clicked, so it stays key.

**Now:** `takeTheKeyboard()` makes the panel key and leaves the front alone.

**With a way out, and a way to see that it is needed.** If that path fails somewhere -
a keyboard-capture utility, a future macOS - typing would silently go nowhere, which is the
worst failure a tool can have. So:

- **A setting**, off out of the box: *come forward while typing*, which is exactly the old
  behaviour including handing the front back afterwards.
- **The app says when it is not working.** A caret with nothing typed into it, two and a half
  seconds on, with this app not in front, flashes on the badge: the keys are not arriving and
  the setting is where to fix it. One-shot timer, gone with the text session.

**Where the judgement lies:** the only thing that can say whether this worked is a real
slideshow and a pair of eyes, so that is a manual check in `docs/RELEASE.md` rather than a
number here.


## 40. How long temporary ink lasts is a setting

Three seconds is a presenter's pen and it is still the default, but the right number depends on
how fast somebody talks and how long their sentences are - which is not a thing this app can
know. One to thirty seconds, in the settings window's ink section, next to the typing checkbox
(entry 39).

**It reaches the ink the right way round.** Every stroke carries its own `life` from the moment
it is finished, so changing the setting moves what is drawn next and leaves what is already on
screen exactly as it was. Nothing had to change in `FadingInk` at all, which is the sign that
the per-stroke life was the right shape to begin with (entry 8).

**What stays out of that window:** colour, width, tool, and whether temporary ink is on. Those
are wheels, in the hand, while the drawing is in front of you. The window is for what you set
once - which is the line that decides whether anything else ever goes in it.


## 41. Moving something is a tool, and it lives on the `⌥X` wheel

**Wanted:** a way to shift a line or a word that landed in the wrong place. Until now the only
answer was to erase it and draw it again.

**Where it lives, and why that is not the tools wheel.** The tools wheel is what you draw
*with*; `⌥X` is what happens to what you have already drawn. Move belongs to the second, even
though it is a mode you drag with rather than an instant action - so `⌥X` now hands you a tool
as well as doing things, and the badge says so out loud when it does (a flash: "Move: drag
anything you have drawn"), because it is the one tool that cannot be reached from the tools
wheel.

**How it holds on.** `mouseDown` takes the topmost mark under the pointer, by id rather than by
index, because an undo or an eraser could shuffle the list under a drag. The hit test is
`Stroke.isUnder(_:slack:)`: the mark's own repaint bounds first, then the distance from the
point to each segment, with at least 8 points of slack - a 2pt line is two pixels of target and
nobody aims at that. Text is a box, and a filled shape is still its outline, so a rectangle is
grabbed by its edge rather than by the empty middle.

**One drag is one edit**, and the edit names the mark: `Edit.moved(before:after:)`. Undo puts it
back where it was, redo takes it there again, and both find the mark by `id` (never number 11).
A drag that ends where it started records nothing at all, because that is somebody deciding not
to move something.

**Temporary ink cannot be moved.** It is on a fading layer of its own; dragging it would mean
dragging that layer too, for a mark that is about to disappear anyway.

**The risk this had, and what caught it.** Moving is the one edit that invalidates two
rectangles for one mark - where it was and where it went - so it is the likeliest to leave a
hole behind. The rendering suite now moves a mark in its session and still reports **0
differing bytes** at 1x, 2x and 3x, and prints `moved=yes` so that a grab which caught nothing
cannot quietly turn that check into a comparison of a session with itself.


## 42. Erasing an area, and the pixels that came with it

**Wanted:** "clear that corner" without rubbing over it with the eraser or clearing the lot.
`ERASE AREA` on the `⌥X` wheel: drag a box, and what is inside it goes.

**It cuts rather than deletes**, like the eraser: the part of a line inside the box goes and the
parts outside stay. Text goes whole, because half a word is not a word (entry 34). The whole
box is one thing to take back, through the same `beginErase`/`finishErase` wrapper an eraser
drag uses, so undo puts back exactly what was there.

**The cut is a clip, not a sweep of circles.** `Stroke.surviving(_:outside:shorterThan:)` clips
each segment against the rectangle (Liang-Barsky) and returns the same shape of answer the
circle version returns - runs of points, crumbs dropped - so the two erasers leave a drawing in
the same state. The reason is cost: a 1000x600 area with a 20pt eraser would be fifteen hundred
circles against every stroke, where clipping a segment is a handful of divisions.

**One real bug fell out of it.** Redo of an erase put the pieces back with `strokes.append`,
which is the end of the list - so redoing a cut moved the pieces to the top of the pile. It had
never shown, because the eraser's pieces had never overlapped anything; a box across an arrow
does. `Edit.erased` now carries the pieces as `Removal`s, with the place each one came from,
and redo puts them back there. The rendering probe prints the stroke order before an undo and
after the redo, so it cannot come back quietly.

**And one thing that is not a bug, measured until it was certain.** With the area erase in the
rendering session, the incremental and single-pass paints stopped agreeing: 44 near-white
pixels at the arrowhead, differing by at most 4 parts in 255. What was ruled out, in this
order:

- **The marquee.** Doing the cut with no rectangle drawn: same 53 bytes.
- **The invalidation.** Repainting the whole view after the cut: same 53 bytes.
- **The cut itself.** The same session without the trailing undo/redo: **0 bytes**. So the
  geometry is right and the pieces are right.
- **The order of the pieces.** Printed before the undo and after the redo: identical.
- **Coverage.** The differing pixels are inside a rectangle the redo asked to have repainted.

What is left is antialiasing where three cut pieces of one arrow overlap at its head, painted
into a cleared rectangle rather than onto an empty canvas. It is invisible at size - the
magnified crop of both passes is white - and it is now printed with the box it sits in, so
anything that moves it shows up immediately. `DIFF=/tmp/d.png ./Testing/run.sh rendering`
writes the picture, with every differing pixel in red and both passes magnified side by side.

**Why it is written down rather than hidden.** The suite could have been kept at zero by moving
the box somewhere emptier, and that would have been a test arranged to pass. The number is in
the README instead, with what it is.
