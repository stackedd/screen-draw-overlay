// Which key does what, and how long a wheel waits before it appears.
//
// The five shortcuts used to be written into Shortcuts.swift as key codes. They are settings
// now for one reason: macOS lets two applications register the same combination and tells
// neither of them, so a clash is silent and there is nothing the user can do about it from
// inside the app (docs/DECISIONS.md 32). The panic key is deliberately not here - it is the
// one thing that has to be true whatever else has been changed.
//
// Stored the way ToolSettings stores the pen: UserDefaults, read on launch, written on every
// change, and a default that stands when nothing has been saved.

import AppKit
import Carbon

final class ShortcutSettings {
    enum Action: String, CaseIterable {
        case tools
        case widths
        case colours
        case undo
        case actions
        case clear

        var label: String {
            switch self {
            case .undo: return "Undo"
            case .tools: return "Tools"
            case .colours: return "Colour"
            case .widths: return "Size"
            case .actions: return "Actions"
            case .clear: return "Clear"
            }
        }

        // What the row says under the name, so the window explains itself without a manual.
        var explanation: String {
            switch self {
            case .undo: return "one press, one thing back - held, it repeats"
            case .tools: return "pen, marker, text, shapes, eraser, laser - and the way out"
            case .colours: return "six colours"
            case .widths: return "six sizes, of whatever is in your hand"
            case .actions: return "redo, temporary ink, hide"
            case .clear: return "takes the screen back to empty - undo puts it back"
            }
        }

        // Undo and clear are presses, not gestures, so they have nothing to wait for.
        var opensAWheel: Bool {
            self != .undo && self != .clear
        }

        // Two rows under the left hand: A S D for what you draw with, Z X C for what happens
        // to what you have drawn (docs/DECISIONS.md 36).
        var fallback: Binding {
            switch self {
            case .tools: return Binding(keyCode: UInt32(kVK_ANSI_A), key: "A")
            case .widths: return Binding(keyCode: UInt32(kVK_ANSI_S), key: "S")
            case .colours: return Binding(keyCode: UInt32(kVK_ANSI_D), key: "D")
            case .undo: return Binding(keyCode: UInt32(kVK_ANSI_Z), key: "Z")
            case .actions: return Binding(keyCode: UInt32(kVK_ANSI_X), key: "X")
            case .clear: return Binding(keyCode: UInt32(kVK_ANSI_C), key: "C")
            }
        }
    }

    struct Binding: Equatable {
        let keyCode: UInt32
        // Carbon's modifier mask, which is what RegisterEventHotKey wants.
        var modifiers: UInt32 = UInt32(optionKey)
        // What to print for the key itself. Captured from the event that recorded it
        // (`charactersIgnoringModifiers`) rather than translated back from the key code:
        // the keyboard layout already did that work once and it is the layout in front of
        // the user, not the one this code guessed.
        var key: String
        var delay: TimeInterval = ShortcutSettings.defaultDelay

        // Two bindings clash when the same keys would fire both, whatever the delay.
        func collides(with other: Binding) -> Bool {
            keyCode == other.keyCode && modifiers == other.modifiers
        }

        var spoken: String {
            ShortcutSettings.symbols(for: modifiers) + key
        }
    }

    // A tenth of a second, which is where the wheel's own threshold has been since it was
    // measured (docs/DECISIONS.md 30). Half a second is the most anybody could want to wait
    // and still call it an interface.
    static let defaultDelay: TimeInterval = 0.11
    static let longestDelay: TimeInterval = 0.5

    private enum Key {
        static func code(_ action: Action) -> String { "shortcut.\(action.rawValue).keyCode" }
        static func modifiers(_ action: Action) -> String { "shortcut.\(action.rawValue).modifiers" }
        static func key(_ action: Action) -> String { "shortcut.\(action.rawValue).key" }
        static func delay(_ action: Action) -> String { "shortcut.\(action.rawValue).delay" }
    }

    private let defaults: UserDefaults
    private var bindings: [Action: Binding] = [:]

    // Set by whoever owns the hot keys: a change here means they have to be taken down and
    // put back up, and that is not this type's business.
    var onChange: (() -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        for action in Action.allCases {
            var binding = action.fallback

            if defaults.object(forKey: Key.code(action)) != nil {
                let stored = Binding(keyCode: UInt32(defaults.integer(forKey: Key.code(action))),
                                     modifiers: UInt32(defaults.integer(forKey: Key.modifiers(action))),
                                     key: defaults.string(forKey: Key.key(action)) ?? binding.key,
                                     delay: binding.delay)
                // A stored binding with no modifier at all would take a bare letter from
                // every other application on the machine. Refuse it on the way in as well as
                // on the way out: a defaults file can be edited by hand.
                if stored.modifiers != 0 {
                    binding = stored
                }
            }

            if defaults.object(forKey: Key.delay(action)) != nil {
                binding.delay = ShortcutSettings.clamped(defaults.double(forKey: Key.delay(action)))
            }

            bindings[action] = binding
        }
    }

