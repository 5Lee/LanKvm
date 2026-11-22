import Darwin
import Foundation

/// Lifecycle diagnostics only. Both writes and scheduled maintenance run off the input thread.
final class DiagnosticLog {
    static let dailyLimit = 256 * 1024
    private let directory: URL
    private let legacy: URL
    private let enabled: Bool
    private let queue = DispatchQueue(label: "lankvm.diagnostics", qos: .utility)
    private let dateLabel: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withDashSeparatorInDate]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()
    private var timer: DispatchSourceTimer?
    private var lastCleanDate = ""

    init(directory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/LanKvm"),
         legacy: URL = URL(fileURLWithPath: "/tmp/lankvm-app.log"),
         enabled: Bool = ProcessInfo.processInfo.environment["LANKVM_DEBUG"] != nil) {
        self.directory = directory
        self.legacy = legacy
        self.enabled = enabled
    }

    func start() {
        guard timer == nil else { return }
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.setEventHandler { [weak self] in self?.clean(at: Date()) }
        source.schedule(deadline: .now(), repeating: .seconds(3600), leeway: .seconds(30))
        timer = source
        source.resume()
    }

    deinit { timer?.cancel() }

    func record(_ event: String) {
        guard enabled else { return }
        let timestamp = Date()
        queue.async { self.append(event, at: timestamp) }
    }

    private func filename(_ date: Date) -> String {
        "diagnostic-" + dateLabel.string(from: date) + ".log"
    }

    private func owned(_ url: URL, type: mode_t) -> stat? {
        var s = stat()
        guard lstat(url.path, &s) == 0, s.st_uid == geteuid(), s.st_mode & S_IFMT == type else { return nil }
        if type == S_IFREG && s.st_nlink != 1 { return nil }
        return s
    }

    func clean(at now: Date) {
        lastCleanDate = filename(now)
        let day: TimeInterval = 86400
        if let s = owned(legacy, type: S_IFREG),
           s.st_size > Self.dailyLimit || now.timeIntervalSince1970 - Double(s.st_mtimespec.tv_sec) >= 7 * day {
            _ = unlink(legacy.path)
        }
        guard owned(directory, type: S_IFDIR) != nil,
              let entries = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        else { return }
        let keep = Set((0..<7).map { filename(now.addingTimeInterval(-Double($0) * day)) })
        for file in entries {
            let name = file.lastPathComponent
            guard name.range(of: #"^diagnostic-[0-9]{4}-[0-9]{2}-[0-9]{2}\.log$"#, options: .regularExpression) != nil,
                  let s = owned(file, type: S_IFREG) else { continue }
            if !keep.contains(name) || s.st_size > Self.dailyLimit { _ = unlink(file.path) }
        }
    }

    func append(_ event: String, at now: Date) {
        let name = filename(now)
        if name != lastCleanDate { clean(at: now) }
        if owned(directory, type: S_IFDIR) == nil {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            guard owned(directory, type: S_IFDIR) != nil else { return }
        }
        let file = directory.appendingPathComponent(name)
        let fd = open(file.path, O_APPEND | O_CREAT | O_WRONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var s = stat()
        guard flock(fd, LOCK_EX | LOCK_NB) == 0, fstat(fd, &s) == 0,
              s.st_uid == geteuid(), s.st_nlink == 1, s.st_mode & S_IFMT == S_IFREG else { return }
        let line = Data(String(format: "%.3f %@\n", now.timeIntervalSince1970, event).utf8)
        guard s.st_size + Int64(line.count) <= Self.dailyLimit else { return }
        line.withUnsafeBytes { buffer in _ = Darwin.write(fd, buffer.baseAddress, buffer.count) }
    }
}
