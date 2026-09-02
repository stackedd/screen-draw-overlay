# ScreenDrawOverlay

A tiny macOS menu bar app that puts a transparent layer over your screens so you can scribble on top of whatever is running — including full screen presentations.

<!-- Record a short demo and drop it at docs/demo.gif; this will pick it up. -->
![ScreenDrawOverlay in action](docs/demo.gif)

It needs no system permissions: no Accessibility, no Screen Recording. The global shortcut uses Carbon's `RegisterEventHotKey`, which does not ask for anything.

## Install

Requires macOS 11 Big Sur or later, on Apple Silicon or Intel.

1. Download `ScreenDrawOverlay.zip` from the [Releases](../../releases) page.
2. Double-click the zip to unpack it.
3. Drag `ScreenDrawOverlay.app` into `/Applications`.
4. **First launch — macOS will refuse to open it.** The app is signed, but only ad-hoc
   signed (a local signature, not a paid Developer ID) and it is not notarized, so
   Gatekeeper will say it "cannot be opened because Apple cannot check it for malicious
   software". This is expected, and you have to clear it once:
   - Right-click (or Control-click) the app and choose **Open**, then **Open** again in the dialog.
   - On macOS 15 Sequoia and later that shortcut usually no longer works. Instead try to open
     the app once normally, then go to **System Settings → Privacy & Security**, scroll to the
     Security section, and click **Open Anyway** next to the ScreenDrawOverlay message.
   - If you prefer the terminal, `xattr -d com.apple.quarantine /Applications/ScreenDrawOverlay.app`
     does the same thing.

   You only do this once. After that it launches like any other app.
5. A small scribble icon appears in the menu bar. That is the whole UI.

### If you cannot find it

The app has no Dock icon and no window — it lives only in the menu bar. If your menu bar is full, macOS quietly hides the items that do not fit, and this one is small enough to be among them. Hold `Command` and drag the menu bar icons to rearrange them and make room.

The quickest way to check that it is running at all is to hold `Option + Z`: a wheel of tools opens under the pointer. Push the mouse at one and let go, and the overlay is up — nothing dims, because it is fully transparent, but a badge appears in the top-right corner with a red stripe down its edge and your pointer becomes the tool you picked. Hold `Option + Z` again and let go in the middle to leave.

Your colour, width and tool are remembered between launches, so a highlighter-in-yellow habit only has to be set once. The eraser and the laser are not: they are things you pick up for a moment, so what comes back is the last tool that actually drew.

To have it start with your Mac, use **Open at Login** in the menu bar item (macOS 13 and later). On older systems, add it under System Settings → General → Login Items.

## Shortcuts

**Four keys, side by side, and nothing else to learn.** Hold one, push the mouse at what you
want, let go. The sectors are forty-five degrees wide, so there is nothing to aim at — and
every one of them works whatever app you are in, because they are registered system-wide.

| Hold | You get |
| --- | --- |
| `Option + Z` | The tools: pen, marker, line, arrow, rectangle, oval, eraser, laser |
| `Option + X` | The colours |
| `Option + C` | The size — of the pen, of the marker, of the hole the eraser takes out, or of the laser's beam |
| `Option + V` | What you do *to* a drawing: redo, clear, temporary ink, hide |

**The middle of a wheel is its default, and letting go there does it.** On the tools wheel the
middle is the way out, one step at a time: first the screen goes back to the app underneath —
click, scroll, type, with your drawing still on it — and again puts the overlay away, keeping
the drawing. On the colour and size wheels the middle is a plain cancel. On `Option + V` the
middle is **undo**, so a tap of it takes one thing back and a run of taps takes back a run of
them; you never have to draw a gesture to undo.

Each wheel shows what the tool in your hand means by it — the size wheel draws the line a pen
will put down, the wider line a marker will, the hole an eraser will take out, or the beam of
light the laser will. Reaching for a colour with the eraser in hand does nothing but say so on
the badge: an eraser has no colour, and changing the tool in your hand to answer a question you
did not ask is worse than saying no.

`Shift` while you drag a shape snaps a line or arrow to 45°, and makes a rectangle square or an
oval round.

| Shortcut | What it does |
| --- | --- |
| `Control + Option + Command + Escape` | Panic key: quits the app outright, from any state |

**There are no other keys, and that is deliberate.** There used to be: `P` for the pen, `C` to
clear, `Command + Z` to undo. They worked only while ScreenDrawOverlay happened to be the app
receiving keystrokes — and it is a background app with no window, so after you click anything
else it is not. A shortcut that sometimes works is worse than no shortcut, and a bare `C` that
erases a whole drawing is worse again. Everything lives on the Option row now, where it works
from anywhere.

If `Option + Z` is ever taken by another app, the menu bar item does the same job.

### Drawing and click-through

There are three states — off, drawing and click-through — and one gesture moves between all of them: hold `Option + Z`, push, let go.

While you are **drawing**, the overlay takes the mouse and the keyboard: your strokes land on it and nothing reaches the app underneath. Let go of the wheel in the middle and it switches to **click-through**: the drawing stays exactly where it is, but clicks, scrolls and keystrokes go straight to the app below, so you can advance a slide, scroll a page or switch apps without losing what you drew. Picking any tool from the wheel takes the screen back.

**Leaving happens one step at a time, and the hub says which step is next.** From drawing, the middle hands the screen back (the hub reads `CLICK-THROUGH`). From there, the middle again puts the overlay away (`HIDE`). Nothing is ever thrown away by accident, because the wheel tells you what it is about to do before you let go.

