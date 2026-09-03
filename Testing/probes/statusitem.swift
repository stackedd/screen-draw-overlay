import AppKit

// What a status item reports when the menu bar has room for it, and what it reports when it
// does not. Run it twice - once as things are, once with the menu bar full - and compare.
//
// It exists because macOS hides a status item that will not fit and tells the app nothing:
// there is no notification, no error, and `NSStatusItem.isVisible` answers "did you ask for it
// to be shown", not "is it on screen". Whatever separates the two cases has to be found by
// looking, and this is the looking. Nothing in the app should test a field this has not shown
// to move (docs/DECISIONS.md 33).
//
//     python3 Testing/make_probe.py statusitem STATUS \
//       && swift build --package-path .build/testing/statusitem -c release \
//       && .build/testing/statusitem/.build/release/STATUS
//
// It also fills the menu bar itself: CROWD=40 puts forty items up, which is more than any
// menu bar has room for, so the ones that do not fit are right here to be measured rather than
// waiting for somebody's machine to be busy enough.

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

func madeItem(_ symbol: String) -> NSStatusItem {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    item.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "probe")
    item.button?.image?.isTemplate = true
    return item
}

let item = madeItem("scribble")

// Enough of them that the menu bar cannot hold them all. The ones past the end are the whole
// point: they are what this app looks like on a machine whose menu bar is full.
let crowd = Int(ProcessInfo.processInfo.environment["CROWD"] ?? "0") ?? 0
let others = (0..<crowd).map { _ in madeItem("circle.fill") }

// The window server needs a turn before a status item has a frame at all.
RunLoop.current.run(until: Date().addingTimeInterval(1.5))

if crowd > 0 {
    print("STATUS crowded the menu bar with \(others.count) more items")
    let frames = others.compactMap { $0.button?.window?.frame }
    let onScreen = frames.filter { frame in NSScreen.screens.contains { $0.frame.intersects(frame) } }
    print("STATUS of those, \(onScreen.count) are over a screen and \(frames.count - onScreen.count) are not")
    if let squeezed = frames.first(where: { frame in !NSScreen.screens.contains { $0.frame.intersects(frame) } }) {
        print("STATUS one that did not fit: \(squeezed)")
    }
    let visible = others.filter { $0.button?.window?.isVisible == true }
    print("STATUS and \(visible.count) of them report window.isVisible")
}

print("STATUS isVisible (what we asked for): \(item.isVisible)")
print("STATUS length: \(item.length)")

if let button = item.button {
    print("STATUS button frame in its window: \(button.frame)")
    print("STATUS button is hidden: \(button.isHidden)")
    print("STATUS button alpha: \(button.alphaValue)")

    if let window = button.window {
        print("STATUS window frame: \(window.frame)")
        print("STATUS window isVisible: \(window.isVisible)")
        print("STATUS window occlusionState visible: \(window.occlusionState.contains(.visible))")
        print("STATUS window level: \(window.level.rawValue)")
        print("STATUS window alpha: \(window.alphaValue)")

        let screens = NSScreen.screens.map { "\($0.frame)" }.joined(separator: " | ")
        print("STATUS screens: \(screens)")

        if let screen = NSScreen.screens.first(where: { $0.frame.intersects(window.frame) }) {
            print("STATUS on a screen: yes, \(screen.frame)")
            print("STATUS gap between the menu bar and the top of the screen: "
                  + "\(screen.frame.maxY - window.frame.maxY)")
        } else {
            print("STATUS on a screen: NO - the window is not over any screen")
        }
    } else {
        print("STATUS window: none")
    }
} else {
    print("STATUS button: none")
}

// And what the app does about it: the card it puts on screen when the icon is not there. Drawn
// through Picture like everything else on a layer here, so unlike the settings window this one
// can be looked at.
if let out = ProcessInfo.processInfo.environment["OUT"] {
    let cards = [
        ("no room, shortcut fine",
         "Scrim is running, but the menu bar has no room for its icon",
         "Hold ⌥X and push the mouse at a tool to draw. ⌃⌥⌘⎋ quits. To get the icon back, "
         + "close something else that lives in the menu bar."),
        ("no room and no shortcut",
         "Scrim is running, but you cannot see or reach it",
         "The menu bar has no room for its icon, and macOS refused ⌥X - another app has it. "
         + "⌃⌥⌘⎋ quits, and that always works."),
        ("shortcut taken",
         "Another app already has ⌥X",
         "macOS gave it to whoever asked first and told neither of us. Open Settings from the "
         + "menu bar icon to choose another key.")
    ]

    let scale: CGFloat = 2
    let drawn = cards.compactMap { NoticePanel.card(headline: $0.1, detail: $0.2, scale: scale) }
    let gap: CGFloat = 16
    let width = CGFloat(drawn.map { $0.width }.max() ?? 0) / scale + gap * 2
    let height = drawn.reduce(gap) { $0 + CGFloat($1.height) / scale + gap }

    let sheet = Picture.drawn(size: NSSize(width: width, height: height), scale: scale) {
        // A checkerboard under them, because the card has a shadow and a translucent plate and
        // both are invisible against flat white.
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSColor(white: 0.85, alpha: 1).setFill()
        var row: CGFloat = 0
        while row < height {
            var column: CGFloat = row.truncatingRemainder(dividingBy: 32) < 16 ? 0 : 16
            while column < width {
                NSRect(x: column, y: row, width: 16, height: 16).fill()
                column += 32
            }
            row += 16
        }

        var y = height - gap
        for card in drawn {
            let size = NSSize(width: CGFloat(card.width) / scale, height: CGFloat(card.height) / scale)
            y -= size.height
            NSGraphicsContext.current?.cgContext.draw(
                card, in: NSRect(x: gap, y: y, width: size.width, height: size.height))
            y -= gap
        }
    }

    try! NSBitmapImageRep(cgImage: sheet!).representation(using: .png, properties: [:])!
        .write(to: URL(fileURLWithPath: out))
    print("STATUS wrote \(out): \(drawn.count) notice cards")
}

// And on screen, where the only thing that can check it is a pair of eyes: does it sit under
// the menu bar, is it readable over whatever is behind it, does it go away on its own.
if ProcessInfo.processInfo.environment["NOTICE_HOLD"] != nil {
    let notice = NoticePanel()
    notice.show("Scrim is running, but the menu bar has no room for its icon",
                "Hold ⌥X and push the mouse at a tool to draw. ⌃⌥⌘⎋ quits. To get the icon "
                + "back, close something else that lives in the menu bar.")
    print("STATUS the card is up - it takes itself away after seven seconds")
    RunLoop.current.run(until: Date().addingTimeInterval(9))
    print("STATUS gone")
}
