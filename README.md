# Scrim

A macOS menu bar app that puts a transparent layer over every screen so you can draw on top of
whatever is running (a slide, a document, a video call) and then get out of the way again.
It has no window of its own, no Dock icon, and it asks for **no system permissions**.

A scrim is the gauze a theatre hangs in front of a stage: paint on it and it holds the mark,
light the stage behind it and it disappears. That is the whole idea.

macOS 11 or later · Apple Silicon and Intel · MIT licence · no permissions asked, no network
access, no account.

<!-- A short screen recording belongs here; docs/RELEASE.md has the shot list.
     ![Drawing over a slide](docs/demo.gif) -->

## What it does

- **Draws over everything**, including full-screen presentations: pen, marker, line, arrow,
  eraser, rectangle, oval, and a laser pointer.
- **Steps aside in one gesture.** Clicks, scrolls and keystrokes go back to the app underneath
  while the drawing stays on screen; the same gesture again puts the drawing away and keeps it.
- **Costs nothing to leave running.** No window, no Dock icon, and no CPU at all while the
  overlay is closed.

## Installing

**From a release.** Download `Scrim.zip` from the
[Releases](../../releases) page, unzip it, and move the app to `/Applications`.

The first time you open it, macOS will refuse. The app is signed, but only ad-hoc signed (a
local signature rather than a paid Developer ID), so you get "cannot be opened because Apple
cannot check it for malicious software". You clear that once and never again:

- Right-click the app and choose **Open**, then **Open** again in the dialog. On macOS 15
  and later this usually no longer works, so:
- open it normally, let it be refused, then go to **System Settings → Privacy & Security**
  and click **Open Anyway**.

**From source.** One command, no Xcode project, no dependencies, and no warning at all. You
need Xcode or its command line tools (`xcode-select --install`):

```bash
git clone https://github.com/stackedd/scrim.git
cd scrim && ./build_app.sh && open dist/Scrim.app
```

Either way, a small scribble icon appears in the menu bar. That is the whole interface. On
macOS 13 and later the menu has **Open at Login**, which starts the app with the Mac; on 11
and 12, add it under System Settings → General → Login Items.

## The first sixty seconds

Four keys sit next to each other on the Option row. **Hold one, push the mouse, let go.** The
wheel opens right where the pointer is, and each slice covers 45°, so you push in a
direction rather than hitting a target. They work whatever app is in front, because they are registered
with the system rather than with a window.

`⌥Z` works from the moment the app starts. The other three come and go with the overlay:
while it is closed they are ordinary keys, and belong to whatever app you are using.

| Hold | What opens |
| --- | --- |
| `⌥Z` | Tools: pen, marker, line, arrow, eraser, rectangle, oval, laser, in that order round the wheel, starting on the right |
| `⌥X` | Colours |
| `⌥C` | Size of the pen, the marker, the hole the eraser takes out, or the laser's beam |
| `⌥V` | What to do to a drawing: undo, redo, clear, temporary ink, hide |

Two rules and that is the interface:

- **The middle of a wheel is its default**, and letting go there chooses it. On `⌥Z` the middle
  is the way out. On `⌥V` the middle is undo, so a *tap* of `⌥V` takes one thing back, and
  three taps take back three.
- **Tapping the other three does nothing**, on purpose, so a key pressed by accident never
  changes the tool or the colour.

`⌃⌥⌘Esc` quits the app from any state. It is the only other shortcut, and it always works.

(`⌥` is Option, `⌃` is Control, `⌘` is Command.)

## The tools

| Tool | What it is |
| --- | --- |
| Pen | A plain line. Six colours, six widths. |
| Marker | Four times wider and see-through, like a highlighter over text. |
| Line, arrow, rectangle, oval | Two-point shapes. Holding `Shift` while dragging snaps to 45°, or makes a square or a circle. |
| Eraser | Rubs out the part of a stroke it passes over: it cuts strokes rather than deleting them. Its size is the hole it leaves. |
| Laser | A glow that follows the pointer. Hold the button down and it leaves a beam of light that thins out behind your hand and is gone in about half a second. Nothing is left on the drawing. |

**Temporary ink**, on the `⌥V` wheel, makes every mark fade out three seconds after it is
finished, the way a presenter's pen does. While it is on, the badge in the corner wears an
orange `TEMP`, so a drawing that disappears is never a surprise.

Colour, width and tool are remembered between launches. The eraser and the laser are not: what
comes back is the last tool that actually drew.

## Three states, one gesture

- **Drawing.** The overlay takes the mouse and the keyboard. Nothing reaches the app
  underneath, and every key is swallowed, including `Escape`. The corner badge has a red
  stripe.
