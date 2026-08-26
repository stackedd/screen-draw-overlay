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

The quickest way to check that it is running at all is to press the shortcut: `Control + Option + Command + D`. Nothing dims — the overlay is fully transparent — but a red `● DRAW` badge appears in the top-right corner and the pointer becomes a crosshair. Press it again to hide it.

The app does not launch at login by itself. Add it under System Settings → General → Login Items if you want that.

## Shortcuts

| Shortcut | What it does |
| --- | --- |
| `Control + Option + Command + D` | Start drawing · back to drawing from click-through · hide the overlay, keeping what you drew |
| `Control + Option + Command + E` | Switch between drawing and click-through |
| `Control + Option + Command + Escape` | Panic key: quits the app outright, from any state |
| Drag the mouse | Draw a red freehand line |
| `C` | Erase everything, stay in drawing mode |
| `Command + Z` | Undo the last stroke |

### Drawing and click-through

There are three states — off, drawing and click-through — and two shortcuts move between them.

While you are **drawing**, the overlay takes the mouse and the keyboard: your strokes land on it and nothing reaches the app underneath. Press `Control + Option + Command + E` and it switches to **click-through**: the drawing stays exactly where it is, but clicks, scrolls and keystrokes go straight to the app below, so you can advance a slide, scroll a page or switch apps without losing what you drew. `Control + Option + Command + E` again goes back to drawing, and so does `Control + Option + Command + D` — from click-through, `D` means "back to drawing", not "throw it away".

**Hiding is not erasing.** `Control + Option + Command + D` while you are drawing puts the overlay away but keeps your strokes; the next `Control + Option + Command + D` brings them back where they were. Hitting the shortcut by accident costs you nothing. The only thing that erases a drawing is `C`.

**While drawing, the keyboard belongs to the tool.** `C` clears, `Command + Z` undoes, and everything else — including `Escape` — is swallowed and does nothing. If you need to type, or need `Escape` to reach the app underneath (leaving a slideshow, for instance), switch to click-through with `Control + Option + Command + E` first.

You can always tell which state you are in: the corner badge reads a red `● DRAW` when the overlay owns your clicks and a dim `◌ CLICK-THROUGH` when they pass through, and its second line names the two shortcuts that apply right now (`⌃⌥⌘E click · ⌃⌥⌘D hide` while drawing). The crosshair pointer is drawn only while drawing, and the menu bar icon turns red while the overlay is taking clicks and becomes a dimmed struck-through pen in click-through.

`Control + Option + Command + Escape` is the panic key, and it is blunt on purpose: **it quits the app**, exactly like Quit in the menu. If the overlay is ever swallowing your clicks and nothing else responds, ending the process is the one recovery that cannot fail — the app releases the screen and closes its panels on the way out. Your drawing goes with it, so use `Control + Option + Command + D` for ordinary "get this out of my way". Start it again from `/Applications` afterwards.

The menu bar item carries **Start / Show / Hide / Back to Drawing**, a **Click-Through** checkbox, and **Quit** — but note that while you are drawing, the overlay covers the whole screen including the menu bar, so the item is not clickable until you hide the overlay or switch to click-through. That is deliberate: drawing mode is meant to interact with nothing. The shortcuts are how you get out of it.

If `Control + Option + Command + D` does nothing at launch, another app already owns that shortcut — the app tells you so with an alert. Change the key code or modifiers in `Sources/ScreenDrawOverlay/main.swift` and rebuild.

## Build from source

You need the Xcode command line tools (`xcode-select --install`). There is no Xcode project; everything is SwiftPM. The package targets macOS 11, which is as low as a universal binary can go — Apple Silicon has no macOS before Big Sur.

```bash
./build_app.sh
```

That builds a universal (Apple Silicon + Intel) release binary, assembles `dist/ScreenDrawOverlay.app`, ad-hoc signs it and writes `dist/ScreenDrawOverlay.zip`. Open the result with `open dist/ScreenDrawOverlay.app`. An app you built yourself is not quarantined, so it opens without the Gatekeeper detour above.

For a quick run without the bundle, `swift build -c release` and then `.build/release/ScreenDrawOverlay`.

## Known limits

This is v0.1 and deliberately small. There is no toolbar, no color picker, no line width control, no shapes or arrows, no saving or screenshot capture, no redo, and no preferences window. One red pen, one clear, one undo.

Beyond that, things worth knowing:

- While drawing mode is on, the overlay is above everything — the menu bar, other apps' status items, dialogs and alerts. Nothing on screen can be clicked until you switch to click-through with `Control + Option + Command + E` or hide the overlay with `Control + Option + Command + D`.
- The Dock still reacts to where the pointer is, even though your clicks never reach it: pass over it while drawing and it will still show app names. macOS reports the pointer position to the Dock independently of which window is on top, and suppressing that would need an event tap and Accessibility permission, which this app deliberately does not ask for. Setting the Dock to hide automatically keeps it out of the way.

- Plugging in, unplugging or rearranging a display while drawing ends drawing mode and discards the drawing, kept strokes included. That is intentional — it is better than leaving an overlay stranded on a display that no longer exists, or restoring an annotation onto the wrong screen.
- `Escape` does nothing while you are drawing. It used to leave drawing mode, but that only worked when the overlay happened to hold keyboard focus, and it threw the drawing away exactly when someone pressed `Escape` to get out of a slideshow. Use click-through if you need `Escape` to reach the app underneath.
- Drawings are never written to disk. They survive hiding and showing the overlay for as long as the app is running, and nothing else: quitting — including with `Control + Option + Command + Escape` — loses them, and so does plugging in or rearranging a display, because a drawing made for one screen layout does not belong on another.

## License

MIT. See [LICENSE](LICENSE).
