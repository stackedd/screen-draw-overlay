# Builds a test copy of the app: every source file, with the internals a probe needs made
# visible, and the probe itself either spliced into the running app or standing in for its
# entry point.
#
#     python3 Testing/make_probe.py behaviour Hold --splice
#     python3 Testing/make_probe.py rendering PIX
#
# The two shapes are there because the two kinds of probe need different things. A probe
# that drives the real app has to run inside it, so its body is spliced into
# applicationDidFinishLaunching and main.swift comes along. A probe that drives one view
# offscreen is its own program, so it replaces main.swift instead.
import io, os, shutil, sys

if len(sys.argv) < 3:
    raise SystemExit("usage: make_probe.py <probe name> <target name> [--splice]")

name, target = sys.argv[1], sys.argv[2]
splice = "--splice" in sys.argv[3:]
root = os.environ.get("TESTING_DIR", ".build/testing")
pkg = root + "/" + name
src = pkg + "/Sources/" + target
probe = io.open("Testing/probes/" + name + ".swift", encoding="utf-8").read()

shutil.rmtree(pkg, ignore_errors=True)
os.makedirs(src)
io.open(pkg + "/Package.swift", "w", encoding="utf-8").write(
    io.open("Package.swift", encoding="utf-8").read().replace("ScreenDrawOverlay", target))

# Where a spliced probe's body goes: the end of applicationDidFinishLaunching, after the
# app has finished setting itself up. The probe closes that method and then declares its
# own helpers, leaving the last one open for the brace added below.
ANCHOR = """            controller.reportUnavailableShortcuts(unavailable)
        }
    }
"""
HEAD = """            controller.reportUnavailableShortcuts(unavailable)
        }

"""

# private is file scoped, so a probe can otherwise only reach what its own file can see.
OPEN_UP = [
    ("    private func ", "    func "),
    ("    private var ", "    var "),
    ("    private let ", "    let "),
    ("    private static func ", "    static func "),
    ("    private(set) var ", "    var "),
    ("    private struct ", "    struct "),
    ("    private enum ", "    enum "),
    ("    private final class ", "    final class "),
    ("    private static let ", "    static let "),
    ("final class DrawingView", "class DrawingView"),
]

spliced = False
for source in sorted(os.listdir("Sources/ScreenDrawOverlay")):
    if source == "main.swift" and not splice:
        continue

    text = io.open("Sources/ScreenDrawOverlay/" + source, encoding="utf-8").read()
    if splice and ANCHOR in text:
        # Probes drive the app with Carbon key codes and hot key events, which the file
        # they are spliced into has no reason to import on its own.
        text = text.replace("import AppKit", "import AppKit\nimport Carbon", 1)
        text = text.replace(ANCHOR, HEAD + probe + "    }\n", 1)
        spliced = True
    for a, b in OPEN_UP:
        text = text.replace(a, b)
    io.open(src + "/" + source, "w", encoding="utf-8").write(text)

if splice:
    assert spliced, "probe anchor not found in any source file"
else:
    io.open(src + "/main.swift", "w", encoding="utf-8").write(probe)

# Probes share persisted settings, so a run that left temporary ink switched on would
# quietly change what the next one measures. Start every probe from the defaults.
os.system("defaults delete " + target + " 2>/dev/null")
print(name, "probe built from", len(os.listdir(src)), "source file(s)")
