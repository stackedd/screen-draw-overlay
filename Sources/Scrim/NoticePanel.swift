// A card that appears under the menu bar, says one thing, and goes away.
//
// It exists for the case where the app has nothing else to say it with: macOS hides a status
// item that will not fit in the menu bar, and an app whose entire interface is a menu bar icon
// and a global shortcut then looks exactly like an app that failed to launch. The same card
// carries the other silent failure - a shortcut macOS refused - which until now was written
// into a menu nobody could open (docs/DECISIONS.md 33).
//
// It cannot take a click and it goes on its own, because it appears without being asked for
// and the user is in the middle of something else. No notification, no dialog, no permission:
// this app has a window server connection and that is all this needs.

import AppKit

final class NoticePanel {
    // Long enough to read twice, short enough that nobody has to go and close it.
    private static let onScreenFor: TimeInterval = 7
    private static let width: CGFloat = 420
    private static let padding: CGFloat = 16
    private static let corner: CGFloat = 12

    private let panel: NSPanel
    private let view = NSView()
    private var goAway: Timer?

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: NoticePanel.width, height: 80),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered,
                        defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // Above the overlay, because it can appear while one is up, and above the menu bar,
        // because what it is usually reporting is that the menu bar has no room for us.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 2)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        // Never takes a click: it is uninvited, and an uninvited window that eats a click is
        // the thing this whole app is careful not to be.
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        view.wantsLayer = true
        panel.contentView = view
    }

    // Shows one message, replacing whatever was up. Two lines: what happened, and what to do
    // about it - the second is the one that matters, because somebody reading this cannot
    // reach the menu.
    func show(_ headline: String, _ detail: String) {
        goAway?.invalidate()

        let screen = NSScreen.main ?? NSScreen.screens.first
        let scale = screen?.backingScaleFactor ?? 2
        guard let card = NoticePanel.card(headline: headline, detail: detail, scale: scale) else {
            return
        }

        let size = NSSize(width: CGFloat(card.width) / scale, height: CGFloat(card.height) / scale)
        view.layer?.contents = card
        view.layer?.contentsScale = scale

        if let bounds = screen?.visibleFrame {
            panel.setFrame(NSRect(x: bounds.midX - size.width / 2,
                                  y: bounds.maxY - size.height - 12,
                                  width: size.width, height: size.height),
                           display: false)
        }

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            panel.animator().alphaValue = 1
        }

        let timer = Timer(timeInterval: NoticePanel.onScreenFor, repeats: false) { [weak self] _ in
            self?.close()
        }
        RunLoop.main.add(timer, forMode: .common)
        goAway = timer
    }

    func close() {
        goAway?.invalidate()
        goAway = nil

        guard panel.isVisible else {
            return
        }

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.panel.orderOut(nil)
        })
    }

    // MARK: - The picture

    // Through Picture.drawn like everything else this app puts on a layer: it is the one place
    // that gets the size and the scale in the right order (CLAUDE.md, never number 12).
    private static func card(headline: String, detail: String, scale: CGFloat) -> CGImage? {
        let headlineText = NSAttributedString(string: headline, attributes: [
            .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
            .foregroundColor: NSColor.white
        ])
        let detailText = NSAttributedString(string: detail, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.white.withAlphaComponent(0.8)
        ])

        let textWidth = width - padding * 2
        let headlineHeight = ceil(headlineText.boundingRect(with: NSSize(width: textWidth, height: 200),
                                                            options: [.usesLineFragmentOrigin]).height)
        let detailHeight = ceil(detailText.boundingRect(with: NSSize(width: textWidth, height: 200),
                                                        options: [.usesLineFragmentOrigin]).height)
        let height = padding * 2 + headlineHeight + 4 + detailHeight

        return Picture.drawn(size: NSSize(width: width, height: height), scale: scale) {
            let plate = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: width, height: height),
                                     xRadius: corner, yRadius: corner)
            NSColor.black.withAlphaComponent(0.86).setFill()
            plate.fill()
            NSColor.white.withAlphaComponent(0.18).setStroke()
            plate.lineWidth = 1
            plate.stroke()

            // Drawn from the bottom up: the context is not flipped, so the detail sits under
            // the headline by being drawn first.
            detailText.draw(with: NSRect(x: padding, y: padding, width: textWidth, height: detailHeight),
                            options: [.usesLineFragmentOrigin])
            headlineText.draw(with: NSRect(x: padding, y: padding + detailHeight + 4,
                                           width: textWidth, height: headlineHeight),
                              options: [.usesLineFragmentOrigin])
        }
    }
}
