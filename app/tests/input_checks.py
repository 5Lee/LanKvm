"""Run isolated Mac helper and TCP/HTTP relay checks with python3 app/tests/input_checks.py."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import socketserver
import subprocess
import tempfile
import threading
import time
import uuid

TESTS = Path(__file__).resolve().parent
ROOT = TESTS.parents[1]
MAC = ROOT / "app/mac/Sources"
TOKEN = "fixture-only"
events = []
active_posts = 0
max_posts = 0
lock = threading.Lock()


class Http(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, obj):
        data = json.dumps(obj).encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == "/api/hello":
            assert self.headers.get("x-kvm-token") is None
        else:
            assert self.path == "/api/ping" and self.headers.get("x-kvm-token") == TOKEN
        self.reply(dict(ok=True, agent="lankvm", machine="fixture", version=4, width=1920, height=1080))

    def do_POST(self):
        global active_posts, max_posts
        assert self.path == "/api/input" and self.headers.get("x-kvm-token") == TOKEN
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        assert body["session"]
        with lock:
            active_posts += 1
            max_posts = max(max_posts, active_posts)
        time.sleep(0.05)
        with lock:
            events.extend(("http", item) for item in body.get("events", [body]))
            active_posts -= 1
        self.reply(dict(ok=True, x=120, y=300))


class InterruptedDownload(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        assert self.path == "/api/file-stream?direction=get&seq=7"
        assert self.headers["x-kvm-token"] == TOKEN
        self.protocol_version = "HTTP/1.1"
        self.send_response(101)
        self.send_header("Connection", "Upgrade")
        self.send_header("Upgrade", "lankvm-files/1")
        self.end_headers()
        header = json.dumps(dict(parent=-1, name="large.bin", size=2**32 + 1)).encode()
        self.wfile.write(len(header).to_bytes(4, "big") + header + bytes(65536))
        self.close_connection = True


class Stream(socketserver.StreamRequestHandler):
    def handle(self):
        assert self.rfile.readline().rstrip() == b"TOKEN fixture-only"
        self.wfile.write(b'{"ok":true,"stream":1}\n')
        for line in self.rfile:
            batch = json.loads(line)
            with lock:
                events.extend(("tcp", event) for event in batch["events"])
            self.wfile.write(b'{"ok":true,"x":230,"y":140}\n')


def compile_swift(output, *sources):
    subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-o", output, *sources], check=True)


def run():
    with tempfile.TemporaryDirectory() as directory:
        tmp = Path(directory)
        helper = (ROOT / "mac-helper.swift").read_text()
        code, entry = helper.rsplit("let helper = KvmHelper()", 1)
        assert entry.strip() == "helper.run()"
        (tmp / "main.swift").write_text(code + (TESTS / "HelperChecks.swift").read_text()
                                       + (TESTS / "ClipboardTreeChecks.swift").read_text())
        compile_swift(tmp / "helper-check", tmp / "main.swift", MAC / "FileTransfer.swift", MAC / "WindowsClient.swift")
        with ThreadingHTTPServer(("127.0.0.1", 0), InterruptedDownload) as partial:
            threading.Thread(target=partial.serve_forever, daemon=True).start()
            result = subprocess.check_output([tmp / "helper-check", str(partial.server_port)], text=True, timeout=30)
            partial.shutdown()
        records = [json.loads(line) for line in result.splitlines()]
        assert {"check": "clipboard-tree-passed"} in records
        print("PASS folder structure, compatibility, whole-selection failure, link handling and interrupted 64-bit file stream cleanup", flush=True)
        assert sum(e.get("kind") == "move" and e.get("dx") == -40 for e in records) == 1000
        returned = next(i for i,e in enumerate(records) if e.get("active") is False and e["type"] == "active")
        assert all(dict(type="key", vk=vk, down=False) in records[:returned] for vk in (87,162))
        assert records[returned-3] == dict(type="mouse", kind="up", button="right")
        print("PASS camera drag, overlapping buttons, edge rearming, game lock, hotkey and releases", flush=True)

        a = records.index({"check": "modifiers"})
        b = records.index({"check": "end-modifiers"})
        observed = [(e["vk"], e["down"]) for e in records[a+1:b]]
        expected = [(162,True),(162,False),(164,True),(164,False)] * 25
        expected += [(162,True),(67,True),(67,False),(162,False),
                     (163,True),(86,True),(86,False),(163,False),
                     (165,True),(164,True),(165,False),(164,False),(162,True),(162,False)]
        assert observed == expected
        print("PASS standalone Ctrl/Alt, duplicate notifications, shared Ctrl, right-side and missed modifier events")

        start = records.index({"check": "missing-up"}) + 1
        stop = records.index({"check": "end-missing-up"})
        key_records = records[start:stop]
        key_edges = [(87, True), (68, True), (87, True), (87, False),
                     (87, True), (87, False), (87, True), (87, False), (68, False),
                     (65, True), (13, True), (13, True), (13, False), (65, False),
                     (87, True), (87, False)]
        assert key_records == [dict(type="key", vk=vk, down=down) for vk, down in key_edges]
        key_stream = tmp / "recovered-keys.jsonl"
        key_stream.write_text("".join(json.dumps(e) + "\n" for e in key_records))

        for _ in range(20):
            http = ThreadingHTTPServer(("127.0.0.1", 0), Http)
            try:
                tcp = socketserver.ThreadingTCPServer(("127.0.0.1", http.server_port + 1), Stream)
                break
            except (OSError, OverflowError):
                http.server_close()
        else:
            raise RuntimeError("No adjacent loopback ports available")
        with http, tcp:
            for server in (http,tcp):
                threading.Thread(target=server.serve_forever, daemon=True).start()
            (tmp / "WindowsClient.swift").write_text((MAC / "WindowsClient.swift").read_text() + "\n"
                                                    + (TESTS / "SessionChecks.swift").read_text())
            (tmp / "AppController.swift").write_text((MAC / "AppController.swift").read_text().replace(
                "NSPasteboard.general", f'NSPasteboard(name: NSPasteboard.Name("lankvm.test.{uuid.uuid4().hex}"))')
                                                     + "\n" + (TESTS / "ControllerChecks.swift").read_text())
            (tmp / "main.swift").write_text("""