    func binding(for action: Action) -> Binding {
        bindings[action] ?? action.fallback
    }

    func delay(for action: Action) -> TimeInterval {
        binding(for: action).delay
    }

    // Why a set can fail: a shortcut with no modifier would swallow a bare key everywhere on
    // the machine, and two of ours on the same combination would leave one of them dead. The
    // caller shows the reason; the settings never hold a state the app cannot honour.
    enum Refusal {
        case needsAModifier
        case alreadyTaken(by: Action)
        case reservedForThePanicKey
    }

    @discardableResult
    func set(keyCode: UInt32, modifiers: UInt32, key: String, for action: Action) -> Refusal? {
        guard modifiers & UInt32(cmdKey | optionKey | controlKey) != 0 else {
            return .needsAModifier
        }

        let wanted = Binding(keyCode: keyCode, modifiers: modifiers, key: key,
                             delay: binding(for: action).delay)

        if keyCode == UInt32(kVK_Escape),
           modifiers == UInt32(cmdKey | optionKey | controlKey) {
            return .reservedForThePanicKey
        }

        if let taken = Action.allCases.first(where: { $0 != action && binding(for: $0).collides(with: wanted) }) {
            return .alreadyTaken(by: taken)
        }

        bindings[action] = wanted
        persist(action)
        onChange?()
        return nil
    }

    func setDelay(_ seconds: TimeInterval, for action: Action) {
        guard action.opensAWheel else {
            return
        }

        var binding = self.binding(for: action)
        binding.delay = ShortcutSettings.clamped(seconds)
        bindings[action] = binding
        persist(action)
        // Deliberately no onChange: the delay is read when a wheel opens, so nothing has to
        // be registered again, and re-registering hot keys on every keystroke in a text field
        // would be a lot of work for nothing.
    }

    func resetToDefaults() {
        for action in Action.allCases {
            bindings[action] = action.fallback
            defaults.removeObject(forKey: Key.code(action))
            defaults.removeObject(forKey: Key.modifiers(action))
            defaults.removeObject(forKey: Key.key(action))
            defaults.removeObject(forKey: Key.delay(action))
        }

        onChange?()
    }

    private func persist(_ action: Action) {
        let binding = self.binding(for: action)
        defaults.set(Int(binding.keyCode), forKey: Key.code(action))
        defaults.set(Int(binding.modifiers), forKey: Key.modifiers(action))
        defaults.set(binding.key, forKey: Key.key(action))
        defaults.set(binding.delay, forKey: Key.delay(action))
    }

    private static func clamped(_ seconds: TimeInterval) -> TimeInterval {
        min(max(seconds, 0), longestDelay)
    }

    // MARK: - Reading a keypress

    // Carbon wants its own modifier mask, and it is not AppKit's.
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var mask: UInt32 = 0
        if flags.contains(.command) { mask |= UInt32(cmdKey) }
        if flags.contains(.option) { mask |= UInt32(optionKey) }
        if flags.contains(.control) { mask |= UInt32(controlKey) }
        if flags.contains(.shift) { mask |= UInt32(shiftKey) }
        return mask
    }

    // In the order the menu bar writes them, because that is the order people read.
    static func symbols(for modifiers: UInt32) -> String {
        var symbols = ""
        if modifiers & UInt32(controlKey) != 0 { symbols += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { symbols += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { symbols += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { symbols += "⌘" }
        return symbols
    }

    // What to show for the key itself. Named keys get their sign; everything else is the
    // character the layout produced, upper-cased, which is what a menu would print.
    static func name(for event: NSEvent) -> String {
        switch Int(event.keyCode) {
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Delete: return "⌫"
        case kVK_ForwardDelete: return "⌦"
        case kVK_Escape: return "⎋"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_Home: return "↖"
        case kVK_End: return "↘"
        case kVK_PageUp: return "⇞"
        case kVK_PageDown: return "⇟"
        default: break
        }

        let characters = event.charactersIgnoringModifiers ?? ""
        return characters.isEmpty ? "key \(event.keyCode)" : characters.uppercased()
    }
}
