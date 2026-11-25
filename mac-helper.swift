//
// DSH LAN KVM - macOS global input helper
//
// Captures keyboard and mouse globally while "remote mode" is active and emits
// newline-delimited JSON events on stdout. The DSH Host forwards those events
// to the Windows agent. This helper deliberately knows nothing about the
// network or the token; its stdin/stdout protocol is owned by the Host.
//
// Build:
//   xcrun swiftc -O -swift-version 5 -framework ApplicationServices \
//     -framework AppKit -o dsh-lan-kvm-helper mac-helper.swift
//
// macOS will ask for Accessibility permission the first time it starts. The
// permission belongs to this executable path, so keep the path stable.
//
import Foundation
import ApplicationServices
import IOKit.hidsystem
import AppKit

private let HOTKEY_KEYCODE: Int64 = 40 // K
private let HOTKEY_LABEL = "Control+Option+Command+K"
private let outputLock = NSLock()

private func emit(_ payload: [String: Any]) {
    guard var data = try? JSONSerialization.data(withJSONObject: payload, options: []) else {
        return
    }
    data.append(0x0A)
    outputLock.lock()
    FileHandle.standardOutput.write(data)
    outputLock.unlock()
}

private func keyVK(_ keycode: Int64) -> Int? {
    switch keycode {
    case 0: return 65   // A
    case 1: return 83   // S
    case 2: return 68   // D
    case 3: return 70   // F
    case 4: return 72   // H
    case 5: return 71   // G
    case 6: return 90   // Z
    case 7: return 88   // X
    case 8: return 67   // C
    case 9: return 86   // V
    case 11: return 66  // B
    case 12: return 81  // Q
    case 13: return 87  // W
    case 14: return 69  // E
    case 15: return 82  // R
    case 16: return 89  // Y
    case 17: return 84  // T
    case 18: return 49  // 1
    case 19: return 50  // 2
    case 20: return 51  // 3
    case 21: return 52  // 4
    case 22: return 54  // 6
    case 23: return 53  // 5
    case 24: return 187 // =
    case 25: return 57  // 9
    case 26: return 55  // 7
    case 27: return 189 // -
    case 28: return 56  // 8
    case 29: return 48  // 0
    case 30: return 221 // ]
    case 31: return 79  // O
    case 32: return 85  // U
    case 33: return 219 // [
    case 34: return 73  // I
    case 35: return 80  // P
    case 36: return 13  // Return
    case 37: return 76  // L
    case 38: return 74  // J
    case 39: return 222 // '
    case 40: return 75  // K
    case 41: return 186 // ;
    case 42: return 220 // backslash
    case 43: return 188 // ,
    case 44: return 191 // /
    case 45: return 78  // N
    case 46: return 77  // M
    case 47: return 190 // .
    case 48: return 9   // Tab
    case 49: return 32  // Space
    case 50: return 192 // `
    case 51: return 8   // Backspace
    case 53: return 27  // Escape
    case 54: return 91  // right Command -> Win (VK_LWIN)
    case 55: return 162 // left Command -> Ctrl
    case 56: return 160 // left Shift
    case 57: return 20  // Caps Lock
    case 58: return 164 // left Option -> Alt
    case 59: return 162 // left Control -> Ctrl
    case 60: return 161 // right Shift
    case 61: return 165 // right Option -> Alt
    case 62: return 163 // right Control -> Ctrl
    case 64: return 128 // F17
    case 65: return 110 // keypad decimal
    case 67: return 106 // keypad multiply
    case 69: return 107 // keypad plus
    case 71: return 12  // keypad clear
    case 75: return 111 // keypad divide
    case 76: return 13  // keypad enter
    case 78: return 109 // keypad minus
    case 79: return 129 // F18
    case 80: return 130 // F19
    case 81: return 107 // keypad equals
    case 82: return 96  // keypad 0
    case 83: return 97  // keypad 1
    case 84: return 98  // keypad 2
    case 85: return 99  // keypad 3
    case 86: return 100 // keypad 4
    case 87: return 101 // keypad 5
    case 88: return 102 // keypad 6
    case 89: return 103 // keypad 7
    case 91: return 104 // keypad 8
    case 92: return 105 // keypad 9
    case 96: return 116 // F5
    case 97: return 117 // F6
    case 98: return 118 // F7
    case 99: return 114 // F3
    case 100: return 119 // F8
    case 101: return 120 // F9
    case 103: return 122 // F11
    case 105: return 124 // F13
    case 106: return 127 // F16
    case 107: return 125 // F14
    case 109: return 121 // F10
    case 111: return 123 // F12
    case 113: return 126 // F15
    case 115: return 36  // Home
    case 116: return 33  // Page Up
    case 117: return 46  // Forward Delete
    case 118: return 115 // F4
    case 119: return 35  // End
    case 120: return 113 // F2
    case 121: return 34  // Page Down
    case 122: return 112 // F1
    case 123: return 37  // Left
    case 124: return 39  // Right
    case 125: return 40  // Down
    case 126: return 38  // Up
    default: return nil
    }
}

// Some event sources publish only the aggregate flag. Physical keyboards also
// supply the side-specific flags declared in IOLLEvent.h.
private typealias ModifierSide = (code: Int64, vk: Int, mask: UInt64)
private let modifierPairs: [(flag: CGEventFlags, left: ModifierSide, right: ModifierSide)] = [
    (.maskControl, (59, 162, UInt64(NX_DEVICELCTLKEYMASK)), (62, 163, UInt64(NX_DEVICERCTLKEYMASK))),
    (.maskAlternate, (58, 164, UInt64(NX_DEVICELALTKEYMASK)), (61, 165, UInt64(NX_DEVICERALTKEYMASK))),
    (.maskShift, (56, 160, UInt64(NX_DEVICELSHIFTKEYMASK)), (60, 161, UInt64(NX_DEVICERSHIFTKEYMASK))),
    (.maskCommand, (55, 162, UInt64(NX_DEVICELCMDKEYMASK)), (54, 91, UInt64(NX_DEVICERCMDKEYMASK)))
]

