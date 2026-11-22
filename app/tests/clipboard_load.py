"""64 MiB bidirectional clipboard/input integration test on loopback and a private named pasteboard.
Run: python3 app/tests/clipboard_load.py [--reference PATH_TO_1_1_0] [--rounds 3]
"""
import argparse
import base64
import hashlib
import http.server
import json
import math
import os
from pathlib import Path
import socket
import socketserver
import sys
import statistics
import subprocess
import tempfile
import threading
import time
import uuid

TESTS = Path(__file__).resolve().parent
ROOT = TESTS.parents[1]
BOARD = 'NSPasteboard(name: NSPasteboard.Name(ProcessInfo.processInfo.environment["LANKVM_LOAD_BOARD"]!))'
MIB = 1024 * 1024


def wait_for(check, what, timeout=60):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        result = check()
        if result:
            return result
        time.sleep(.015)
    raise RuntimeError("timed out waiting for " + what)


def swift(exe, *sources):
    subprocess.run(["xcrun", "swiftc", "-O", "-swift-version", "5", "-suppress-warnings", "-o", exe,
                    *sources], check=True, timeout=120)


def drivers(root, build):
    build.mkdir()
    mac = root / "app/mac/Sources"
    base = (root / "mac-helper.swift").read_text()
    code, entry = base.rsplit("let helper = KvmHelper()", 1)
    assert entry.strip() == "helper.run()"
    is_split = (mac / "ClipboardWorker.swift").exists()
    code = code.replace("NSPasteboard.general", BOARD).replace("board: NSPasteboard = .general", "board: NSPasteboard = " + BOARD)
    (build / "main.swift").write_text(code + (TESTS / "ClipboardLoadHelper.swift").read_text())
    extra = ["-D", "LANKVM_STANDALONE", mac / "ClipboardWorker.swift", mac / "WindowsClient.swift"] if is_split else []
    if (mac / "FileTransfer.swift").exists(): extra.append(mac / "FileTransfer.swift")
    swift(build / "helper", build / "main.swift", *extra)
    controller = (mac / "AppController.swift").read_text().replace("NSPasteboard.general", BOARD)
    fragment = 'supportDirectory.appendingPathComponent("bin/lankvm-helper")'
    assert fragment in controller
    controller = controller.replace(fragment, 'URL(fileURLWithPath: ProcessInfo.processInfo.environment["LANKVM_LOAD_HELPER"]!)')
    (build / "AppController.swift").write_text(controller + "\n" + (TESTS / "ClipboardLoadController.swift").read_text())
    (build / "main.swift").write_text("""
import AppKit
Task { @MainActor in
    do {
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["LANKVM_LOAD_DIR"]!)
        try await AppController.shared.runLoadFixture(dir, port: Int(CommandLine.arguments[1])!)
        exit(0)
    } catch { print(error); exit(1) }
}
RunLoop.main.add(Port(), forMode: .default)
RunLoop.main.run()
""")
    diagnostics = [mac / "DiagnosticLog.swift"] if (mac / "DiagnosticLog.swift").exists() else []
    swift(build / "relay", build / "main.swift", build / "AppController.swift",
          *[mac / name for name in ["WindowsClient.swift", "Settings.swift", "Discovery.swift"]], *diagnostics)


class Fixture:
    def __init__(self, reference_hash):
        self.digest = reference_hash
        self.seq = 1
        self.remote = None
        self.polls = 0
        self.downloads = 0
        self.hold_download = False
        self.download_started = threading.Event()
        self.resume_download = threading.Event()
        self.new_text = None
        self.uploads = 0
        self.errors = []


