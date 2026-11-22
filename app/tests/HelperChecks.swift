// Appended to the helper source by input_checks.py. Events are never posted to macOS.
extension KvmHelper {
    func checkCameraDrag() {
        active = true
        edgeArmed = true
        returnArmed = true
        setEdgeMode("right")
        updateRemoteBounds(["left": 0, "top": 0, "width": 1920, "height": 1080])
        updateRemoteCursor(["x": 1, "y": 500])
        precondition(returnProbeX() == 1 && returnProbeY() == 500)

        func mouse(_ type: CGEventType, _ button: CGMouseButton, _ dx: Int64 = 0) {
            let event = CGEvent(mouseEventSource: nil, mouseType: type,
                                mouseCursorPosition: .zero, mouseButton: button)!
            event.setIntegerValueField(.mouseEventDeltaX, value: dx)
            handleMouse(event: event, type: type)
        }
        mouse(.rightMouseDown, .right)
        for _ in 0..<1000 { mouse(.rightMouseDragged, .right, -40) }
        precondition(active && !shouldReturnOnEdge(deltaX: -12))
        mouse(.leftMouseDown, .left)
        mouse(.rightMouseUp, .right)
        mouse(.mouseMoved, .left, -80)
        precondition(active && !shouldReturnOnEdge(deltaX: -12))
        mouse(.leftMouseUp, .left)
        precondition(!shouldReturnOnEdge(deltaX: -12))
        edgeEnteredAt = CFAbsoluteTimeGetCurrent() - 1
        updateRemoteCursor(["x": 150, "y": 500])
        mouse(.mouseMoved, .left, 5)
        updateRemoteCursor(["x": 1, "y": 500])
        precondition(shouldReturnOnEdge(deltaX: -1))

        handleOnMain(command: ["action": "lockReturn", "enabled": true])
        precondition(!shouldReturnOnEdge(deltaX: -1))
        mouse(.rightMouseDown, .right)
        let w = CGEvent(keyboardEventSource: nil, virtualKey: 13, keyDown: true)!
        handleKey(event: w, down: true)
        sentModifiers.insert(162)
        edgeArmed = false // Exercise the hotkey without moving the real desktop pointer.
        let hotkey = CGEvent(keyboardEventSource: nil, virtualKey: 40, keyDown: true)!
        hotkey.flags = [.maskControl, .maskAlternate, .maskCommand]
        _ = handleTap(type: .keyDown, event: hotkey)
        precondition(!active && sentKeys.isEmpty && sentModifiers.isEmpty && pressedButtons.isEmpty)
    }
}
KvmHelper().checkCameraDrag()

extension KvmHelper {
    func checkModifiers() {
        active = true
        func edge(_ type: CGEventType, _ code: UInt16, _ flags: UInt64) {
            let ev = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: type != .keyUp)!
            ev.type = type
            ev.flags = CGEventFlags(rawValue: flags)
            _ = handleTap(type: type, event: ev)
        }
        let ctrl = CGEventFlags.maskControl.rawValue, alt = CGEventFlags.maskAlternate.rawValue
        let cmd = CGEventFlags.maskCommand.rawValue
        emit(["check":"modifiers"])
        for _ in 0..<25 {
            edge(.flagsChanged,59,ctrl|1); edge(.flagsChanged,59,ctrl|1); edge(.flagsChanged,59,0)
            edge(.flagsChanged,58,alt|32); edge(.flagsChanged,58,0)
        }
        // Left Command and left Control own the same Windows Ctrl.
        edge(.flagsChanged,55,cmd|8); edge(.flagsChanged,59,cmd|ctrl|9)
        edge(.flagsChanged,55,ctrl|1); edge(.keyDown,8,ctrl|1); edge(.keyUp,8,ctrl|1); edge(.flagsChanged,59,0)
        // A missed initial modifier event, right-hand modifiers, both Options held, and direct events.
        edge(.keyDown,9,ctrl|8192); edge(.keyUp,9,ctrl|8192); edge(.flagsChanged,62,0)
        edge(.flagsChanged,61,alt|64); edge(.flagsChanged,58,alt|96)
        edge(.flagsChanged,61,alt|32); edge(.flagsChanged,58,0)
        edge(.keyDown,59,ctrl); edge(.keyUp,59,0)
        emit(["check":"end-modifiers"])
    }
}
KvmHelper().checkModifiers()
