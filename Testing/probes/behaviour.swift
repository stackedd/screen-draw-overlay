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

    func drag(_ tool: Int, _ chars: String, from: NSPoint, to: NSPoint) {
        press(tool, chars)
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

        press(kVK_ANSI_3, "3"); press(kVK_ANSI_A, "a")
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

        press(kVK_ANSI_E, "e")
        check("bare E selects eraser", controller.tools.tool.label + "/" + state, "ERASER/DRAWING")
        press(kVK_Space, " ")
        check("space selects laser", controller.tools.tool.label, "LASER")
        press(kVK_Space, " ")
        press(kVK_ANSI_P, "p")
        press(kVK_ANSI_Q, "q", .command)
        check("Cmd+Q swallowed", "\(NSApp.isRunning)", "true")
        let beforeClear = live
        press(kVK_ANSI_C, "c")
        check("C clears", "\(live)", "0")
        press(kVK_ANSI_Z, "z", .command)
        check("undo restores the clear", "\(live)", "\(beforeClear)")
        press(kVK_ANSI_Z, "z", [.command, .shift])
        check("redo clears again", "\(live)", "0")

        // Hiding the overlay used to throw the history away with the panels, so the drawing
        // came back and could no longer be taken back.
        stroke(y: 540)
        stroke(y: 560)
        controller.toggleDrawingMode()
        controller.toggleDrawingMode()
        press(kVK_ANSI_Z, "z", .command)
        check("undo still works after hide and show", "\(live)", "1")

        // A temporary stroke that fades leaves nothing behind - including its entry in the
        // history. It used to stay, and the next undo applied it to whatever happened to be
        // last, which took back a line the user had just drawn and offered a faded one back
        // in its place.
        press(kVK_ANSI_C, "c")
        stroke(y: 560)
        stroke(y: 580)
        press(kVK_ANSI_T, "t")
        stroke(y: 600)
        press(kVK_ANSI_T, "t")
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
        press(kVK_ANSI_Z, "z", .command)
        press(kVK_ANSI_Z, "z", [.command, .shift])
        check("undo steps over temporary ink that has faded", "\(live)", "2")

        // The wheel's whole promise is that a direction picks a tool without aiming, so the
        // two that need no thought have to be the two that need no thought: a flick right
        // is the pen, a flick left is the eraser. And letting go in the middle has to pick
        // nothing, because that is the only way to change your mind.
        let wheel = OverlayController.toolWheel
        func toolPushing(_ x: CGFloat, _ y: CGFloat) -> String {
            guard let sector = wheel.selection(for: NSPoint(x: x, y: y)),
                  let tool = OverlayController.toolOrder[sector] else { return "none" }
            return tool.label
        }
        check("wheel: right is the pen, left is the eraser",
              toolPushing(120, 0) + "/" + toolPushing(-120, 0), "PEN/ERASER")
        check("wheel: the dead zone picks nothing", toolPushing(6, -4), "none")

        // Shapes are erased like everything else. Their `points` are only the two corners
        // the drag was defined by, so measuring to those measured to a rectangle's diagonal
        // rather than its outline: the eraser did nothing over most of a shape and took the
        // whole thing where it did reach. Flattened, a shape cuts like a line, and what is
        // left is no longer a shape - which is right, a piece was rubbed out of it.
        press(kVK_ANSI_C, "c")
        drag(kVK_ANSI_R, "r", from: NSPoint(x: 240, y: 620), to: NSPoint(x: 460, y: 760))
        check("a rectangle is one stroke", "\(live)", "1")
        press(kVK_ANSI_E, "e")
        rubAcross(from: NSPoint(x: 200, y: 690), to: NSPoint(x: 280, y: 690))
        check("erasing a rectangle's edge leaves the rest of it", live > 0 ? "yes" : "gone", "yes")
        press(kVK_ANSI_C, "c")
        press(kVK_ANSI_P, "p")

        // The laser is a light on the overlay, not a decoration on the cursor - a cursor is
        // only ours while we own the window under the pointer, and being there is the one
        // thing a laser has to do. It also has no business sitting on top of an app the
        // user has just been handed back.
        press(kVK_Space, " ")
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
        controller.toggleInteractionMode()
        press(kVK_Space, " ")

        // The eraser cuts, it does not delete. Rubbing out whole strokes made its size
        // meaningless: one touch anywhere on a line took the entire line, so a wide eraser
        // and a narrow one did exactly the same thing.
        press(kVK_ANSI_C, "c")
        press(kVK_ANSI_P, "p")
        stroke(y: 700)
        press(kVK_ANSI_E, "e")
        rub(x: 290, y: 700)
        check("eraser cuts a line in two", "\(live)", "2")

        // A quick hand produces one event that jumps a long way. The eraser used to cut a
        // circle only where each event landed, so a fast stroke across a line passed either
        // side of it and did nothing - which is the "sometimes it doesn't erase" reported.
        press(kVK_ANSI_C, "c")
        press(kVK_ANSI_P, "p")
        stroke(y: 700)
        press(kVK_ANSI_E, "e")
        rubAcross(from: NSPoint(x: 290, y: 760), to: NSPoint(x: 290, y: 640))
        check("a fast eraser stroke still cuts what it crossed", "\(live)", "2")

        // And a drag is one thing to take back, not one per mouse move.
        press(kVK_ANSI_Z, "z", .command)
        check("one eraser drag is one undo", "\(live)", "1")
        press(kVK_ANSI_P, "p")

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

        // Each tool draws its own pointer, in the colour in hand. Two things have to hold
        // and neither is visible from a screenshot: the hot spot has to be the middle of
        // the image - which is the point the tool works from and the point the ink lands on
        // - and the tools have to actually differ, or "per tool" is a claim and not a fact.
        // Compared by painting them, not by asking for their data: these images draw
        // through a handler, and tiffRepresentation hands back a blank of the right size
        // rather than running it - which made a first version of this check believe four
        // different tools drew the same cursor.
        func painted(_ tools: ToolSettings) -> Data {
            let cursor = PointerCursor.cursor(for: tools)
            let side = 64
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
                                       bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                       isPlanar: false, colorSpaceName: .deviceRGB,
                                       bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            cursor.image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
            NSGraphicsContext.restoreGraphicsState()
            return Data(bytes: rep.bitmapData!, count: rep.bytesPerRow * side)
        }

        var pictures: Set<Data> = []
        var centred = true
        for tool in [DrawingTool.pen, .highlighter, .line, .arrow, .rectangle, .ellipse, .eraser] {
            controller.tools.select(tool: tool)
            let cursor = PointerCursor.cursor(for: controller.tools)
            centred = centred
                && cursor.hotSpot.x == cursor.image.size.width / 2
                && cursor.hotSpot.y == cursor.image.size.height / 2
            pictures.insert(painted(controller.tools))
        }
        check("every tool's cursor points from its own hot spot", centred ? "yes" : "no", "yes")
        check("every tool draws a different cursor", "\(pictures.count)", "7")

        // And the colour is in it, or the pen you are holding is a guess.
        controller.tools.select(tool: .pen)
        controller.tools.selectColor(0)
        let red = painted(controller.tools)
        controller.tools.selectColor(4)
        let blue = painted(controller.tools)
        check("the cursor carries the colour", red == blue ? "same" : "different", "different")
        controller.tools.selectColor(0)

        // The wheel is the only way in now, so it has to be able to open an overlay that
        // is not there - and the eighth sector has to be able to put it away again, keeping
        // the drawing, which is what ⌃⌥⌘D used to do.
        controller.toggleDrawingMode()
        check("hidden to start with", state, "OFF")
        controller.openToolWheel()
        controller.wheels.track(NSPoint(x: controller.wheels.centre.x + 120,
                                        y: controller.wheels.centre.y))
        controller.wheels.release()
        check("the wheel opens an overlay that was not there",
              controller.tools.tool.label + "/" + state, "PEN/DRAWING")

        stroke(y: 300)
        let beforeHiding = live
        controller.openToolWheel()
        controller.wheels.track(NSPoint(x: controller.wheels.centre.x + 92,
                                        y: controller.wheels.centre.y + 92))
        controller.wheels.release()
        check("the wheel puts it away again", state, "OFF")
        controller.toggleDrawingMode()
        check("and hiding kept the drawing", "\(live)", "\(beforeHiding)")

        print("REG summary: \(pass) passed, \(fail) failed")
        // Quits through the panic key rather than NSApp.terminate, so the shortcut that has
        // to work from any state is exercised on every run.
        fireHotKey(id: 2)

