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
        heldModifiers[59] = 162
        edgeArmed = false // Exercise the hotkey without moving the real desktop pointer.
        let hotkey = CGEvent(keyboardEventSource: nil, virtualKey: 40, keyDown: true)!
        hotkey.flags = [.maskControl, .maskAlternate, .maskCommand]
        _ = handleTap(type: .keyDown, event: hotkey)
        precondition(!active && heldKeys.isEmpty && heldModifiers.isEmpty && pressedButtons.isEmpty)
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
        emit(["check":"command"])
        for (code, mask) in [(UInt16(55), UInt64(NX_DEVICELCMDKEYMASK)), (54, UInt64(NX_DEVICERCMDKEYMASK))] {
            edge(.flagsChanged,code,cmd|mask)
            edge(.flagsChanged,code,0)
            for letter: UInt16 in [2, 15] { // D, R
                edge(.flagsChanged,code,cmd|mask)
                edge(.keyDown,letter,cmd|mask)
                edge(.keyUp,letter,cmd|mask)
                edge(.flagsChanged,code,0)
            }
        }
        // Both physical Command keys share Win. Remapping must respect a held key's owner.
        edge(.flagsChanged,55,cmd|8)
        edge(.flagsChanged,54,cmd|24)
        handleOnMain(command:["action":"leftCommandIsWin","enabled":false])
        edge(.flagsChanged,54,cmd|8)
        edge(.flagsChanged,55,0)
        edge(.flagsChanged,55,cmd|8)
        edge(.keyDown,9,cmd|8)
        edge(.keyUp,9,cmd|8)
        edge(.flagsChanged,55,0)
        edge(.flagsChanged,54,cmd|16)
        edge(.flagsChanged,54,0)
        emit(["check":"end-command"])
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

extension KvmHelper {
    static func checkMissingKeyUp() {
        var physical: Set<CGKeyCode> = []
        let helper = KvmHelper(hardwareKeyDown: { physical.contains($0) })
        helper.active = true
        func key(_ code: CGKeyCode, down: Bool, repeating: Bool = false) {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)!
            event.setIntegerValueField(.keyboardEventAutorepeat, value: repeating ? 1 : 0)
            _ = helper.handleTap(type: down ? .keyDown : .keyUp, event: event)
        }

        emit(["check": "missing-up"])
        physical = [13, 2] // W and D
        key(13, down: true)
        key(2, down: true)
        key(13, down: true, repeating: true)
        physical.remove(13) // Intentionally withhold the W key-up callback.
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        precondition(helper.active && helper.heldKeys == [2: 68])
        key(13, down: true, repeating: true) // A late repeat must not relatch W.
        key(13, down: false)                // A late up must not release D.
        physical.insert(13)
        key(13, down: true)
        key(13, down: true)                 // Re-press before the next timer tick.
        physical.remove(13)
        _ = helper.handleTap(type: .tapDisabledByTimeout, event: CGEvent(source: nil)!)
        precondition(helper.heldKeys == [2: 68])
        physical.remove(2)
        key(2, down: false)
        precondition(helper.keyCheckTimer == nil)

        // Hardware polling must preserve software-generated keys and aliases.
        key(0, down: true)
        physical = [36, 76] // Return and keypad Enter share VK_RETURN.
        key(36, down: true)
        key(76, down: true)
        physical.remove(36)
        helper.checkKeyReleases()
        precondition(helper.heldKeys == [0: 65, 76: 13])
        physical.remove(76)
        key(76, down: false)
        key(0, down: false)
        // If the initial press was before capture, a real held-key repeat is valid.
        physical.insert(13)
        key(13, down: true, repeating: true)
        physical.remove(13)
        key(13, down: false)
        precondition(helper.keyCheckTimer == nil && helper.heldKeys.isEmpty)
        emit(["check": "end-missing-up"])
    }
}
KvmHelper.checkMissingKeyUp()
