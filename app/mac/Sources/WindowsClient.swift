import Foundation
import Network

/// Target Windows receiver.
struct LanKvmTarget: Equatable {
    var host: String
    var port: Int
    var token: String

    var httpBase: String { "http://\(host):\(port)" }
    var streamPort: Int { port < 65535 ? port + 1 : 0 }
}

/// Screen geometry reported by the receiver.
struct RemoteScreen {
    var left: Double
    var top: Double
    var width: Double
    var height: Double
}

enum LanKvmError: LocalizedError {
    case message(String)
    case credentialsRejected

    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        case .credentialsRejected: return "Windows 拒绝了配对令牌，请检查设置。"
        }
    }
}

/// Talks to the Windows receiver: one-shot HTTP calls for setup, plus a
/// persistent TCP stream that carries input batches with minimal latency.
///
/// The stream is the low-latency path; every call falls back to HTTP when the
/// stream is not up yet, so a dropped stream degrades instead of failing.
@MainActor
final class WindowsClient {
    private(set) var target: LanKvmTarget?
    private(set) var screen: RemoteScreen?
    private(set) var supportsFileStream = false
    private(set) var supportsFolders = false
    private(set) var supportsLease = false
    let sessionID = UUID().uuidString
    private(set) var streamReady = false
    private var pendingResponseSince: TimeInterval?
    private var lastSlowReport = -Double.infinity
    var onSlowAcknowledgement: ((Int) -> Void)?
    var streamTimedOut: Bool {
        guard let since = pendingResponseSince else { return false }
        return ProcessInfo.processInfo.systemUptime - since > 5
    }
    private(set) var lastError = ""

    private var stream: NWConnection?
    private var streamBuffer = Data()

    /// Called on the main queue with the latest cursor position in a read.
    var onCursor: ((Double, Double) -> Void)?
    /// Called on the main queue when the persistent stream comes up or drops.
    var onStreamStateChange: ((Bool) -> Void)?

    private let session: URLSession

    init(clipboardTarget: LanKvmTarget? = nil, sequenceOnly: Bool = false, folders: Bool = false, streamFiles: Bool = false) {
        target = clipboardTarget
        supportsFileStream = streamFiles
        supportsFolders = folders
        supportsLease = sequenceOnly
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.waitsForConnectivity = false
        if clipboardTarget != nil {
            configuration.networkServiceType = .background
            configuration.urlCache = nil
        }
        session = URLSession(configuration: configuration)
    }

    // MARK: - HTTP