final class KvmHelper {
    private let stateLock = NSLock()
    private var tap: CFMachPort?
    private var tapInstalled = false
    private var active = false
    private var trusted = false
    private var hotkeyHeld = false
    private var permissionTimer: Timer?
    private var signalSources: [DispatchSourceSignal] = []

    // Edge crossing state. Coordinates from CGEvent use a top-left origin;
    // NSScreen uses bottom-left, so ratios are converted at the boundary.
    private var edgeMode = "off"
    private var edgeArmed = false
    private var entrySide = "right"
    private var entryScreenFrame = CGRect.zero
    private var edgeCooldownUntil = 0.0
    private var remoteX = 0.0
    private var remoteY = 0.0
    private var remoteLeft = 0.0
    private var remoteTop = 0.0
    private var remoteWidth = 0.0
    private var remoteHeight = 0.0
    private var remoteValid = false
    /// Windows virtual-screen bounds, known as soon as the Host probes it.
    private var remoteBoundsValid = false
    /// Which Mac edge the pointer is currently resting on, and since when.
    private var pinnedSide: String?
    private var pinnedSince: CFAbsoluteTime = 0
    /// The pointer enters Windows exactly at the Windows edge nearest the Mac,
    /// which is also where the return test fires. Without arming hysteresis the
    /// first pixel of hand jitter returns to the Mac, the Mac cursor is warped
    /// back to its own edge, and the pair oscillates. Returning is therefore
    /// enabled only after the pointer has genuinely left the entry edge.
    private var returnArmed = false
    /// Minimum distance to travel away from the entry edge before returning.
    private let returnArmDistance: Double = 10
    /// Entry time, so a return cannot fire in the first moments after entry.
    private var edgeEnteredAt: CFAbsoluteTime = 0
    private let returnArmDelay: CFAbsoluteTime = 0.15
    /// Locally accumulated Windows cursor position. Return detection must not
    /// depend on cursor reports arriving: if that feedback stalls while the
    /// pointer is on Windows, the user would be unable to cross back.
    private var remoteEstimateX = 0.0
    private var remoteEstimateY = 0.0

    private var heldModifierCodes = Set<Int64>()
    private var sentModifiers = Set<Int>()
    private var heldKeys: [CGKeyCode: Int] = [:]
    private var hardwareKeys = Set<CGKeyCode>()
    private var keyCheckTimer: Timer?
    private let hardwareKeyDown: (CGKeyCode) -> Bool
    private var pressedButtons = Set<String>()
    private var lockReturn = false
    private var cursorReportTime = -Double.infinity

    private var hiddenDisplays: [CGDirectDisplayID] = []
    private var nsCursorHidden = false
    private var previousApp: NSRunningApplication?
    private var activationWindow: NSWindow?
    private var clipboardEnabled = false
    private var clipboardTimer: Timer?
    private var lastClipboardChangeCount = 0

    private lazy var clipboard = MacClipboard()

    init(hardwareKeyDown: @escaping (CGKeyCode) -> Bool = { CGEventSource.keyState(.hidSystemState, key: $0) }) {
        self.hardwareKeyDown = hardwareKeyDown
    }

    func run() {
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.finishLaunching()
        let window = NSWindow(
            contentRect: NSRect(x: -10000, y: -10000, width: 1, height: 1),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary]
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
        activationWindow = window

        emit([
            "type": "hello",
            "hotkey": HOTKEY_LABEL,
            "pid": Int(getpid()),
            "version": 1,
        ])
        installSignalHandlers()
        installStdinReader()
        requestPermission(prompt: !CommandLine.arguments.contains("--no-prompt"))
        NSApplication.shared.run()
        showCursor()
        restorePreviousApp()
    }

