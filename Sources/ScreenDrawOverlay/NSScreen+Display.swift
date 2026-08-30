// Identifying a screen across time.
//
// NSScreen objects are not stable between calls, so anything that has to remember which
// display something belonged to - which panel shows the badge, which screen a kept drawing
// came from - compares display IDs rather than object identity.

import AppKit

extension NSScreen {
    // NSScreen instances are not guaranteed to be identical across calls, so fall back
    // to the display ID when object identity does not match.
    // Stable per display, so a drawing can be put back on the screen it was drawn on.
    var displayIdentifier: String {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard let displayID = deviceDescription[key] as? CGDirectDisplayID else {
            return "unknown"
        }

        return String(displayID)
    }

    func matches(_ other: NSScreen) -> Bool {
        if self === other {
            return true
        }

        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard let lhs = deviceDescription[key] as? CGDirectDisplayID,
              let rhs = other.deviceDescription[key] as? CGDirectDisplayID else {
            return false
        }

        return lhs == rhs
    }
}
