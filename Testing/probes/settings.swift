import AppKit
import Carbon

// The settings window: what its layout came out as, and - if you ask - the window itself, on
// screen, to click at.
//
// **Why there is no PNG here** when every other by-hand probe renders one: the controls in
// this window are hosted views (`_NSCoreHostingView`), and `cacheDisplay(in:to:)` draws
// nothing for them - the first version of this probe produced a picture with four text fields
// floating in an empty rectangle, which is a worse answer than no picture. Capturing what is
// really on screen would need Screen Recording, the one permission this app will not ask for
// (CLAUDE.md, never number 1). So this prints the geometry, which is what goes wrong - a row
// that does not line up, a control with no width, two of them on top of each other - and
// SETTINGS_HOLD=1 leaves the real window up for a human to look at and click.
//
//     python3 Testing/make_probe.py settings SETTINGS \
//       && swift build --package-path .build/testing/settings -c release \
//       && SETTINGS_HOLD=1 .build/testing/settings/.build/release/SETTINGS

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

// A defaults domain of its own: a probe that wrote to the real one would change the keys of
// whatever copy of the app is installed on this machine.
let domain = "scrim.probe.settings"
let scratch = UserDefaults(suiteName: domain)!
scratch.removePersistentDomain(forName: domain)
let settings = ShortcutSettings(defaults: scratch)

// One row moved and one delay taken to zero, so the report shows a changed binding and a field
// holding 0 rather than only the defaults.
settings.set(keyCode: UInt32(kVK_ANSI_U), modifiers: UInt32(cmdKey | controlKey),
             key: "U", for: .undo)
settings.setDelay(0, for: .actions)

let window = SettingsWindow(settings: settings, suspendShortcuts: { _ in })
window.show()

guard let content = window.window?.contentView else {
    print("SETTINGS no window")
    exit(1)
}

// Laid out before it is measured: a window that has never been displayed has no frames yet,
// and everything in it would report the origin.
content.layoutSubtreeIfNeeded()
window.window?.displayIfNeeded()

// Only the controls, named by what they are for. The view tree under a modern AppKit control
// is four layers of private classes and none of it is worth reading.
func controls(in view: NSView, into found: inout [(String, NSRect)]) {
    for subview in view.subviews {
        let frame = subview.convert(subview.bounds, to: content)
        switch subview {
        case let button as SettingsWindow.RecorderButton:
            found.append(("recorder \"\(button.title)\"", frame))
        case let field as NSTextField where field.isEditable:
            found.append(("delay \"\(field.stringValue)\"", frame))
        case let label as NSTextField:
            found.append(("label \"\(label.stringValue.prefix(36))\"", frame))
        case let button as NSButton:
            found.append(("button \"\(button.title)\"", frame))
        default:
            controls(in: subview, into: &found)
        }
    }
}

var found: [(String, NSRect)] = []
controls(in: content, into: &found)

print("SETTINGS window \(Int(content.bounds.width))x\(Int(content.bounds.height)), "
      + "\(found.count) controls")

var faults = 0
for (name, frame) in found.sorted(by: { $0.1.maxY > $1.1.maxY }) {
    var note = ""
    if frame.width < 1 || frame.height < 1 {
        note = "  <- no size"
        faults += 1
    }

    if frame.minX < 0 || frame.maxX > content.bounds.width
        || frame.minY < 0 || frame.maxY > content.bounds.height {
        note += "  <- outside the window"
        faults += 1
    }

    let position = "\(Int(frame.minX)),\(Int(frame.minY))"
    let size = "\(Int(frame.width))x\(Int(frame.height))"
    print("SETTINGS   \(name.padding(toLength: 44, withPad: " ", startingAt: 0)) \(position)  \(size)\(note)")
}

// Two controls on top of each other is the layout fault a report like this exists to catch.
for (index, one) in found.enumerated() {
    for other in found.dropFirst(index + 1) where one.1.intersects(other.1) {
        let overlap = one.1.intersection(other.1)
        if overlap.width > 1, overlap.height > 1 {
            print("SETTINGS   OVERLAP \(one.0) and \(other.0)")
            faults += 1
        }
    }
}

print("SETTINGS \(faults) fault(s)")

// Left up to be looked at and clicked, because the one thing this cannot check is whether
// recording a shortcut feels like anything.
if ProcessInfo.processInfo.environment["SETTINGS_HOLD"] != nil {
    print("SETTINGS holding the window up - close it, or Control-C")
    app.setActivationPolicy(.regular)
    app.activate(ignoringOtherApps: true)
    app.run()
}
