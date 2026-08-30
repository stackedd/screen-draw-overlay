#!/bin/bash
#
# Runs both suites against the current sources and prints a summary.
#
#   ./Testing/run.sh              both suites
#   ./Testing/run.sh behaviour    the mode and editing checks only
#   ./Testing/run.sh rendering    the incremental-repaint comparison only
#
# Neither suite needs a window on screen or any system permission. Both compile the app's
# own sources, so they test the real code rather than a copy of it.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
export TESTING_DIR="${TESTING_DIR:-.build/testing}"
suite="${1:-all}"
status=0

if [ "$suite" = "all" ] || [ "$suite" = "behaviour" ]; then
    echo "==> Behaviour"
    python3 Testing/make_behaviour_probe.py Testing/probes/behaviour.swift > /dev/null
    swift build --package-path "$TESTING_DIR/behaviour" -c release 2>&1 | grep -E "error:" && exit 1
    output=$("$TESTING_DIR/behaviour/.build/release/Hold" 2>&1 | grep "REG " || true)
    echo "$output" | sed 's/^REG /    /'
    echo "$output" | grep -q "0 failed" || status=1
fi

if [ "$suite" = "all" ] || [ "$suite" = "rendering" ]; then
    echo "==> Rendering (incremental repaint against a single full repaint)"
    python3 Testing/make_render_probe.py > /dev/null
    swift build --package-path "$TESTING_DIR/rendering" -c release 2>&1 | grep -E "error:" && exit 1
    for scale in 1 2 3; do
        SCALE=$scale "$TESTING_DIR/rendering/.build/release/PIX" | sed 's/^/    /'
    done
    echo
    echo "    fullViewInvalidations must be 0: a drag that repaints the whole view is the"
    echo "    bug this suite exists to catch. The differing bytes are antialiasing along"
    echo "    clip boundaries, not missed paint - expanding every dirty rect makes them"
    echo "    worse, not better (docs/DECISIONS.md). What matters is that the numbers do"
    echo "    not move when you change how painting works."
fi

echo
if [ "$status" -eq 0 ]; then
    echo "All good."
else
    echo "FAILURES above."
fi
exit "$status"
