// The global shortcuts, as one set.
//
// Global rather than local because a non-activating panel only receives ordinary keystrokes
// while this app is the active one, and after the user has clicked anything in another app it
// is not. **Everything this app can be told to do is here**: undo, four wheels on the Option
// row, and the panic key. There is no second, quieter set of keys that works only while this app
// happens to have the keyboard - there was, and a shortcut that sometimes works is worse than
// no shortcut (docs/DECISIONS.md 30).
//
// Carbon rather than an event monitor because Carbon needs no Accessibility permission, which
// is the decision the whole app hangs off (docs/DECISIONS.md 1).

import AppKit
import Carbon

final class Shortcuts {
    // The ones that are always live. Opening the overlay is among them, because the tools
    // wheel is the only thing that opens one.
    struct Actions {
        let toolWheel: () -> Void
        let wheelReleased: () -> Void
        let quit: () -> Void
    }

    // The rest only mean something once there is a canvas, so they come and go with the
    // overlay: three more wheels, and undo. Every one of them needs both halves of the
    // keypress - the wheels because they are held, and undo because holding it repeats.
    struct WheelActions {
        let colours: () -> Void
        let widths: () -> Void
        let actions: () -> Void
        let released: () -> Void
        let undo: () -> Void
        let undoReleased: () -> Void
    }

    // Carbon identifies a hot key by a number. Named rather than written out at the call
    // site, because one of these is load-bearing elsewhere: the behaviour suite fires the
    // quit key by id, so its number is part of the contract.
    private enum ID: UInt32 {
        case quit = 2
        case toolWheel = 6
        case colourWheel = 7
        case widthWheel = 8
        case actionWheel = 9
        case undo = 10
    }

    // Held only to keep them registered; nothing here needs to reach one by name.
    private var hotKeys: [GlobalHotKey] = []
    private var wheelKeys: [GlobalHotKey] = []

    // Where the keys come from. Everything except the panic key is a setting, because a
    // clash with another application is silent and otherwise unanswerable (DECISIONS 32).
    private let settings: ShortcutSettings

    init(settings: ShortcutSettings) {
        self.settings = settings
    }

    // Whether the overlay's own keys are up, so whoever re-registers after a change knows
    // whether to put them back.
    var wheelsAreRegistered: Bool {
        !wheelKeys.isEmpty
    }

    // Registers the lot and returns the ones macOS refused, written the way a menu would
    // show them. A refusal is rare and quiet - two different processes can register the same
    // combination and both succeed - so this only ever catches the case macOS turns down
    // outright.
    @discardableResult
    func register(_ actions: Actions) -> [String] {
        let tools = settings.binding(for: .tools)
        let shortcuts: [(key: GlobalHotKey, spoken: String, symbols: String)] = [
            // The way in and the way around. Registered for the life of the app rather than
            // with the overlay, because it is the only thing that opens one - which costs
            // this combination system-wide, and is why it can be changed.
            (GlobalHotKey(id: ID.toolWheel.rawValue,
                          keyCode: tools.keyCode,
                          modifiers: tools.modifiers,
                          handler: actions.toolWheel,
                          releaseHandler: actions.wheelReleased),
             tools.spoken, tools.spoken),

            // Not a setting, on purpose: the panic key is the one thing that has to be true
            // whatever else has been changed, including by somebody who has changed
            // everything else (CLAUDE.md, never number 4).
            (GlobalHotKey(id: ID.quit.rawValue,
                          keyCode: UInt32(kVK_Escape),
                          modifiers: UInt32(cmdKey | optionKey | controlKey),
                          handler: actions.quit),
             "Control + Option + Command + Escape", "\u{2303}\u{2325}\u{2318}\u{238B}")
        ]

        // A modal alert is the wrong tool for a background app: runModal blocks the main
        // thread, and an accessory app's dialog can sit behind everything, so a failure at
        // login would look like a hang. Failures go to the menu bar item instead, which is
        // also the way to work without the shortcut at all.
        var unavailable: [String] = []
        for shortcut in shortcuts {
            hotKeys.append(shortcut.key)
            if shortcut.key.register() {
                print("Scrim: hotkey registered - \(shortcut.spoken)")
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

    // These come up with the overlay and go down with it: they change or take back what is
    // on it, and there is nothing to change without a canvas. The ones macOS refused are
    // collected the same way the always-live ones are.
    private(set) var refused: [String] = []

    func registerWheels(_ actions: WheelActions) {
        guard wheelKeys.isEmpty else {
            return
        }

        refused = []

        // Z X C V B out of the box, five keys in a row under the left hand: undo, tools,
        // colour, size, and the things you do to a drawing rather than with it. Undo sits on
        // Z because that is where every other application on this machine puts it
        // (docs/DECISIONS.md 31). Any of them can be moved (32).
        let wheels: [(ID, ShortcutSettings.Action, () -> Void)] = [
            (.colourWheel, .colours, actions.colours),
            (.widthWheel, .widths, actions.widths),
            (.actionWheel, .actions, actions.actions)
        ]

        for (id, setting, opened) in wheels {
            let binding = settings.binding(for: setting)
            let key = GlobalHotKey(id: id.rawValue,
                                   keyCode: binding.keyCode,
                                   modifiers: binding.modifiers,
                                   handler: opened,
                                   releaseHandler: actions.released)
            wheelKeys.append(key)
            if !key.register() {
                print("Scrim: \(setting.label) shortcut unavailable")
                refused.append(binding.spoken)
            }
        }

        // Undo is not a wheel and has a release half of its own: letting go stops the repeat
        // that holding it starts.
        let undo = settings.binding(for: .undo)
        let undoKey = GlobalHotKey(id: ID.undo.rawValue,
                                   keyCode: undo.keyCode,
                                   modifiers: undo.modifiers,
                                   handler: actions.undo,
                                   releaseHandler: actions.undoReleased)
        wheelKeys.append(undoKey)
        if !undoKey.register() {
            print("Scrim: undo shortcut unavailable")
            refused.append(undo.spoken)
        }
    }

    func unregisterWheels() {
        wheelKeys.forEach { $0.unregister() }
        wheelKeys.removeAll()
    }
}