- **Click-through.** The drawing stays on screen, but clicks, scrolls and keystrokes go
  straight to the app below, so a slide can be advanced or a page scrolled without losing it.
  Letting go of the `⌥Z` wheel in the middle gets here; picking any tool takes the screen back.
- **Away.** Letting go in the middle once more. The overlay closes and the drawing is kept:
  picking any tool brings it back where it was, undo history and all.

`CLEAR` on the `⌥V` wheel is the only thing that erases a drawing, and even that can be undone.

## If something goes wrong

**The overlay is taking clicks and the menu bar is out of reach.** Hold `⌥Z` and let go in the
middle; that hands the screen back. If nothing responds at all, `⌃⌥⌘Esc` quits the app.

**The menu bar icon is not there.** The app has no Dock icon and no window. When the menu bar
is full macOS hides what does not fit; holding `Command` and dragging the icons makes room.

**`⌥Z` does nothing.** Another app may have registered the same shortcut; macOS allows that
without reporting a conflict. The menu bar item does the same job, and the shortcuts are
defined in one file for anyone building their own copy.

**The pointer vanished during a presentation.** It should not. While drawing, the pointer is
painted on the overlay rather than handed to the system, precisely because presentation apps
hide the system cursor. If it happens, it is a bug worth reporting.

## Known limits

These follow from asking for no permissions, and they are not going to change:

- **Drawings do not follow content.** Scrolling a page leaves the ink where it was. Following
  content would need Accessibility.
- **The Dock still reacts.** Passing over it while drawing pops up app names, because macOS
  tells the Dock where the pointer is whatever window is on top.
- **Nothing is saved.** Drawings live in memory, survive hiding the overlay, and are gone when
  the app quits. There is no file to export or to lose.
- Changing the display arrangement while drawing closes the overlay rather than guessing where
  the strokes should go.

## How it works

One transparent, non-activating panel per screen, at pop-up-menu window level so it sits above
full-screen apps and on every Space. Ink is drawn into a `CALayer` and only the rectangle that
changed is repainted. The global shortcuts use Carbon's `RegisterEventHotKey`, which needs no
Accessibility permission. Open at Login uses `SMAppService`.

The frameworks are AppKit, Carbon, QuartzCore and ServiceManagement, with no third-party
dependencies. The only thing written to disk is the small settings record (tool, colour,
width) in the app's own preferences.

## Checking that it works

Everything below runs from a clone, on any Mac:

```bash
./Testing/run.sh
```

- **91 behaviour checks** drive the real app: every wheel and what its slices do, hiding and
  showing keeping the strokes *and* the undo history, the eraser cutting rather than deleting,
  the laser, temporary ink, and the pointer the overlay hands to the window server.
- **A pixel comparison** of one drawing painted incrementally and painted in a single pass, at
  1x, 2x and 3x backing scale: **0 differing bytes**. That is how "the optimisation did not
  change what is on screen" is proved rather than asserted.
- **A cost suite** that times painting: seven sweeps, including a single 5000-point stroke and
  a drag with the marker at its widest.

Measured on a real screen (`Testing/probes/onscreen.swift`), as a percentage of one core:

| State | CPU |
| --- | --- |
| Overlay up, nothing moving | ~0.9% |
| Pointer moving over 200 strokes | ~1.7% |
| Drawing over 200 strokes | ~5.9% |
| Overlay closed | 0.0% |

The permission claim is checkable in two commands rather than taken on trust:

```bash
grep -rn "AXUIElement\|CGEventTap\|ScreenCaptureKit\|URLSession" Sources/   # prints nothing
grep -c "UsageDescription" Packaging/Info.plist                            # 0
```

There is no network code, no analytics, and no telemetry of any kind.

## Building and developing

```bash
swift build -c release      # the binary; must be warning-free
./build_app.sh              # the universal .app plus a zip, in dist/
./Testing/run.sh            # every suite
```

There is no XCTest target. Tests are built by compiling the app's own sources into a probe that
drives the real code and prints what happened; `Testing/README.md` explains how, and how to add
one. Several probes render PNGs (the wheels, the badge, the cursors, the laser, the ink)
because some things can only be checked by looking at them.

The documentation is short and worth reading before changing anything:

- `docs/ARCHITECTURE.md`: what each file owns, the invariants, and every measurement.
- `docs/DECISIONS.md`: why things are as they are, including what was tried and dropped.
- `docs/RELEASE.md`: how a release is cut.
- `CLAUDE.md`: the operational summary, meaning commands, conventions, and the list of things
  never to do.

Issues and pull requests are welcome. Anything that touches drawing should come with
`./Testing/run.sh` output and a note on what moved.

## Licence

MIT. See [`LICENSE`](LICENSE). Use it, change it, ship it.
