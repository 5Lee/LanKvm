import AppKit
import Foundation

/// Runs in its own helper process. Only configuration and status cross the parent pipe.
@MainActor
final class ClipboardWorker {
    private let client: WindowsClient
    private let board: MacClipboard
    private var checkedPendingFiles = false
    private var seenLocal: Int
    private var remoteSeq: UInt32?
    private var skippedRemote: UInt32?
    private var lastStatus = ""
    private var lastReportedLocal: Int?
    private var skippedLocal: Int?

    init(client: WindowsClient, board: MacClipboard, initialLocal: Int? = nil) {
        self.client = client
        self.board = board
        board.supportsFolders = client.supportsFolders
        seenLocal = initialLocal ?? board.changeCount
    }

    nonisolated static func run() -> Never {
        guard let line = readLine(), let data = line.data(using: .utf8),
              let config = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let host = config["host"] as? String, let token = config["token"] as? String,
              let port = config["port"] as? Int, (1...65535).contains(port) else { exit(2) }
        let target = LanKvmTarget(host: host, port: port, token: token)
        let metadataOnly = config["sequenceOnly"] as? Bool == true
        // Closing stdin (including a parent crash) terminates ongoing transfers and stops polling.
        Thread.detachNewThread {
            while readLine() != nil {}
            exit(0)
        }
        Task { @MainActor in
            let client = WindowsClient(clipboardTarget: target, sequenceOnly: metadataOnly, folders: config["fileTrees"] as? Bool == true, streamFiles: config["fileStream"] as? Bool == true)
            await ClipboardWorker(client: client, board: MacClipboard(), initialLocal: config["localChange"] as? Int).synchronize()
        }
        // Pasteboard ownership changes are delivered through the Cocoa run loop.
        let runLoopPort = Port()
        RunLoop.main.add(runLoopPort, forMode: .default)
        RunLoop.main.run()
        exit(0)
    }

    private func status(_ message: String) {
        guard message != lastStatus || lastReportedLocal != seenLocal else { return }
        lastReportedLocal = seenLocal
        lastStatus = message
        if var data = try? JSONSerialization.data(withJSONObject: ["message": message, "localChange": seenLocal, "skipped": skippedLocal == seenLocal]) {
            data.append(0x0a)
            try? FileHandle.standardOutput.write(contentsOf: data)
        }
    }

    func synchronize() async {
        var backoff: UInt64 = 400_000_000
        var nextRemotePoll: TimeInterval = 0
        while !Task.isCancelled {
            let now = ProcessInfo.processInfo.systemUptime
            if board.changeCount != seenLocal || now >= nextRemotePoll {
                do {
                    try await synchronizeOnce()
                    backoff = 400_000_000
                    nextRemotePoll = now + 0.4
                    if board.changeCount != seenLocal { continue }
                } catch {
                    status(error.localizedDescription)
                    do { try await Task.sleep(nanoseconds: backoff) } catch { return }
                    backoff = min(backoff * 2, 4_000_000_000)
                    continue
                }
            }
            do { try await Task.sleep(nanoseconds: 60_000_000) } catch { return }
        }
    }

    private func transfer<T>(local: Int, _ body: @escaping @Sendable () throws -> T) async throws -> T {
        let job = Task.detached(priority:.utility, operation:body)
        let monitor = Task {
            while !Task.isCancelled {
                if board.changeCount != local { job.cancel(); return }
                do { try await Task.sleep(nanoseconds:150_000_000) } catch { return }
            }
        }
        defer { monitor.cancel() }
        return try await withTaskCancellationHandler(operation:{try await job.value},onCancel:{job.cancel()})
    }

    func synchronizeOnce() async throws {
        let local = board.changeCount
        if local != seenLocal {
            if client.supportsFileStream, let target = client.target {
                let temp = FileManager.default.temporaryDirectory.appendingPathComponent("lankvm-images-" + UUID().uuidString)
                defer { try? FileManager.default.removeItem(at:temp) }
                if let roots = try board.streamingSelection(in:temp) {
                    guard board.changeCount == local else { return }
                    status("正在向 Windows 传输文件")
                    do {
                        remoteSeq = try await transfer(local:local) { try FileTransfer.upload(roots,to:target) }
                    } catch FileTransfer.Failure.selection(let message) {
                        seenLocal = local
                        skippedLocal = local
                        status(message)
                        return
                    }
                    seenLocal = local
                    skippedRemote = nil
                    status("")
                    return
                }
            }
            guard var item = autoreleasepool(invoking: { board.read() }) else {
                seenLocal = local
                skippedLocal = local
                status("")
                return
            }
            guard board.changeCount == local else { return }
            if item.removeValue(forKey: "type") as? String == "clipboardSkipped" {
                seenLocal = local
                skippedLocal = local
                status(item["reason"] as? String ?? "剪贴板项目超过传输上限")
                return
            }
            let result = try await client.writeClipboard(item, timeout: 90)
            guard let seq = (result["seq"] as? NSNumber)?.uint32Value else { throw invalidResponse() }
            remoteSeq = seq
            skippedRemote = nil
            seenLocal = local
            status("")
            return
        }

        let priming = remoteSeq == nil
        let result = try await client.readClipboard(since: remoteSeq ?? 0, timeout: 90, sequenceOnly: priming)
        guard let seq = (result["seq"] as? NSNumber)?.uint32Value else { throw invalidResponse() }
        if let error = result["error"] as? String { throw LanKvmError.message(error) }
        guard board.changeCount == local else { return }
        if !priming, result["kind"] as? String == "fileStream", let target = client.target {
            let base = FileManager.default.temporaryDirectory.appendingPathComponent("dsh-lan-kvm-paste")
            if !checkedPendingFiles {
                checkedPendingFiles = true
                await Task.detached(priority:.utility) { FileTransfer.clearAbandoned(in:base) }.value
            }
            let stage = base.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at:stage,withIntermediateDirectories:true)
            var published = false
            defer { if !published { try? FileManager.default.removeItem(at:stage) } }
            status("正在从 Windows 接收文件")
            let urls: [URL]
            do {
                urls = try await transfer(local:local) { try FileTransfer.download(from:target,sequence:seq,into:stage) }
            } catch FileTransfer.Failure.selection(let message) {
                skippedRemote = seq
                remoteSeq = seq
                status(message)
                return
            } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileWriteOutOfSpaceError {
                skippedRemote = seq
                remoteSeq = seq
                status("Mac 磁盘空间不足，释放空间后请重新复制")
                return
            }
            guard try board.publishFiles(urls,ifUnchangedSince:local) else { return }
            published = true
            seenLocal = board.changeCount
            remoteSeq = seq
            status("")
            return
        }
        if !priming, result["kind"] as? String == "skipped" {
            remoteSeq = seq
            skippedRemote = seq
            status(result["reason"] as? String ?? "Windows 无法传输此选择")
            return
        }
        if !priming, result["unchanged"] as? Bool == true {
            if skippedRemote != seq && skippedLocal != seenLocal { status("") }
            return
        }
        if !priming, result["unchanged"] as? Bool != true, let kind = result["kind"] as? String, kind != "none" {
            guard try autoreleasepool(invoking: { try board.write(result, ifUnchangedSince: local) }) else { return }
            seenLocal = board.changeCount
        }
        remoteSeq = seq
        status("")
    }

    private func invalidResponse() -> LanKvmError {
        .message("Windows 返回的剪贴板状态无效")
    }
}
