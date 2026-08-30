#!/bin/bash
#
# Runs the suites against the current sources and prints a summary.
#
#   ./Testing/run.sh              every suite
#   ./Testing/run.sh behaviour    the mode and editing checks only
#   ./Testing/run.sh rendering    the incremental-repaint comparison only
#   ./Testing/run.sh cost         what a repaint costs to paint
#
# No suite needs a window on screen or any system permission. All of them compile the app's
# own sources, so they test the real code rather than a copy of it. The one measurement that
# does need a window on screen is Testing/experiments/, which is run by hand.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
export TESTING_DIR="${TESTING_DIR:-.build/testing}"
suite="${1:-all}"
status=0

if [ "$suite" = "all" ] || [ "$suite" = "behaviour" ]; then
    echo "==> Behaviour"
    python3 Testing/make_probe.py behaviour Hold --splice > /dev/null
    swift build --package-path "$TESTING_DIR/behaviour" -c release 2>&1 | grep -E "error:" && exit 1
    output=$("$TESTING_DIR/behaviour/.build/release/Hold" 2>&1 | grep "REG " || true)
    echo "$output" | sed 's/^REG /    /'
    echo "$output" | grep -q "0 failed" || status=1
fi

if [ "$suite" = "all" ] || [ "$suite" = "rendering" ]; then
    echo "==> Rendering (incremental repaint against a single full repaint)"
    python3 Testing/make_probe.py rendering PIX > /dev/null
    swift build --package-path "$TESTING_DIR/rendering" -c release 2>&1 | grep -E "error:" && exit 1
    for scale in 1 2 3; do
        SCALE=$scale "$TESTING_DIR/rendering/.build/release/PIX" | sed 's/^/    /'
    done
    echo
    echo "    fullInkInvalidations must be 0: a drag that repaints the whole drawing is the"
    echo "    bug this suite exists to catch. The differing bytes are antialiasing along"
    echo "    clip boundaries, not missed paint - expanding every dirty rect makes them"
    echo "    worse, not better (docs/DECISIONS.md). What matters is that the numbers do"
    echo "    not move when you change how painting works."
fi

if [ "$suite" = "all" ] || [ "$suite" = "cost" ]; then
    echo
    echo "==> Cost (what a repaint costs to paint)"
    python3 Testing/make_probe.py cost COST > /dev/null
    swift build --package-path "$TESTING_DIR/cost" -c release 2>&1 | grep -E "error:" && exit 1
    "$TESTING_DIR/cost/.build/release/COST" | sed 's/^/    /'
fi

echo
if [ "$status" -eq 0 ]; then
    echo "All good."
else
    echo "FAILURES above."
fi
exit "$status"
