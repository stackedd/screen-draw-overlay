// The one window this app has, and it is only ever on screen because somebody asked for it.
//
// It exists because a global shortcut can be taken by another application without either side
// being told (docs/DECISIONS.md 32), and because a tenth of a second before a wheel appears is
// right for most hands and wrong for some. Five rows, one recorder and one delay each.
//
// Not an alert and not modal: `runModal` blocks a background app and can sit behind every
// other window (CLAUDE.md, never number 7). This is an ordinary window that can be closed and
// ignored.

import AppKit
import Carbon

final class SettingsWindow: NSObject, NSWindowDelegate, NSTextFieldDelegate {
    private let settings: ShortcutSettings
    // The pen in hand, for the things about ink rather than about keys.
    private let tools: ToolSettings
    // Recording a shortcut means pressing keys this app has registered system-wide, so they
    // have to be taken down while a recorder is armed - otherwise pressing ⌥A to record it
    // opens the tools wheel over the window.
    private let suspendShortcuts: (Bool) -> Void

    private var window: NSWindow?
    private var recorders: [ShortcutSettings.Action: RecorderButton] = [:]
    private var delayFields: [ShortcutSettings.Action: NSTextField] = [:]
    private let comeForward = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let inkLife = NSTextField(string: "")
    private let message = NSTextField(labelWithString: "")

    init(settings: ShortcutSettings, tools: ToolSettings,
         suspendShortcuts: @escaping (Bool) -> Void) {
        self.settings = settings
        self.tools = tools
        self.suspendShortcuts = suspendShortcuts
        super.init()
    }

