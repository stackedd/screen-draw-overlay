// The menu bar item: the app's only permanent presence on screen.
//
// It is three things at once, which is why it is worth its own file. A mode light - the
// icon says whether the overlay is taking clicks, only showing, or away. A way out that
// does not depend on a shortcut, which matters because drawing mode covers the whole
// screen. And the place the app admits things: a shortcut it could not register, or macOS
// waiting for the user to approve opening at login.
//
// Two things here are measured rather than chosen. The mode is carried by the symbol and
// never by a colour, because tinting a template image switches off the appearance-driven
// rendering that keeps a menu bar icon visible on a dark bar - a tinted icon measured at
// luminance 0.000, black on black. And the item sizes itself to the icon, because a
// crowded menu bar drops what does not fit.

import AppKit
import Foundation
import ServiceManagement

final class MenuBarItem: NSObject, NSMenuDelegate {
    // What the menu can ask for. The controller knows how to present the modes; it does
    // not know what they mean.
    struct Actions {
        let toggleDrawing: () -> Void
        let toggleClickThrough: () -> Void
        let quit: () -> Void
    }

    private let statusItem: NSStatusItem
    private let actions: Actions
    private var drawingMenuItem: NSMenuItem?
    private var interactionMenuItem: NSMenuItem?
    private var hotKeyWarningItem: NSMenuItem?
    private var loginItem: NSMenuItem?

    init(actions: Actions) {
        // variableLength lets the item size itself to the icon instead of a fixed square.
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.actions = actions
        super.init()
        build()
        update(isDrawing: false, isClickThrough: false, hasKeptStrokes: false)
    }

    // Said out loud in the menu rather than in a dialog: a modal alert from a background
    // app blocks its main thread and can sit behind every other window, so a failure at
    // login would look exactly like a hang.
    func reportUnavailableShortcuts(_ shortcuts: [String]) {
        guard !shortcuts.isEmpty else {
            return
        }

        hotKeyWarningItem?.title = "Shortcut unavailable: " + shortcuts.joined(separator: " ")
        hotKeyWarningItem?.isHidden = false
    }

    @objc private func toggleDrawingModeFromMenu() {
        actions.toggleDrawing()
    }

    @objc private func toggleInteractionModeFromMenu() {
        actions.toggleClickThrough()
    }

    @objc private func quit() {
        actions.quit()
    }

    private func build() {
        let menu = NSMenu()
        // The titles and the enabled state are driven by the current mode, so AppKit must
        // not second-guess them.
        menu.autoenablesItems = false
        // Hidden unless a shortcut could not be registered; this is where the app says so.
        let warningItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        warningItem.isEnabled = false
        warningItem.isHidden = true
        menu.addItem(warningItem)
        hotKeyWarningItem = warningItem

        let toggleItem = NSMenuItem(title: "Start Drawing",
                                    action: #selector(toggleDrawingModeFromMenu),
                                    keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(toggleItem)
        drawingMenuItem = toggleItem

        let interactionItem = NSMenuItem(title: "Click-Through",
                                         action: #selector(toggleInteractionModeFromMenu),
                                         keyEquivalent: "")
        interactionItem.target = self
        menu.addItem(interactionItem)
        interactionMenuItem = interactionItem
        menu.addItem(.separator())

        // Only offered where the system can do it without a helper bundle, and only for a
        // real installed copy - an unbundled build has nothing to register.
        if #available(macOS 13.0, *), Bundle.main.bundleIdentifier != nil {
            let launchItem = NSMenuItem(title: "Open at Login",
                                        action: #selector(toggleLaunchAtLogin),
                                        keyEquivalent: "")
            launchItem.target = self
            menu.addItem(launchItem)
            loginItem = launchItem
            menu.addItem(.separator())
        }

        let quitItem = NSMenuItem(title: "Quit",
                                  action: #selector(quit),
                                  keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        menu.delegate = self
        statusItem.menu = menu
    }

    func update(isDrawing: Bool, isClickThrough: Bool, hasKeptStrokes: Bool) {
        // The menu says the same thing the hot keys do: D returns to drawing or puts the
        // overlay away, E only means anything once there is something on screen.
        // Click-Through is a state, so it reads as a checkable item rather than a second
        // command that would say the same thing as the first one.
        drawingMenuItem?.title = !isDrawing
            ? (!hasKeptStrokes ? "Start Drawing" : "Show Drawing")
            : (isClickThrough ? "Back to Drawing" : "Hide Overlay")
        interactionMenuItem?.state = isClickThrough ? .on : .off
        interactionMenuItem?.isEnabled = isDrawing

        guard let button = statusItem.button else {
            return
        }

        // The menu bar item doubles as the mode light: red while the overlay is taking
        // the mouse, dimmed while it is only showing, plain when there is no overlay.
        // The mode is carried by the symbol, never by a colour. Setting contentTintColor
        // on a template image switches off the appearance-driven rendering that makes a
        // menu bar icon light on a dark menu bar: measured, a tinted icon rendered at
        // luminance 0.000 - black on black - while an untinted one rendered at 0.791.
        let symbolName: String
        let tooltip: String
        if !isDrawing {
            symbolName = "scribble"
            tooltip = "Screen Draw Overlay - Control Option Command D to draw"
        } else if isClickThrough {
            symbolName = "pencil.slash"
            tooltip = "Click-through: drawing is showing, clicks go to the app underneath"
        } else {
            symbolName = "pencil.tip.crop.circle.fill"
            tooltip = "Drawing: the overlay is taking your clicks"
        }

        button.contentTintColor = nil

        if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Screen Draw Overlay") {
            // A template image follows the menu bar's own look in both themes. An icon
            // also takes less width than a letter, which matters on a crowded menu bar
            // where macOS drops the items that do not fit.
            image.isTemplate = true
            button.image = image.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
            ) ?? image
            button.title = ""
        } else {
            // No symbol on this system: fall back to the letter this app shipped with,
            // plainly, so AppKit styles it for the current appearance.
            button.image = nil
            button.title = "D"
        }

        button.toolTip = tooltip
    }

    // The login state can be changed from System Settings behind the app's back, so it is
    // read when the menu opens rather than cached.
    func menuWillOpen(_ menu: NSMenu) {
        refreshLoginItem()
    }

    @objc private func toggleLaunchAtLogin() {
        guard #available(macOS 13.0, *) else {
            return
        }

        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
                print("ScreenDrawOverlay: will no longer open at login")
            } else {
                try SMAppService.mainApp.register()
                print("ScreenDrawOverlay: will open at login")
            }
        } catch {
            // Nothing to shout about: macOS refuses this for copies in odd places, and the
            // app works exactly the same either way.
            print("ScreenDrawOverlay: could not change the login item - \(error.localizedDescription)")
        }

        refreshLoginItem()
    }

    private func refreshLoginItem() {
        guard #available(macOS 13.0, *), let loginItem else {
            return
        }

        switch SMAppService.mainApp.status {
        case .enabled:
            loginItem.title = "Open at Login"
            loginItem.state = .on
        case .requiresApproval:
            // macOS is waiting for the user in System Settings; saying so beats a
            // checkbox that looks broken.
            loginItem.title = "Open at Login (approve in System Settings)"
            loginItem.state = .mixed
        default:
            loginItem.title = "Open at Login"
            loginItem.state = .off
        }
    }
}
