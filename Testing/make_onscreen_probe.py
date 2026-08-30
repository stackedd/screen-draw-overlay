# Builds the on-screen harness: the app's sources, minus the bootstrap, plus a probe that
# puts a real OverlayPanel on screen and times what it costs to drive it.
import io, os, shutil

root = os.environ.get("TESTING_DIR", ".build/testing")
pkg = root + "/onscreen"
src = pkg + "/Sources/LIVE"
shutil.rmtree(pkg, ignore_errors=True)
os.makedirs(src)
io.open(pkg + "/Package.swift", "w", encoding="utf-8").write(
    io.open("Package.swift", encoding="utf-8").read().replace("ScreenDrawOverlay", "LIVE"))

OPEN_UP = [("    private func ", "    func "), ("    private var ", "    var "),
           ("    private let ", "    let "), ("    private static func ", "    static func "),
           ("    private static let ", "    static let "), ("    private(set) var ", "    var "),
           ("    private struct ", "    struct "), ("    private enum ", "    enum "),
           ("    private final class ", "    final class "),
           ("final class DrawingView", "class DrawingView")]

for name in sorted(os.listdir("Sources/ScreenDrawOverlay")):
    if name == "main.swift":
        continue
    text = io.open("Sources/ScreenDrawOverlay/" + name, encoding="utf-8").read()
    for a, b in OPEN_UP:
        text = text.replace(a, b)
    io.open(src + "/" + name, "w", encoding="utf-8").write(text)

shutil.copy("Testing/probes/onscreen.swift", src + "/main.swift")
print("onscreen harness built")
