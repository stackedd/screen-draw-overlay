// The global shortcuts, as one set.
//
// Global rather than local because a non-activating panel only receives ordinary keystrokes
// while this app is the active one, and after the user has clicked anything in another app it
// is not. Every shortcut that has to work whatever has focus is here; the tool keys, which
// only mean anything while the overlay already has the keyboard, are in DrawingView.
//
// Carbon rather than an event monitor because Carbon needs no Accessibility permission, which
// is the decision the whole app hangs off (docs/DECISIONS.md 1).

import AppKit
import Carbon

final class Shortcuts {
    // The ones that are always live. Opening the overlay is among them, because the tools
    // wheel is now the only thing that opens one.
    struct Actions {
        let toolWheel: () -> Void
        let wheelReleased: () -> Void
        let quit: () -> Void
        let undo: () -> Void
        let redo: () -> Void
    }

    // The other three wheels only mean something once there is a canvas, so they come and go
    // with the overlay. Each is held rather than tapped, so each needs both halves of the
    // keypress.
    struct WheelActions {
        let colours: () -> Void
        let widths: () -> Void
        let actions: () -> Void
        let released: () -> Void
    }

    // Carbon identifies a hot key by a number. Named rather than written out at the call
    // site, because one of these is load-bearing elsewhere: the behaviour suite fires the
    // quit key by id, so its number is part of the contract.
    private enum ID: UInt32 {
        case quit = 2
        case undo = 4
        case redo = 5
        case toolWheel = 6
        case colourWheel = 7
        case widthWheel = 8
        case actionWheel = 9
    }

    // Held only to keep them registered; nothing here needs to reach one by name.
    private var hotKeys: [GlobalHotKey] = []
    private var wheelKeys: [GlobalHotKey] = []

    // Registers the lot and returns the ones macOS refused, written the way a menu would
    // show them. A refusal is rare and quiet - two different processes can register the same
    // combination and both succeed - so this only ever catches the case macOS turns down
    // outright.
    @discardableResult
    func register(_ actions: Actions) -> [String] {
        let shortcuts: [(key: GlobalHotKey, spoken: String, symbols: String)] = [
            // The way in and the way around. Registered for the life of the app rather than
            // with the overlay, because it is now the only thing that opens one - which
            // costs ⌥Z system-wide, and is the strongest argument there is for eventually
            // letting people change these.
            (GlobalHotKey(id: ID.toolWheel.rawValue,
                          keyCode: UInt32(kVK_ANSI_Z),
                          modifiers: UInt32(optionKey),
                          handler: actions.toolWheel,
                          releaseHandler: actions.wheelReleased),
             "Option + Z", "\u{2325}Z"),

            (GlobalHotKey(id: ID.quit.rawValue,
                          keyCode: UInt32(kVK_Escape),
                          modifiers: UInt32(cmdKey | optionKey | controlKey),
                          handler: actions.quit),
             "Control + Option + Command + Escape", "\u{2303}\u{2325}\u{2318}\u{238B}"),

            // Undo is global because Command+Z is not: the panels are non-activating, so
            // they only get the keyboard while this app is active, and after the user has
            // clicked anything at all in another app they are not. Redo comes with it rather
            // than after it - an undo that always works beside a redo that only sometimes
            // does is a trap.
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
        // thread, and an accessory app's dialog can sit behind everything, so a failure at
        // login would look like a hang. Failures go to the menu bar item instead, which is
        // also the way to work without the shortcut at all.
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

    // Colour and width come up with the overlay and go down with it: they change what is in
    // hand, and there is nothing in hand without a canvas.
    func registerWheels(_ actions: WheelActions) {
        guard wheelKeys.isEmpty else {
            return
        }

        // Z X C V, four keys in a row under the left hand: tools, colour, size, and the
        // things you do to a drawing rather than with it.
        let wheels: [(ID, UInt32, () -> Void)] = [
            (.colourWheel, UInt32(kVK_ANSI_X), actions.colours),
            (.widthWheel, UInt32(kVK_ANSI_C), actions.widths),
            (.actionWheel, UInt32(kVK_ANSI_V), actions.actions)
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
