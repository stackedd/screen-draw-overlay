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
        guard let panel = overlayWindowSnapshot().first else { return }
        NSApp.sendEvent(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                         windowNumber: panel.windowNumber, context: nil, characters: chars,
                                         charactersIgnoringModifiers: chars, isARepeat: false, keyCode: UInt16(code))!)
    }

    func stroke(finish: Bool = true, y: CGFloat = 300) {
        guard let panel = overlayWindowSnapshot().first else { return }
        let v = panel.drawingView
        func ev(_ t: NSEvent.EventType, _ x: CGFloat) -> NSEvent {
            NSEvent.mouseEvent(with: t, location: NSPoint(x: x, y: y), modifierFlags: [], timestamp: 0,
                               windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        v.mouseDown(with: ev(.leftMouseDown, 200))
        for i in 1...6 { v.mouseDragged(with: ev(.leftMouseDragged, 200 + CGFloat(i) * 30)) }
        if finish { v.mouseUp(with: ev(.leftMouseUp, 380)) }
    }

    var live: Int { drawingViewSnapshot(from: overlayWindowSnapshot()).first?.capturedStrokes().count ?? -1 }
    var state: String { !isDrawingMode ? "OFF" : (isInteractionMode ? "CLICK-THROUGH" : "DRAWING") }

    func regress() {
        var pass = 0, fail = 0
        func check(_ name: String, _ got: String, _ want: String) {
            if got == want { pass += 1; print("REG ok    \(name): \(got)") }
            else { fail += 1; print("REG FAIL  \(name): got \(got), want \(want)") }
        }

        check("off + E", { toggleInteractionMode(); return state }(), "OFF")
        check("off + D", { toggleDrawingMode(); return state }(), "DRAWING")
        stroke(); stroke()
        check("two strokes", "\(live)", "2")
        check("drawing + E", { toggleInteractionMode(); return state }(), "CLICK-THROUGH")
        check("strokes survive E", "\(live)", "2")
        check("click-through + D", { toggleDrawingMode(); return state }(), "DRAWING")
        check("strokes survive D from click-through", "\(live)", "2")

        press(kVK_ANSI_3, "3"); press(kVK_ANSI_A, "a")
        stroke(y: 400)
        let signature = drawingViewSnapshot(from: overlayWindowSnapshot()).first!.capturedStrokes()
            .map { "\($0.style.label)/\(Int($0.width))/\($0.points.count)" }.joined(separator: ",")
        check("arrow tool produced a two-point stroke", signature.hasSuffix("/2") ? "yes" : "no: \(signature)", "yes")
        toggleDrawingMode()
        check("hidden", state, "OFF")
        toggleDrawingMode()
        let restored = drawingViewSnapshot(from: overlayWindowSnapshot()).first!.capturedStrokes()
            .map { "\($0.style.label)/\(Int($0.width))/\($0.points.count)" }.joined(separator: ",")
        check("hide+show keeps strokes exactly", restored, signature)

        stroke(finish: false, y: 500)
        toggleInteractionMode()
        check("unfinished stroke committed on mode switch", "\(live)", "4")
        toggleInteractionMode()

        press(kVK_ANSI_E, "e")
        check("bare E selects eraser", tools.tool.label + "/" + state, "ERASER/DRAWING")
        press(kVK_Space, " ")
        check("space selects laser", tools.tool.label, "LASER")
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
        toggleDrawingMode()
        toggleDrawingMode()
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
        if let view = drawingViewSnapshot(from: overlayWindowSnapshot()).first {
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

        // The pointer is the system arrow with a ring around its tip. Three points have
        // to be the same one - the hot spot, the middle of the ring and where the ink
        // lands - or the stroke appears offset from the arrow the user is aiming with.
        let cursor = PointerCursor.cursor(for: tools)
        let aimed = cursor.hotSpot.x == cursor.image.size.width / 2
            && cursor.hotSpot.y == cursor.image.size.height / 2
            && cursor.image.size.width > NSCursor.arrow.image.size.width
        check("cursor is the arrow with its tip on the ink", aimed ? "yes" : "no", "yes")

        // hold to draw: a long press puts it away on release, a tap does not
        toggleDrawingMode()
        fireHotKey(id: 1)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
            self.fireHotKey(id: 1, release: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                check("hold then release hides", self.state, "OFF")
                self.fireHotKey(id: 1)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    self.fireHotKey(id: 1, release: true)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        check("tap stays open", self.state, "DRAWING")
                        print("REG summary: \(pass) passed, \(fail) failed")
                        self.fireHotKey(id: 2)
                    }
                }
            }
        }
