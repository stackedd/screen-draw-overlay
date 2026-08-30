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
the per-app adapters would turn a 2,300-line tool into a product with a maintenance surface
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
because no way out depends on anything on screen: all three shortcuts are global, and the
panic key quits the process.

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
- `C` (or Delete) is the only thing that erases — and it is undoable.

Kept drawings are tied to the display layout they were made on and dropped when it changes,
rather than restored onto the wrong screen at the wrong scale.

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

## 6. The pointer is drawn, not requested

**Tried:** `NSCursor.crosshair` — invisible over a presentation, because the presenting app
had hidden the pointer entirely.

**Tried:** `NSCursor.unhide()` + `CGDisplayShowCursor` to force it back. Unverifiable and
ineffective: cursor hiding is per application and only applies while that application is
active, so a background `.accessory` app hides and unhides nothing.

**Tried:** `NSCursor.hide()` so only our drawn crosshair shows. Same reason, same failure —
and the user got two pointers on screen during a presentation.

**Chosen:** hand the window a **fully transparent cursor** (a 16×16 empty `NSImage`). The
window server asks whoever owns the window under the pointer, and in drawing mode that is
us. It needs no permission and does not depend on being frontmost. The crosshair below it is
drawn by the view; click-through drops the cursor rects and hands the real pointer back.

**A crash to not repeat:** the first version called
`window.invalidateCursorRects(for:)` from inside `cursorUpdate`. That re-enters AppKit's
tracking machinery and throws — `SIGABRT` the moment the pointer moved over the panel.
Rebuilding cursor rects now lives in its own method that only mode changes call.

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

## 8. The fade ticks at 15 Hz

Temporary ink (`T`) holds full strength for the first 55% of three seconds, then fades.

The first version cost **12.5% CPU** with 50 strokes fading — it invalidated each stroke
separately, so fifty repaint passes each redrew every stroke they touched. Invalidating the
union once removed that square law: **5.0%**.

Then the tick rate: 20/s cost 5.1%, 15/s 4.4%, 12/s 4.3%. Past 15 the smoothness is free and
the savings are not, so 15 it is.

Chasing this turned up the fact that governs all performance work here: **each repaint of a
full-screen transparent layer costs about 0.4% CPU whatever the dirty rect contains**. The
bill is the number of repaints, not their area — which is why 50 fading strokes and 1 cost
the same. For scale: drawing by hand at 60 mouse moves a second costs 23.2%.

The timer starts when the first temporary stroke lands and stops when the last one is gone,
so idle stays at 0.0%.

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
eraser and Clear took away, at the right depth.

## 17. Temporary ink is not kept across a hide

It was drawn to vanish. Bringing it back mid-fade on the next show would be a surprise, and
its disappearance is not an edit, so undo has nothing to say about it either.

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
second costs **15.2% of a core**, whatever the dirty rect's size. Actually painting what a
drag puts on screen costs **0.3–0.5%**. The ratio is about thirty to one, and every idea
that makes painting cheaper is bidding for that half point.

The same repaint asked for through a `CALayer` delegate rather than `NSView.draw(_:)` costs
**3.5%** — 4.3x less for identical output — and moving a sublayer, which is not a repaint,
costs **1.5%**. WindowServer does not move in any of these runs, so this is our own process
and not the compositor.

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

## 20. The pointer and the badge are layers, not paint

The crosshair used to be painted in `draw(_:)`, and following the mouse meant invalidating
where it had been and where it had arrived. Both rectangles are about 26pt square, which
sounded free and was not: a repaint of a full screen transparent overlay costs the same
whatever its dirty rect, so **painting the crosshair cost as much as painting everything**.
On a canvas with ink on it, it cost more than that — the two rectangles union into one
region and every stroke that region touches is re-stroked, while the user is drawing nothing
at all.

**Now:** the pointer is a `CGImage` on a `CALayer`, and a mouse move sets `position`.
Measured at 60 moves a second: **15.2% of a core before, 1.5% after**. The offscreen cost
suite puts it more bluntly — moving the pointer over a canvas of 200 strokes now paints
**nothing**, where it used to paint on every move.

Two details that are not optional:

- `pointerLayer.actions` disables the implicit animation on `position`. Core Animation
  animates a position change by default, and a cursor that eases towards the mouse is worse
  than no cursor at all.
- The picture is redrawn only when the tool or colour changes (the laser is a coloured dot,
  everything else is the crosshair) and when the backing scale does. A layer-backed view can
  be handed a new backing layer when it changes windows, so the sublayer is re-attached in
  `viewDidMoveToWindow` rather than only in `init`.

The behaviour suite checks the one thing that could break silently: that the layer sits on
the mouse point and the backing layer is not geometry-flipped. A flipped layer would put the
crosshair as far from the pointer as the pointer is from the middle of the screen.

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
costs **15.2% of a core through AppKit's view display machinery and 3.5% through a
`CALayer`** — 4.3x, for identical output. Nothing about what is painted changes; the
difference is the path the repaint is asked through.

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
