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

The quickest way to check that it is running at all is to press the shortcut: `Control + Option + Command + D`. Nothing dims — the overlay is fully transparent — but a badge appears in the top-right corner with a red stripe down its edge, and a coloured ring appears around your pointer. Press it again to hide it.

Your colour, width and tool are remembered between launches, so a highlighter-in-yellow habit only has to be set once. The eraser and the laser are not: they are things you pick up for a moment, so what comes back is the last tool that actually drew.

To have it start with your Mac, use **Open at Login** in the menu bar item (macOS 13 and later). On older systems, add it under System Settings → General → Login Items.

## Shortcuts

**One key does almost everything.** Hold `Option + Z` anywhere, push the mouse at what you
want, and let go. The sectors are forty-five degrees wide, so there is nothing to aim at.

| Push at | What happens |
| --- | --- |
| a tool | The overlay opens if it was not open, takes the screen, and hands you that tool |
| the middle | You leave, one step at a time. First the screen goes back to the app underneath — click, scroll, type, with your drawing still on it. Do it again and the overlay goes away, keeping the drawing. The hub tells you which one is next |

Two more wheels, while the overlay is up: `Option + X` for colour and `Option + C` for width.
Each shows what the tool in your hand means by it — the width wheel draws the line a pen will
put down, the wider line a marker will, or the hole an eraser will take out. Reaching for a
colour with the eraser in hand hands you your pen back in that colour, because that is plainly
what you meant.

And three shortcuts that work from anywhere, whatever has focus:

| Shortcut | What it does |
| --- | --- |
| `Control + Option + Command + Z` | Undo · add `Shift` to redo |
| `Control + Option + Command + Escape` | Panic key: quits the app outright, from any state |

Undo is on that list rather than only on `Command + Z` for a reason: the overlay is a
non-activating panel, so it only receives ordinary keystrokes while ScreenDrawOverlay is the
active app. Click anything in another app and `Command + Z` stops reaching it, with nothing on
screen to tell you so. The global one always works.

If `Option + Z` is ever taken by another app, the menu bar item does the same job.

While you are drawing, the keyboard belongs to the tool. No modifiers to hold — your other hand is on the mouse:

| Key | Tool |
| --- | --- |
| `P` | Pen |
| `H` | Highlighter |
| `L` | Straight line |
| `A` | Arrow |
| `R` | Rectangle |
| `O` | Oval |
| `E` | Eraser — rubs out the part you pass over, as wide as the current width. One drag is one undo |
| `Space` | Laser pointer — a glow that follows the pointer and leaves no ink. It is drawn on the overlay, not on the cursor, so it is there whatever else the system is doing with the pointer. Press again for the tool you had |

| Key | What it does |
| --- | --- |
| `1`–`6` | Colour: red, orange, yellow, green, blue, white |
| `T` | Temporary ink — strokes fade away after about three seconds, the way a presenter's pen does |
| `[` `]` | Thinner / thicker |
| `Shift` while drawing a shape | Snap a line or arrow to 45°, make a rectangle square or an oval round |
| `Command + Z` / `Shift + Command + Z` | Undo / redo — including undoing a Clear. Works while the overlay has the keyboard; the global `⌃⌥⌘Z` always does |
| `Delete` or `C` | Clear everything (undoable) |

### Drawing and click-through

There are three states — off, drawing and click-through — and two shortcuts move between them.

While you are **drawing**, the overlay takes the mouse and the keyboard: your strokes land on it and nothing reaches the app underneath. Press `Control + Option + Command + E` and it switches to **click-through**: the drawing stays exactly where it is, but clicks, scrolls and keystrokes go straight to the app below, so you can advance a slide, scroll a page or switch apps without losing what you drew. `Control + Option + Command + E` again goes back to drawing, and so does `Control + Option + Command + D` — from click-through, `D` means "back to drawing", not "throw it away".

**Holding beats toggling.** Tapping `Control + Option + Command + D` leaves the overlay up until you tap it again, which is what you want when you are marking up a slide for a minute. Holding it down is for the other case: press, scribble one arrow, let go, and the screen is yours again — nothing to remember to switch off. That is what makes it safe to leave running all day.