    private func installSignalHandlers() {
        for number in [SIGHUP, SIGINT, SIGTERM] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { [weak self] in
                self?.shutdown()
            }
            source.resume()
            signalSources.append(source)
        }
    }

    /// Single teardown path: release input, restore the cursor and focus, then
    /// end the process. Called for `quit`, stdin EOF and fatal signals.
    private func shutdown() {
        clipboardTimer?.invalidate()
        clipboardTimer = nil
        setActive(false)
        showCursor()
        restorePreviousApp()
        exit(0)
    }

    private func installStdinReader() {
        Thread.detachNewThread { [weak self] in
            while let line = readLine() {
                guard let data = line.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data, options: []),
                      let command = object as? [String: Any] else {
                    continue
                }
                DispatchQueue.main.async {
                    self?.handleOnMain(command: command)
                }
            }
            DispatchQueue.main.async {
                // The Host is gone (DSH quit or crashed). Never leave the Mac
                // with a hidden cursor and a captured keyboard.
                self?.shutdown()
            }
        }
    }

    private func handleOnMain(command: [String: Any]) {
        let action = (command["action"] as? String) ?? ""
        switch action {
        case "activate":
            edgeArmed = false
            setActive(true)
        case "deactivate":
            setActive(false)
        case "return":
            forceReturn()
        case "screen":
            updateRemoteBounds(command)
        case "edge":
            if let mode = command["mode"] as? String {
                setEdgeMode(mode)
            }
        case "lockReturn":
            lockReturn = command["enabled"] as? Bool == true
        case "cursor":
            updateRemoteCursor(command)
        case "clipboard":
            // Accept any JSON number: a Swift Int is written as an integer.
            if let textLimit = numberValue(command["textLimit"]), textLimit >= 1024 {
                clipboard.textLimit = Int(textLimit)
            }
            if let imageLimit = numberValue(command["imageLimit"]), imageLimit >= 1024 {
                clipboard.imageLimit = Int(imageLimit)
            }
            if let fileLimit = numberValue(command["fileLimit"]), fileLimit >= 1024 {
                clipboard.fileLimit = Int(fileLimit)
            }
            if let enabled = command["enabled"] as? Bool {
                setClipboardEnabled(enabled)
            }
        case "clipboardSet":
            writeClipboard(command)
        case "status":
            emitStatus()
        case "quit":
            shutdown()
        default:
            emit(["type": "error", "message": "unknown command: \(action)"])
        }
    }

    private func requestPermission(prompt: Bool) {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [promptKey: prompt] as CFDictionary
        trusted = AXIsProcessTrustedWithOptions(options)
        emit(["type": "permission", "trusted": trusted])
        if trusted {
            installTap()
        } else {
            schedulePermissionPoll()
        }
    }

    private func schedulePermissionPoll() {
        guard permissionTimer == nil else { return }
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            if AXIsProcessTrusted() {
                self.trusted = true
                self.permissionTimer?.invalidate()
                self.permissionTimer = nil
                emit(["type": "permission", "trusted": true])
                self.installTap()
            }
        }
        if let timer = permissionTimer {
            RunLoop.current.add(timer, forMode: .common)
        }
    }

    private func installTap() {
        guard !tapInstalled else { return }

        let mask =
            (1 << CGEventType.mouseMoved.rawValue) |
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.leftMouseUp.rawValue) |
            (1 << CGEventType.leftMouseDragged.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue) |
            (1 << CGEventType.rightMouseUp.rawValue) |
            (1 << CGEventType.rightMouseDragged.rawValue) |
            (1 << CGEventType.otherMouseDown.rawValue) |
            (1 << CGEventType.otherMouseUp.rawValue) |
            (1 << CGEventType.otherMouseDragged.rawValue) |
            (1 << CGEventType.scrollWheel.rawValue) |
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)

        guard let created = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            emit(["type": "error", "code": "tap-failed", "message": "Cannot create the global event tap. Grant Accessibility permission and restart."])
            return
        }

        tap = created
        tapInstalled = true
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: created, enable: true)
        emit(["type": "ready", "trusted": true, "hotkey": HOTKEY_LABEL])
    }

    private func emitStatus() {
        stateLock.lock()
        let snapshot = (active, trusted, tapInstalled)
        stateLock.unlock()
        emit([
            "type": "status",
            "active": snapshot.0,
            "trusted": snapshot.1,
            "tapInstalled": snapshot.2,
            "hotkey": HOTKEY_LABEL,
            "edgeMode": edgeMode,
            "hiddenDisplays": hiddenDisplays.count,
            "clipboard": clipboardEnabled,
            "remoteTracked": remoteValid || remoteBoundsValid,
            "returnArmed": returnArmed,
            "clipboardTextLimit": clipboard.textLimit,
            "clipboardImageLimit": clipboard.imageLimit,
            "clipboardFileLimit": clipboard.fileLimit,
        ])
    }

    private func currentActive() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return active
    }

    func setActive(_ value: Bool) {
        if value && !tapInstalled {
            emit(["type": "error", "code": "not-ready", "message": "Accessibility permission is not ready yet."])
            return
        }
        stateLock.lock()
        if active == value {
            stateLock.unlock()
            return
        }
        active = value
        stateLock.unlock()

        if value {
            edgeArmed = false
            returnArmed = false
            remoteValid = false
            heldModifierCodes.removeAll()
            sentModifiers.removeAll()
            activateForCursorHiding()
            hideCursor()
        } else {
            edgeArmed = false
            returnArmed = false
            remoteValid = false
            edgeCooldownUntil = CFAbsoluteTimeGetCurrent() + 0.35
            for button in pressedButtons.sorted() {
                emit(["type": "mouse", "kind": "up", "button": button])
            }
            pressedButtons.removeAll()
            keyCheckTimer?.invalidate()
            keyCheckTimer = nil
            hardwareKeys.removeAll()
            for vk in Set(heldKeys.values).sorted() {
                emit(["type": "key", "vk": vk, "down": false])
            }
            heldKeys.removeAll()
            flushSentModifierUps()
            heldModifierCodes.removeAll()
            showCursor()
            restorePreviousApp()
        }
        emit(["type": "active", "active": value])
        if value { syncModifiers(CGEventSource.flagsState(.combinedSessionState)) }
        emitStatus()
    }

    private func activateForCursorHiding() {
        if previousApp == nil {
            previousApp = NSWorkspace.shared.frontmostApplication
        }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid() {
            return
        }
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
        NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps])
    }

    private func restorePreviousApp() {
        guard let app = previousApp else { return }
        previousApp = nil
        if app.processIdentifier != getpid() {
            app.activate(options: [.activateIgnoringOtherApps])
        }
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    private func hideCursor() {
        guard hiddenDisplays.isEmpty else { return }

        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        if count > 0 {
            CGGetActiveDisplayList(count, &displays, &count)
            for display in displays.prefix(Int(count)) {
                if CGDisplayHideCursor(display) == .success {
                    hiddenDisplays.append(display)
                }
            }
        }
        if hiddenDisplays.isEmpty {
            CGDisplayHideCursor(CGMainDisplayID())
            hiddenDisplays.append(CGMainDisplayID())
        }
        if !nsCursorHidden {
            NSCursor.hide()
            nsCursorHidden = true
        }
    }

    private func showCursor() {
        for display in hiddenDisplays {
            CGDisplayShowCursor(display)
        }
        hiddenDisplays.removeAll()
        if nsCursorHidden {
            NSCursor.unhide()
            nsCursorHidden = false
        }
    }

    private func flushSentModifierUps() {
        for vk in sentModifiers {
            emit(["type": "key", "vk": vk, "down": false])
        }
        sentModifiers.removeAll()
    }

    /// Reconcile the flags on each shortcut as well as flagsChanged. A modifier
    /// may already be held on entry, and two Mac keys can own the same Windows Ctrl.
    private func syncModifiers(_ flags: CGEventFlags, changed: Int64? = nil, directDown: Bool? = nil) {
        var physical = Set<Int64>()
        var wanted = Set<Int>()
        for pair in modifierPairs {
            let sides = [pair.left, pair.right]
            let hasSideFlags = flags.rawValue & (pair.left.mask | pair.right.mask) != 0
            let hasAggregate = flags.contains(pair.flag)
            let knownSide = sides.contains { heldModifierCodes.contains($0.code) }
            for side in sides {
                let held: Bool
                if let directDown, sides.contains(where: { $0.code == changed }) {
                    held = side.code == changed ? directDown : heldModifierCodes.contains(side.code)
                } else if hasSideFlags {
                    held = flags.rawValue & side.mask != 0
                } else if hasAggregate {
                    if changed == pair.left.code || changed == pair.right.code {
                        if side.code == changed && sides.allSatisfy({ heldModifierCodes.contains($0.code) }) {
                            held = CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(side.code))
                        } else {
                            held = side.code == changed || heldModifierCodes.contains(side.code)
                        }
                    } else {
                        held = knownSide ? heldModifierCodes.contains(side.code) : side.code == pair.left.code
                    }
                } else {
                    held = false
                }
                if held { physical.insert(side.code); wanted.insert(side.vk) }
            }
        }
        for vk in sentModifiers.subtracting(wanted).sorted() {
            emit(["type": "key", "vk": vk, "down": false])
        }
        for vk in wanted.subtracting(sentModifiers).sorted() {
            emit(["type": "key", "vk": vk, "down": true])
        }
        heldModifierCodes = physical
        sentModifiers = wanted
    }

    private func handleKey(event: CGEvent, down: Bool) {
        let keycode = event.getIntegerValueField(.keyboardEventKeycode)
        if keycode == 63 { return } // Fn
        if modifierPairs.contains(where: { $0.left.code == keycode || $0.right.code == keycode }) {
            syncModifiers(event.flags, changed: keycode, directDown: down)
            return
        }
        syncModifiers(event.flags)
        guard let vk = keyVK(keycode) else { return }
        let code = CGKeyCode(keycode)
        guard down else {
            releaseKey(code)
            return
        }
        let repeating = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        if repeating && heldKeys[code] == nil && !hardwareKeyDown(code) { return }
        // A fresh press of an already-held physical key implies a missed release.
        if !repeating && hardwareKeys.contains(code) { releaseKey(code) }
        heldKeys[code] = vk
        emit(["type": "key", "vk": vk, "down": true])
        if !hardwareKeys.contains(code) && hardwareKeyDown(code) {
            hardwareKeys.insert(code)
            if keyCheckTimer == nil {
                let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in self?.checkKeyReleases() }
                RunLoop.main.add(timer, forMode: .common)
                keyCheckTimer = timer
            }
        }
    }

    private func releaseKey(_ code: CGKeyCode) {
        guard let vk = heldKeys.removeValue(forKey: code) else { return }
        hardwareKeys.remove(code)
        if hardwareKeys.isEmpty {
            keyCheckTimer?.invalidate()
            keyCheckTimer = nil
        }
        // Return and keypad Enter, for example, share one Windows virtual key.
        if !heldKeys.values.contains(vk) {
            emit(["type": "key", "vk": vk, "down": false])
        }
    }

    private func checkKeyReleases() {
        // Only consult HID for keys actually observed down there. Remapped or
        // software-generated keys may have no corresponding hardware state.
        for code in hardwareKeys where !hardwareKeyDown(code) {
            releaseKey(code)
        }
    }

    private func setClipboardEnabled(_ enabled: Bool) {
        clipboardEnabled = enabled
        if enabled {
            lastClipboardChangeCount = clipboard.changeCount
            guard clipboardTimer == nil else { return }
            let timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                self?.pollClipboard()
            }
            RunLoop.current.add(timer, forMode: .common)
            clipboardTimer = timer
        } else {
            clipboardTimer?.invalidate()
            clipboardTimer = nil
        }
    }

    private func pollClipboard() {
        guard clipboardEnabled else { return }
        let count = clipboard.changeCount
        guard count != lastClipboardChangeCount else { return }
        lastClipboardChangeCount = count
        if let event = clipboard.read(), clipboard.changeCount == count { emit(event) }
    }

    private func writeClipboard(_ command: [String: Any]) {
        do {
            if try clipboard.write(command, ifUnchangedSince: clipboard.changeCount) {
                lastClipboardChangeCount = clipboard.changeCount
            }
        } catch {
            emit(["type": "error", "code": "clipboard", "message": error.localizedDescription])
        }
    }

    private func setEdgeMode(_ mode: String) {
        guard ["right", "left", "both", "off"].contains(mode) else { return }
        edgeMode = mode
        pinnedSide = nil
        pinnedSince = 0
        emit(["type": "edgeMode", "mode": mode])
    }

    private func updateRemoteCursor(_ command: [String: Any]) {
        if command["width"] != nil { updateRemoteBounds(command) }
        guard remoteBoundsValid, let x = doubleValue(command["x"]),
              let y = doubleValue(command["y"]) else { return }
        remoteX = x
        remoteY = y
        remoteEstimateX = x
        remoteEstimateY = y
        remoteValid = true
        cursorReportTime = ProcessInfo.processInfo.systemUptime
    }

    private func updateRemoteBounds(_ command: [String: Any]) {
        guard let left = doubleValue(command["left"]),
              let top = doubleValue(command["top"]),
              let width = doubleValue(command["width"]),
              let height = doubleValue(command["height"]),
              width > 0, height > 0 else {
            remoteBoundsValid = false
            return
        }
        remoteLeft = left
        remoteTop = top
        remoteWidth = width
        remoteHeight = height
        remoteBoundsValid = true
    }

    /// Begin a local cursor track at the Windows edge the pointer entered.
    private func seedRemoteEstimate(ratio: Double) {
        guard remoteBoundsValid else { return }
        remoteEstimateX = entrySide == "right" ? remoteLeft : remoteLeft + remoteWidth
        remoteEstimateY = remoteTop + ratio * remoteHeight
    }

    private func advanceRemoteEstimate(dx: Double, dy: Double) {
        guard remoteBoundsValid else { return }
        remoteEstimateX = min(max(remoteEstimateX + dx, remoteLeft), remoteLeft + remoteWidth)
        remoteEstimateY = min(max(remoteEstimateY + dy, remoteTop), remoteTop + remoteHeight)
    }

    /// Windows cursor X to test for an outward crossing, preferring the real
    /// reported position and falling back to the local estimate.
    private func returnProbeX() -> Double? {
        if remoteValid && ProcessInfo.processInfo.systemUptime - cursorReportTime < 0.12 { return remoteX }
        if remoteBoundsValid { return remoteEstimateX }
        return nil
    }

    private func returnProbeY() -> Double? {
        if remoteValid && ProcessInfo.processInfo.systemUptime - cursorReportTime < 0.12 { return remoteY }
        if remoteBoundsValid { return remoteEstimateY }
        return nil
    }

    /// Distance from the Windows edge the pointer entered through.
    private func distanceFromEntryEdge() -> Double? {
        guard remoteBoundsValid, let x = returnProbeX() else { return nil }
        return entrySide == "right" ? x - remoteLeft : (remoteLeft + remoteWidth) - x
    }

    /// Enables returning once the pointer is clear of the entry edge.
    private func updateReturnArming() {
        guard edgeArmed, !returnArmed, pressedButtons.isEmpty else { return }
        guard CFAbsoluteTimeGetCurrent() - edgeEnteredAt >= returnArmDelay else { return }
        guard let distance = distanceFromEntryEdge() else { return }
        if distance >= returnArmDistance {
            returnArmed = true
        }
    }

    /// Any JSON number (Int, Double or NSNumber) as a Double.
    private func numberValue(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let number = value as? Double { return number }
        if let number = value as? Int { return Double(number) }
        return nil
    }

    private func doubleValue(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let number = value as? Double { return number }
        if let number = value as? Int { return Double(number) }
        return nil
    }

    private func hasAdjacentScreen(_ screen: NSScreen, side: String) -> Bool {
        for other in NSScreen.screens where other !== screen {
            let overlap = min(screen.frame.maxY, other.frame.maxY) - max(screen.frame.minY, other.frame.minY)
            if overlap <= 1 { continue }
            if side == "right" && other.frame.minX >= screen.frame.maxX - 1 { return true }
            if side == "left" && other.frame.maxX <= screen.frame.minX + 1 { return true }
        }
        return false
    }

    /// Returns the side and top-down vertical ratio when the pointer crosses
    /// the configured Mac edge outward.
    private func edgeExit(event: CGEvent) -> (side: String, screen: NSScreen, ratio: Double)? {
        if edgeMode == "off" { return nil }
        let now = CFAbsoluteTimeGetCurrent()
        if now < edgeCooldownUntil { return nil }

        let point = event.location
        let mainHeight = NSScreen.main?.frame.maxY ?? NSScreen.screens.first?.frame.maxY ?? 0
        let nsPoint = NSPoint(x: point.x, y: mainHeight - point.y)
        guard let screen = NSScreen.screens.first(where: {
            $0.frame.insetBy(dx: -1, dy: -1).contains(nsPoint)
        }) else {
            pinnedSide = nil
            pinnedSince = 0
            return nil
        }
        let frame = screen.frame
        let deltaX = event.getIntegerValueField(.mouseEventDeltaX)
        let wantsRight = edgeMode == "right" || edgeMode == "both"
        let wantsLeft = edgeMode == "left" || edgeMode == "both"

        var side: String?
        if wantsRight, point.x >= frame.maxX - 2, !hasAdjacentScreen(screen, side: "right") {
            // An outward delta is the unambiguous signal. When the pointer is
            // already pinned on the last pixel the system can report a zero
            // delta, so also accept a short dwell there: a move event exists at
            // all only because the pointing device moved, and the boundary is
            // what stopped it.
            if deltaX > 0 || (pinnedSide == "right" && now - pinnedSince >= 0.06) {
                side = "right"
            } else if pinnedSide != "right" {
                pinnedSide = "right"
                pinnedSince = now
            }
        } else if wantsLeft, point.x <= frame.minX + 2, !hasAdjacentScreen(screen, side: "left") {
            if deltaX < 0 || (pinnedSide == "left" && now - pinnedSince >= 0.06) {
                side = "left"
            } else if pinnedSide != "left" {
                pinnedSide = "left"
                pinnedSince = now
            }
        } else if deltaX != 0 {
            pinnedSide = nil
            pinnedSince = 0
        }

        guard let side else { return nil }
        pinnedSide = nil
        pinnedSince = 0
        let ratio = Double(max(0, min(1, 1 - ((nsPoint.y - frame.minY) / max(frame.height, 1)))))
        return (side: side, screen: screen, ratio: ratio)
    }

    private func beginEdge(side: String, screen: NSScreen, ratio: Double) -> Bool {
        guard tapInstalled, !currentActive() else { return false }
        entrySide = side
        entryScreenFrame = screen.frame
        setActive(true)
        edgeArmed = true
        returnArmed = false
        edgeEnteredAt = CFAbsoluteTimeGetCurrent()
        remoteValid = false
        seedRemoteEstimate(ratio: ratio)
        emit(["type": "edgeEnter", "side": side, "ratio": ratio])
        return true
    }

    private func shouldReturnOnEdge(deltaX: Double) -> Bool {
        guard !lockReturn, pressedButtons.isEmpty, edgeArmed, returnArmed, deltaX != 0, let x = returnProbeX() else { return false }
        let returnsAtLeft = edgeMode == "right" || (edgeMode == "both" && entrySide == "right")
        if returnsAtLeft && x <= remoteLeft + 2 && deltaX < 0 {
            return true
        }
        let returnsAtRight = edgeMode == "left" || (edgeMode == "both" && entrySide == "left")
        if returnsAtRight && x >= remoteLeft + remoteWidth - 3 && deltaX > 0 {
            return true
        }
        return false
    }

    /// Unconditional way back to the Mac, used by the shortcut, the panel
    /// button, and the Host when Windows stops answering.
    private func forceReturn() {
        if edgeArmed {
            returnArmed = true
            returnToMac()
            return
        }
        edgeCooldownUntil = CFAbsoluteTimeGetCurrent() + 0.35
        setActive(false)
    }

    private func returnToMac() {
        guard edgeArmed else { return }
        returnArmed = false
        let frame = entryScreenFrame.width > 0
            ? entryScreenFrame
            : (NSScreen.main?.frame ?? CGRect.zero)
        guard frame.width > 0, frame.height > 0 else {
            setActive(false)
            return
        }
        let ratio = returnProbeY().map { max(0, min(1, ($0 - remoteTop) / max(remoteHeight, 1))) } ?? 0.5
        let macYBottom = frame.minY + (1 - ratio) * frame.height
        let mainHeight = NSScreen.main?.frame.maxY ?? frame.maxY
        let macX = entrySide == "right" ? frame.maxX - 4 : frame.minX + 4
        CGWarpMouseCursorPosition(CGPoint(x: macX, y: mainHeight - macYBottom))
        edgeArmed = false
        remoteValid = false
        edgeCooldownUntil = CFAbsoluteTimeGetCurrent() + 0.35
        setActive(false)
    }

    private func handleMouse(event: CGEvent, type: CGEventType) {
        switch type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            syncModifiers(event.flags)
            let button = type == .leftMouseDown ? "left" : type == .rightMouseDown ? "right" : "middle"
            pressedButtons.insert(button)
            emit(["type": "mouse", "kind": "down", "button": button])
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            let button = type == .leftMouseUp ? "left" : type == .rightMouseUp ? "right" : "middle"
            pressedButtons.remove(button)
            if pressedButtons.isEmpty {
                // A game can warp the desktop cursor to an edge while looking around.
                returnArmed = false
                edgeEnteredAt = CFAbsoluteTimeGetCurrent()
            }
            emit(["type": "mouse", "kind": "up", "button": button])
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            let dx = event.getIntegerValueField(.mouseEventDeltaX)
            let dy = event.getIntegerValueField(.mouseEventDeltaY)
            if type == .mouseMoved && shouldReturnOnEdge(deltaX: Double(dx)) {
                returnToMac()
                return
            }
            if dx != 0 || dy != 0 {
                advanceRemoteEstimate(dx: Double(dx), dy: Double(dy))
                updateReturnArming()
                emit(["type": "mouse", "kind": "move", "dx": Int(dx), "dy": Int(dy)])
            }
        case .scrollWheel:
            syncModifiers(event.flags)
            let vertical = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
            let horizontal = event.getIntegerValueField(.scrollWheelEventDeltaAxis2)
            if vertical != 0 {
                emit(["type": "wheel", "delta": Int(vertical) * 120, "horizontal": false])
            }
            if horizontal != 0 {
                emit(["type": "wheel", "delta": Int(horizontal) * 120, "horizontal": true])
            }
        default:
            break
        }
    }

    private func isHotkey(event: CGEvent) -> Bool {
        let keycode = event.getIntegerValueField(.keyboardEventKeycode)
        guard keycode == HOTKEY_KEYCODE else { return false }
        let required: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand]
        return event.flags.intersection(required) == required
    }

    func handleTap(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            checkKeyReleases()
            return Unmanaged.passUnretained(event)
        }


        let keycode = event.getIntegerValueField(.keyboardEventKeycode)

        if hotkeyHeld {
            if type == .keyUp && keycode == HOTKEY_KEYCODE {
                hotkeyHeld = false
            }
            return nil
        }

        guard currentActive() else {
            if type == .mouseMoved {
                if let edge = edgeExit(event: event), beginEdge(side: edge.side, screen: edge.screen, ratio: edge.ratio) {
                    return nil
                }
            }
            return Unmanaged.passUnretained(event)
        }

        if type == .keyDown && isHotkey(event: event) {
            hotkeyHeld = true
            if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                forceReturn()
            }
            return nil
        }

        switch type {
        case .keyDown:
            handleKey(event: event, down: true)
        case .keyUp:
            handleKey(event: event, down: false)
        case .flagsChanged:
            let keycode = event.getIntegerValueField(.keyboardEventKeycode)
            syncModifiers(event.flags, changed: keycode)
            if keycode == 57 {
                emit(["type": "key", "vk": 20, "down": true])
                emit(["type": "key", "vk": 20, "down": false])
            }
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
             .otherMouseDown, .otherMouseUp, .mouseMoved, .leftMouseDragged,
             .rightMouseDragged, .otherMouseDragged, .scrollWheel:
            handleMouse(event: event, type: type)
        default:
            break
        }
        return nil
    }
}