class Http(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, body):
        if not isinstance(body, bytes):
            body = json.dumps(body).encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        state = self.server.state
        assert self.headers.get("x-kvm-token") == "load-fixture"
        if self.path == "/api/ping":
            self.reply(dict(ok=True, agent="lankvm", version=4, width=1920, height=1080))
        elif self.path.startswith("/api/clipboard?"):
            state.polls += 1
            from urllib.parse import parse_qs, urlsplit
            query = parse_qs(urlsplit(self.path).query)
            if query.get("sequenceOnly") == ["1"] or query.get("since") == [str(state.seq)] or state.remote is None:
                self.reply(dict(ok=True, unchanged=True, seq=state.seq))
            else:
                state.downloads += 1
                response = state.remote
                if state.hold_download:
                    state.download_started.set()
                    assert state.resume_download.wait(timeout=8)
                self.reply(response)
        else:
            self.send_error(404)

    def do_POST(self):
        state = self.server.state
        assert self.headers.get("x-kvm-token") == "load-fixture"
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        if self.path == "/api/clipboard":
            try:
                if body.get("kind") == "text":
                    state.new_text = body["text"]
                    state.seq += 1
                    self.reply(dict(ok=True, seq=state.seq))
                    return
                files = body["files"]
                assert len(files) == 1 and files[0]["name"] == "outgoing.bin"
                assert hashlib.sha256(base64.b64decode(files[0]["data"], validate=True)).digest() == state.digest
                state.seq += 1
                state.uploads += 1
                self.reply(dict(ok=True, seq=state.seq))
            except Exception as e:
                state.errors.append(repr(e))
                self.send_error(422)
        else:
            assert self.path == "/api/input" and body["op"] == "release"
            self.reply(dict(ok=True))


def input_receiver(fd, directory):
    # Keep clipboard JSON decoding and its Python GIL out of receiver timing.
    directory = Path(directory)
    samples, buttons = [], []
    with socket.socket(fileno=fd) as listener:
        conn, _ = listener.accept()
        with conn, conn.makefile("rb") as stream:
            assert stream.readline().strip() == b"TOKEN load-fixture"
            conn.sendall(b'{"ok":true,"stream":1}\n')
            warm = False
            for line in stream:
                arrival = time.time()
                for e in json.loads(line).get("events", []):
                    if e["op"] == "moveRel":
                        samples.extend([arrival] * e["dx"])
                        if not warm and len(samples) > 40:
                            (directory/"warm").touch()
                            warm = True
                    else:
                        buttons.append((e["op"], e["button"]))
                        if e["op"] == "up":
                            tmp = directory/"received.tmp"
                            tmp.write_text(json.dumps([samples,buttons]))
                            tmp.rename(directory/"received.json")
                conn.sendall(b'{"ok":true,"x":320,"y":300}\n')


def describe(sent, received, start, end):
    delays = sorted((b-a)*1000 for a,b in zip(sent,received) if start <= a <= end)
    assert delays and delays[0] >= 0
    return dict(samples=len(delays), p50=round(statistics.median(delays), 2),
                p95=round(delays[math.ceil(.95*len(delays))-1], 2), max=round(max(delays), 2))


