# Cutting a release

Scrim is free software under the MIT licence. A release is a tag, a built app, and
a GitHub Release with the zip attached - plus, if you want, a pay-what-you-want page pointing
at the same download. Nothing in the app knows or cares about any of that.

## Before anything

    ./Testing/run.sh          # behaviour: 0 failed. rendering: 0 differing bytes. cost prints.
    ./build_app.sh            # must be warning-free; it also compiles the x86_64 slice

And look at the pictures, because the suites cannot: `probes/wheel.swift` (the four wheels),
`probes/badge.swift`, `probes/cursor.swift`, `probes/laser.swift`, `probes/ink.swift`, and
`Packaging/icon-preview.png`. Anything whose appearance changed should have been looked at in
the commit that changed it; this is the last check that nothing moved since.

Manual, because nothing in this repo can inject a real mouse or a real presentation:

- The whole `⌥A` gesture with a real hand: open, pick, draw, undo with `⌥Z` (tapped and held),
  leave by the hub.
- A real slideshow, full screen: the pointer is visible, the laser reads, the overlay is above
  the slides. **Keynote is the only one any of this has ever been checked against** - 13.2, by
  hand, on this machine. PowerPoint, Google Slides in a browser and a Zoom or Teams share have
  never been tried. If you try one, write down what happened either way: a second reference is
  worth more here than another number.
- **Typing over that slideshow.** Pick the text tool, click, type a word. The keys must arrive
  and the slideshow must keep running - it is the one thing this app cannot check for itself
  (docs/DECISIONS.md 39). If the keys do not arrive, Settings has "come forward while typing".
- A second display, if there is one: the badge on one screen, drawing on both.
- A clean user account: first launch and the Gatekeeper warning.

## Version

`Packaging/Info.plist`: `CFBundleShortVersionString` is what people see; `CFBundleVersion` is a
number that only ever goes up. Both change in the release commit, and the tag matches it:
`git tag -a v1.0 -m "..."` then `git push --tags`.

**Where the numbering stands.** Nothing has been released yet, so the app is **0.9**: the
version that says "this is the shape 1.0 will have". The first public release is **1.0**, and
until it is cut, 0.9 is what every measurement in `docs/ARCHITECTURE.md` is stamped with. That
matters more than it sounds: a number in a document with no version beside it is a number
nobody can weigh, so anything measured from here on says which version it was measured on and
on what machine.

## Building what people download

Without an Apple Developer Program membership:

    ./build_app.sh            # ad-hoc signed; dist/Scrim.zip is the download

With one ($99/year), the same script does the whole job:

    DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" \
    NOTARY_PROFILE=screendraw ./build_app.sh

The profile is made once:

    xcrun notarytool store-credentials screendraw \
      --apple-id you@example.com --team-id TEAMID --password <app-specific-password>

That signs with the hardened runtime, submits to Apple, waits, staples the ticket to the app,
and rebuilds the zip - so the copy people download opens with no warning and no network.

## What an unsigned copy costs

Until the membership exists, everyone who downloads it meets Gatekeeper. Put this on the
release page and the download page, in these words, above the link:

> **First launch:** macOS will say the app "cannot be opened because Apple cannot check it for
> malicious software". Right-click the app and choose **Open**, then **Open** again. On macOS
> 15 and later: try to open it once, then go to **System Settings → Privacy & Security** and
> click **Open Anyway**. You only do this once.

People who build from source do not hit this at all, which is worth saying too - it is one
command.

## Publishing

1. `gh release create v1.0 dist/Scrim.zip --title "..." --notes "..."`, or the web
   UI. Attach the zip, not the app folder.
2. The release notes are for users, not for git: what is new, what broke, and the Gatekeeper
   paragraph above.
3. If there is a pay-what-you-want page, point it at the same zip and say plainly that the app
   is free and MIT-licensed and that paying is optional. Nothing in the app mentions it: no
   nag, no reminder, no menu item. That is deliberate.

## Recording the demo

The README has room for one short clip, and it is the single most convincing thing on the page.
Twenty seconds, one take, no narration:

1. A slide or a document on screen. Hold `⌥A`, the wheel opens, push right, let go - the pen.
2. Underline a word. Circle something.
3. Hold `⌥D`, push at another colour, draw one more mark.
4. Press `⌥Z` twice: the last two marks go. Then `⌥C`: the screen is empty, and the badge
   says ⌥Z puts it back.
5. Hold `⌥A`, push at `LASER`, let go, and sweep the beam across a diagram.
6. Hold `⌥A`, let go in the middle: the screen goes back to the app underneath, drawing still
   on it. Once more: it is gone.

Record with QuickTime (File → New Screen Recording), then:

    ffmpeg -i demo.mov -vf "fps=12,scale=900:-1:flags=lanczos" -loop 0 docs/demo.gif

No ffmpeg? Keep the `.mov`, or export a smaller `.mp4` from QuickTime and link it instead -
GitHub plays uploaded video in a README, it just cannot be committed as easily.

Still shots worth having next to it: the tools wheel open over something real, the badge in the
corner, and the laser mid-sweep. Take them with `⇧⌘4` on your own screen; the renders in
`Testing/probes/` are for developers, not for the front page.

## Later: the App Store

The architecture does not rule it out. Carbon's `RegisterEventHotKey` works inside the sandbox
(it is not an event tap), `SMAppService` is the sandbox-friendly way to open at login and is
already what this app uses, and a panel at `.popUpMenu` level is allowed. What it would take is
the membership, a sandbox entitlement set, and review. Nothing in the code has to change for
it, which is worth keeping true.
