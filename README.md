# ScreenDrawOverlay

A tiny macOS menu bar app that puts a transparent layer over your screens so you can scribble on top of whatever is running — including full screen presentations.

<!-- Record a short demo and drop it at docs/demo.gif; this will pick it up. -->
![ScreenDrawOverlay in action](docs/demo.gif)

It needs no system permissions: no Accessibility, no Screen Recording. The global shortcut uses Carbon's `RegisterEventHotKey`, which does not ask for anything.

## Install

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

The quickest way to check that it is running at all is to press the shortcut: `Control + Option + Command + D`. Nothing dims — the overlay is fully transparent — but a red `● DRAW` badge appears in the top-right corner and the pointer becomes a crosshair. Press it again to leave.

The app does not launch at login by itself. Add it under System Settings → General → Login Items if you want that.

## Shortcuts

| Shortcut | What it does |
| --- | --- |
| `Control + Option + Command + D` | Start drawing · back to drawing from click-through · put the overlay away |
| `Control + Option + Command + E` | Switch between drawing and click-through |
| `Control + Option + Command + Escape` | Emergency exit: force close the overlay from anywhere |
| Drag the mouse | Draw a red freehand line |
| `C` | Clear everything, stay in drawing mode |
| `Command + Z` | Undo the last stroke |

### Drawing and click-through

There are three states — off, drawing and click-through — and two shortcuts move between them.

While you are **drawing**, the overlay takes the mouse and the keyboard: your strokes land on it and nothing reaches the app underneath. Press `Control + Option + Command + E` and it switches to **click-through**: the drawing stays exactly where it is, but clicks, scrolls and keystrokes go straight to the app below, so you can advance a slide, scroll a page or switch apps without losing what you drew. `Control + Option + Command + E` again goes back to drawing, and so does `Control + Option + Command + D` — from click-through, `D` means "back to drawing", not "throw it away".

Only leaving drawing mode clears the drawing: `Control + Option + Command + D` while you are drawing, the emergency shortcut from anywhere, or the menu bar item. Switching between the two states never clears anything.

**While drawing, the keyboard belongs to the tool.** `C` clears, `Command + Z` undoes, and everything else — including `Escape` — is swallowed and does nothing. If you need to type, or need `Escape` to reach the app underneath (leaving a slideshow, for instance), switch to click-through with `Control + Option + Command + E` first.

You can always tell which state you are in: the corner badge reads a red `● DRAW` when the overlay owns your clicks and a dim `◌ CLICK-THROUGH` when they pass through, and its second line names the two shortcuts that apply right now. The crosshair pointer is drawn only while drawing, and the menu bar icon turns red while the overlay is taking clicks and becomes a dimmed struck-through pen in click-through.

`Control + Option + Command + Escape` exists for a reason. If drawing mode ever gets stuck and the overlay is swallowing your clicks, that shortcut always releases the screen, from either state, and it works even when nothing else responds. The menu bar item is the other way out: it stays clickable while you are drawing — the overlay deliberately sits just below the menu bar, so it never traps you behind itself — and carries **Start / Stop / Back to Drawing**, a **Click-Through** checkbox, and **Quit**.

If `Control + Option + Command + D` does nothing at launch, another app already owns that shortcut — the app tells you so with an alert. Change the key code or modifiers in `Sources/ScreenDrawOverlay/main.swift` and rebuild.

## Build from source

You need the Xcode command line tools (`xcode-select --install`). There is no Xcode project; everything is SwiftPM.

```bash
./build_app.sh
```

That builds a universal (Apple Silicon + Intel) release binary, assembles `dist/ScreenDrawOverlay.app`, ad-hoc signs it and writes `dist/ScreenDrawOverlay.zip`. Open the result with `open dist/ScreenDrawOverlay.app`. An app you built yourself is not quarantined, so it opens without the Gatekeeper detour above.

For a quick run without the bundle, `swift build -c release` and then `.build/release/ScreenDrawOverlay`.

## Known limits

This is v0.1 and deliberately small. There is no toolbar, no color picker, no line width control, no shapes or arrows, no saving or screenshot capture, no redo, and no preferences window. One red pen, one clear, one undo.

Beyond that, things worth knowing:

- While drawing mode is on, the overlay is above ordinary windows and dialogs, so another app's alert can end up underneath your drawing until you leave drawing mode. The menu bar and its status items stay above the overlay.
- While you are drawing, apps underneath still see where the pointer is even though your clicks come to the overlay, so the Dock and other apps may show hover highlights or tooltips under your cursor. Suppressing that would need an event tap and Accessibility permission, which this app deliberately does not ask for. Click-through mode is the way to interact with them normally.
- Keynote fades in and out of a slideshow with a window drawn above the overlay, so your drawing disappears for about a second at the start and end of a presentation. It comes back on its own.
- Plugging in, unplugging or rearranging a display while drawing ends drawing mode and clears the drawing. That is intentional — it is better than leaving an overlay stranded on a display that no longer exists.
- `Escape` does nothing while you are drawing. It used to leave drawing mode, but that only worked when the overlay happened to hold keyboard focus, and it threw the drawing away exactly when someone pressed `Escape` to get out of a slideshow. Use click-through if you need `Escape` to reach the app underneath.
- Drawings are never saved. Leaving drawing mode throws them away.

## License

MIT. See [LICENSE](LICENSE).