import Foundation
Task { @MainActor in
    do { try checkDiagnosticRetention(); WindowsClient().checkCoalescedFeedback(); try await AppController.shared.checkRelay(port: Int(CommandLine.arguments[1])!); exit(0) }
    catch { print(error); exit(1) }
}
dispatchMain()
""")
            compile_swift(tmp / "relay-check", tmp / "main.swift", tmp / "AppController.swift",
                          tmp / "WindowsClient.swift", MAC / "Discovery.swift", MAC / "Settings.swift", MAC / "DiagnosticLog.swift")
            subprocess.run([tmp / "relay-check", str(http.server_port), key_stream], check=True, timeout=30)
            http.shutdown()
            tcp.shutdown()
        print("PASS delayed cursor bursts, fragmented replies, log rotation and retention")
        assert max_posts == 1
        assert [e for transport,e in events if transport == "http" and e.get("op") == "key"] == [
            dict(op="key", vk=162, down=True), dict(op="key", vk=162, down=False)]
        assert [e for transport,e in events if transport == "tcp"] == [
            *[dict(op="key", vk=vk, down=down) for vk, down in key_edges],
            *[dict(op="wheel", delta=delta, horizontal=horizontal) for delta, horizontal in
              [(-120, False), (240, False), (120, True), (120, False), (-240, False), (-120, True)]],
            dict(op="down", button="right"), *[dict(op="moveRel", dx=2, dy=-1)] * 2000,
            dict(op="up", button="right"), dict(op="moveRel", dx=150, dy=-100),
            *[dict(op="key", vk=vk, down=down) for vk,down in [
                (162,True),(86,True),(86,False),(162,False),
                (162,True),(162,False),(162,True),(162,False)]],
            dict(op="moveRel", dx=7, dy=2)]
        assert events[-1][1]["op"] == "release"
        print("PASS missing W release reaches receiver while D stays held; late repeats, re-press and tap recovery")
        print("PASS reverse and matched vertical wheel, horizontal unchanged, no forwarding on Mac")
        print("PASS anonymous discovery, serialized HTTP, ordered key-up, TCP handshake, 2000 individual right-drag samples, ordinary moves coalesced, motion during pending clipboard transfer, disconnect")


if __name__ == "__main__":
    run()
