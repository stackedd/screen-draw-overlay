# Builds a test copy of the app: every source file, with a probe body spliced into
# applicationDidFinishLaunching and the internals the probe needs made visible.
import io, os, shutil, sys

root = os.environ.get("TESTING_DIR", ".build/testing")
body = io.open(sys.argv[1], encoding="utf-8").read()
pkg = root + "/behaviour"
src = pkg + "/Sources/Hold"
shutil.rmtree(pkg, ignore_errors=True)
os.makedirs(src)

package = io.open("Package.swift", encoding="utf-8").read().replace("ScreenDrawOverlay", "Hold")
io.open(pkg + "/Package.swift", "w", encoding="utf-8").write(package)

ANCHOR = """            menuBar?.reportUnavailableShortcuts(unavailable)
        }
    }
"""
HEAD = """            menuBar?.reportUnavailableShortcuts(unavailable)
        }

"""
# private is file scoped, so the probe can only reach what the probe's own file can see.
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
for name in sorted(os.listdir("Sources/ScreenDrawOverlay")):
    text = io.open("Sources/ScreenDrawOverlay/" + name, encoding="utf-8").read()
    if ANCHOR in text:
        text = text.replace(ANCHOR, HEAD + body + "    }\n", 1)
        spliced = True
    for a, b in OPEN_UP:
        text = text.replace(a, b)
    io.open(src + "/" + name, "w", encoding="utf-8").write(text)

assert spliced, "probe anchor not found in any source file"
# Probes share persisted settings, so a run that left temporary ink switched on would
# quietly change what the next one measures. Start every probe from the defaults.
os.system("defaults delete Hold 2>/dev/null")
print("probe built from", len(os.listdir(src)), "source file(s)")
