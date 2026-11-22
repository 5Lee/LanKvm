// A private pasteboard exercises the same file URL codec used by the worker.
private func checkClipboardTree() throws {
    let fm = FileManager.default
    let temp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let folder = temp.appendingPathComponent("相册")
    let empty = folder.appendingPathComponent("一级/空目录")
    let leaf = folder.appendingPathComponent("一级/空文件")
    let note = temp.appendingPathComponent("note.txt")
    try fm.createDirectory(at: empty, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: temp) }
    try Data().write(to: leaf)
    try Data("hello".utf8).write(to: note)

    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    let codec = MacClipboard(board: board)
    precondition(board.writeObjects([folder, note] as [NSURL]))
    precondition(codec.read()?["type"] as? String == "clipboardSkipped")
    codec.supportsFolders = true
    guard let item = codec.read() else { preconditionFailure("missing clipboard selection") }
    precondition(item["kind"] as? String == "fileTree")
    let written = try codec.write(item, ifUnchangedSince: codec.changeCount)
    precondition(written)
    let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as! [URL]
    precondition(urls.map(\.lastPathComponent) == ["相册", "note.txt"])
    let stage = urls[0].deletingLastPathComponent().deletingLastPathComponent()
    defer { try? fm.removeItem(at: stage) }
    var directory: ObjCBool = false
    precondition(fm.fileExists(atPath: urls[0].appendingPathComponent("一级/空目录").path, isDirectory: &directory) && directory.boolValue)
    let zero = try Data(contentsOf: urls[0].appendingPathComponent("一级/空文件"))
    let text = try String(contentsOf: urls[1], encoding: .utf8)
    precondition(zero.isEmpty && text == "hello")

    // Completed and active stages must survive an abandoned-transfer sweep.
    let cache = temp.appendingPathComponent("staging")
    let active = cache.appendingPathComponent(UUID().uuidString)
    let abandoned = cache.appendingPathComponent(UUID().uuidString)
    let complete = cache.appendingPathComponent(UUID().uuidString)
    for dir in [active, abandoned, complete] {
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    let marker = ".lankvm-stream-pending"
    try Data().write(to: abandoned.appendingPathComponent(marker))
    let lease = open(active.appendingPathComponent(marker).path, O_CREAT | O_EXLOCK | O_RDWR, 0o600)
    precondition(lease >= 0)
    defer { close(lease) }
    FileTransfer.clearAbandoned(in: cache)
    precondition(fm.fileExists(atPath: active.path) && fm.fileExists(atPath: complete.path))
    precondition(!fm.fileExists(atPath: abandoned.path))

    let incomplete = cache.appendingPathComponent(UUID().uuidString)
    try fm.createDirectory(at: incomplete, withIntermediateDirectories: false)
    let target = LanKvmTarget(host: "127.0.0.1", port: Int(CommandLine.arguments[1])!, token: "fixture-only")
    do {
        _ = try FileTransfer.download(from: target, sequence: 7, into: incomplete)
        preconditionFailure("a partial file must never become available to paste")
    } catch {
        let fragment = incomplete.appendingPathComponent("0/large.bin")
        let length = try fragment.resourceValues(forKeys: [.fileSizeKey]).fileSize
        precondition(length == 65536)
    }
    FileTransfer.clearAbandoned(in: cache)
    precondition(!fm.fileExists(atPath: incomplete.path))

    let previous = codec.changeCount
    let repeated: [[String: Any]] = [
        ["name": "dir", "directory": true], ["name": "same", "parent": 0, "data": ""],
        ["name": "same", "parent": 0, "data": ""]
    ]
    do {
        _ = try codec.write(["kind":"fileTree", "files":repeated], ifUnchangedSince: previous)
        preconditionFailure("conflicting entries must not replace the existing selection")
    } catch { precondition(codec.changeCount == previous) }

    codec.fileLimit = 4
    precondition(codec.read()?["type"] as? String == "clipboardSkipped")
    codec.fileLimit = 128
    try fm.createSymbolicLink(at: folder.appendingPathComponent("link"), withDestinationURL: note)
    board.clearContents()
    precondition(board.writeObjects([folder as NSURL]))
    precondition(codec.read()?["type"] as? String == "clipboardSkipped")
    emit(["check": "clipboard-tree-passed"])
}
try checkClipboardTree()