**Hiding is not erasing.** `Control + Option + Command + D` while you are drawing puts the overlay away but keeps your strokes; the next `Control + Option + Command + D` brings them back where they were. Hitting the shortcut by accident costs you nothing. The only thing that erases a drawing is `C`.

**While drawing, the keyboard belongs to the tool.** The keys above do their thing and everything else — including `Escape` — is swallowed and does nothing. If you need to type, or need `Escape` to reach the app underneath (leaving a slideshow, for instance), switch to click-through with `Control + Option + Command + E` first.

You can always tell which state you are in, and which tool you are holding: the corner badge reads `PEN 4` — the tool, its width, and a dot in the current colour beside it — or `CLICK-THROUGH` when your clicks pass through. A red stripe down its left edge means the overlay is taking your clicks; it disappears in click-through, when it is not. Its second line names what to do right now (`⌥Z wheel · middle hands it back · ⌃⌥⌘Z undo` while drawing) — which matters, because it is the only thing on screen telling someone whose clicks have stopped working what to press. There is no palette on screen on purpose: a tool that occupies screen space is not one you leave running.

Each tool has its own pointer, in the colour you are drawing with: the pen is a nib, the highlighter a chisel, the shape tools a fine crosshair with the shape they make beside it, and the eraser a ring exactly the size of the hole it will leave. The laser has no cursor at all — its glow is drawn on the overlay, where the audience can see it, and two marks an inch apart would be worse than one. If something else takes the cursor for a moment you get the ordinary arrow back, which is a thing you can see rather than a bug; the overlay takes it again as soon as you move.

The menu bar icon turns red while the overlay is taking clicks and becomes a dimmed struck-through pen in click-through.

`Control + Option + Command + Escape` is the panic key, and it is blunt on purpose: **it quits the app**, exactly like Quit in the menu. If the overlay is ever swallowing your clicks and nothing else responds, ending the process is the one recovery that cannot fail — the app releases the screen and closes its panels on the way out. Your drawing goes with it, so use `Control + Option + Command + D` for ordinary "get this out of my way". Start it again from `/Applications` afterwards.

The menu bar item carries **Start / Show / Hide / Back to Drawing**, a **Click-Through** checkbox, and **Quit** — but note that while you are drawing, the overlay covers the whole screen including the menu bar, so the item is not clickable until you hide the overlay or switch to click-through. That is deliberate: drawing mode is meant to interact with nothing. The shortcuts are how you get out of it.

If `Control + Option + Command + D` does nothing, another app is probably using the same shortcut. macOS lets several apps register one shortcut without complaining, so the conflict is usually silent — the app can only warn you when the system refuses the registration outright, and it does that in the menu ("Shortcut unavailable"), never with a dialog. Either way the menu bar item still works, and you can change the key code or modifiers in `Sources/ScreenDrawOverlay/AppDelegate.swift` and rebuild.

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

- While drawing mode is on, the overlay is above everything — the menu bar, other apps' status items, dialogs and alerts. Nothing on screen can be clicked until you switch to click-through with `Control + Option + Command + E` or hide the overlay with `Control + Option + Command + D`.
- The Dock still reacts to where the pointer is, even though your clicks never reach it: pass over it while drawing and it will still show app names. macOS reports the pointer position to the Dock independently of which window is on top, and suppressing that would need an event tap and Accessibility permission, which this app deliberately does not ask for. Setting the Dock to hide automatically keeps it out of the way.

- Plugging in, unplugging or rearranging a display while drawing ends drawing mode and discards the drawing, kept strokes included. That is intentional — it is better than leaving an overlay stranded on a display that no longer exists, or restoring an annotation onto the wrong screen.
- `Escape` does nothing while you are drawing. It used to leave drawing mode, but that only worked when the overlay happened to hold keyboard focus, and it threw the drawing away exactly when someone pressed `Escape` to get out of a slideshow. Use click-through if you need `Escape` to reach the app underneath.
- Temporary ink (`T`) is not kept when you hide the overlay: it was drawn to disappear, so it is not brought back mid-fade. Ordinary ink is kept as always.
- Drawings are never written to disk. They survive hiding and showing the overlay for as long as the app is running, and nothing else: quitting — including with `Control + Option + Command + Escape` — loses them, and so does plugging in or rearranging a display, because a drawing made for one screen layout does not belong on another.

## License

MIT. See [LICENSE](LICENSE).