**Hiding is not erasing.** Putting the overlay away keeps your strokes and the undo history that goes with them; the next tool you pick brings both back where they were. Reaching for the wheel by accident costs you nothing. The only thing that erases a drawing is `CLEAR` on the `Option + V` wheel — and that can be taken back too.

**While drawing, the keyboard reaches nothing.** Every key — including `Escape` — is swallowed, so nothing you type lands in the app underneath and nothing beeps. If you need to type, or need `Escape` to reach the app underneath (leaving a slideshow, for instance), let go of the tools wheel in the middle first.

You can always tell which state you are in, and which tool you are holding: the corner badge reads `Pen 4` — the tool, its width, and the tool's own icon beside it, drawn in the colour you are about to draw with — or `Click-through` when your clicks pass through. A red stripe down its left edge means the overlay is taking your clicks; it disappears in click-through, when it is not. Its second line names what to do right now (`⌥Z tools · ⌥V undo · middle of a wheel hands it back` while drawing) — which matters, because it is the only thing on screen telling someone whose clicks have stopped working what to press. There is no palette on screen on purpose: a tool that occupies screen space is not one you leave running.

Each tool has its own pointer, in the colour you are drawing with: the pen is a nib, the highlighter a chisel, the shape tools a fine crosshair with the shape they make beside it, and the eraser a ring exactly the size of the hole it will leave. The laser's is its glow, and nothing else, because two marks an inch apart would be worse than one.

All of them are **drawn on the overlay** rather than handed to the system as a mouse cursor, and that is not a detail: an app that is presenting hides the pointer while its slideshow is running, and a cursor of ours is then not drawn at all — during a presentation every tool's pointer disappeared and only the laser, which was always drawn on the overlay, could be seen. There is no way for an app like this one to notice that or to undo it, so the pointer stopped being a cursor. The wheel draws its own dot for the same reason, so you can always see which way you are pushing.

The menu bar icon turns red while the overlay is taking clicks and becomes a dimmed struck-through pen in click-through.

`Control + Option + Command + Escape` is the panic key, and it is blunt on purpose: **it quits the app**, exactly like Quit in the menu. If the overlay is ever swallowing your clicks and nothing else responds, ending the process is the one recovery that cannot fail — the app releases the screen and closes its panels on the way out. Your drawing goes with it, so use the wheel's middle for ordinary "get this out of my way". Start it again from `/Applications` afterwards.

The menu bar item names the wheel shortcut and carries **Start / Show / Hide / Back to Drawing**, a **Click-Through** checkbox, and **Quit** — but note that while you are drawing, the overlay covers the whole screen including the menu bar, so the item is not clickable until you hide the overlay or switch to click-through. That is deliberate: drawing mode is meant to interact with nothing. The shortcuts are how you get out of it.

If `Option + Z` does nothing, another app is probably using the same shortcut. macOS lets several apps register one shortcut without complaining, so the conflict is usually silent — the app can only warn you when the system refuses the registration outright, and it does that in the menu ("Shortcut unavailable"), never with a dialog. Either way the menu bar item still works, and you can change the key code or modifiers in `Sources/ScreenDrawOverlay/Shortcuts.swift` and rebuild.

## Build from source

You need the Xcode command line tools (`xcode-select --install`). There is no Xcode project; everything is SwiftPM. The package targets macOS 11, which is as low as a universal binary can go — Apple Silicon has no macOS before Big Sur.

```bash
./build_app.sh
```

That builds a universal (Apple Silicon + Intel) release binary, assembles `dist/ScreenDrawOverlay.app`, ad-hoc signs it and writes `dist/ScreenDrawOverlay.zip`. Open the result with `open dist/ScreenDrawOverlay.app`. An app you built yourself is not quarantined, so it opens without the Gatekeeper detour above.

For a quick run without the bundle, `swift build -c release` and then `.build/release/ScreenDrawOverlay`.

If you are going to change the code, read [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) first: it says what each file owns, which behaviours exist because something went wrong once, and what has already been measured — window levels, CPU cost, repaint behaviour — so none of it has to be rediscovered.

## Known limits

Deliberately small. There is no toolbar or palette, no text tool, no saving or screenshot capture, and no preferences window.

Beyond that, things worth knowing:

- While drawing mode is on, the overlay is above everything — the menu bar, other apps' status items, dialogs and alerts. Nothing on screen can be clicked until you let go of the wheel in the middle, which hands the screen back and then, a second time, puts the overlay away.
- The Dock still reacts to where the pointer is, even though your clicks never reach it: pass over it while drawing and it will still show app names. macOS reports the pointer position to the Dock independently of which window is on top, and suppressing that would need an event tap and Accessibility permission, which this app deliberately does not ask for. Setting the Dock to hide automatically keeps it out of the way.

- Plugging in, unplugging or rearranging a display while drawing ends drawing mode and discards the drawing, kept strokes included. That is intentional — it is better than leaving an overlay stranded on a display that no longer exists, or restoring an annotation onto the wrong screen.
- `Escape` does nothing while you are drawing. It used to leave drawing mode, but that only worked when the overlay happened to hold keyboard focus, and it threw the drawing away exactly when someone pressed `Escape` to get out of a slideshow. Use click-through if you need `Escape` to reach the app underneath.
- Temporary ink (`T`) is not kept when you hide the overlay: it was drawn to disappear, so it is not brought back mid-fade. Ordinary ink is kept as always.
- Drawings are never written to disk. They survive hiding and showing the overlay for as long as the app is running, and nothing else: quitting — including with `Control + Option + Command + Escape` — loses them, and so does plugging in or rearranging a display, because a drawing made for one screen layout does not belong on another.

## License

MIT. See [LICENSE](LICENSE).
