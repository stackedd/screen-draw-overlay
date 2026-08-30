// The global shortcuts, as one set.
//
// Global rather than local because a non-activating panel only receives ordinary keystrokes
// while this app is the active one, and after the user has clicked anything in another app
// it is not. Every shortcut that has to work whatever has focus is here; the tool keys,
// which only mean anything while the overlay already has the keyboard, are in DrawingView.
//
// Carbon rather than an event monitor because Carbon needs no Accessibility permission,
// which is the decision the whole app hangs off (docs/DECISIONS.md 1).

import AppKit
import Carbon

final class Shortcuts {
    // What each shortcut does, handed in rather than reached for, so this type knows about
    // keys and nothing about modes. The same shape MenuBarItem uses.
    struct Actions {
        let drawPressed: () -> Void
        let drawReleased: () -> Void
        let toggleClickThrough: () -> Void
        let quit: () -> Void
        let undo: () -> Void
        let redo: () -> Void
    }

    // Carbon identifies a hot key by a number. Named rather than written out at the call
    // site, because two of these are load-bearing elsewhere: the behaviour suite fires the
    // draw and quit keys by id, so the numbers are part of the contract and not free to
    // renumber.
    private enum ID: UInt32 {
        case draw = 1
        case quit = 2
        case clickThrough = 3
        case undo = 4
        case redo = 5
        case toolWheel = 6
        case colourWheel = 7
        case widthWheel = 8
    }

    // The wheels are held down rather than tapped, so each one needs both halves of the
    // keypress - the same mechanism hold-to-draw uses.
    struct WheelActions {
        let tools: () -> Void
        let colours: () -> Void
        let widths: () -> Void
        let released: () -> Void
    }

    // Held only to keep them registered; nothing here needs to reach one by name.
    private var hotKeys: [GlobalHotKey] = []
    private var wheelKeys: [GlobalHotKey] = []

    // Registers the lot and returns the ones macOS refused, written the way a menu would
    // show them. A refusal is rare and quiet - two different processes can register the
    // same combination and both succeed - so this only ever catches the case macOS turns
    // down outright.
    @discardableResult
    func register(_ actions: Actions) -> [String] {
    // Every shortcut, its spoken name for the log, and the symbols the menu uses to
    // report it if macOS will not give it to us.
    let shortcuts: [(key: GlobalHotKey, spoken: String, symbols: String)] = [
        (GlobalHotKey(id: ID.draw.rawValue,
                      keyCode: UInt32(kVK_ANSI_D),
                      modifiers: UInt32(cmdKey | optionKey | controlKey),
                      handler: actions.drawPressed,
                      releaseHandler: actions.drawReleased),
         "Control + Option + Command + D", "\u{2303}\u{2325}\u{2318}D"),

        (GlobalHotKey(id: ID.clickThrough.rawValue,
                      keyCode: UInt32(kVK_ANSI_E),
                      modifiers: UInt32(cmdKey | optionKey | controlKey),
                      handler: actions.toggleClickThrough),
         "Control + Option + Command + E", "\u{2303}\u{2325}\u{2318}E"),

        (GlobalHotKey(id: ID.quit.rawValue,
                      keyCode: UInt32(kVK_Escape),
                      modifiers: UInt32(cmdKey | optionKey | controlKey),
                      handler: actions.quit),
         "Control + Option + Command + Escape", "\u{2303}\u{2325}\u{2318}\u{238B}"),

        // Undo is global because Command+Z is not. The panels are non-activating, so
        // they only get the keyboard while this app is the active one - and after the
        // user has clicked anything at all in another app, they are not. Command+Z
        // inside the overlay was then a silent no-op, in a state nothing on screen
        // distinguishes from the working one. Redo comes with it rather than after it:
        // an undo that always works beside a redo that only sometimes does is a trap.
        (GlobalHotKey(id: ID.undo.rawValue,
                      keyCode: UInt32(kVK_ANSI_Z),
                      modifiers: UInt32(cmdKey | optionKey | controlKey),
                      handler: actions.undo),
         "Control + Option + Command + Z", "\u{2303}\u{2325}\u{2318}Z"),

        (GlobalHotKey(id: ID.redo.rawValue,
                      keyCode: UInt32(kVK_ANSI_Z),
                      modifiers: UInt32(cmdKey | optionKey | controlKey | shiftKey),
                      handler: actions.redo),
         "Shift + Control + Option + Command + Z", "\u{21E7}\u{2303}\u{2325}\u{2318}Z")
    ]

    // A modal alert is the wrong tool for a background app: runModal blocks the main
    // thread, and an accessory app's dialog can sit behind everything, so a failure
    // at login would look like a hang. Failures go to the menu bar item instead,
    // which is also the way to work without the shortcut.
    var unavailable: [String] = []
    for shortcut in shortcuts {
        hotKeys.append(shortcut.key)
        if shortcut.key.register() {
            print("ScreenDrawOverlay: hotkey registered - \(shortcut.spoken)")
        } else {
            unavailable.append(shortcut.symbols)
        }
    }
        return unavailable
    }

    func unregister() {
        hotKeys.forEach { $0.unregister() }
        hotKeys.removeAll()
        unregisterWheels()
    }

    // The wheels come and go with the overlay, and deliberately: ⌥Z is a key that types
    // something, and taking it system-wide for a tool picker that only means anything while
    // there is a canvas would be rude. Held while drawing, it is ours; the rest of the time
    // it is not registered at all.
    func registerWheels(_ actions: WheelActions) {
        guard wheelKeys.isEmpty else {
            return
        }

        let wheels: [(ID, UInt32, () -> Void)] = [
            (.toolWheel, UInt32(kVK_ANSI_Z), actions.tools),
            (.colourWheel, UInt32(kVK_ANSI_X), actions.colours),
            (.widthWheel, UInt32(kVK_ANSI_C), actions.widths)
        ]

        for (id, keyCode, opened) in wheels {
            let key = GlobalHotKey(id: id.rawValue,
                                   keyCode: keyCode,
                                   modifiers: UInt32(optionKey),
                                   handler: opened,
                                   releaseHandler: actions.released)
            wheelKeys.append(key)
            if !key.register() {
                print("ScreenDrawOverlay: wheel shortcut unavailable")
            }
        }
    }

    func unregisterWheels() {
        wheelKeys.forEach { $0.unregister() }
        wheelKeys.removeAll()
    }
}
