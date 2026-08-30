# Testing

There is no XCTest target. A test here is the app's own sources compiled into a probe that
drives the real code and prints what happened, which is how behaviour that only exists in a
running AppKit app - window levels, key dispatch, cursor ownership, repaint regions - can be
checked at all.

    ./Testing/run.sh              both suites
    ./Testing/run.sh behaviour    the mode and editing checks
    ./Testing/run.sh rendering    the repaint comparison

**behaviour** (`probes/behaviour.swift`) drives a real AppDelegate: the mode matrix, hiding
and showing keeping strokes with their tool attributes, the unfinished-stroke commit, tool
keys through NSApplication's real key dispatch, Command+Q being swallowed,
clear/undo/redo, and tap versus hold on the drawing shortcut. Any refactor is judged by
whether its output is unchanged line for line.

**rendering** (`probes/rendering.swift`) paints the same session twice - once incrementally,
repainting only what the view asked for, and once in a single pass - and compares the two
bitmaps at 1x, 2x and 3x backing scale. It is how "the optimisation did not change what is
on screen" gets proved rather than asserted.

## Writing another probe

`make_behaviour_probe.py` copies every source file into `.build/testing/behaviour`, splices
the probe body into `applicationDidFinishLaunching`, and widens `private` so the probe can
reach internals. A probe body is Swift statements that close
`applicationDidFinishLaunching` and then declare helper methods, leaving the last one
unclosed - the builder adds the final brace. Copy `probes/behaviour.swift` and start there.

Two things learned the hard way, both worth keeping in mind:

- Send keys with `NSApp.sendEvent`, not by calling `keyDown` directly. AppKit routes
  modified keys through `performKeyEquivalent` first, and a probe that skips that path once
  reported four failures that did not exist - and, another time, hid a real one.
- Probes share persisted settings with each other. The builder clears them per run; a probe
  that writes settings and then reads them back should not assume otherwise.
