"""Exercise production HTTP transfers over fixture-only Darwin loopback HTTP."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import platform
import plistlib
import shlex
import socket
import subprocess
import sys
import threading

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "build/native-http-transfer-check"
SOURCES = [
    "ios/Runner/Native/Bridge/PiliBridgeValue.swift",
    "ios/Runner/Native/Bridge/PiliBridgeMethodInvoker.swift",
    "ios/Runner/Native/Bridge/PiliBridgeLeaseFinalizer.swift",
    "ios/Runner/Native/Networking/HTTP/PiliPreparedHTTPPolicy.swift",
    "ios/Runner/Native/Networking/HTTP/PiliPreparedHTTPPolicyCodec.swift",
    "ios/Runner/Native/Domain/Accounts/PiliHTTPRequestContext.swift",
    "ios/Runner/Native/Data/Accounts/PiliHTTPRequestContextBridgeCodec.swift",
    "ios/Runner/Native/Data/Accounts/PiliFlutterHTTPRequestContextProvider.swift",
    "ios/Runner/Native/Data/Accounts/PiliHTTPRequestHeaderFinalizer.swift",
    "ios/Runner/Native/Networking/HTTP/PiliHTTPClient.swift",
    "ios/Runner/Native/Networking/HTTP/PiliURLSessionHTTPClient.swift",
    "ios/Runner/Native/Networking/HTTP/PiliURLSessionHTTPTransfer.swift",
    "tool/prepared_http_policy_fixture.swift",
    "tool/check_native_http_transfer.swift",
]


def fixtures():
    items = [
        ("single-cookie", ["wire_single=one; Path=/"], 200, "normal"),
        ("error-cookie", ["wire_error=denied; Path=/"], 403, "normal"),
        ("path-ambiguous", ["path_a=one; Path=/x", "path_b=two"], 200, "normal"),
        ("expires-ambiguous", ["expires_a=one; Expires=Wed, 09 Jun 2027 10:18:14 GMT", "expires_b=two; Path=/"], 200, "normal"),
        ("cancel-after-head", ["wire_cancel=retained; Path=/"], 200, "pending"),
        ("cancel-before-head", [], 200, "no-head"),
        ("redirect", ["wire_redirect=original; Path=/"], 302, "normal"),
        ("early-eof", ["wire_eof=retained; Path=/"], 200, "eof"),
        ("concurrent-cancel", ["wire_concurrent=cancel; Path=/"], 200, "pending"),
        ("concurrent-complete", ["wire_concurrent=success; Path=/"], 200, "normal"),
        ("keepalive-one", ["wire_keepalive=one; Path=/"], 200, "keepalive"),
        ("keepalive-two", ["wire_keepalive=two; Path=/"], 200, "keepalive"),
    ]
    return [dict(id=name, wireValues=values, statusCode=status, mode=mode,
                 bodyBytes=0 if mode in ("pending", "no-head", "eof") else len(body_for(name)))
            for name, values, status, mode in items]


def body_for(name):
    return f"production transfer fixture {name}\n".encode("ascii")


class TransferServer(ThreadingHTTPServer):
    daemon_threads = True
    block_on_close = False

    def __init__(self, cases):
        self.lock = threading.Lock()
        self.records = []
        self.connection_ids = {}
        self.socket_count = 0
        self.cases = {item["id"]: item for item in cases}
        super().__init__(("127.0.0.1", 0), TransferHandler)

    def get_request(self):
        connection, address = super().get_request()
        with self.lock:
            self.socket_count += 1
            self.connection_ids[connection] = self.socket_count
        return connection, address

    def snapshot(self):
        with self.lock:
            return json.loads(json.dumps(self.records))


class TransferHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):
        pass

    def do_GET(self):
        name = self.path.removeprefix("/")
        item = self.server.cases.get(name)
        mode = item["mode"] if item else "normal"
        status = item["statusCode"] if item else 404
        values = item["wireValues"] if item else []
        body = body_for(name)
        record = dict(id=name, wireValues=values, statusCode=status,
                      bodyBytesSent=0, connectionID=self.server.connection_ids[self.connection])
        with self.server.lock:
            self.server.records.append(record)
        (OUTPUT / f"seen-{name}").write_text("received", encoding="ascii")
        self.close_connection = mode != "keepalive"
        self.connection.settimeout(8)
        try:
            if mode == "no-head":
                self.connection.recv(1)
                return
            fields = [("Set-Cookie", value) for value in values]
            if name == "redirect":
                fields.append(("Location", f"http://127.0.0.1:{self.server.server_port}/redirect-target"))
            fields.extend([("Content-Type", "application/octet-stream"),
                           ("Content-Length", str(4096 if mode in ("pending", "eof") else len(body))),
                           ("Connection", "keep-alive" if mode == "keepalive" else "close")])
            reason = {200: "OK", 302: "Found", 403: "Forbidden", 404: "Not Found"}[status]
            header = "\r\n".join([f"HTTP/1.1 {status} {reason}", *(f"{key}: {value}" for key, value in fields)]) + "\r\n\r\n"
            record["headerBytesASCII"] = header
            prefix = b"x" * 1024 if mode in ("pending", "eof") else body
            self.connection.sendall(header.encode("ascii") + prefix)
            with self.server.lock:
                record["bodyBytesSent"] = len(prefix)
            if mode == "pending":
                self.connection.recv(1)
        except (ConnectionError, socket.timeout):
            pass


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")


def main():
    OUTPUT.mkdir(parents=True, exist_ok=True)
    report_path = OUTPUT / "report.json"
    report = dict(status="running", checks=0, os=platform.platform(), observations=[],
                  scope="Production lower transfer over loopback HTTP; external client HTTPS policy unchanged; Native runtime disabled")
    if sys.platform != "darwin":
        report.update(status="skipped", reason="macOS Swift is required; Darwin transfers and compilation were not verified")
        write_json(report_path, report)
        print(f"SKIP native HTTP transfer: {report['reason']} ({sys.platform})")
        return 0
    cases = fixtures()
    manifest = OUTPUT / "fixtures.json"
    write_json(manifest, cases)
    for item in cases:
        (OUTPUT / f"seen-{item['id']}").unlink(missing_ok=True)
    info = OUTPUT / "observer-info.plist"
    info.write_bytes(plistlib.dumps({
        "CFBundleIdentifier": "org.piliglass.fixture.http-transfer",
        "NSAppTransportSecurity": {"NSExceptionDomains": {
            "127.0.0.1": {"NSExceptionAllowsInsecureHTTPLoads": True}
        }},
    }))
    executable = OUTPUT / "check-native-http-transfer"
    command = ["xcrun", "swiftc", "-swift-version", "6", "-strict-concurrency=complete",
               "-parse-as-library", "-o", str(executable),
               "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", str(info),
               *(str(ROOT / source) for source in SOURCES)]
    server = None
    try:
        server = TransferServer(cases)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        compiled = subprocess.run(command, cwd=ROOT, capture_output=True, text=True, timeout=120)
        (OUTPUT / "compile.log").write_text(shlex.join(command) + "\n" + compiled.stdout + compiled.stderr, encoding="utf-8")
        if compiled.returncode:
            report.update(status="failed", stage="compile", exitCode=compiled.returncode)
            print(compiled.stdout + compiled.stderr, end="")
            return compiled.returncode
        result = subprocess.run([str(executable), f"http://127.0.0.1:{server.server_port}/", str(manifest), str(report_path)],
                                cwd=ROOT, capture_output=True, text=True, timeout=45)
        (OUTPUT / "result.log").write_text(result.stdout + result.stderr, encoding="utf-8")
        print(result.stdout + result.stderr, end="")
        report = json.loads(report_path.read_text(encoding="utf-8"))
        records = server.snapshot()
        by_id = {record["id"]: record for record in records}
        problems = []
        if result.returncode or report.get("status") != "passed":
            problems.append("Production Swift transfer checks failed")
        if len(records) != len(cases) or set(by_id) != {item["id"] for item in cases}:
            problems.append("Missing/duplicate request or redirect target followed")
        for observation in report.get("observations", []):
            if observation["wireValues"] != by_id.get(observation["id"], {}).get("wireValues"):
                problems.append(f"Observed raw Cookie input differs from wire: {observation['id']}")
        keepalive = [by_id.get(name, {}).get("connectionID") for name in ("keepalive-one", "keepalive-two")]
        report["keepalive"] = dict(connectionIDs=keepalive, uniqueSocketCount=len(set(keepalive)))
        if None in keepalive or len(set(keepalive)) != 1:
            problems.append("Sequential keep-alive transfers did not reuse one actual accepted socket")
        for name in ("cancel-after-head", "concurrent-cancel", "early-eof"):
            if by_id.get(name, {}).get("bodyBytesSent") != 1024:
                problems.append(f"Missing 1024/4096 incomplete-body evidence: {name}")
        report["checks"] += 4
        report["exitCode"] = result.returncode
        if problems:
            report.update(status="failed", failures=problems)
        return 0 if report["status"] == "passed" else 1
    except (OSError, subprocess.TimeoutExpired, ValueError, KeyError) as error:
        report.update(status="failed", reason=str(error))
        print(f"Native HTTP transfer checks failed: {error}")
        return 1
    finally:
        if server:
            server.shutdown()
            server.server_close()
            write_json(OUTPUT / "server-wire.json", server.snapshot())
            report["acceptedSocketCount"] = server.socket_count
        write_json(report_path, report)


if __name__ == "__main__":
    raise SystemExit(main())
