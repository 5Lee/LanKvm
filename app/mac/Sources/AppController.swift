import AppKit
import ApplicationServices
import Foundation

/// The Mac side of LanKvm.
///
/// Owns the input helper subprocess, relays its events to the Windows receiver,
/// and provides the menu bar interface. This is the standalone counterpart of
/// the DSH plugin: same helper, no DSH required.
@MainActor
final class AppController: NSObject {
    static let shared = AppController()

    private var client = WindowsClient()
    private var httpInput: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var heartbeat: Timer?
    private var nextStreamAttempt = 0.0
    private var retryDelay: UInt64 = 2
    private var sentKeys = Set<Int>()
    private var sentButtons = Set<String>()
    private let helperWriter = DispatchQueue(label: "lankvm.helper.commands")
    private var lockReturn = UserDefaults.standard.bool(forKey: "gameLock")
    private var reverseWindowsWheel = (UserDefaults.standard.object(forKey: "reverseWindowsWheel") as? Bool) ?? true
    private var diagnostics: DiagnosticLog?
    private var helper: Process?
    private var helperBuffer = Data()
    private var helperReady = false
    private var restartScheduled = false
    private var trustWatch: Timer?
    private var permissionAlertShown = false

    private var statusItem: NSStatusItem?
    private var menu: NSMenu?
    private var settingsWindow: SettingsWindow?

    // Connection state
    private(set) var target: LanKvmTarget?
    private(set) var connected = false
    private(set) var connecting = false
    private(set) var lastError = ""
    private(set) var streamUp = false
    private(set) var edgeMode = "right"
    private(set) var clipboardEnabled = (UserDefaults.standard.object(forKey: "syncClipboard") as? Bool) ?? true
    private(set) var active = false
    private(set) var trusted = false

    // Input batching
    private var inputQueue: [[String: Any]] = []
    private var rightButtonDown = false
    private var flushScheduled = false
    private let flushInterval: TimeInterval = 0.004
    private let maxBatchEvents = 256
    private let maxQueuedEvents = 1200

    private var clipboardProcess: Process?
    private var clipboardError = ""
    private var acknowledgedClipboard: Int?
    private var skippedClipboard: Int?
    private var discardPasteKeyUp = false
    private var shortcutModifiers = Set<Int>()
    private let pasteboard = NSPasteboard.general

