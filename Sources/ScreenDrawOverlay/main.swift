// Entry point, and nothing else.
//
// Top level code has to live in a file called main.swift, so this is only the four lines
// that start the app. Everything it does is in AppDelegate.swift.

import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
