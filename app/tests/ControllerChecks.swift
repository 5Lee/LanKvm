// Compiled with AppController.swift so the test can drive the normal helper-message path.
extension AppController {
    func checkRelay(port: Int) async throws {
        let receiver = LanKvmTarget(host: "127.0.0.1", port: port, token: "fixture-only")
        let found = await Discovery.identify(host: receiver.host, port: port)
        precondition(found?.machine == "fixture")
        _ = try await client.probe(receiver)
        target = receiver
        connected = true
        active = true
        lockReturn = false

        func deliver(_ line: String) { handleHelperData(Data(line.utf8)) }
        func pause(_ milliseconds: UInt64) async throws {
            try await Task.sleep(nanoseconds: milliseconds * 1_000_000)
        }
        deliver(#"{"type":"key","vk":162,"down":true}"#)
        flushInput()
        try await pause(10)
        deliver(#"{"type":"key","vk":162,"down":false}"#)
        deliver(#"{"type":"active","active":false}"#)
        try await pause(220)
        precondition(inputQueue.isEmpty && httpInput == nil)

        client.openStream()
        for _ in 0..<100 where !client.streamReady { try await pause(10) }
        precondition(client.streamReady)
        deliver(#"{"type":"active","active":true}"#)
        consumeHelperOutput(try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])))
        flushInput()
        let defaults = UserDefaults.standard
        let previousWheelSetting = defaults.object(forKey: "reverseWindowsWheel")
        defer { defaults.set(previousWheelSetting, forKey: "reverseWindowsWheel") }
        reverseWindowsWheel = true
        func scroll(_ delta: Int, horizontal: Bool = false) {
            deliver("{\"type\":\"wheel\",\"delta\":\(delta),\"horizontal\":\(horizontal)}")
        }
        scroll(120)
        scroll(-240)
        scroll(120, horizontal: true)
        toggleWheelDirection()
        precondition(defaults.object(forKey: "reverseWindowsWheel") as? Bool == false)
        scroll(120)
        scroll(-240)
        scroll(-120, horizontal: true)
        deliver(#"{"type":"active","active":false}"#)
        scroll(120)
        deliver(#"{"type":"active","active":true}"#)
        deliver(#"{"type":"mouse","kind":"down","button":"right"}"#)
        for _ in 0..<2000 {
            deliver(#"{"type":"mouse","kind":"move","dx":2,"dy":-1}"#)
        }
        precondition(inputQueue.count < maxBatchEvents)
        deliver(#"{"type":"mouse","kind":"up","button":"right"}"#)
        for _ in 0..<50 {
            deliver(#"{"type":"mouse","kind":"move","dx":3,"dy":-2}"#)
        }
        deliver(#"{"type":"active","active":false}"#)
        try await pause(100)
        // The wrapper gives this controller a private pasteboard. Exercise a paste
        // ahead of upload confirmation, then a second one cancelled on return.
        clipboardProcess = Process()
        for action in ["ack", "return", "move"] {
            deliver(#"{"type":"active","active":true}"#)
            pasteboard.clearContents()
            precondition(pasteboard.setString("paste-guard", forType: .string))
            acknowledgedClipboard = pasteboard.changeCount - 1
            for (vk, down) in [(162,true),(86,true),(86,false),(162,false)] {
                queueInput(["type":"key","vk":vk,"down":down])
            }
            flushInput()
            try await pause(25)
            precondition(inputQueue.first?["pasteChange"] as? Int == pasteboard.changeCount)
            if action == "move" {
                deliver(#"{"type":"mouse","kind":"move","dx":7,"dy":2}"#)
            } else if action == "return" {
                deliver(#"{"type":"active","active":false}"#)
            } else {
                acknowledgedClipboard = pasteboard.changeCount
                flushInput()
            }
            try await pause(25)
            precondition(inputQueue.isEmpty)
        }
        clipboardProcess = nil
        pasteboard.releaseGlobally()
        disconnect()
        deliver(#"{"type":"mouse","kind":"down","button":"left"}"#)
        deliver(#"{"type":"edgeEnter","side":"right","ratio":0.5}"#)
        precondition(inputQueue.isEmpty && !connected && !active)
        try await pause(180)
    }
}