    private let supportDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("LanKvm", isDirectory: true)
    }()

    var helperBinary: URL {
        supportDirectory.appendingPathComponent("bin/lankvm-helper")
    }

    /// Whether macOS trusts this app for Accessibility.
    ///
    /// The input helper is a child process, so macOS attributes its trust to
    /// this app (the responsible process). The permission must therefore be
    /// requested and held by the app, not only by the helper binary.
    private(set) var appTrusted = false

    /// Asks macOS for Accessibility access, showing the system prompt once.
    /// Returns whether access is already granted.
    @discardableResult
    func ensureAccessibilityPermission(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: prompt] as CFDictionary
        appTrusted = AXIsProcessTrustedWithOptions(options)
        diagnostics?.record("app.trust \(appTrusted)")
        return appTrusted
    }

    // MARK: - Lifecycle

    func start() {
        diagnostics = DiagnosticLog()
        diagnostics?.start()
        signal(SIGPIPE, SIG_IGN)
        buildMenu()
        // The child helper inherits this grant, so it must be requested here.
        ensureAccessibilityPermission(prompt: true)
        if !appTrusted {
            // Watch continuously: the user may grant it directly in System
            // Settings without coming back through the menu.
            startTrustWatch()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
                self?.showPermissionAlert()
            }
        }
        ensureHelper()
        // Reconnect to the last receiver automatically.
        if let saved = Settings.loadTarget() {
            Task { await connect(to: saved, announce: false, retry: true) }
        }
    }

    func shutdown() {
        disconnect()
        if let helper, helper.isRunning {
            sendHelper(["action": "deactivate"])
            sendHelper(["action": "quit"])
            let deadline = Date().addingTimeInterval(1.5)
            while helper.isRunning && Date() < deadline {
                usleep(50_000)
            }
            if helper.isRunning { helper.terminate() }
        }
        helper = nil
    }

    // MARK: - Helper process

    /// Installs the helper next to the app on first run, then launches it.
    func ensureHelper() {
        do {
            try installHelperIfNeeded()
        } catch {
            lastError = "Could not install the input helper: \(error.localizedDescription)"
            refreshMenu()
            return
        }
        launchHelper()
    }

    /// Copies the helper bundled in the app to Application Support.
    ///
    /// The path must stay stable: macOS keys the Accessibility grant to the
    /// binary path, so running it from inside the app bundle would lose the
    /// permission on every rebuild or update.
    private func installHelperIfNeeded() throws {
        let fileManager = FileManager.default
        let binDirectory = helperBinary.deletingLastPathComponent()
        try fileManager.createDirectory(at: binDirectory, withIntermediateDirectories: true)

        guard let bundled = Bundle.main.url(forResource: "lankvm-helper", withExtension: nil) else {
            // Running from a build directory: use the sibling build output.
            let sibling = URL(fileURLWithPath: CommandLine.arguments[0])
                .deletingLastPathComponent()
                .appendingPathComponent("lankvm-helper")
            if fileManager.fileExists(atPath: sibling.path) {
                try replace(sibling, with: helperBinary)
                return
            }
            throw LanKvmError.message("the helper binary is missing from the app bundle")
        }
        try replace(bundled, with: helperBinary)
    }

    private func replace(_ source: URL, with destination: URL) throws {
        let fileManager = FileManager.default
        if fileManager.contentsEqual(atPath: source.path, andPath: destination.path) { return }
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        try fileManager.copyItem(at: source, to: temporary)
        defer { try? fileManager.removeItem(at: temporary) }
        // Atomic rename preserves the bundled signature and the previous helper if installation fails.
        if rename(temporary.path, destination.path) != 0 {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    /// Restarts the helper so it can install its event tap. macOS only allows
    /// the tap once the Accessibility grant exists at launch time.
    private func restartHelperSoon() {
        guard restartScheduled == false else { return }
        restartScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.restartScheduled = false
            if self.helperReady && self.trusted { return }
            self.sendHelper(["action": "quit"])
            self.helper?.terminate()
            self.helper = nil
            self.helperReady = false
            self.launchHelper()
        }
    }

    private func launchHelper() {
        guard helper?.isRunning != true else { return }
        helperBuffer.removeAll()
        let process = Process()
        process.executableURL = helperBinary
        process.arguments = ["--no-prompt"]
        let output = Pipe()
        process.standardOutput = output
        process.standardInput = Pipe()
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            DispatchQueue.main.async {
                guard self?.helper === process else { return }
                self?.consumeHelperOutput(data)
            }
        }
        process.terminationHandler = { [weak self] _ in
            output.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                guard let self, self.helper === process else { return }
                self.helper = nil
                self.helperBuffer.removeAll()
                self.helperReady = false
                if self.connected { self.recoverConnection("输入助手已退出，正在恢复连接") }
                self.active = false
                self.refreshMenu()
            }
        }
        do {
            try process.run()
            helper = process
        } catch {
            lastError = "Could not start the input helper: \(error.localizedDescription)"
        }
        refreshMenu()
    }

    private func consumeHelperOutput(_ data: Data) {
        var searchFrom = helperBuffer.endIndex
        helperBuffer.append(data)
        while let newline = helperBuffer[searchFrom...].firstIndex(of: 0x0A) {
            let lineData = helperBuffer[helperBuffer.startIndex..<newline]
            helperBuffer.removeSubrange(helperBuffer.startIndex...newline)
            searchFrom = helperBuffer.startIndex
            handleHelperData(lineData)
        }
    }

    private func sendHelper(_ command: [String: Any]) {
        guard let helper, helper.isRunning, let pipe = helper.standardInput as? Pipe else { return }
        helperWriter.async {
            guard var data = try? JSONSerialization.data(withJSONObject: command) else { return }
            data.append(0x0A)
            try? pipe.fileHandleForWriting.write(contentsOf: data)
        }
    }

    private func handleHelperData(_ data: Data) {
        guard let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = message["type"] as? String else { return }

        switch type {
        case "permission":
            trusted = message["trusted"] as? Bool == true
            if !trusted {
                // Re-check the app itself: the helper reports the inherited
                // state, which only changes once this app is granted.
                // A tap can only be installed after permission exists, so the
                // helper is restarted as soon as the grant appears.
                appTrusted = AXIsProcessTrusted()
                diagnostics?.record("app.trust-recheck \(appTrusted)")
                if appTrusted { restartHelperSoon() }
            } else {
                appTrusted = true
            }
        case "ready":
            diagnostics?.record("helper.ready")
            helperReady = true
            trusted = message["trusted"] as? Bool == true
            sendHelper(["action": "lockReturn", "enabled": lockReturn])
            sendHelper(["action": "edge", "mode": connected ? edgeMode : "off"])
            if let screen = client.screen {
                sendHelper(["action": "screen", "left": screen.left, "top": screen.top,
                            "width": screen.width, "height": screen.height])
            }
            if connected, edgeMode == "off" { sendHelper(["action": "activate"]) }
        case "active":
            active = connected && message["active"] as? Bool == true
            if !active { clearCursorFeedback(); flushInput() }
        case "edgeEnter":
            let ratio = (message["ratio"] as? NSNumber)?.doubleValue ?? 0.5
            guard connected, let screen = client.screen else { return }
            let x = (message["side"] as? String) == "right" ? screen.left + 1 : screen.left + screen.width - 2
            inputQueue.append(["op": "move", "entrySide": message["side"] as? String ?? "right", "ratio": ratio, "x": x, "y": (screen.top + ratio * (screen.height - 1)).rounded()])
            flushSoon(immediately: true)
            return
        case "error":
            if (message["code"] as? String) != "not-ready" {
                lastError = message["message"] as? String ?? "Input helper error"
            }
        case "mouse", "key", "wheel":
            if connected && active { queueInput(message) }
            return
        default:
            return
        }
        refreshMenu()
    }

    // MARK: - Input

    private func queueInput(_ event: [String: Any]) {
        guard let type = event["type"] as? String else { return }
        if type == "mouse", (event["kind"] as? String) == "move" {
            let dx = (event["dx"] as? NSNumber)?.intValue ?? 0
            let dy = (event["dy"] as? NSNumber)?.intValue ?? 0
            if dx == 0 && dy == 0 { return }
            // Relative input can be accelerated by Windows per sample. Preserve
            // each right-drag delta and batch only its transport.
            if !rightButtonDown, var last = inputQueue.last, (last["op"] as? String) == "moveRel" {
                last["dx"] = ((last["dx"] as? Int) ?? 0) + dx
                last["dy"] = ((last["dy"] as? Int) ?? 0) + dy
                inputQueue[inputQueue.count - 1] = last
            } else {
                var move: [String: Any] = ["op": "moveRel", "dx": dx, "dy": dy]
                if lockReturn { move["gameDrag"] = true }
                inputQueue.append(move)
            }
        } else if type == "mouse" {
            let kind = (event["kind"] as? String) ?? ""
            guard kind == "down" || kind == "up" else { return }
            let button = (event["button"] as? String) ?? "left"
            if button == "right" { rightButtonDown = kind == "down" }
            inputQueue.append(["op": kind, "button": button])
        } else if type == "key" {
            let vk = (event["vk"] as? NSNumber)?.intValue ?? 0
            guard vk > 0, vk <= 255 else { return }
            let down = event["down"] as? Bool == true
            if [91, 92, 162, 163, 164, 165].contains(vk) {
                if down { shortcutModifiers.insert(vk) } else { shortcutModifiers.remove(vk) }
            }
            var key: [String: Any] = ["op": "key", "vk": vk, "down": down]
            if vk == 86, down, !shortcutModifiers.isDisjoint(with: [162, 163]),
               shortcutModifiers.isDisjoint(with: [91, 92, 164, 165]), clipboardProcess != nil {
                let change = pasteboard.changeCount
                if acknowledgedClipboard != change {
                    key["pasteChange"] = change
                    key["deadline"] = ProcessInfo.processInfo.systemUptime + 1.5
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.flushInput() }
                }
            }
            inputQueue.append(key)
        } else if type == "wheel" {
            let delta = max(-1200, min(1200, (event["delta"] as? NSNumber)?.intValue ?? 0))
            guard delta != 0 else { return }
            let horizontal = event["horizontal"] as? Bool == true
            inputQueue.append(["op": "wheel",
                               "delta": reverseWindowsWheel && !horizontal ? -delta : delta,
                               "horizontal": horizontal])
        } else {
            return
        }
        if inputQueue.count > maxQueuedEvents {
            recoverConnection("输入积压，已交还 Mac")
            return
        }
        flushSoon(immediately: inputQueue.count >= maxBatchEvents && httpInput == nil)
    }

    private func flushSoon(immediately: Bool = false) {
        if immediately {
            flushInput()
            return
        }
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + flushInterval) { [weak self] in
            self?.flushScheduled = false
            self?.flushInput()
        }
    }

    private func flushInput() {
        guard connected, httpInput == nil, !inputQueue.isEmpty else { return }
        // Only a paste racing an unfinished local copy waits. Preserve the order of
        // Ctrl, V and their releases. Never replay a stale paste after returning.
        var batch: [[String: Any]] = []
        var consumed = 0
        var vDown = sentKeys.contains(86)
        for var event in inputQueue.prefix(maxBatchEvents) {
            if let change = event.removeValue(forKey: "pasteChange") as? Int {
                let deadline = event.removeValue(forKey: "deadline") as? TimeInterval ?? 0
                if !active || clipboardProcess == nil || pasteboard.changeCount != change || skippedClipboard == change {
                    discardPasteKeyUp = !vDown
                    consumed += 1
                    continue
                }
                if acknowledgedClipboard != change {
                    // New pointer input must never wait behind a large file paste.
                    let pointerWaiting = inputQueue.contains { $0["op"] as? String == "moveRel" ||
                        $0["button"] != nil || $0["op"] as? String == "wheel" }
                    if !pointerWaiting && ProcessInfo.processInfo.systemUptime < deadline && inputQueue.count < maxQueuedEvents / 2 { break }
                    clipboardError = "剪贴板仍在同步，请再按一次粘贴"
                    refreshMenu()
                    discardPasteKeyUp = !vDown
                    consumed += 1
                    continue
                }
            }
            if event["vk"] as? Int == 86 {
                vDown = event["down"] as? Bool == true
                if !vDown && discardPasteKeyUp {
                    discardPasteKeyUp = false
                    consumed += 1
                    continue
                }
                discardPasteKeyUp = false
            }
            batch.append(event)
            consumed += 1
        }
        inputQueue.removeFirst(consumed)
        guard !batch.isEmpty else {
            if consumed > 0 && !inputQueue.isEmpty { flushSoon() }
            return
        }
        for event in batch {
            if let vk = event["vk"] as? Int {
                if event["down"] as? Bool == true { sentKeys.insert(vk) } else { sentKeys.remove(vk) }
            } else if let button = event["button"] as? String {
                if event["op"] as? String == "down" { sentButtons.insert(button) } else { sentButtons.remove(button) }
            }
        }
        dispatchInput(client.inputPayload(batch))
    }

    private func dispatchInput(_ payload: [String: Any]) {
        let session = client
        if session.sendInputStream(payload) {
            if !inputQueue.isEmpty { flushSoon() }
            return
        }
        httpInput = Task {
            do {
                let result = try await session.sendInputHTTP(payload)
                guard connected, client === session else { return }
                httpInput = nil
                if let x = result["x"] as? Double, let y = result["y"] as? Double {
                    reportCursor(x: x, y: y)
                }
                if !inputQueue.isEmpty { flushInput() }
            } catch {
                guard connected, client === session else { return }
                httpInput = nil
                recoverConnection(error.localizedDescription)
            }
        }
    }

    // MARK: - Connection

    func connect(to candidate: LanKvmTarget, announce: Bool = true, retry: Bool = false) async {
        guard !connecting else { return }
        if !retry { retryDelay = 2 }
        disconnect()
        let session = WindowsClient()
        client = session
        connecting = true
        target = candidate
        refreshMenu()
        do {
            let screen = try await session.probe(candidate)
            guard client === session else { return }
            connecting = false
            connected = true
            retryDelay = 2
            diagnostics?.record("receiver.connected")
            Settings.saveTarget(candidate)
            session.onSlowAcknowledgement = { [weak self] milliseconds in
                self?.diagnostics?.record("input.ack_wait_ms " + String(milliseconds))
            }
            session.onCursor = { [weak self] x, y in
                self?.reportCursor(x: x, y: y)
            }
            session.onStreamStateChange = { [weak self] up in
                guard let self else { return }
                self.streamUp = up
                if !up && self.connected {
                    self.recoverConnection("输入连接中断，已交还 Mac")
                } else { self.refreshMenu() }
            }
            if helper?.isRunning != true { ensureHelper() }
            sendHelper(["action": "screen", "left": screen.left, "top": screen.top,
                        "width": screen.width, "height": screen.height])
            sendHelper(["action": "edge", "mode": edgeMode])
            if edgeMode == "off" { sendHelper(["action": "activate"]) }
            session.openStream()
            startClipboardSync()
            nextStreamAttempt = ProcessInfo.processInfo.systemUptime + 5
            if session.supportsLease || candidate.streamPort > 0 {
                let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.checkInputLink() }
                }
                RunLoop.main.add(timer, forMode: .common)
                heartbeat = timer
            }
        } catch {
            guard client === session else { return }
            connecting = false
            if case LanKvmError.credentialsRejected = error {
                disconnect()
                lastError = error.localizedDescription
                if announce { presentError(lastError) }
            } else if retry {
                recoverConnection(error.localizedDescription)
            } else {
                disconnect()
                lastError = error.localizedDescription
                if announce { presentError(lastError) }
            }
        }
        refreshMenu()
    }

    private var lastCursorTime = -Double.infinity
    private var pendingCursor: (Double, Double)?
    private var cursorDelivery: DispatchWorkItem?

    private func clearCursorFeedback() {
        cursorDelivery?.cancel()
        cursorDelivery = nil
        pendingCursor = nil
        lastCursorTime = -Double.infinity
    }

    private func deliverCursor() {
        cursorDelivery = nil
        guard let (x, y) = pendingCursor, active else { return }
        pendingCursor = nil
        lastCursorTime = ProcessInfo.processInfo.systemUptime
        sendHelper(["action": "cursor", "x": x, "y": y])
    }

    private func reportCursor(x: Double, y: Double) {
        guard active else { return }
        pendingCursor = (x, y)
        guard cursorDelivery == nil else { return }
        let delay = lastCursorTime + 1.0 / 60.0 - ProcessInfo.processInfo.systemUptime
        if delay <= 0 {
            deliverCursor()
        } else {
            let work = DispatchWorkItem { [weak self] in self?.deliverCursor() }
            cursorDelivery = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    private func checkInputLink() {
        guard connected else { return }
        if client.streamTimedOut {
            recoverConnection("Windows 输入连接超时，已交还 Mac")
            return
        }
        guard httpInput == nil, inputQueue.isEmpty else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if !client.streamReady, target?.streamPort != 0, now >= nextStreamAttempt {
            nextStreamAttempt = now + 5
            client.openStream()
        }
        if client.supportsLease { dispatchInput(["op": "keepalive", "session": client.sessionID]) }
    }

    private func recoverConnection(_ message: String) {
        guard let previousTarget = target else { return }
        diagnostics?.record("receiver.retry")
        disconnect()
        lastError = message
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, 30)
        reconnectTask = Task {
            do { try await Task.sleep(nanoseconds: delay * 1_000_000_000) } catch { return }
            reconnectTask = nil
            await connect(to: previousTarget, announce: false, retry: true)
        }
        refreshMenu()
    }

    func disconnect() {
        clearCursorFeedback()
        reconnectTask?.cancel()
        reconnectTask = nil
        heartbeat?.invalidate()
        heartbeat = nil
        stopClipboardSync()
        let previous = client
        previous.onSlowAcknowledgement = nil
        previous.onCursor = nil
        previous.onStreamStateChange = nil
        let inFlight = httpInput
        var releases: [[String: Any]] = sentKeys.map { ["op": "key", "vk": $0, "down": false] }
        releases += sentButtons.map { ["op": "up", "button": $0] }
        if connected && (previous.supportsLease || !releases.isEmpty) {
            let payload = previous.supportsLease ? ["op": "release", "session": previous.sessionID] : previous.inputPayload(releases)
            Task {
                await inFlight?.value
                _ = try? await previous.sendInputHTTP(payload)
            }
        }
        previous.closeStream()
        client = WindowsClient()
        httpInput = nil
        inputQueue.removeAll()
        rightButtonDown = false
        discardPasteKeyUp = false
        shortcutModifiers.removeAll()
        sentKeys.removeAll()
        sentButtons.removeAll()
        sendHelper(["action": "edge", "mode": "off"])
        sendHelper(["action": "return"])
        connected = false
        connecting = false
        target = nil
        active = false
        streamUp = false
        lastError = ""
        refreshMenu()
    }

    func returnToMac() {
        sendHelper(["action": "return"])
    }

    func setEdgeMode(_ mode: String) {
        edgeMode = mode
        sendHelper(["action": "edge", "mode": connected ? mode : "off"])
        refreshMenu()
    }

    func setClipboardEnabled(_ enabled: Bool) {
        clipboardEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "syncClipboard")
        if enabled { startClipboardSync() } else { stopClipboardSync() }
        refreshMenu()
    }

    func scanLan(port: Int? = nil) async -> [Discovery.Found] {
        await Discovery.scan(port: port ?? Settings.loadPort() ?? 7681) { _ in }
    }

    // MARK: - Clipboard

    private func startClipboardSync() {
        guard connected, clipboardEnabled, let target, clipboardProcess == nil else { return }
        let process = Process()
        process.executableURL = helperBinary
        process.arguments = ["--clipboard-worker"]
        process.qualityOfService = .utility
        let control = Pipe()
        let status = Pipe()
        process.standardInput = control
        process.standardOutput = status
        process.terminationHandler = { [weak self] ended in
            Task { @MainActor in
                guard let self, self.clipboardProcess === ended else { return }
                self.clipboardError = "剪贴板进程已退出，正在重试"
                self.refreshMenu()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard self.clipboardProcess === ended else { return }
                self.stopClipboardSync()
                self.startClipboardSync()
            }
        }
        do {
            let baseline = pasteboard.changeCount
            acknowledgedClipboard = baseline
            skippedClipboard = nil
            var config = try JSONSerialization.data(withJSONObject: [
                "host": target.host, "port": target.port, "token": target.token,
                "sequenceOnly": client.supportsLease, "fileTrees": client.supportsFolders, "fileStream": client.supportsFileStream, "localChange": baseline
            ])
            config.append(0x0a)
            try process.run()
            clipboardProcess = process
            try control.fileHandleForWriting.write(contentsOf: config)
            Task { [weak self] in
                do {
                    for try await line in status.fileHandleForReading.bytes.lines {
                        guard let self, self.clipboardProcess === process else { return }
                        if let fields = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] {
                            self.acknowledgedClipboard = fields["localChange"] as? Int
                            self.skippedClipboard = fields["skipped"] as? Bool == true ? self.acknowledgedClipboard : nil
                            self.clipboardError = fields["message"] as? String ?? ""
                            self.flushInput()
                            self.refreshMenu()
                        }
                    }
                } catch { /* Exit and restart are handled by terminationHandler. */ }
            }
        } catch {
            stopClipboardSync()
            clipboardError = error.localizedDescription
            refreshMenu()
        }
    }

    private func stopClipboardSync() {
        let process = clipboardProcess
        clipboardProcess = nil
        acknowledgedClipboard = nil
        skippedClipboard = nil
        clipboardError = ""
        if let pipe = process?.standardInput as? Pipe { try? pipe.fileHandleForWriting.close() }
        if let process, process.isRunning { process.terminate() }
    }

    // MARK: - Menu

    private func buildMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "rectangle.connected.to.line.below",
                                     accessibilityDescription: "LanKvm")
        item.button?.image?.isTemplate = true
        statusItem = item
        menu = NSMenu()
        item.menu = menu
        refreshMenu()
    }

    func refreshMenu() {
        guard let menu else { return }
        menu.removeAllItems()

        let state: String
        if !trusted {
            state = "需要辅助功能权限"
        } else if connected {
            state = active ? "正在控制 Windows" : "已连接"
        } else {
            state = connecting ? "正在连接…" : "未连接"
        }
        menu.addItem(label: "LanKvm — \(state)")
        if let target { menu.addItem(label: "   \(target.host):\(target.port)") }
        if !streamUp && connected { menu.addItem(label: "   （HTTP 回退模式）") }
        menu.addItem(.separator())

        if connected {
            let returnItem = NSMenuItem(title: "立即交还 Mac", action: #selector(returnNow), keyEquivalent: "")
            returnItem.target = self
            menu.addItem(returnItem)
            let disconnectItem = NSMenuItem(title: "断开连接", action: #selector(doDisconnect), keyEquivalent: "")
            disconnectItem.target = self
            menu.addItem(disconnectItem)
        } else {
            let connectItem = NSMenuItem(title: connecting ? "正在连接…" : "连接", action: #selector(doConnect), keyEquivalent: "")
            connectItem.target = self
            connectItem.isEnabled = !connecting
            menu.addItem(connectItem)
            if reconnectTask != nil || connecting {
                let stop = NSMenuItem(title: "取消连接", action: #selector(doDisconnect), keyEquivalent: "")
                stop.target = self
                menu.addItem(stop)
            }
        }

        let edgeItem = NSMenuItem(title: "跨屏方向", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for (mode, title) in [("off", "关闭跨屏"), ("right", "Windows 在右侧"), ("left", "Windows 在左侧"), ("both", "两侧都启用")] {
            let entry = NSMenuItem(title: title, action: #selector(setEdge(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = mode
            entry.state = edgeMode == mode ? .on : .off
            submenu.addItem(entry)
        }
        edgeItem.submenu = submenu
        menu.addItem(edgeItem)

        let wheelItem = NSMenuItem(title: "Windows 纵向滚轮与 Mac 相反", action: #selector(toggleWheelDirection), keyEquivalent: "")
        wheelItem.target = self
        wheelItem.state = reverseWindowsWheel ? .on : .off
        menu.addItem(wheelItem)

        let gameItem = NSMenuItem(title: "游戏锁屏（快捷键返回 Mac）", action: #selector(toggleGameLock), keyEquivalent: "")
        gameItem.target = self
        gameItem.state = lockReturn ? .on : .off
        menu.addItem(gameItem)

        let clipboardItem = NSMenuItem(title: "同步剪贴板", action: #selector(toggleClipboard), keyEquivalent: "")
        clipboardItem.target = self
        clipboardItem.state = clipboardEnabled ? .on : .off
        menu.addItem(clipboardItem)

        menu.addItem(.separator())
        if !trusted {
            let permissionItem = NSMenuItem(
                title: "⚠︎ 授予 LanKvm 辅助功能权限…",
                action: #selector(openAccessibility),
                keyEquivalent: ""
            )
            permissionItem.target = self
            menu.addItem(permissionItem)
            menu.addItem(label: "   在列表里打开 LanKvm 开关即可")
        }
        let settingsItem = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        let scanItem = NSMenuItem(title: "搜索局域网 Windows", action: #selector(doScan), keyEquivalent: "")
        scanItem.target = self
        menu.addItem(scanItem)

        if !clipboardError.isEmpty {
            menu.addItem(label: "剪贴板：\(clipboardError)")
        }
        if !lastError.isEmpty {
            menu.addItem(.separator())
            menu.addItem(label: "⚠︎ \(lastError)")
        }

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "退出 LanKvm", action: #selector(doQuit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    private func presentError(_ text: String) {
        let alert = NSAlert()
        alert.messageText = "LanKvm"
        alert.informativeText = text
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - Actions

    @objc private func returnNow() { returnToMac() }

    @objc private func doDisconnect() { disconnect() }

    @objc private func doConnect() {
        guard let port = Settings.loadPort(), let token = Settings.loadToken(), !token.isEmpty else {
            openSettings()
            return
        }
        guard let host = Settings.loadHost(), !host.isEmpty else {
            openSettings()
            return
        }
        Task { await connect(to: LanKvmTarget(host: host, port: port, token: token)) }
    }

    @objc private func setEdge(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? String else { return }
        setEdgeMode(mode)
    }

    @objc private func toggleGameLock() {
        lockReturn.toggle()
        UserDefaults.standard.set(lockReturn, forKey: "gameLock")
        sendHelper(["action": "lockReturn", "enabled": lockReturn])
        refreshMenu()
    }

    @objc private func toggleWheelDirection() {
        reverseWindowsWheel.toggle()
        UserDefaults.standard.set(reverseWindowsWheel, forKey: "reverseWindowsWheel")
        refreshMenu()
    }

    @objc private func toggleClipboard() { setClipboardEnabled(!clipboardEnabled) }

    /// Polls for the Accessibility grant so the app starts working the moment
    /// the user flips the switch, without a relaunch.
    private func startTrustWatch() {
        guard trustWatch == nil else { return }
        trustWatch = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, AXIsProcessTrusted() else { return }
                self.appTrusted = true
                self.trustWatch?.invalidate()
                self.trustWatch = nil
                self.restartHelperSoon()
                self.refreshMenu()
            }
        }
        if let timer = trustWatch { RunLoop.main.add(timer, forMode: .common) }
    }

    /// Explains the one manual step macOS requires.
    private func showPermissionAlert() {
        guard !appTrusted, !permissionAlertShown else { return }
        permissionAlertShown = true
        let text = [
            "macOS 要求先授予这个权限，LanKvm 才能捕获键盘和鼠标。",
            "没有它，跨屏和键盘都不会生效 —— 即使界面显示「已连接」。",
            "",
            "点「打开系统设置」，然后在「隐私与安全性 → 辅助功能」里",
            "打开 LanKvm 的开关。授权后立刻生效，不需要重启。",
        ].joined(separator: "\n")

        let alert = NSAlert()
        alert.messageText = "LanKvm 需要辅助功能权限"
        alert.informativeText = text
        alert.alertStyle = .warning
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "稍后再说")
        if alert.runModal() == .alertFirstButtonReturn {
            Settings.openAccessibility()
            startTrustWatch()
        }
    }

    @objc private func openAccessibility() {
        ensureAccessibilityPermission(prompt: true)
        Settings.openAccessibility()
        // Poll while the user is in System Settings; when the grant lands the
        // helper restarts and the tap starts working without a manual relaunch.
        startTrustWatch()
    }

    @objc func openSettings() {
        if settingsWindow == nil { settingsWindow = SettingsWindow(controller: self) }
        settingsWindow?.show()
    }

    @objc private func doScan() {
        Task {
            lastError = "正在扫描局域网…"
            refreshMenu()
            let found = await scanLan()
            if found.isEmpty {
                lastError = "局域网内没有找到 LanKvm 接收端"
            } else if let first = found.first {
                lastError = ""
                openSettings()
                settingsWindow?.suggestHost(first.host)
            }
            refreshMenu()
        }
    }

    @objc private func doQuit() {
        shutdown()
        NSApp.terminate(nil)
    }
}

private extension NSMenu {
    func addItem(label text: String) {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        addItem(item)
    }
}
