// The app itself, and almost nothing else.
//
// What happens on launch: refuse to be a second copy, stay out of the Dock, bring up the
// overlay controller, and hand the global shortcuts something to call. The mode model and
// the panels are in OverlayController; the shortcuts are in Shortcuts. This file is the
// wiring between them and AppKit.

import AppKit
import Foundation

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let controller = OverlayController()
    private let shortcuts = Shortcuts()

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("ScreenDrawOverlay: app launched")

        // Two copies at once is a trap, not a feature: macOS lets both register the same
        // global hot keys, so one press opens two overlays stacked on each other and
        // whichever one the user cannot see is the one still taking their clicks.
        // Launching again - by double clicking, or by a login item on top of a copy that
        // is already up - quietly leaves the running one alone.
        guard !AppDelegate.anotherInstanceIsRunning() else {
            print("ScreenDrawOverlay: another copy is already running, quitting this one")
            NSApp.terminate(nil)
            return
        }

        // Keep the app out of the Dock. The small menu bar item is the whole presence.
        NSApp.setActivationPolicy(.accessory)

        controller.start()

        let unavailable = shortcuts.register(Shortcuts.Actions(
            drawPressed: { [weak self] in self?.controller.drawingHotKeyPressed() },
            drawReleased: { [weak self] in self?.controller.drawingHotKeyReleased() },
            toggleClickThrough: { [weak self] in self?.controller.toggleInteractionMode() },
            quit: { [weak self] in self?.emergencyQuit() },
            undo: { [weak self] in self?.controller.undoOnScreenUnderPointer(redo: false) },
            redo: { [weak self] in self?.controller.undoOnScreenUnderPointer(redo: true) }
        ))

        if !unavailable.isEmpty {
            print("ScreenDrawOverlay: hotkeys unavailable: \(unavailable.joined(separator: ", "))")
            controller.reportUnavailableShortcuts(unavailable)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        print("ScreenDrawOverlay: app terminating")
        controller.shutDown()
        shortcuts.unregister()
    }

    // The panic key. Anything short of ending the process can in principle still leave the
    // user stuck, so this quits outright, the same as Quit in the menu.
    // applicationWillTerminate releases the overlay's mouse events and closes the panels on
    // the way out.
    private func emergencyQuit() {
        print("ScreenDrawOverlay: emergency quit")
        NSApp.terminate(nil)
    }

    private static func anotherInstanceIsRunning() -> Bool {
        // Running unbundled (swift run, or a test harness) means there is no identity to
        // compare, so the check stands down rather than guessing.
        guard let bundleID = Bundle.main.bundleIdentifier else {
            return false
        }

        let ownProcessID = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).contains { app in
            app.processIdentifier != ownProcessID && !app.isTerminated
        }
    }
}