    func show() {
        if window == nil {
            window = build()
        }

        refresh()
        // An accessory app has to ask for the keyboard: without this the window comes up
        // behind whatever is in front and cannot record anything.
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Building it

    private func build() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0,
                                                  width: SettingsWindow.windowWidth, height: 340),
                              styleMask: [.titled, .closable],
                              backing: .buffered,
                              defer: false)
        window.title = "Scrim Settings"
        window.isReleasedWhenClosed = false
        window.delegate = self

        let heading = NSTextField(labelWithString: "Shortcuts")
        heading.font = .boldSystemFont(ofSize: NSFont.systemFontSize)

        let explanation = NSTextField(wrappingLabelWithString:
            "Click a shortcut and press the keys you want. Every one needs ⌘, ⌥ or ⌃ in it, "
            + "because a bare key would be taken from every other application. The delay is "
            + "how long a wheel waits before it appears; 0 opens it at once.")
        explanation.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        explanation.textColor = .secondaryLabelColor
        // Wrapped to the width the rows have, rather than to the window: left to itself a
        // wrapping label takes the whole width and hangs over the inset on the right.
        explanation.preferredMaxLayoutWidth = SettingsWindow.contentWidth
        explanation.widthAnchor.constraint(equalToConstant: SettingsWindow.contentWidth).isActive = true

        let grid = NSGridView(numberOfColumns: 3, rows: 0)
        grid.columnSpacing = 12
        grid.rowSpacing = 8
        grid.column(at: 0).xPlacement = .trailing

        for action in ShortcutSettings.Action.allCases {
            let name = NSTextField(labelWithString: action.label)
            let recorder = RecorderButton()
            recorder.onRecording = { [weak self] recording in
                guard let self else {
                    return
                }

                // Only one at a time: arming this one puts any other one down, so two rows
                // cannot both be waiting for the same keypress.
                if recording {
                    for (other, button) in self.recorders where other != action {
                        button.cancelRecording()
                    }
                }

                self.suspendShortcuts(recording)
                self.say(recording ? "Press the keys you want for \(action.label)." : "")
            }
            recorder.onCapture = { [weak self] event in
                self?.record(event, for: action)
            }
            recorders[action] = recorder

            let trailing: NSView
            if action.opensAWheel {
                let field = NSTextField(string: "")
                field.alignment = .right
                field.formatter = SettingsWindow.milliseconds
                field.target = self
                field.action = #selector(delayChanged(_:))
                field.delegate = self
                field.tag = ShortcutSettings.Action.allCases.firstIndex(of: action) ?? 0
                field.toolTip = "Milliseconds before the wheel appears. 0 opens it at once."
                delayFields[action] = field

                let unit = NSTextField(labelWithString: "ms")
                unit.textColor = .secondaryLabelColor
                let pair = NSStackView(views: [field, unit])
                pair.orientation = .horizontal
                pair.spacing = 4
                field.widthAnchor.constraint(equalToConstant: 52).isActive = true
                trailing = pair
            } else {
                let held = NSTextField(labelWithString: "held, it repeats")
                held.textColor = .secondaryLabelColor
                held.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
                trailing = held
            }

            grid.addRow(with: [name, recorder, trailing])

            let note = NSTextField(labelWithString: action.explanation)
            note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            note.textColor = .tertiaryLabelColor
            let noteRow = grid.addRow(with: [NSGridCell.emptyContentView, note])
            noteRow.mergeCells(in: NSRange(location: 1, length: 2))
        }

        // The panic key is shown because somebody who has rebound everything else still has
        // to know how to get out, and it is not editable for exactly the same reason.
        let panicName = NSTextField(labelWithString: "Quit")
        let panicKeys = NSTextField(labelWithString: "⌃⌥⌘⎋")
        panicKeys.textColor = .secondaryLabelColor
        let panicNote = NSTextField(labelWithString: "always this, so it always works")
        panicNote.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        panicNote.textColor = .tertiaryLabelColor
        grid.addRow(with: [panicName, panicKeys, panicNote])

        // Ink: the things that are not keys. Small on purpose - what belongs in a window is
        // what you set once, and everything you change while drawing is a wheel.
        let inkHeading = NSTextField(labelWithString: "Ink")
        inkHeading.font = .boldSystemFont(ofSize: NSFont.systemFontSize)

        inkLife.alignment = .right
        inkLife.formatter = SettingsWindow.seconds
        inkLife.target = self
        inkLife.action = #selector(inkLifeChanged)
        inkLife.delegate = self
        inkLife.toolTip = "Seconds before temporary ink fades, once a mark is finished."
        inkLife.widthAnchor.constraint(equalToConstant: 52).isActive = true

        let inkLifeLabel = NSTextField(labelWithString: "Temporary ink lasts")
        let inkLifeUnit = NSTextField(labelWithString: "seconds")
        inkLifeUnit.textColor = .secondaryLabelColor
        let inkLifeRow = NSStackView(views: [inkLifeLabel, inkLife, inkLifeUnit])
        inkLifeRow.orientation = .horizontal
        inkLifeRow.spacing = 8

        comeForward.title = "Come forward while typing"
        comeForward.target = self
        comeForward.action = #selector(comeForwardChanged)

        let comeForwardNote = NSTextField(wrappingLabelWithString:
            "Off, Scrim takes the keyboard without taking the front, so a slideshow keeps "
            + "running. Switch it on only if typing does not reach the caret: it works "
            + "everywhere, but the app in front loses the front while you type.")
        comeForwardNote.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        comeForwardNote.textColor = .tertiaryLabelColor
        comeForwardNote.preferredMaxLayoutWidth = SettingsWindow.contentWidth
        comeForwardNote.widthAnchor
            .constraint(equalToConstant: SettingsWindow.contentWidth).isActive = true

        message.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        message.textColor = .systemRed

        let reset = NSButton(title: "Reset to Defaults", target: self,
                             action: #selector(resetToDefaults))
        reset.bezelStyle = .rounded

        let footer = NSStackView(views: [message, NSView(), reset])
        footer.orientation = .horizontal

        let stack = NSStackView(views: [heading, explanation, grid,
                                        NSBox.separator(width: SettingsWindow.contentWidth),
                                        inkHeading, inkLifeRow, comeForward, comeForwardNote,
                                        footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: SettingsWindow.inset, left: SettingsWindow.inset,
                                        bottom: SettingsWindow.inset, right: SettingsWindow.inset)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            footer.widthAnchor.constraint(equalToConstant: SettingsWindow.contentWidth)
        ])
        window.contentView = content
        return window
    }

    // The window is a fixed size, so the width the rows get is a number rather than a chain of
    // constraints: 460 across, 20 of inset either side.
    private static let windowWidth: CGFloat = 460
    private static let inset: CGFloat = 20
    private static var contentWidth: CGFloat { windowWidth - inset * 2 }

    private static let seconds: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .none
        formatter.minimum = NSNumber(value: ToolSettings.shortestInkLife)
        formatter.maximum = NSNumber(value: ToolSettings.longestInkLife)
        return formatter
    }()

    private static let milliseconds: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .none
        formatter.minimum = 0
        formatter.maximum = NSNumber(value: Int(ShortcutSettings.longestDelay * 1000))
        return formatter
    }()

    // MARK: - Reading and writing

    private func refresh() {
        for action in ShortcutSettings.Action.allCases {
            let binding = settings.binding(for: action)
            recorders[action]?.show(binding.spoken)
            delayFields[action]?.stringValue = "\(Int((binding.delay * 1000).rounded()))"
        }

        comeForward.state = tools.comesForwardToType ? .on : .off
        inkLife.stringValue = "\(Int(tools.temporaryInkSeconds.rounded()))"
    }

    @objc private func inkLifeChanged() {
        disarm()
        tools.setTemporaryInkSeconds(TimeInterval(inkLife.integerValue))
        refresh()
    }

    @objc private func comeForwardChanged() {
        disarm()
        tools.setComesForwardToType(comeForward.state == .on)
    }

    private func record(_ event: NSEvent, for action: ShortcutSettings.Action) {
        let refusal = settings.set(keyCode: UInt32(event.keyCode),
                                   modifiers: ShortcutSettings.carbonModifiers(from: event.modifierFlags),
                                   key: ShortcutSettings.name(for: event),
                                   for: action)

        switch refusal {
        case .none:
            say("")
        case .needsAModifier:
            say("That needs ⌘, ⌥ or ⌃ with it - a bare key would be taken from every app.")
        case .alreadyTaken(let other):
            say("\(other.label) already uses that.")
        case .reservedForThePanicKey:
            say("⌃⌥⌘⎋ is the panic key and cannot be moved.")
        }

        refresh()
    }

    // Typing in a delay field is doing something else, so it puts a waiting recorder down -
    // on the way in rather than on the way out. Ending an edit fires the field's action, and
    // that happens when the focus *leaves* it, which is often because a recorder was just
    // clicked: disarming there would put down the recorder the click had only just armed.
    func controlTextDidBeginEditing(_ notification: Notification) {
        disarm()
    }

    @objc private func delayChanged(_ sender: NSTextField) {
        let actions = ShortcutSettings.Action.allCases
        guard actions.indices.contains(sender.tag) else {
            return
        }

        settings.setDelay(TimeInterval(sender.integerValue) / 1000, for: actions[sender.tag])
        refresh()
    }

    @objc private func resetToDefaults() {
        // Anything else in this window means the recorder is not what you are doing any more.
        // Clicking a button does not move the first responder on macOS, so a recorder left
        // armed goes on swallowing keystrokes behind whatever you clicked: reset the row and
        // the next key you press is taken as a new shortcut for it.
        disarm()
        settings.resetToDefaults()
        say("Back to ⌥A tools, ⌥S size, ⌥D colour, ⌥Z undo, ⌥X actions, ⌥C clear.")
        refresh()
    }

    // Puts every recorder down and takes the keyboard focus off them, which is what makes the
    // hot keys come back (cancelRecording tells the controller to re-register).
    private func disarm() {
        recorders.values.forEach { $0.cancelRecording() }
        window?.makeFirstResponder(nil)
        refresh()
    }

    private func say(_ text: String) {
        message.stringValue = text
    }

    // A window that closes with a recorder still armed would leave the app with no shortcuts
    // at all, which is the worst state this window could produce.
    func windowWillClose(_ notification: Notification) {
        recorders.values.forEach { $0.cancelRecording() }
        suspendShortcuts(false)
    }

    // MARK: - The recorder

    // A button that, once clicked, is listening: the next keypress is the shortcut. The keys
    // are read here rather than through a global monitor, which would need Accessibility - the
    // one permission this app will not ask for (CLAUDE.md, never number 1).
    final class RecorderButton: NSButton {
        private var isRecording = false

        var onCapture: ((NSEvent) -> Void)?
        var onRecording: ((Bool) -> Void)?

        init() {
            super.init(frame: .zero)
            bezelStyle = .rounded
            setButtonType(.momentaryPushIn)
            target = self
            action = #selector(beginRecording)
            widthAnchor.constraint(greaterThanOrEqualToConstant: 90).isActive = true
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not used - this window is built in code")
        }

        func show(_ keys: String) {
            guard !isRecording else {
                return
            }

            title = keys
        }

        @objc private func beginRecording() {
            isRecording = true
            title = "Press keys…"
            onRecording?(true)
            window?.makeFirstResponder(self)
        }

        func cancelRecording() {
            guard isRecording else {
                return
            }

            isRecording = false
            onRecording?(false)
        }

        override var acceptsFirstResponder: Bool {
            true
        }

        override func resignFirstResponder() -> Bool {
            cancelRecording()
            return super.resignFirstResponder()
        }

        override func keyDown(with event: NSEvent) {
            guard isRecording else {
                super.keyDown(with: event)
                return
            }

            // Escape on its own means "never mind", which is what Escape means everywhere.
            if Int(event.keyCode) == kVK_Escape, event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
                cancelRecording()
                return
            }

            isRecording = false
            onRecording?(false)
            onCapture?(event)
        }

        // Anything with ⌘ in it is offered to the window as a key equivalent before it is
        // ever a keyDown, so a recorder that only overrode keyDown could not record ⌘ at all.
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard isRecording else {
                return super.performKeyEquivalent(with: event)
            }

            keyDown(with: event)
            return true
        }
    }
}

// A hairline between the sections, which is what a window with more than one thing in it
// needs and what AppKit gives no shorthand for.
private extension NSBox {
    static func separator(width: CGFloat) -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.widthAnchor.constraint(equalToConstant: width).isActive = true
        return box
    }
}