    private nonisolated func request(
        _ target: LanKvmTarget,
        _ path: String,
        method: String = "GET",
        json: [String: Any]? = nil,
        timeout: TimeInterval = 8
    ) async throws -> [String: Any] {
        guard let url = URL(string: target.httpBase + path) else {
            throw LanKvmError.message("Bad address")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue(target.token, forHTTPHeaderField: "x-kvm-token")
        if let json {
            request.httpBody = try JSONSerialization.data(withJSONObject: json, options: [.withoutEscapingSlashes])
            request.setValue("application/json", forHTTPHeaderField: "content-type")
        }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw LanKvmError.message("No response from \(target.host):\(target.port)")
            }
            if http.statusCode == 401 { throw LanKvmError.credentialsRejected }
            guard (200..<300).contains(http.statusCode) else {
                let text = String(data: data, encoding: .utf8) ?? ""
                throw LanKvmError.message(text.isEmpty ? "HTTP \(http.statusCode)" : text)
            }
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw LanKvmError.message("Invalid response from Windows")
            }
            return object
        } catch let error as LanKvmError {
            throw error
        } catch {
            let code = (error as NSError).code
            if code == NSURLErrorCannotConnectToHost || code == NSURLErrorNetworkConnectionLost {
                throw LanKvmError.message("Cannot reach \(target.host):\(target.port). Is LanKvm running on Windows?")
            }
            if code == NSURLErrorNotConnectedToInternet {
                throw LanKvmError.message("无法访问局域网。请检查网络，并在「系统设置 → 隐私与安全性 → 本地网络」中允许 LanKvm。")
            }
            if code == NSURLErrorTimedOut {
                throw LanKvmError.message("\(target.host) did not answer in time")
            }
            throw LanKvmError.message(error.localizedDescription)
        }
    }

    /// Confirm the receiver and read its screen geometry.
    @discardableResult
    func probe(_ candidate: LanKvmTarget) async throws -> RemoteScreen {
        target = candidate
        let payload = try await request(candidate, "/api/ping", timeout: 5)
        guard payload["ok"] as? Bool == true, let agent = payload["agent"] as? String,
              ["dsh-lan-kvm", "lankvm"].contains(agent) else {
            throw LanKvmError.message("Not a LanKvm receiver")
        }
        let screen = RemoteScreen(
            left: (payload["left"] as? NSNumber)?.doubleValue ?? 0,
            top: (payload["top"] as? NSNumber)?.doubleValue ?? 0,
            width: (payload["width"] as? NSNumber)?.doubleValue ?? 1920,
            height: (payload["height"] as? NSNumber)?.doubleValue ?? 1080
        )
        supportsFileStream = payload["fileStream"] as? Bool == true
        supportsFolders = payload["fileTrees"] as? Bool == true
        supportsLease = (payload["version"] as? Int ?? 0) >= 4
        self.screen = screen
        lastError = ""
        return screen
    }

    /// Send one input payload over HTTP. Used when the stream is unavailable.
    func sendInputHTTP(_ payload: [String: Any]) async throws -> [String: Any] {
        guard let target else { throw LanKvmError.message("Not connected") }
        return try await request(target, "/api/input", method: "POST", json: payload, timeout: 5)
    }

    func readClipboard(since: UInt32, timeout: TimeInterval, sequenceOnly: Bool = false) async throws -> [String: Any] {
        guard let target else { throw LanKvmError.message("Not connected") }
        let suffix = (sequenceOnly && supportsLease ? "&sequenceOnly=1" : "") + (supportsFolders ? "&fileTrees=1" : "") + (supportsFileStream ? "&streamFiles=1" : "")
        return try await request(target, "/api/clipboard?since=\(since)" + suffix, timeout: timeout)
    }

    func writeClipboard(_ payload: [String: Any], timeout: TimeInterval) async throws -> [String: Any] {
        guard let target else { throw LanKvmError.message("Not connected") }
        return try await request(target, "/api/clipboard", method: "POST", json: payload, timeout: timeout)
    }

    // MARK: - Persistent input stream

    func openStream() {
        guard let target, target.streamPort > 0 else { return }
        closeStream()
        guard let port = NWEndpoint.Port(rawValue: UInt16(target.streamPort)) else { return }
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.serviceClass = .responsiveData
        let connection = NWConnection(host: NWEndpoint.Host(target.host), port: port, using: parameters)
        stream = connection
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self, self.stream === connection else { return }
                switch state {
                case .ready:
                    self.sendStream("TOKEN \(target.token)\n")
                case .failed, .cancelled:
                    self.markStreamDown()
                default:
                    break
                }
            }
        }
        connection.start(queue: .main)
        receiveStream(connection)
    }

    func closeStream() {
        let previous = stream
        stream = nil
        previous?.stateUpdateHandler = nil
        previous?.cancel()
        pendingResponseSince = nil
        streamBuffer.removeAll()
        markStreamDown()
    }

    private func markStreamDown() {
        pendingResponseSince = nil
        guard streamReady else { return }
        streamReady = false
        onStreamStateChange?(false)
    }

    private func sendStream(_ text: String) {
        guard let stream, let data = text.data(using: .utf8) else { return }
        stream.send(content: data, completion: .contentProcessed { [weak self] error in
            MainActor.assumeIsolated {
                if error != nil, self?.stream === stream { self?.markStreamDown() }
            }
        })
    }

    private func receiveStream(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            MainActor.assumeIsolated {
                guard let self, self.stream === connection else { return }
                if let data, !data.isEmpty {
                    self.streamBuffer.append(data)
                    self.drainStreamBuffer()
                }
                if complete || error != nil {
                    self.markStreamDown()
                    return
                }
                self.receiveStream(connection)
            }
        }
    }

    private func drainStreamBuffer() {
        guard let end = streamBuffer.lastIndex(of: 0x0A) else { return }
        let frames = streamBuffer[...end]
        streamBuffer = Data(streamBuffer.suffix(from: streamBuffer.index(after: end)))

        // After a network stall many acknowledgements can arrive together. Keep
        // control messages ordered and publish only the newest cursor position.
        var cursor: (Double, Double)?
        for line in frames.split(separator: 0x0A) {
            guard let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
            if let started = pendingResponseSince, let report = onSlowAcknowledgement {
                let now = ProcessInfo.processInfo.systemUptime
                if now - started >= 0.25, now - lastSlowReport >= 30 {
                    lastSlowReport = now
                    report(Int((1000 * (now - started)).rounded()))
                }
            }
            pendingResponseSince = nil
            if message["ok"] as? Bool == false {
                lastError = message["error"] as? String ?? "Windows input error"
                markStreamDown()
                return
            }
            if message["stream"] as? Int == 1 {
                if !streamReady {
                    streamReady = true
                    onStreamStateChange?(true)
                }
            } else if let x = (message["x"] as? NSNumber)?.doubleValue,
                      let y = (message["y"] as? NSNumber)?.doubleValue {
                cursor = (x, y)
            }
        }
        if let (x, y) = cursor, streamReady { onCursor?(x, y) }
    }

    func inputPayload(_ events: [[String: Any]]) -> [String: Any] {
        var payload: [String: Any] = ["op": "batch", "events": events]
        if supportsLease { payload["session"] = sessionID }
        return payload
    }

    func sendInputStream(_ payload: [String: Any]) -> Bool {
        guard streamReady, let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else { return false }
        if pendingResponseSince == nil { pendingResponseSince = ProcessInfo.processInfo.systemUptime }
        sendStream(text + "\n")
        return true
    }
}
