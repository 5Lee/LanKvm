extension AppController {
    func runLoadFixture(_ dir: URL, port: Int) async throws {
        let candidate = LanKvmTarget(host: "127.0.0.1", port: port, token: "load-fixture")
        _ = try await client.probe(candidate)
        connected = true
        active = true
        target = candidate
        launchHelper()
        client.openStream()
        startClipboardSync()
        while !client.streamReady || !helperReady { try await Task.sleep(nanoseconds: 10_000_000) }
        try Data().write(to: dir.appendingPathComponent("ready"))
        while !FileManager.default.fileExists(atPath: dir.appendingPathComponent("finish").path) {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        shutdown()
    }
}
