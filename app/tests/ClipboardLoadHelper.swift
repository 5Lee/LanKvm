// Input driver for clipboard_load.py. Synthetic events go to the helper callback, never to macOS.
extension KvmHelper {
    func runLoadFixture() {
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["LANKVM_LOAD_DIR"]!)
        active = true
        installStdinReader()
        emit(["type": "ready", "trusted": true])
        Thread.detachNewThread {
            while !FileManager.default.fileExists(atPath: dir.appendingPathComponent("go").path) {
                Thread.sleep(forTimeInterval: 0.01)
            }
            func mouse(_ type: CGEventType) {
                DispatchQueue.main.async {
                    let event = CGEvent(mouseEventSource: nil, mouseType: type,
                                        mouseCursorPosition: .zero, mouseButton: .right)!
                    event.setIntegerValueField(.mouseEventDeltaX, value: 1)
                    self.handleMouse(event: event, type: type)
                }
            }
            mouse(.rightMouseDown)
            var times = [Double]()
            while !FileManager.default.fileExists(atPath: dir.appendingPathComponent("stop-input").path) {
                times.append(Date().timeIntervalSince1970)
                mouse(.rightMouseDragged)
                Thread.sleep(forTimeInterval: 0.008)
            }
            mouse(.rightMouseUp)
            try! JSONEncoder().encode(times).write(to: dir.appendingPathComponent("times.json"), options: .atomic)
        }
        RunLoop.main.run()
    }
}
KvmHelper().runLoadFixture()