def trial(build, temp, boardctl, file, digest, label):
    dir = temp / uuid.uuid4().hex
    dir.mkdir()
    board = "local.lankvm.load." + uuid.uuid4().hex
    env = dict(os.environ, LANKVM_LOAD_DIR=str(dir), LANKVM_LOAD_BOARD=board, LANKVM_LOAD_HELPER=str(build / "helper"))
    state = Fixture(digest)
    name = "lankvm-test-" + uuid.uuid4().hex + ".bin"
    response = base64.b64encode(file.read_bytes())
    state.remote = None
    for _ in range(20):
        httpd = http.server.ThreadingHTTPServer(("127.0.0.1",0), Http)
        try:
            tcp = socketserver.TCPServer(("127.0.0.1",httpd.server_port+1), socketserver.BaseRequestHandler)
            break
        except (OSError,OverflowError):
            httpd.server_close()
    else:
        raise RuntimeError("no adjacent loopback ports")
    with httpd, tcp:
        httpd.state = state
        threading.Thread(target=httpd.serve_forever,daemon=True).start()
        fd = tcp.fileno()
        input_proc = subprocess.Popen([sys.executable, __file__, "--input-socket", str(fd), str(dir)], pass_fds=(fd,))
        proc = subprocess.Popen([build/"relay",str(httpd.server_port)],env=env)
        def board_command(*args):
            return subprocess.check_output([boardctl,board,*args],text=True,timeout=4).strip()
        try:
            wait_for(lambda: (dir/"ready").exists() and state.polls, "receiver priming")
            (dir/"go").touch()
            wait_for(lambda: (dir/"warm").exists(), "mouse input warmup")
            up_start = time.time()
            board_command("set",str(file))
            try:
                wait_for(lambda: state.uploads or state.errors, "64 MiB upload")
            except RuntimeError:
                print("receiver polls / served downloads:", state.polls, state.downloads, flush=True)
                raise
            assert not state.errors
            up_end = time.time()
            print(label, "outbound SHA-256 verified", flush=True)
            body = json.dumps(dict(ok=True,seq=state.seq+1,kind="files",
                files=[dict(name=name,data=response.decode("ascii"))]), separators=(",",":")).encode()
            time.sleep(.15)
            down_start = time.time()
            state.seq += 1
            state.remote = body
            def remote_file():
                path = board_command("get")
                return Path(path) if path and Path(path).name == name else None
            try:
                dest = wait_for(remote_file, "64 MiB download")
            except RuntimeError:
                print("receiver polls / served downloads:", state.polls, state.downloads, flush=True)
                raise
            down_end = time.time()
            print(label, "inbound file published", flush=True)
            assert hashlib.sha256(dest.read_bytes()).digest() == digest
            dest.unlink()
            # Remove only the fixture's empty per-transfer directories.
            for parent in (dest.parent,dest.parent.parent):
                if parent.name == "dsh-lan-kvm-paste" or parent == Path("/"): break
                try: parent.rmdir()
                except OSError: break
            (dir/"stop-input").touch()
            wait_for(lambda: (dir/"times.json").exists() and (dir/"received.json").exists(), "ordered button release")
            sent = json.loads((dir/"times.json").read_text())
            received, buttons = json.loads((dir/"received.json").read_text())
            assert len(sent) == len(received), (len(sent),len(received))
            assert buttons == [["down","right"],["up","right"]] and state.uploads == 1
            result=dict(version=label, events=len(sent), upload=describe(sent,received,up_start,up_end),
                        download=describe(sent,received,down_start,down_end))
            print(json.dumps(result),flush=True)
            if label == "updated":
                state.hold_download = True
                state.remote = json.dumps(dict(ok=True, seq=state.seq+1, kind="text", text="older remote")).encode()
                state.seq += 1
                assert state.download_started.wait(timeout=5)
                board_command("text", "newer local")
                state.resume_download.set()
                wait_for(lambda: state.new_text == "newer local", "latest local copy upload", timeout=5)
                assert board_command("read-text") == "newer local"
                print("PASS a newer local copy wins during an outstanding download", flush=True)
            board_command("release")
            return result
        finally:
            (dir/"finish").touch()
            try: proc.wait(timeout=4)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait()
            httpd.shutdown()
            try: input_proc.wait(timeout=2)
            except subprocess.TimeoutExpired:
                input_proc.kill()
                input_proc.wait()


if __name__ == "__main__":
    if sys.argv[1:2] == ["--input-socket"]:
        input_receiver(int(sys.argv[2]),sys.argv[3])
        sys.exit(0)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--reference",type=Path)
    parser.add_argument("--rounds",type=int,default=1)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory() as name:
        temp = Path(name)
        (temp/"board.swift").write_text("""
import AppKit
let args = CommandLine.arguments
let pb = NSPasteboard(name: NSPasteboard.Name(args[1]))
switch args[2] {
case "set":
    pb.clearContents()
    precondition(pb.writeObjects([URL(fileURLWithPath: args[3]) as NSURL]))
case "text":
    pb.clearContents()
    precondition(pb.setString(args[3], forType: .string))
case "read-text":
    print(pb.string(forType: .string) ?? "")
case "get":
    let items = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly:true]) as? [URL]
    print(items?.first?.path ?? "")
default: pb.releaseGlobally()
}
""")
        swift(temp/"board",temp/"board.swift")
        file = temp/"outgoing.bin"
        file.write_bytes(os.urandom(64*MIB))
        digest = hashlib.sha256(file.read_bytes()).digest()
        versions = ([("reference",args.reference)] if args.reference else []) + [("updated", ROOT)]
        for label,root in versions: drivers(root,temp/label)
        for i in range(args.rounds):
            for label,_ in (versions if i%2 == 0 else reversed(versions)):
                trial(temp/label,temp,temp/"board",file,digest,label)
