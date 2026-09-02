        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.regress() }
    }

    func fireHotKey(id: UInt32, release: Bool = false) {
        var event: EventRef?
        let kind = release ? UInt32(kEventHotKeyReleased) : UInt32(kEventHotKeyPressed)
        guard CreateEvent(nil, OSType(kEventClassKeyboard), kind, GetCurrentEventTime(),
                          UInt32(kEventAttributeNone), &event) == noErr, let event else { return }
        var hotKeyID = EventHotKeyID(signature: OSType(UInt32(ascii: "SDO1")), id: id)
        SetEventParameter(event, EventParamName(kEventParamDirectObject),
                          EventParamType(typeEventHotKeyID), MemoryLayout<EventHotKeyID>.size, &hotKeyID)
        SendEventToEventTarget(event, GetApplicationEventTarget())
        ReleaseEvent(event)
    }

    func press(_ code: Int, _ chars: String, _ flags: NSEvent.ModifierFlags = []) {
        guard let panel = controller.overlayWindowSnapshot().first else { return }
        NSApp.sendEvent(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                         windowNumber: panel.windowNumber, context: nil, characters: chars,
                                         charactersIgnoringModifiers: chars, isARepeat: false, keyCode: UInt16(code))!)
    }

    // Everything a user can ask for is on a wheel now, so the checks ask for it the same way.
    // Sector 0 is due right and the order runs clockwise: redo, clear, temp ink, hide.
    func pushAction(_ index: Int?) {
        controller.openActionWheel()
        guard let index else {
            controller.wheels.track(controller.wheels.centre)
            controller.wheels.release()
            return
        }

        let sweep = CGFloat.pi * 2 / CGFloat(OverlayController.actionOrder.count)
        let angle = -CGFloat(index) * sweep
        controller.wheels.track(NSPoint(x: controller.wheels.centre.x + cos(angle) * 120,
                                        y: controller.wheels.centre.y + sin(angle) * 120))
        controller.wheels.release()
    }

    func undoOnce() { pushAction(nil) }
    func redoOnce() { pushAction(0) }
    func clearAll() { pushAction(1) }
    func toggleTemporaryInk() { pushAction(2) }

    func stroke(finish: Bool = true, y: CGFloat = 300) {
        guard let panel = controller.overlayWindowSnapshot().first else { return }
        let v = panel.drawingView
        func ev(_ t: NSEvent.EventType, _ x: CGFloat) -> NSEvent {
            NSEvent.mouseEvent(with: t, location: NSPoint(x: x, y: y), modifierFlags: [], timestamp: 0,
                               windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        v.mouseDown(with: ev(.leftMouseDown, 200))
        for i in 1...6 { v.mouseDragged(with: ev(.leftMouseDragged, 200 + CGFloat(i) * 30)) }
        if finish { v.mouseUp(with: ev(.leftMouseUp, 380)) }
    }

    func rub(x: CGFloat, y: CGFloat) {
        guard let panel = controller.overlayWindowSnapshot().first else { return }
        let v = panel.drawingView
        func ev(_ t: NSEvent.EventType, _ x: CGFloat) -> NSEvent {
            NSEvent.mouseEvent(with: t, location: NSPoint(x: x, y: y), modifierFlags: [], timestamp: 0,
                               windowNumber: panel.windowNumber, context: nil, eventNumber: 0,
                               clickCount: 1, pressure: 1)!
        }
        v.mouseDown(with: ev(.leftMouseDown, x))
        v.mouseDragged(with: ev(.leftMouseDragged, x + 4))
        v.mouseUp(with: ev(.leftMouseUp, x + 4))
    }

    // One mouse event that jumps a long way, which is what a quick hand actually produces.
    func rubAcross(from: NSPoint, to: NSPoint) {
        guard let panel = controller.overlayWindowSnapshot().first else { return }
        let v = panel.drawingView
        func ev(_ t: NSEvent.EventType, _ p: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: t, location: p, modifierFlags: [], timestamp: 0,
                               windowNumber: panel.windowNumber, context: nil, eventNumber: 0,
                               clickCount: 1, pressure: 1)!
        }
        v.mouseDown(with: ev(.leftMouseDown, from))
        v.mouseDragged(with: ev(.leftMouseDragged, to))
        v.mouseUp(with: ev(.leftMouseUp, to))
    }

    func drag(_ tool: DrawingTool, from: NSPoint, to: NSPoint) {
        controller.tools.select(tool: tool)
        guard let panel = controller.overlayWindowSnapshot().first else { return }
        let v = panel.drawingView
        func ev(_ t: NSEvent.EventType, _ p: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: t, location: p, modifierFlags: [], timestamp: 0,
                               windowNumber: panel.windowNumber, context: nil, eventNumber: 0,
                               clickCount: 1, pressure: 1)!
        }
        v.mouseDown(with: ev(.leftMouseDown, from))
        v.mouseDragged(with: ev(.leftMouseDragged, to))
        v.mouseUp(with: ev(.leftMouseUp, to))
    }

    var live: Int { controller.drawingViewSnapshot(from: controller.overlayWindowSnapshot()).first?.capturedStrokes().count ?? -1 }
    var state: String { !controller.isDrawingMode ? "OFF" : (controller.isInteractionMode ? "CLICK-THROUGH" : "DRAWING") }

    func regress() {
        var pass = 0, fail = 0
        func check(_ name: String, _ got: String, _ want: String) {
            if got == want { pass += 1; print("REG ok    \(name): \(got)") }
            else { fail += 1; print("REG FAIL  \(name): got \(got), want \(want)") }
        }

        check("off + E", { controller.toggleInteractionMode(); return self.state }(), "OFF")
        check("off + D", { controller.toggleDrawingMode(); return self.state }(), "DRAWING")
        stroke(); stroke()
        check("two strokes", "\(live)", "2")
        check("drawing + E", { controller.toggleInteractionMode(); return self.state }(), "CLICK-THROUGH")
        check("strokes survive E", "\(live)", "2")
        check("click-through + D", { controller.toggleDrawingMode(); return self.state }(), "DRAWING")
        check("strokes survive D from click-through", "\(live)", "2")

        controller.tools.selectColor(2); controller.tools.select(tool: .arrow)
        stroke(y: 400)
        let signature = controller.drawingViewSnapshot(from: controller.overlayWindowSnapshot()).first!.capturedStrokes()
            .map { "\($0.style.label)/\(Int($0.width))/\($0.points.count)" }.joined(separator: ",")
        check("arrow tool produced a two-point stroke", signature.hasSuffix("/2") ? "yes" : "no: \(signature)", "yes")
        controller.toggleDrawingMode()
        check("hidden", state, "OFF")
        controller.toggleDrawingMode()
        let restored = controller.drawingViewSnapshot(from: controller.overlayWindowSnapshot()).first!.capturedStrokes()
            .map { "\($0.style.label)/\(Int($0.width))/\($0.points.count)" }.joined(separator: ",")
        check("hide+show keeps strokes exactly", restored, signature)

        stroke(finish: false, y: 500)
        controller.toggleInteractionMode()
        check("unfinished stroke committed on mode switch", "\(live)", "4")
        controller.toggleInteractionMode()

        // The keyboard belongs to nobody now. There used to be a layer of bare keys - E for
        // the eraser, Space for the laser, C to clear, Command+Z to undo - and they worked
        // only while this panel happened to be the key window, which is a state the user
        // cannot see. Everything moved to the Option row, where it works whatever has focus,
        // and what is left here is a check that the old keys do nothing at all.
        controller.tools.select(tool: .pen)
        let beforeKeys = live
        let beforeColour = controller.tools.colorIndex
        for (code, characters) in [(kVK_ANSI_E, "e"), (kVK_Space, " "), (kVK_ANSI_T, "t"),
                                   (kVK_ANSI_C, "c"), (kVK_ANSI_3, "3")] {
            press(code, characters)
        }
        press(kVK_ANSI_Z, "z", .command)
        check("the bare keys are gone: nothing moved",
              controller.tools.tool.label + "/\(controller.tools.colorIndex)/\(live)",
              "PEN/\(beforeColour)/\(beforeKeys)")
        press(kVK_ANSI_Q, "q", .command)
        check("Cmd+Q swallowed", "\(NSApp.isRunning)", "true")

        let beforeClear = live
        clearAll()
        check("the wheel's CLEAR clears", "\(live)", "0")
        undoOnce()
        check("undo restores the clear", "\(live)", "\(beforeClear)")
        redoOnce()
        check("redo clears again", "\(live)", "0")

        // Hiding the overlay used to throw the history away with the panels, so the drawing
        // came back and could no longer be taken back.
        stroke(y: 540)
        stroke(y: 560)
        controller.toggleDrawingMode()
        controller.toggleDrawingMode()
        undoOnce()
        check("undo still works after hide and show", "\(live)", "1")

        // A temporary stroke that fades leaves nothing behind - including its entry in the
        // history. It used to stay, and the next undo applied it to whatever happened to be
        // last, which took back a line the user had just drawn and offered a faded one back
        // in its place.
        clearAll()
        stroke(y: 560)
        stroke(y: 580)
        controller.tools.toggleTemporaryInk()
        stroke(y: 600)
        controller.tools.toggleTemporaryInk()
        if let view = controller.drawingViewSnapshot(from: controller.overlayWindowSnapshot()).first {
            let expired = Date().addingTimeInterval(-Stroke.fadeDuration - 1)
            view.canvas.strokes = view.canvas.strokes.map { stroke in
                guard stroke.createdAt != nil else { return stroke }
                return Stroke(id: stroke.id, points: stroke.points, path: stroke.path,
                              color: stroke.color, width: stroke.width, style: stroke.style,
                              createdAt: expired)
            }
            view.advanceFade()
        }
        undoOnce()
        redoOnce()
        check("undo steps over temporary ink that has faded", "\(live)", "2")

        // The wheel's whole promise is that a direction picks a tool without aiming, so the
        // two that need no thought have to be the two that need no thought: a flick right
        // is the pen, a flick left is the eraser. And letting go in the middle has to pick
        // nothing, because that is the only way to change your mind.
        let wheel = OverlayController.toolWheel
        func toolPushing(_ x: CGFloat, _ y: CGFloat) -> String {
            guard let sector = wheel.selection(for: NSPoint(x: x, y: y)) else { return "none" }
            return OverlayController.toolOrder[sector].label
        }
        check("wheel: right is the pen, left is the eraser",
              toolPushing(120, 0) + "/" + toolPushing(-120, 0), "PEN/ERASER")
        check("wheel: the dead zone picks nothing", toolPushing(6, -4), "none")

        // The strongest thing that can be said about the eraser without looking at it: rub
        // a dense canvas about a bit, take every drag back, and exactly as much ink has to
        // come back as went away. It catches bookkeeping the counts cannot - a piece
        // recorded twice, an original not recorded, a tail quietly dropped.
        clearAll()
        controller.tools.select(tool: .pen)
        for row in 0..<6 {
            stroke(y: 300 + CGFloat(row) * 24)
        }
        func inkOnScreen() -> CGFloat {
            let views = controller.drawingViewSnapshot(from: controller.overlayWindowSnapshot())
            guard let canvas = views.first?.canvas else { return 0 }
            return canvas.strokes.reduce(0) { $0 + Stroke.totalLength(of: $1.outline()) }
        }
        let inkBefore = inkOnScreen()
        controller.tools.select(tool: .eraser)
        let rubs = [(NSPoint(x: 240, y: 260), NSPoint(x: 300, y: 460)),
                    (NSPoint(x: 360, y: 460), NSPoint(x: 300, y: 260)),
                    (NSPoint(x: 200, y: 380), NSPoint(x: 400, y: 372))]
        for rub in rubs {
            rubAcross(from: rub.0, to: rub.1)
        }
        check("rubbing a full canvas takes ink away", inkOnScreen() < inkBefore ? "yes" : "no", "yes")
        for _ in rubs {
            undoOnce()
        }
        let back = inkOnScreen()
        check("and taking every drag back puts all of it back",
              abs(back - inkBefore) < 0.5 ? "yes" : "no: \(Int(back)) of \(Int(inkBefore))", "yes")
        clearAll()
        controller.tools.select(tool: .pen)

        // Shapes are erased like everything else. Their `points` are only the two corners
        // the drag was defined by, so measuring to those measured to a rectangle's diagonal
        // rather than its outline: the eraser did nothing over most of a shape and took the
        // whole thing where it did reach. Flattened, a shape cuts like a line, and what is
        // left is no longer a shape - which is right, a piece was rubbed out of it.
        clearAll()
        drag(.rectangle, from: NSPoint(x: 240, y: 620), to: NSPoint(x: 460, y: 760))
        check("a rectangle is one stroke", "\(live)", "1")
        controller.tools.select(tool: .eraser)
        rubAcross(from: NSPoint(x: 200, y: 690), to: NSPoint(x: 280, y: 690))
        check("erasing a rectangle's edge leaves the rest of it", live > 0 ? "yes" : "gone", "yes")
        clearAll()
        controller.tools.select(tool: .pen)

        // The laser is a light on the overlay, not a decoration on the cursor - a cursor is
        // only ours while we own the window under the pointer, and being there is the one
        // thing a laser has to do. It also has no business sitting on top of an app the
        // user has just been handed back.
        controller.tools.toggleLaser()
        let laserLit = controller.drawingViewSnapshot(from: controller.overlayWindowSnapshot())
            .first.map { !$0.laserLayer.isHidden } ?? false
        check("space lights the laser on the overlay", laserLit ? "yes" : "no", "yes")

        // And it lights up under the hand, not wherever it was last left. It showed the
        // layer before placing it once, and moving a hidden layer does nothing.
        let underHand = controller.drawingViewSnapshot(from: controller.overlayWindowSnapshot())
            .first.map { view -> Bool in
                guard let window = view.window else { return false }
                let pointer = view.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
                return hypot(view.laserLayer.position.x - pointer.x,
                             view.laserLayer.position.y - pointer.y) < 1
            } ?? false
        check("the laser lights up under the pointer", underHand ? "yes" : "no", "yes")
        controller.toggleInteractionMode()
        let laserInClickThrough = controller.drawingViewSnapshot(from: controller.overlayWindowSnapshot())
            .first.map { !$0.laserLayer.isHidden } ?? true
        check("click-through puts the laser out", laserInClickThrough ? "still lit" : "out", "out")

        // Back to drawing, and then the two ways the light used to go missing. The pointer
        // leaving the panel put it out - mouseExited hid the layer and nothing except a tool
        // change ever showed it again, so a menu opening over the overlay took the laser away
        // for the rest of the session. And a drag moved the ink without moving the glow,
        // because only the poll placed it, so the light ran a frame or more behind the beam
        // it was supposed to be drawing.
        controller.toggleInteractionMode()
        if let view = controller.drawingViewSnapshot(from: controller.overlayWindowSnapshot()).first,
           let panel = controller.overlayWindowSnapshot().first {
            let exit = NSEvent.enterExitEvent(with: .mouseExited, location: .zero, modifierFlags: [],
                                              timestamp: 0, windowNumber: panel.windowNumber,
                                              context: nil, eventNumber: 0, trackingNumber: 0,
                                              userData: nil)!
            view.mouseExited(with: exit)
            view.followPointer(to: NSPoint(x: 300, y: 300))
            check("the laser comes back when the pointer does",
                  view.laserLayer.isHidden ? "still out" : "lit", "lit")

            let target = NSPoint(x: 420, y: 260)
            view.mouseDragged(with: NSEvent.mouseEvent(with: .leftMouseDragged, location: target,
                                                       modifierFlags: [], timestamp: 0,
                                                       windowNumber: panel.windowNumber, context: nil,
                                                       eventNumber: 0, clickCount: 1, pressure: 1)!)
            check("and it is where the event says the pointer is, not where the poll left it",
                  "\(view.laserLayer.position)", "\(target)")
            view.finishStrokeInProgress()
        }
        controller.toggleInteractionMode()

        // Every picture this app hands to a layer has to cover the frame it was drawn for.
        // An NSBitmapImageRep measures itself in pixels until it is told otherwise and the
        // graphics context takes that measurement when it is made, so setting the size
        // afterwards left the badge, the glow and every piece of fading ink painted at 1x
        // into the bottom left quarter of a Retina bitmap. On screen: a half-size badge, a
        // glow thirteen points down and left of the pointer, and ink that jumped the moment
        // the mouse came up. None of it was visible to a test that counted strokes.
        func alpha(_ image: CGImage) -> [Double] {
            let (w, h) = (image.width, image.height)
            var pixels = [UInt8](repeating: 0, count: w * h * 4)
            guard let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return [] }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return stride(from: 3, to: pixels.count, by: 4).map { Double(pixels[$0]) / 255 }
        }

        for scale in [1.0, 2.0, 3.0] as [CGFloat] {
            let filled = Picture.drawn(size: NSSize(width: 20, height: 20), scale: scale) {
                NSColor.white.setFill()
                NSRect(x: 0, y: 0, width: 20, height: 20).fill()
            }
            let covered = filled.map { alpha($0).filter { $0 > 0.5 }.count } ?? -1
            check("a picture covers the frame it was drawn for at \(Int(scale))x",
                  "\(covered)", "\(Int(20 * scale) * Int(20 * scale))")
        }

        // And the glow has to sit on the pointer, not down and to the left of it: the fault
        // above moved it by a quarter of its own width, which is where "the laser does not
        // point at what I am pointing at" came from.
        if let glow = LaserDot.glow(controller.tools.color, width: 6, scale: 2) {
            let values = alpha(glow)
            let side = glow.width
            var weight = 0.0, x = 0.0, y = 0.0
            for (index, value) in values.enumerated() {
                weight += value
                x += value * Double(index % side)
                y += value * Double(index / side)
            }
            let offset = weight > 0 ? hypot(x / weight - Double(side - 1) / 2,
                                            y / weight - Double(side - 1) / 2) : 999
            check("the glow is centred on the pointer", offset < 1 ? "yes" : "no: \(offset) px", "yes")
        }

        // Holding the button with the laser in hand draws a beam that goes away by itself.
        // It used to be a trail of little dots dropped as the pointer passed, pressed or
        // not, which looked like beads and was drawing something nobody had asked for.
        // Back to drawing, with the laser still in hand - Space is a toggle, and pressing
        // it again here would quietly put the pen back and test the pen.
        controller.toggleInteractionMode()
        let permanentBefore = live
        stroke(y: 640)
        if let view = controller.drawingViewSnapshot(from: controller.overlayWindowSnapshot()).first {
            let beams = view.canvas.strokes.filter { $0.createdAt != nil }
            check("the laser draws a beam while the button is down",
                  beams.count == 1 ? "yes" : "no: \(beams.count)", "yes")
            check("and the beam is gone in well under a second",
                  (beams.first?.life ?? 99) < 1 ? "yes" : "no", "yes")
        }
        // Temporary ink is timed from when it is finished, not from when it was begun. A
        // stroke that took longer to draw than it lives had already expired when the mouse
        // came up, so it vanished instead of fading - which the laser, at half a second, did
        // every single time somebody held the button down.
        let stale = Stroke(points: [.zero], path: NSBezierPath(), color: .systemRed, width: 2,
                           style: .pen, createdAt: Date(timeIntervalSinceNow: -10), life: 3)
        check("temporary ink is timed from when it is finished",
              stale.startingNow().hasFaded ? "already gone" : "still fading", "still fading")

        // And the beam is cut into pieces as it is drawn, because one stroke has one age: it
        // holds at full strength until the button comes up and then goes all at once, instead
        // of thinning out behind the hand the way a laser trail does.
        if let panel = controller.overlayWindowSnapshot().first {
            let view = panel.drawingView
            func beam(_ type: NSEvent.EventType, _ x: CGFloat) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: 700), modifierFlags: [],
                                   timestamp: 0, windowNumber: panel.windowNumber, context: nil,
                                   eventNumber: 0, clickCount: 1, pressure: 1)!
            }
            view.mouseDown(with: beam(.leftMouseDown, 200))
            for step in 1...3 {
                RunLoop.current.run(until: Date().addingTimeInterval(Stroke.beamPiece + 0.02))
                view.mouseDragged(with: beam(.leftMouseDragged, 200 + CGFloat(step) * 40))
            }
            let trail = view.canvas.strokes.filter { $0.createdAt != nil }.count
            view.mouseUp(with: beam(.leftMouseUp, 320))
            check("and it is cut into pieces as it is drawn, so it fades behind the hand",
                  trail > 1 ? "yes" : "no: \(trail)", "yes")

            // Left to expire rather than cleared, so the checks after this one see the canvas
            // they expect: a beam is temporary ink and takes its undo entry with it.
            RunLoop.current.run(until: Date().addingTimeInterval(Stroke.fadeDuration * 0.25))
            view.advanceFade()
        }

        check("and it leaves no permanent ink", "\(live)", "\(permanentBefore)")
        controller.tools.toggleLaser()

        // The laser draws light, not a pen line that happens to disappear - which is what
        // "it has no design of its own" meant. A beam is three passes: a halo that reaches
        // past the line, the colour, and a white core down the middle.
        func sample(_ image: CGImage, _ x: Int, _ y: Int) -> (Double, Double, Double, Double) {
            let (w, h) = (image.width, image.height)
            var pixels = [UInt8](repeating: 0, count: w * h * 4)
            guard let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                return (0, 0, 0, 0)
            }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            // The image counts rows from the top and the drawing counted them from the bottom.
            let index = ((h - 1 - y) * w + x) * 4
            return (Double(pixels[index]) / 255, Double(pixels[index + 1]) / 255,
                    Double(pixels[index + 2]) / 255, Double(pixels[index + 3]) / 255)
        }

        let beamLine = NSBezierPath()
        beamLine.move(to: NSPoint(x: 10, y: 30))
        beamLine.line(to: NSPoint(x: 70, y: 30))
        if let picture = Picture.drawn(size: NSSize(width: 80, height: 60), scale: 1, {
            StrokeStyle.paintBeam(beamLine, width: 8, colour: .systemRed)
        }) {
            let core = sample(picture, 40, 30)
            let halo = sample(picture, 40, 36)
            let clear = sample(picture, 40, 44)
            check("the beam has a white core, not a flat line",
                  core.1 > 0.5 && core.2 > 0.5 ? "yes" : "no: \(core)", "yes")
            check("and a halo that reaches past the line it draws",
                  halo.3 > 0.05 && halo.3 < 0.7 && clear.3 < 0.05 ? "yes" : "no: \(halo) \(clear)",
                  "yes")
        }

        // And its size is a setting now. It was pinned at 6, which made the size wheel six
        // sectors that did nothing - the fault the eraser had before its size started to mean
        // something.
        controller.tools.select(tool: .laser)
        controller.tools.selectWidth(0)
        let thinBeam = controller.tools.renderWidth
        let thinGlow = LaserDot.extent(for: thinBeam)
        controller.tools.selectWidth(5)
        let fatBeam = controller.tools.renderWidth
        check("the size wheel means something to the laser as well",
              fatBeam > thinBeam && LaserDot.extent(for: fatBeam) > thinGlow ? "yes" : "no", "yes")
        controller.tools.selectWidth(2)
        check("and its middle setting is the 6pt beam it always had",
              "\(Int(controller.tools.renderWidth))", "6")
        controller.tools.select(tool: .pen)

        // Colour means nothing to the eraser, so the colour wheel does not open for it and
        // the badge says why. Handing the pen back instead was tried and was worse: it
        // answered a question nobody asked and changed the tool in your hand.
        controller.tools.select(tool: .eraser)
        controller.openColourWheel()
        check("the colour wheel does not open for the eraser",
              controller.wheels.isOpen ? "opened" : "no", "no")
        check("and the eraser is still in hand", controller.tools.tool.label, "ERASER")
        if let badge = controller.drawingViewSnapshot(from: controller.overlayWindowSnapshot())
            .first?.badge {
            check("the badge says why", badge.notice ?? "nothing", "The eraser has no colour")
        }
        controller.tools.select(tool: .pen)

        // The eraser cuts, it does not delete. Rubbing out whole strokes made its size
        // meaningless: one touch anywhere on a line took the entire line, so a wide eraser
        // and a narrow one did exactly the same thing.
        clearAll()
        controller.tools.select(tool: .pen)
        stroke(y: 700)
        controller.tools.select(tool: .eraser)
        rub(x: 290, y: 700)
        check("eraser cuts a line in two", "\(live)", "2")

        // A quick hand produces one event that jumps a long way. The eraser used to cut a
        // circle only where each event landed, so a fast stroke across a line passed either
        // side of it and did nothing - which is the "sometimes it doesn't erase" reported.
        clearAll()
        controller.tools.select(tool: .pen)
        stroke(y: 700)
        controller.tools.select(tool: .eraser)
        rubAcross(from: NSPoint(x: 290, y: 760), to: NSPoint(x: 290, y: 640))
        check("a fast eraser stroke still cuts what it crossed", "\(live)", "2")

        // And a drag is one thing to take back, not one per mouse move.
        undoOnce()
        check("one eraser drag is one undo", "\(live)", "1")
        controller.tools.select(tool: .pen)

        // And the whole gesture, end to end, through the same code the shortcut runs: open
        // the wheel where the pointer is, push, let go.
        controller.tools.select(tool: .eraser)
        // Pushed from the wheel's own centre, not from wherever the mouse happens to be:
        // the wheel clamps itself to fit on screen, so opening it near an edge puts the
        // centre somewhere other than the pointer. A test that assumed otherwise passed or
        // failed depending on where the mouse had been left.
        controller.openToolWheel()
        controller.wheels.track(NSPoint(x: controller.wheels.centre.x + 120, y: controller.wheels.centre.y))
        controller.wheels.release()
        check("wheel: push right, let go, holding the pen",
              controller.tools.tool.label + "/" + state, "PEN/DRAWING")

        // The hub is not a cancel. It is the way out to driving the system, which is the
        // point of putting the mode on the same gesture as the tool: one thing to learn
        // instead of a tool picker and a mode shortcut.
        controller.openToolWheel()
        controller.wheels.track(controller.wheels.centre)
        controller.wheels.release()
        check("wheel: let go in the middle and the system has the screen", state, "CLICK-THROUGH")

        // And back, by picking a tool - which is the only way back in, so it had better be.
        controller.openToolWheel()
        controller.wheels.track(NSPoint(x: controller.wheels.centre.x - 120, y: controller.wheels.centre.y))
        controller.wheels.release()
        check("wheel: pick a tool and the overlay takes the screen back",
              controller.tools.tool.label + "/" + state, "ERASER/DRAWING")
        controller.tools.select(tool: .pen)

        // Each tool draws its own pointer, in the colour in hand - onto a layer, not into a
        // cursor, because an app that is presenting hides the pointer and then a cursor of
        // ours is not drawn at all (docs/DECISIONS.md 6). Two things have to hold and neither
        // is visible from a screenshot: every picture is square, which is what puts the point
        // the tool works from under the pointer when the layer carries it centred, and the
        // tools have to actually differ, or "per tool" is a claim and not a fact.
        func painted(_ tools: ToolSettings) -> Data {
            guard let picture = PointerCursor.picture(for: tools, scale: 1) else {
                return Data()
            }

            let side = 64
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
                                       bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                       isPlanar: false, colorSpaceName: .deviceRGB,
                                       bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSGraphicsContext.current?.cgContext
                .draw(picture.image, in: CGRect(x: 0, y: 0, width: side, height: side))
            NSGraphicsContext.restoreGraphicsState()
            return Data(bytes: rep.bitmapData!, count: rep.bytesPerRow * side)
        }

        var pictures: Set<Data> = []
        var centred = true
        for tool in [DrawingTool.pen, .highlighter, .line, .arrow, .rectangle, .ellipse, .eraser] {
            controller.tools.select(tool: tool)
            let picture = PointerCursor.picture(for: controller.tools, scale: 2)
            centred = centred && picture != nil && picture!.size.width == picture!.size.height
            pictures.insert(painted(controller.tools))
        }
        check("every tool's pointer is drawn around the point it works from",
              centred ? "yes" : "no", "yes")

        // Four pictures from seven tools, on purpose: a pen, a marker, an eraser, and one
        // crosshair shared by the four that place a corner. Those four do the same thing
        // with the mouse, and a crosshair with a little picture beside it was two cursors
        // in one place - which is what "the pens should be pens" was about.
        check("the tools that draw differently look different", "\(pictures.count)", "4")

        // The laser is the one tool with no picture: its glow is its pointer, and two marks
        // an inch apart are worse than one.
        controller.tools.select(tool: .laser)
        check("the laser's pointer is its glow, and nothing else",
              PointerCursor.picture(for: controller.tools, scale: 2) == nil ? "nothing" : "a picture",
              "nothing")
        controller.tools.select(tool: .pen)

        // And size shows, which is the whole reason for drawing a tool rather than an arrow.
        controller.tools.selectWidth(0)
        let thin = PointerCursor.picture(for: controller.tools, scale: 2)!.size.width
        controller.tools.selectWidth(5)
        let thick = PointerCursor.picture(for: controller.tools, scale: 2)!.size.width
        check("a fat pen has a fatter pointer", thick > thin ? "yes" : "no", "yes")
        controller.tools.select(tool: .eraser)
        controller.tools.selectWidth(0)
        let small = PointerCursor.picture(for: controller.tools, scale: 2)!.size.width
        controller.tools.selectWidth(5)
        let big = PointerCursor.picture(for: controller.tools, scale: 2)!.size.width
        check("and a big eraser a bigger one", big > small ? "yes" : "no", "yes")
        controller.tools.selectWidth(2)

        // And the colour is in it, or the pen you are holding is a guess.
        controller.tools.select(tool: .pen)
        controller.tools.selectColor(0)
        let red = painted(controller.tools)
        controller.tools.selectColor(4)
        let blue = painted(controller.tools)
        check("the pointer carries the colour", red == blue ? "same" : "different", "different")
        controller.tools.selectColor(0)

        // A marker's line stops where the hand did. Every cap style except butt extends past
        // the end of the line by half its width, so a 56pt marker ran 28pt ahead of the
        // pointer and that overshoot swung round as the hand turned - which is what "the
        // marker moves coarsely" was. Painted here rather than described: ink to the right of
        // where the line ends is the fault.
        let straight = NSBezierPath()
        straight.lineWidth = 56
        straight.lineCapStyle = StrokeStyle.highlighter.lineCapStyle
        straight.move(to: NSPoint(x: 40, y: 100))
        straight.line(to: NSPoint(x: 160, y: 100))
        let laid = Stroke(points: [NSPoint(x: 40, y: 100), NSPoint(x: 160, y: 100)],
                          path: straight, color: .systemYellow, width: 56,
                          style: .highlighter, createdAt: nil)
        if let picture = Picture.drawn(size: NSSize(width: 220, height: 200), scale: 1, {
            laid.paint()
        }) {
            let values = alpha(picture)
            let side = picture.width
            // The image counts rows from the top; the line is at y = 100 of 200.
            func at(_ x: Int) -> Double { values[(200 - 1 - 100) * side + x] }
            check("the marker's line stops where the hand stopped",
                  at(150) > 0.1 && at(175) < 0.02 ? "yes" : "no: \(at(150)) \(at(175))", "yes")
        }

        // The cost of a butt cap: a tap has no length, and a line of no length paints nothing
        // at all. The dab is drawn on purpose instead of left to the cap.
        let dabPath = NSBezierPath()
        dabPath.move(to: NSPoint(x: 100, y: 100))
        let dab = Stroke(points: [NSPoint(x: 100, y: 100)], path: dabPath, color: .systemYellow,
                         width: 56, style: .highlighter, createdAt: nil)
        if let picture = Picture.drawn(size: NSSize(width: 200, height: 200), scale: 1, {
            dab.paint()
        }) {
            let inked = alpha(picture).filter { $0 > 0.1 }.count
            check("and a tap with it still leaves a mark", inked > 100 ? "yes" : "no: \(inked)", "yes")
        }

        // What the window server is handed is a cursor that shows nothing - so that nothing
        // else claims the pointer and draws an arrow beside ours - and the pointer itself is
        // a layer on the overlay, which is what a presenting app cannot hide.
        if let view = controller.drawingViewSnapshot(from: controller.overlayWindowSnapshot()).first {
            view.applyDrawingCursor()
            check("the window server is handed a cursor that shows nothing",
                  NSCursor.current === PointerCursor.invisible ? "yes" : "no", "yes")
            view.followPointer(to: NSPoint(x: 320, y: 240))
            check("and the pointer the user sees is a layer, under the hand",
                  !view.pointerLayer.isHidden && view.pointerLayer.contents != nil
                    && view.pointerLayer.position == NSPoint(x: 320, y: 240) ? "yes" : "no", "yes")
            controller.toggleInteractionMode()
            check("which goes out when the screen is handed back",
                  view.pointerLayer.isHidden ? "yes" : "no", "yes")
            controller.toggleInteractionMode()
        }

        // The actions wheel is the one whose hub does something rather than cancelling: a tap
        // of ⌥V undoes, because taking things back is the one job here that is done over and
        // over and a gesture for each would be the wrong shape. Everything on it works
        // whatever has the keyboard, which is why the bare letters it replaces are gone.
        controller.tools.select(tool: .pen)
        clearAll()
        stroke(y: 300); stroke(y: 340)
        let beforeUndo = live
        controller.openActionWheel()
        controller.wheels.track(controller.wheels.centre)
        controller.wheels.release()
        check("a tap on the actions wheel takes one back", "\(live)", "\(beforeUndo - 1)")

        // Sector 0 is due right, and the order runs clockwise from there: redo, clear, temp
        // ink, hide.
        func pushAction(_ index: Int) {
            let sweep = CGFloat.pi * 2 / CGFloat(OverlayController.actionOrder.count)
            let angle = -CGFloat(index) * sweep
            controller.openActionWheel()
            controller.wheels.track(NSPoint(x: controller.wheels.centre.x + cos(angle) * 120,
                                            y: controller.wheels.centre.y + sin(angle) * 120))
            controller.wheels.release()
        }

        pushAction(0)
        check("and pushing right puts it back", "\(live)", "\(beforeUndo)")

        pushAction(1)
        check("pushing down clears the screen", "\(live)", "0")
        controller.openActionWheel()
        controller.wheels.track(controller.wheels.centre)
        controller.wheels.release()
        check("and that is one thing to take back", "\(live)", "\(beforeUndo)")

        let temporaryBefore = controller.tools.drawsTemporaryInk
        pushAction(2)
        check("pushing left switches temporary ink",
              controller.tools.drawsTemporaryInk == temporaryBefore ? "no" : "yes", "yes")
        pushAction(2)

        pushAction(3)
        check("and pushing up puts the overlay away, keeping the drawing", state, "OFF")
        controller.toggleDrawingMode()
        check("which came back", "\(live)", "\(beforeUndo)")
        clearAll()

        // A wheel only appears if you hold the key. Under the threshold it is a tap and the
        // hub's job is done with nothing on screen - which matters most for ⌥V, whose hub is
        // undo: a wheel flashing up on every undo would be the wrong thing for the one action
        // people repeat.
        controller.openActionWheel()
        check("a tap puts nothing on screen",
              controller.wheels.isShowing ? "a wheel" : "nothing", "nothing")
        controller.wheels.release()

        controller.openActionWheel()
        controller.wheels.track(NSPoint(x: controller.wheels.centre.x + 120,
                                        y: controller.wheels.centre.y))
        check("but aiming shows it at once, however short the press",
              controller.wheels.isShowing ? "a wheel" : "nothing", "a wheel")
        controller.wheels.close()

        controller.openActionWheel()
        RunLoop.current.run(until: Date().addingTimeInterval(WheelPanel.holdBeforeShowing + 0.1))
        check("and holding brings it up on its own",
              controller.wheels.isShowing ? "a wheel" : "nothing", "a wheel")
        controller.wheels.close()

        // The wheel is the only way in now, so it has to be able to open an overlay that
        // is not there - and the eighth sector has to be able to put it away again, keeping
        // the drawing, which is what ⌃⌥⌘D used to do.
        controller.toggleDrawingMode()
        check("hidden to start with", state, "OFF")

        // The wheel wears a cursor that shows nothing, like the overlay - so the one thing
        // that must never happen is a wheel closing with no overlay behind it and leaving the
        // user with no pointer at all. Letting go in the middle with nothing open is exactly
        // that case.
        controller.openToolWheel()
        controller.wheels.track(controller.wheels.centre)
        controller.wheels.release()
        check("a wheel that closes with no overlay hands a pointer back",
              NSCursor.current === PointerCursor.invisible ? "nothing" : "a pointer", "a pointer")
        controller.openToolWheel()
        controller.wheels.track(NSPoint(x: controller.wheels.centre.x + 120,
                                        y: controller.wheels.centre.y))
        controller.wheels.release()
        check("the wheel opens an overlay that was not there",
              controller.tools.tool.label + "/" + state, "PEN/DRAWING")

        // The hub is the way out and it goes one step at a time: drawing hands the screen
        // back, and doing it again from there puts the overlay away with the drawing kept.
        stroke(y: 300)
        let beforeHiding = live
        controller.openToolWheel()
        controller.wheels.track(controller.wheels.centre)
        controller.wheels.release()
        check("the hub hands the screen back first", state, "CLICK-THROUGH")
        controller.openToolWheel()
        controller.wheels.track(controller.wheels.centre)
        controller.wheels.release()
        check("and the second time puts it away", state, "OFF")
        controller.toggleDrawingMode()
        check("and hiding kept the drawing", "\(live)", "\(beforeHiding)")

        // The cursor hold is what stops the window server leaving an arrow on a pointer that
        // is not moving, and it is a timer, so where it stops matters as much as where it
        // runs: click-through hands the pointer to the app underneath, and a closed overlay
        // has to cost nothing at all.
        check("the cursor hold runs while drawing mode has the mouse",
              controller.cursorHold != nil ? "yes" : "no", "yes")
        controller.toggleInteractionMode()
        check("and stops when the screen is handed back",
              controller.cursorHold == nil ? "yes" : "no", "yes")
        controller.toggleInteractionMode()
        controller.toggleDrawingMode()
        check("and when the overlay goes away", controller.cursorHold == nil ? "yes" : "no", "yes")

        print("REG summary: \(pass) passed, \(fail) failed")
        // Quits through the panic key rather than NSApp.terminate, so the shortcut that has
        // to work from any state is exercised on every run.
        fireHotKey(id: 2)

