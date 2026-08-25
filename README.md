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
5. A `D` appears in the menu bar. That is the whole UI.

The app does not launch at login by itself. Add it under System Settings → General → Login Items if you want that.

## Shortcuts

| Shortcut | What it does |
| --- | --- |
| `Control + Option + Command + D` | Toggle drawing mode on and off |
| Drag the mouse | Draw a red freehand line |
| `C` | Clear everything, stay in drawing mode |
| `Command + Z` | Undo the last stroke |
| `Escape` | Clear and leave drawing mode |
| `Control + Option + Command + Escape` | Emergency exit: force close the overlay |

The last one exists for a reason. If drawing mode ever gets stuck and the overlay is swallowing your clicks, that shortcut always releases the screen, and it works even when nothing else responds. The menu bar item also has **Toggle Drawing Mode** and **Quit**, and it stays clickable while you are drawing: the overlay deliberately sits just below the menu bar, so it never traps you behind itself.

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
- Keynote fades in and out of a slideshow with a window drawn above the overlay, so your drawing disappears for about a second at the start and end of a presentation. It comes back on its own.
- Plugging in, unplugging or rearranging a display while drawing ends drawing mode and clears the drawing. That is intentional — it is better than leaving an overlay stranded on a display that no longer exists.
- Drawings are never saved. Leaving drawing mode throws them away.

## License

MIT. See [LICENSE](LICENSE).
