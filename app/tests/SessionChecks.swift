// Compiled alongside the client implementation for deterministic receive-buffer checks.
extension WindowsClient {
    func checkCoalescedFeedback() {
        var received: [Double] = []
        onCursor = { x, _ in received.append(x) }
        func feed(_ bytes: String) {
            streamBuffer.append(contentsOf: bytes.utf8)
            drainStreamBuffer()
        }
        feed("{\"ok\":true,\"stream\":1}\n")
        precondition(streamReady)
        feed("{\"x\":1,\"y\":0}\n{\"x\":2,\"y\":0}\n{\"x\":3,")
        precondition(received == [2])
        feed("\"y\":0}\n")
        precondition(received == [2, 3])
        var delays: [Int] = []
        onSlowAcknowledgement = { delays.append($0) }
        for _ in 0..<2 {
            pendingResponseSince = ProcessInfo.processInfo.systemUptime - 0.3
            feed("{\"ok\":true}\n")
        }
        precondition(delays.count == 1 && delays[0] >= 300)
        feed("{\"x\":4,\"y\":0}\n{\"ok\":false,\"error\":\"fixture\"}\n")
        precondition(!streamReady && received == [2, 3] && lastError == "fixture")
    }
}

func checkDiagnosticRetention() throws {
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let folder = base.appendingPathComponent("logs")
    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: base) }
    let legacy = base.appendingPathComponent("legacy.log")
    let log = DiagnosticLog(directory: folder, legacy: legacy, enabled: true)
    let date = ISO8601DateFormatter().date(from: "2026-11-22T11:00:00Z")!
    for i in (0..<10).reversed() { log.append("fixture", at: date.addingTimeInterval(-86400 * Double(i))) }
    let unrelated = folder.appendingPathComponent("unrelated.log")
    try Data("keep".utf8).write(to: unrelated)
    let symlink = folder.appendingPathComponent("diagnostic-2000-01-01.log")
    try fm.createSymbolicLink(at: symlink, withDestinationURL: unrelated)
    try Data(count: DiagnosticLog.dailyLimit + 1).write(to: legacy)
    log.clean(at: date)
    precondition(!fm.fileExists(atPath: legacy.path))
    let remaining = try fm.contentsOfDirectory(atPath: folder.path)
    precondition(remaining.count == 9 && remaining.contains("diagnostic-2026-11-16.log"))
    precondition(!remaining.contains("diagnostic-2026-11-15.log"))
    let today = folder.appendingPathComponent("diagnostic-2026-11-22.log")
    let full = Data(repeating: 65, count: DiagnosticLog.dailyLimit)
    try full.write(to: today)
    log.append("one more", at: date)
    let contents = try Data(contentsOf: today)
    precondition(contents == full)
    let target = try fm.destinationOfSymbolicLink(atPath: symlink.path)
    precondition(target == unrelated.path)
    try fm.createSymbolicLink(at: legacy, withDestinationURL: unrelated)
    log.clean(at: date.addingTimeInterval(86400 * 20))
    precondition(fm.fileExists(atPath: unrelated.path))
    let link = try fm.destinationOfSymbolicLink(atPath: legacy.path)
    precondition(link == unrelated.path)
}
