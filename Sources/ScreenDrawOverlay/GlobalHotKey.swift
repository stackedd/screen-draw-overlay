// The three system-wide shortcuts, on Carbon's RegisterEventHotKey.
//
// Carbon because it is the only way to get a global shortcut without asking for
// Accessibility permission, which this app does not want to ask for. That single decision
// is why the app can be installed and used without a single system prompt.
//
// Ownership runs one way: whoever creates a hot key owns it, and the Carbon callback owns
// nothing - it looks instances up in a table of weak references, so an unregistered or
// deallocated hot key simply is not found. It also carries the release half of the
// keypress, which is what lets a shortcut be held rather than toggled.

import AppKit
import Carbon

final class GlobalHotKey {
    // Ownership, on purpose: a GlobalHotKey is owned by whoever created it (AppDelegate
    // keeps both hot keys alive for the lifetime of the app). The Carbon callback must
    // never own it - register() used to pass a retained pointer as userData, which meant
    // deinit could never run and the unregister() in it was dead code. Instead the
    // callback looks the hot key up in `registeredHotKeys`, which holds weak references.
    // An unregistered or deallocated hot key is simply not found, so the callback cannot
    // reach freed memory, and unregistering/re-registering at runtime works.
    private final class WeakHotKey {
        weak var value: GlobalHotKey?

        init(_ value: GlobalHotKey) {
            self.value = value
        }
    }

    private static let signature = OSType(UInt32(ascii: "SDO1"))

    // One handler for every hot key instead of one per hot key. It holds no per-instance
    // state and is installed with a nil userData pointer, so there is nothing in it that
    // can dangle; it is installed once and left in place for the life of the process.
    private static var sharedEventHandler: EventHandlerRef?
    private static var registeredHotKeys: [UInt32: WeakHotKey] = [:]

    private let hotKeyID: EventHotKeyID
    private let keyCode: UInt32
    private let modifiers: UInt32
    private let handler: () -> Void
    private let releaseHandler: (() -> Void)?
    private var hotKeyRef: EventHotKeyRef?

    init(id: UInt32,
         keyCode: UInt32,
         modifiers: UInt32,
         handler: @escaping () -> Void,
         releaseHandler: (() -> Void)? = nil) {
        hotKeyID = EventHotKeyID(signature: GlobalHotKey.signature, id: id)
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.handler = handler
        self.releaseHandler = releaseHandler
    }

    func register() -> Bool {
        guard hotKeyRef == nil else {
            return true
        }

        guard GlobalHotKey.installSharedEventHandlerIfNeeded() else {
            return false
        }

        GlobalHotKey.registeredHotKeys[hotKeyID.id] = WeakHotKey(self)

        let registerStatus = RegisterEventHotKey(keyCode,
                                                 modifiers,
                                                 hotKeyID,
                                                 GetApplicationEventTarget(),
                                                 0,
                                                 &hotKeyRef)

        guard registerStatus == noErr, hotKeyRef != nil else {
            hotKeyRef = nil
            GlobalHotKey.registeredHotKeys.removeValue(forKey: hotKeyID.id)
            return false
        }

        return true
    }

    func unregister() {
        // Order matters: stop Carbon from delivering events first, then drop the entry the
        // callback would look this instance up in.
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }

        if GlobalHotKey.registeredHotKeys[hotKeyID.id]?.value === self {
            GlobalHotKey.registeredHotKeys.removeValue(forKey: hotKeyID.id)
        }
    }

    deinit {
        unregister()
    }

    private static func installSharedEventHandlerIfNeeded() -> Bool {
        guard sharedEventHandler == nil else {
            return true
        }

        // Both halves of the keypress. The release half is what lets a hot key be held
        // rather than toggled - press and hold to draw, let go to put it away.
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]

        let installStatus = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            guard let event else {
                return OSStatus(eventNotHandledErr)
            }

            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event,
                                           EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID),
                                           nil,
                                           MemoryLayout<EventHotKeyID>.size,
                                           nil,
                                           &hotKeyID)

            guard status == noErr,
                  hotKeyID.signature == GlobalHotKey.signature,
                  let hotKey = GlobalHotKey.registeredHotKeys[hotKeyID.id]?.value else {
                return OSStatus(eventNotHandledErr)
            }

            // Copy the closure out of the instance so the async block never touches the
            // hot key object, which may be gone by the time the block runs.
            let isRelease = GetEventKind(event) == UInt32(kEventHotKeyReleased)
            guard let handler = isRelease ? hotKey.releaseHandler : hotKey.handler else {
                return OSStatus(eventNotHandledErr)
            }

            DispatchQueue.main.async {
                handler()
            }

            return noErr
        }, eventTypes.count, &eventTypes, nil, &sharedEventHandler)

        guard installStatus == noErr else {
            sharedEventHandler = nil
            return false
        }

        return true
    }
}

extension UInt32 {
    init(ascii string: String) {
        precondition(string.utf8.count == 4)
        self = string.utf8.reduce(0) { partial, byte in
            (partial << 8) + UInt32(byte)
        }
    }
}