private func eventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let helper = Unmanaged<KvmHelper>.fromOpaque(refcon).takeUnretainedValue()
    return helper.handleTap(type: type, event: event)
}

/// Pasteboard codec shared by the standalone clipboard worker and the DSH helper.
final class MacClipboard {
    private let board: NSPasteboard
    var textLimit = 32 * 1024 * 1024
    var imageLimit = 64 * 1024 * 1024
    var fileLimit = 128 * 1024 * 1024
    var changeCount: Int { board.changeCount }

    init(board: NSPasteboard = .general) { self.board = board }

    private func skipped(_ kind: String, _ bytes: Int, _ limit: Int) -> [String: Any] {
        ["type": "clipboardSkipped", "kind": kind, "bytes": bytes, "limit": limit]
    }

    var supportsFolders = false
    private let maxFileEntries = 10000

    private enum FileCopyError: String, LocalizedError {
        case unsupported = "请同时更新两端以复制文件夹"
        case link = "此选择包含链接或不支持的文件类型"
        case name = "目标系统无法保留此文件名或同目录下的同名项目"
        case limit = "文件总大小或项目数量超过传输上限"
        case invalid = "文件夹目录信息无效"
        var errorDescription: String? { rawValue }
    }

    private static let invalidNameCharacters = CharacterSet(charactersIn: "/\\:*?\"<>|").union(CharacterSet(charactersIn: Unicode.Scalar(0)!...Unicode.Scalar(31)!))
    static func validFileName(_ name: String) -> Bool {
        var stem = name.components(separatedBy: ".")[0].uppercased()
        while stem.last == " " { stem.removeLast() }
        return !name.isEmpty && !name.hasSuffix(".") && !name.hasSuffix(" ")
            && name.rangeOfCharacter(from: Self.invalidNameCharacters) == nil
            && !["CON", "PRN", "AUX", "NUL", "CONIN$", "CONOUT$"].contains(stem)
            && !(stem.count == 4 && (stem.hasPrefix("COM") || stem.hasPrefix("LPT"))
                 && "123456789¹²³".contains(stem.last!))
    }

