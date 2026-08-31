# Testing

There is no XCTest target. A test here is the app's own sources compiled into a probe that
drives the real code and prints what happened, which is how behaviour that only exists in a
running AppKit app - window levels, key dispatch, cursor ownership, repaint regions - can be
checked at all.

    ./Testing/run.sh              every suite
    ./Testing/run.sh behaviour    the mode and editing checks
    ./Testing/run.sh rendering    the repaint comparison
    ./Testing/run.sh cost         what a repaint costs to paint

**behaviour** (`probes/behaviour.swift`) drives a real AppDelegate: the mode matrix, hiding
and showing keeping strokes with their tool attributes, the unfinished-stroke commit, tool
keys through NSApplication's real key dispatch, Command+Q being swallowed,
clear/undo/redo, and tap versus hold on the drawing shortcut. Any refactor is judged by
whether its output is unchanged line for line.

**rendering** (`probes/rendering.swift`) paints the same session twice - once incrementally,
repainting only what the view asked for, and once in a single pass - and compares the two
bitmaps at 1x, 2x and 3x backing scale. It is how "the optimisation did not change what is
on screen" gets proved rather than asserted.

`differingBytes` and `fullInkInvalidations` are the results; `strokes` only describes the
session and moves whenever the session's own behaviour changes - it went 5 to 7 when the
eraser started cutting shapes instead of removing them.

**cost** (`probes/cost.swift`) drives the same view and paints, into an offscreen bitmap at
a Retina backing scale, every rectangle the view asks to have repainted - then times it. Four
sweeps: one unbroken stroke of up to 5000 points, pointer moves over a canvas holding 0, 50
and 200 strokes, a short drag over the same, and a fade tick. Two dirty-region models are run
side by side (each rectangle painted on its own, and one paint covering all of them), because
a layer-backed view really does get the union.

It measures **painting only**. Updating the window's backing store and compositing the panel
happen in no process this probe can see, and they are most of the bill - see
`docs/ARCHITECTURE.md`. Read a cost number as "how much of the small half moved".

## Looking at it

`probes/cursor.swift`, `probes/eraser.swift` and `probes/wheel.swift` render to a PNG.

The cursor one draws every tool over a light background and a dark one. The suite can check
that the hot spot is where the ink lands; it cannot tell whether a pen looks like a pen.

The eraser one exists because counting strokes proves it cut something and cannot show that
the hole is the size of the eraser, that a shape comes apart the way a line does, or that no
crumbs are left in the gap. All three have been wrong at least once.

`probes/wheel.swift` renders the wheels. It is not a pass or a fail, so it is not in
`run.sh`; it exists because the suites cannot catch what goes wrong with a picture - blurry
text, a swatch the same colour as the plate under it, a label too long for the hub it has to
fit inside. The badge taught that twice.

    python3 Testing/make_probe.py wheel WHEEL \
      && swift build --package-path .build/testing/wheel -c release \
      && OUT=/tmp/wheel.png .build/testing/wheel/.build/release/WHEEL

## On a real screen

Two measurements need a window on screen, so neither is in `run.sh`.

`probes/onscreen.swift` is the end-to-end one: a real `OverlayPanel`, driven at 60 events a
second, reporting this process's own CPU for each thing a user might be doing. It is built
the same way as the other probes and run by hand:

    python3 Testing/make_probe.py onscreen LIVE && \
      swift build --package-path .build/testing/onscreen -c release && \
      .build/testing/onscreen/.build/release/LIVE

To get a before as well as an after, run it against an older commit in a worktree - it only
uses API that has been there all along:

    git worktree add /tmp/before <commit>
    cp Testing/probes/onscreen.swift /tmp/before/Testing/probes/
    cp Testing/make_probe.py /tmp/before/Testing/

`experiments/repaint_paths.swift` is the other one: what one
repaint of a full screen transparent overlay costs, split between this process and
WindowServer, across the ways of asking for one. It needs a real window on a real screen, so
it is run by hand rather than by `run.sh`:

    swiftc -O -o /tmp/repaint_paths Testing/experiments/repaint_paths.swift && /tmp/repaint_paths

It puts a transparent panel up for about a minute. The panel sets `ignoresMouseEvents`, so it
cannot take anyone's click while it is up.

## Writing another probe

One builder makes all of them:

    python3 Testing/make_probe.py <probe name> <target name> [--splice]

It copies every source file into `.build/testing/<probe name>` and widens `private` so the
probe can reach internals. There are two shapes, because the two kinds of probe need
different things:

- **Spliced** (`--splice`, which only `behaviour` uses). The probe runs inside the real app,
  so its body goes into the end of `applicationDidFinishLaunching` and `main.swift` comes
  along. A probe body is Swift statements that close `applicationDidFinishLaunching` and
  then declare helper methods, leaving the last one unclosed - the builder adds the final
  brace. Copy `probes/behaviour.swift` and start there.
- **Standalone** (everything else). The probe *is* the program, so it replaces `main.swift`
  and drives a view or a panel directly. Copy `probes/rendering.swift`.

Two things learned the hard way, both worth keeping in mind:

- Send keys with `NSApp.sendEvent`, not by calling `keyDown` directly. AppKit routes
  modified keys through `performKeyEquivalent` first, and a probe that skips that path once
  reported four failures that did not exist - and, another time, hid a real one.
- Probes share persisted settings with each other. The builder clears them per run; a probe
  that writes settings and then reads them back should not assume otherwise.
