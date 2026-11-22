import Foundation
import Darwin

// Framed stream on the receiver's authenticated HTTP port. File contents never
// enter a JSON object. Both directions acknowledge every 128 KiB of wire data.
final class FileTransfer {
    enum Failure: LocalizedError {
        case message(String)
        case selection(String)
        var errorDescription: String? {
            switch self { case .message(let text), .selection(let text): return text }
        }
    }
    private let fd: Int32
    private var credit = 131072

    private init(target: LanKvmTarget, query: String) throws {
        var hints = addrinfo()
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP
        var head: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(target.host, String(target.port), &hints, &head) == 0 else {
            throw Failure.message("找不到 Windows 文件接收端")
        }
        defer { freeaddrinfo(head) }
        var address = head
        var connected: Int32 = -1
        while let node = address {
            let a = node.pointee
            let sock = socket(a.ai_family, a.ai_socktype, a.ai_protocol)
            if sock >= 0 {
                var one: Int32 = 1
                var buffer: Int32 = 131072
                var traffic: Int32 = NET_SERVICE_TYPE_BK
                setsockopt(sock, SOL_SOCKET, SO_NET_SERVICE_TYPE, &traffic, socklen_t(MemoryLayout.size(ofValue: traffic)))
                var timeout = timeval(tv_sec: 30, tv_usec: 0)
                setsockopt(sock, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout.size(ofValue: one)))
                setsockopt(sock, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout.size(ofValue: one)))
                setsockopt(sock, SOL_SOCKET, SO_SNDBUF, &buffer, socklen_t(MemoryLayout.size(ofValue: buffer)))
                setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
                setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
                if Darwin.connect(sock, a.ai_addr, a.ai_addrlen) == 0 { connected = sock; break }
                Darwin.close(sock)
            }
            address = a.ai_next
        }
        guard connected >= 0 else { throw Failure.message("Windows 文件通道连接失败") }
        fd = connected
        guard !target.token.contains("\r"), !target.token.contains("\n") else { throw Failure.message("配对令牌无效") }
        let request = "GET /api/file-stream?\(query) HTTP/1.1\r\nHost: \(target.host)\r\nConnection: Upgrade\r\nUpgrade: lankvm-files/1\r\nx-kvm-token: \(target.token)\r\n\r\n"
        try writeRaw(Data(request.utf8))
        guard try line().hasPrefix("HTTP/1.1 101 ") else { throw Failure.message("文件选择已更改或文件通道不可用") }
        for _ in 0..<32 { if try line().isEmpty { return } }
        throw Failure.message("文件通道响应无效")
    }
    deinit { Darwin.close(fd) }

    private func writeRaw(_ data: Data) throws {
        try data.withUnsafeBytes { buf in
            var offset = 0
            while offset < buf.count {
                try Task.checkCancellation()
                let n = Darwin.send(fd, buf.baseAddress!.advanced(by: offset), buf.count - offset, 0)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw Failure.message("文件连接已中断") }
                offset += n
            }
        }
    }

    private func readRaw(_ count: Int) throws -> Data {
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { buf in
            var offset = 0
            while offset < count {
                try Task.checkCancellation()
                let n = recv(fd, buf.baseAddress!.advanced(by: offset), count - offset, 0)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw Failure.message("文件连接已中断或源文件已变化") }
                offset += n
            }
        }
        return data
    }

    private func line() throws -> String {
        var data = Data()
        while data.count < 8192 {
            let byte = try readRaw(1)[0]
            if byte == 10 { return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines) }
            data.append(byte)
        }
        throw Failure.message("文件响应过长")
    }

    private func send(_ data: Data) throws {
        var pos = data.startIndex
        while pos < data.endIndex {
            let n = min(credit, data.endIndex - pos)
            try writeRaw(data[pos..<pos+n])
            credit -= n
            pos += n
            if credit == 0 {
                let ack = try readRaw(1)[0]
                if ack == 69 { throw Failure.selection(String(("E" + (try line())).dropFirst(4))) }
                guard ack == 6 else { throw Failure.message("Windows 文件通道已中断") }
                credit = 131072
            }
        }
    }

    private func read(_ count: Int) throws -> Data {
        var data = Data()
        data.reserveCapacity(count)
        while data.count < count {
            let n = min(credit, count - data.count)
            data.append(try readRaw(n))
            credit -= n
            if credit == 0 { try writeRaw(Data([6])); credit = 131072 }
        }
        return data
    }

    private func sendHeader(_ value: [String: Any]) throws {
        let json = try JSONSerialization.data(withJSONObject:value)
        var size = UInt32(json.count).bigEndian
        var packet = withUnsafeBytes(of:&size) { Data($0) }
        packet.append(json)
        try send(packet)
    }
    private func readHeader() throws -> [String: Any] {
        let n = try read(4).reduce(0) { $0 * 256 + Int($1) }
        guard (1...65536).contains(n), let header = try JSONSerialization.jsonObject(with: read(n)) as? [String: Any]
        else { throw Failure.message("文件头无效") }
        return header
    }

    static func upload(_ urls: [URL], to target: LanKvmTarget) throws -> UInt32 {
        let wire = try FileTransfer(target:target, query:"direction=put")
        var next: Int64 = 0
        func append(_ url: URL, parent: Int64) throws {
            try Task.checkCancellation()
            let info = try url.resourceValues(forKeys:[.isSymbolicLinkKey,.isDirectoryKey,.isRegularFileKey,.contentModificationDateKey])
            let name = url.lastPathComponent
            guard MacClipboard.validFileName(name) else { throw Failure.selection("Windows 无法保留文件名：\(name)") }
            guard info.isSymbolicLink != true else { throw Failure.selection("选择中包含符号链接：\(name)") }
            let index = next
            next += 1
            var entry: [String:Any] = ["name":name, "parent":parent]
            if info.isDirectory == true {
                entry["directory"] = true
                try wire.sendHeader(entry)
                for child in try FileManager.default.contentsOfDirectory(at:url, includingPropertiesForKeys:nil) {
                    try append(child,parent:index)
                }
                return
            }
            guard info.isRegularFile == true else { throw Failure.selection("不支持此文件类型：\(name)") }
            let file = try FileHandle(forReadingFrom:url)
            defer { try? file.close() }
            let length = try file.seekToEnd()
            try file.seek(toOffset:0)
            entry["size"] = length
            try wire.sendHeader(entry)
            var left = length
            while left > 0 {
                try autoreleasepool {
                    guard let bytes = try file.read(upToCount:Int(min(65536,left))), !bytes.isEmpty else {
                        throw Failure.selection("复制期间文件已更改：\(name)")
                    }
                    try wire.send(bytes)
                    left -= UInt64(bytes.count)
                }
            }
            let freshURL = URL(fileURLWithPath:url.path)
            let current = try freshURL.resourceValues(forKeys:[.fileSizeKey,.contentModificationDateKey])
            guard current.fileSize.map(UInt64.init) == length,
                  current.contentModificationDate == info.contentModificationDate else {
                throw Failure.selection("复制期间文件已更改：\(name)")
            }
        }
        for url in urls { try append(url,parent:-1) }
        try Task.checkCancellation()
        try wire.sendHeader(["end":true])
        let reply = try wire.line()
        guard reply.hasPrefix("OK "), let seq = UInt32(reply.dropFirst(3)) else {
            if reply.hasPrefix("ERR ") { throw Failure.selection(String(reply.dropFirst(4))) }
            throw Failure.message("Windows 未确认文件传输")
        }
        return seq
    }

    // On a forced worker exit the OS releases the lock. Only incomplete stages
    // carry this marker; completed copies may still be in use by Finder.
    static func clearAbandoned(in base: URL) {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at:base,includingPropertiesForKeys:[.isSymbolicLinkKey]) else { return }
        for dir in dirs where UUID(uuidString:dir.lastPathComponent) != nil {
            guard (try? dir.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink) == false else { continue }
            let marker = dir.appendingPathComponent(".lankvm-stream-pending").path
            let fd = open(marker,O_RDWR | O_NOFOLLOW | O_EXLOCK | O_NONBLOCK)
            guard fd >= 0 else { continue }
            if unlink(marker) == 0 { try? fm.removeItem(at:dir) }
            Darwin.close(fd)
        }
    }

    static func download(from target: LanKvmTarget, sequence: UInt32, into stage: URL) throws -> [URL] {
        let wire = try FileTransfer(target:target, query:"direction=get&seq=\(sequence)")
        let fm = FileManager.default
        let marker = stage.appendingPathComponent(".lankvm-stream-pending").path
        let lease = open(marker,O_CREAT | O_EXCL | O_EXLOCK | O_RDWR,0o600)
        guard lease >= 0 else { throw Failure.message("无法创建文件接收目录") }
        defer { Darwin.close(lease) }
        var roots: [URL] = [], dirs: [Int64:URL] = [:]
        var index: Int64 = 0
        while true {
            let entry = try wire.readHeader()
            if let error = entry["error"] as? String { throw Failure.selection(error) }
            if entry["end"] as? Bool == true { break }
            guard let name = entry["name"] as? String, MacClipboard.validFileName(name),
                  let parent = entry["parent"] as? Int64 else { throw Failure.message("文件目录信息无效") }
            let base: URL
            if parent == -1 {
                base = stage.appendingPathComponent(String(index))
                try fm.createDirectory(at:base, withIntermediateDirectories:false)
            } else if let dir = dirs[parent] { base = dir }
            else { throw Failure.message("文件父目录无效") }
            let url = base.appendingPathComponent(name)
            guard !fm.fileExists(atPath:url.path) else { throw Failure.selection("目标目录存在同名项目：\(name)") }
            if entry["directory"] as? Bool == true {
                try fm.createDirectory(at:url,withIntermediateDirectories:false)
                dirs[index] = url
            } else {
                guard var left = entry["size"] as? Int64, left >= 0 else { throw Failure.message("文件大小无效") }
                try Data().write(to:url,options:.withoutOverwriting)
                let file = try FileHandle(forWritingTo:url)
                defer { try? file.close() }
                while left > 0 {
                    let n = Int(min(left,65536))
                    try autoreleasepool { try file.write(contentsOf:wire.read(n)) }
                    left -= Int64(n)
                }
                try file.close()
            }
            if parent == -1 { roots.append(url) }
            index += 1
        }
        guard !roots.isEmpty else { throw Failure.message("文件选择为空") }
        guard unlink(marker) == 0 else { throw Failure.message("无法完成文件接收") }
        return roots
    }
}