    private func readFiles(_ sources: [(URL?, String, Data?)]) throws -> [String: Any] {
        let fm = FileManager.default
        var entries: [[String: Any]] = []
        var remaining = fileLimit
        var folders = false
        func append(_ source: URL?, _ name: String, _ supplied: Data?, parent: Int?) throws {
            guard entries.count < maxFileEntries else { throw FileCopyError.limit }
            guard Self.validFileName(name) else { throw FileCopyError.name }
            var entry: [String: Any] = ["name": name]
            if let parent { entry["parent"] = parent }
            if let url = source {
                let info = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey, .fileSizeKey])
                guard info.isSymbolicLink != true else { throw FileCopyError.link }
                if info.isDirectory == true {
                    guard supportsFolders else { throw FileCopyError.unsupported }
                    folders = true
                    entry["directory"] = true
                    let index = entries.count
                    entries.append(entry)
                    let children = try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
                    var names = Set<String>()
                    for child in children {
                        guard names.insert(child.lastPathComponent.uppercased()).inserted else { throw FileCopyError.name }
                        try append(child, child.lastPathComponent, nil, parent: index)
                    }
                    return
                }
                guard info.isRegularFile == true else { throw FileCopyError.link }
                guard let size = info.fileSize, size <= remaining else { throw FileCopyError.limit }
            }
            let bytes: Data
            if let supplied { bytes = supplied }
            else if let source { bytes = try Data(contentsOf: source, options: .mappedIfSafe) }
            else { throw FileCopyError.invalid }
            guard bytes.count <= remaining else { throw FileCopyError.limit }
            remaining -= bytes.count
            entry["data"] = bytes.base64EncodedString()
            entries.append(entry)
        }
        for (url, name, bytes) in sources { try append(url, name, bytes, parent: nil) }
        return ["type": "clipboard", "kind": folders ? "fileTree" : "files", "files": entries]
    }

    /// File URLs remain lazy. Multiple independent bitmap items are materialized
    /// one at a time because Windows exposes an image selection as a file list.
    func streamingSelection(in temp: URL) throws -> [URL]? {
        let items = board.pasteboardItems ?? []
        let ignored = ["org.nspasteboard.ConcealedType","org.nspasteboard.TransientType","org.nspasteboard.AutoGeneratedType"]
        if board.types?.contains(where: { ignored.contains($0.rawValue) }) == true ||
            items.contains(where: { $0.types.contains { ignored.contains($0.rawValue) } }) { return nil }
        let formats: [(NSPasteboard.PasteboardType,String)] = [(.png,"png"),(.init("public.jpeg"),"jpg"),(.tiff,"tiff")]
        if items.count > 1 && items.contains(where: { item in formats.contains { item.types.contains($0.0) } }) {
            var roots: [URL] = []
            for (index,item) in items.enumerated() {
                if let path = item.string(forType:.fileURL), let url = URL(string:path), url.isFileURL { roots.append(url) }
                else {
                    let url = try autoreleasepool { () throws -> URL in
                        guard let (format,ext) = formats.first(where:{item.types.contains($0.0)}),
                              let bytes = item.data(forType:format) else {throw FileCopyError.invalid}
                        try FileManager.default.createDirectory(at:temp,withIntermediateDirectories:true)
                        let url = temp.appendingPathComponent("Image-\(index + 1).\(ext)")
                        try bytes.write(to:url,options:.withoutOverwriting)
                        return url
                    }
                    roots.append(url)
                }
            }
            return roots
        }
        let urls = board.readObjects(forClasses:[NSURL.self],options:[.urlReadingFileURLsOnly:true]) as? [URL]
        return urls?.isEmpty == false ? urls : nil
    }

    func publishFiles(_ urls: [URL], ifUnchangedSince expected: Int) throws -> Bool {
        guard changeCount == expected else { return false }
        board.clearContents()
        guard board.writeObjects(urls as [NSURL]) else {throw FileCopyError.invalid}
        return true
    }

    func read() -> [String: Any]? {
        let ignored = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType",
                       "org.nspasteboard.AutoGeneratedType"]
        if board.types?.contains(where: { ignored.contains($0.rawValue) }) == true { return nil }

        do {
            let items = board.pasteboardItems ?? []
            if items.contains(where: { $0.types.contains { ignored.contains($0.rawValue) } }) { return nil }
            let formats: [(NSPasteboard.PasteboardType, String)] = [(.png,"png"), (.init("public.jpeg"),"jpg"), (.tiff,"tiff")]
            if items.count > 1 && items.contains(where: { item in formats.contains { item.types.contains($0.0) } }) {
                guard items.count <= maxFileEntries else { throw FileCopyError.limit }
                var sources: [(URL?, String, Data?)] = []
                var remaining = fileLimit
                for (index, item) in items.enumerated() {
                    if let path = item.string(forType: .fileURL), let url = URL(string: path), url.isFileURL {
                        sources.append((url, url.lastPathComponent, nil))
                    } else if let (type, ext) = formats.first(where: { item.types.contains($0.0) }),
                              let bytes = item.data(forType: type) {
                        guard bytes.count <= remaining else { throw FileCopyError.limit }
                        remaining -= bytes.count
                        sources.append((nil, "Image-\(index + 1).\(ext)", bytes))
                    } else { throw FileCopyError.invalid }
                }
                return try readFiles(sources)
            }
            let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
            if let urls = board.readObjects(forClasses: [NSURL.self], options: options) as? [URL], !urls.isEmpty {
                return try readFiles(urls.map { ($0, $0.lastPathComponent, nil) })
            }
        } catch {
            let reason = (error as? FileCopyError)?.rawValue ?? error.localizedDescription
            return ["type": "clipboardSkipped", "kind": "files", "reason": reason]
        }

        let png = board.data(forType: .png) ?? board.data(forType: .tiff).flatMap {
            NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:])
        }
        if let png {
            if png.count > imageLimit { return skipped("image", png.count, imageLimit) }
            return ["type": "clipboard", "kind": "image", "image": png.base64EncodedString()]
        }
        guard let text = board.string(forType: .string), !text.isEmpty else { return nil }
        if text.utf8.count > textLimit { return skipped("text", text.utf8.count, textLimit) }
        return ["type": "clipboard", "kind": "text", "text": text]
    }

    /// Stage the entire item before replacing the pasteboard. A more recent local copy wins.
    func write(_ item: [String: Any], ifUnchangedSince expected: Int) throws -> Bool {
        guard changeCount == expected else { return false }
        let kind = item["kind"] as? String
        let invalid = NSError(domain: "LanKvm.Clipboard", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "剪贴板内容无效或超过大小限制"])
        let busy = NSError(domain: "LanKvm.Clipboard", code: 2,
                           userInfo: [NSLocalizedDescriptionKey: "无法写入 Mac 剪贴板"])
        if kind == "files" || kind == "fileTree" {
            guard let files = item["files"] as? [[String: Any]], !files.isEmpty,
                  files.count <= maxFileEntries else { throw invalid }
            let fm = FileManager.default
            let dir = fm.temporaryDirectory.appendingPathComponent("dsh-lan-kvm-paste")
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            var published = false
            defer { if !published { try? fm.removeItem(at: dir) } }
            var roots: [URL] = []
            var directories: [Int: URL] = [:]
            var remaining = fileLimit
            for (index, entry) in files.enumerated() {
                guard let name = entry["name"] as? String, Self.validFileName(name) else { throw FileCopyError.name }
                let parent: URL
                let isRoot = entry["parent"] == nil
                if isRoot {
                    parent = dir.appendingPathComponent(String(index), isDirectory: true)
                    try fm.createDirectory(at: parent, withIntermediateDirectories: false)
                } else {
                    guard kind == "fileTree", let i = entry["parent"] as? Int, let folder = directories[i] else { throw invalid }
                    parent = folder
                }
                let url = parent.appendingPathComponent(name)
                if entry["directory"] as? Bool == true {
                    guard kind == "fileTree", entry["data"] == nil, !fm.fileExists(atPath: url.path) else { throw invalid }
                    try fm.createDirectory(at: url, withIntermediateDirectories: false)
                    directories[index] = url
                } else {
                    guard let encoded = entry["data"] as? String,
                          encoded.utf8.count <= (remaining + 2) / 3 * 4,
                          let bytes = Data(base64Encoded: encoded), bytes.count <= remaining else { throw invalid }
                    try bytes.write(to: url, options: .withoutOverwriting)
                    remaining -= bytes.count
                }
                if isRoot { roots.append(url) }
            }
            guard changeCount == expected else { return false }
            board.clearContents()
            guard board.writeObjects(roots as [NSURL]) else { throw busy }
            published = true
            return true
        }
        if kind == "text", let text = item["text"] as? String, text.utf8.count <= textLimit {
            guard changeCount == expected else { return false }
            board.clearContents()
            guard board.setString(text, forType: .string) else { throw busy }
            return true
        }
        if kind == "image", let encoded = item["image"] as? String,
           encoded.utf8.count <= ((imageLimit + 2) / 3) * 4,
           let png = Data(base64Encoded: encoded), png.count <= imageLimit {
            guard changeCount == expected else { return false }
            board.clearContents()
            guard board.setData(png, forType: .png) else { throw busy }
            return true
        }
        throw invalid
    }
}

// MARK: - Entry point

#if LANKVM_STANDALONE
if CommandLine.arguments.contains("--clipboard-worker") {
    ClipboardWorker.run()
}
#endif
let helper = KvmHelper()
helper.run()
