"""Observe Darwin URLSession cookie headers over fixture-only loopback HTTP."""
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
from urllib.parse import parse_qs, urlsplit

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "build/native-cookie-wire"
SOURCES = [
    "ios/Runner/Native/Networking/HTTP/PiliHTTPClient.swift",
    "ios/Runner/Native/Networking/HTTP/PiliURLSessionHTTPClient.swift",
    "ios/Runner/Native/Networking/HTTP/PiliURLSessionHTTPTransfer.swift",
    "tool/check_native_cookie_wire.swift",
]
SCOPE = "Darwin HTTP/1.1 representation observation; not production native Cookie compatibility"
PENDING_PREFIX = b"x" * 1024


def fixtures():
    cases = [
        ("pair-only-ordered", ["first=one", "second=two", "third=three"]),
        ("pair-only-same-identity", ["same=old", "same=new"]),
        ("ordered", ["first=one; Path=/", "second=two; Path=/", "third=three; Path=/"]),
        ("same-path-forward", ["same=path; Path=/x", "same=root; Path=/"]),
        ("same-path-reverse", ["same=root; Path=/", "same=path; Path=/x"]),
        ("same-identity", ["same=old; Path=/", "same=new; Path=/"]),
        ("expires-separated", ["expires=one; Expires=Wed, 09 Jun 2027 10:18:14 GMT", "tail=two; Path=/"]),
        ("expires-folded", ["expires=one; Expires=Wed, 09 Jun 2027 10:18:14 GMT, tail=two; Path=/"]),
        ("error-cookie", ["error=one; Path=/", "error_tail=two; Path=/"]),
        ("ambiguous-separated", ["a=1; Path=/x", "b=2"]),
        ("ambiguous-literal", ["a=1; Path=/x, b=2"]),
        ("pending-body", ["pending=one; Path=/", "pending_tail=two; Path=/"]),
        ("redirect", ["redirect=one; Path=/"]),
    ]
    return [
        {"id": name, "wireValues": values,
         "statusCode": 403 if name == "error-cookie" else 302 if name == "redirect" else 200,
         "expectedBodyBytes": 0 if name == "pending-body" else len(body_for(name)),
         "cancelAfterHeaders": name == "pending-body"}
        for name, values in cases
    ]


def body_for(name):
    return f"fixture body {name}\n".encode("ascii")


class WireServer(ThreadingHTTPServer):
    daemon_threads = True
    block_on_close = False

    def __init__(self, cases):
        super().__init__(("127.0.0.1", 0), WireHandler)
        self.cases = {item["id"]: item for item in cases}
        self.records = []
        self.record_lock = threading.Lock()

    def snapshot(self):
        with self.record_lock:
            return json.loads(json.dumps(self.records))


class WireHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):
        pass

    def do_GET(self):
        request = urlsplit(self.path)
        name = request.path.removeprefix("/")
        item = self.server.cases.get(name)
        values = list(item["wireValues"]) if item else []
        status = item["statusCode"] if item else 404
        if name == "ambiguous-literal" and request.query:
            supplied = parse_qs(request.query).get("value", [])
            # The observer may replay Darwin's separator, never arbitrary headers.
            if len(supplied) != 1 or supplied[0] not in (
                "a=1; Path=/x,b=2", "a=1; Path=/x, b=2"
            ):
                self.send_error(400, "Unsupported fixture literal")
                return
            values = supplied
        body = body_for(name)
        pending = name == "pending-body"
        fields = [("Set-Cookie", value) for value in values]
        if name == "redirect":
            fields.append(("Location", f"http://127.0.0.1:{self.server.server_port}/redirect-target"))
        fields.extend([("Content-Type", "application/octet-stream" if pending else "text/plain"),
                       ("Content-Length", str(4096 if pending else len(body))),
                       ("Connection", "close")])
        reason = {200: "OK", 302: "Found", 403: "Forbidden", 404: "Not Found"}[status]
        lines = [f"HTTP/1.1 {status} {reason}", *(f"{key}: {value}" for key, value in fields)]
        record = {"id": name, "requestTarget": self.path, "statusCode": status,
                  "wireValues": values, "headerLines": lines,
                  "headerBytesASCII": "\r\n".join(lines) + "\r\n\r\n",
                  "receivedCookie": self.headers.get("Cookie"), "bodyBytesSent": 0}
        with self.server.record_lock:
            self.server.records.append(record)
        self.close_connection = True
        self.connection.settimeout(10)
        try:
            header_bytes = record["headerBytesASCII"].encode("ascii")
            if pending:
                # Darwin may defer delivering the response until body progress.
                # Send a prefix with the headers, leaving the 4096-byte body incomplete.
                self.connection.sendall(header_bytes + PENDING_PREFIX)
                with self.server.record_lock:
                    record["bodyBytesSent"] = len(PENDING_PREFIX)
                # Swift's response callback, not a sleep, triggers cancellation.
                self.connection.recv(1)
            else:
                self.connection.sendall(header_bytes + body)
                with self.server.record_lock:
                    record["bodyBytesSent"] = len(body)
        except (ConnectionError, socket.timeout):
            pass


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")


def main():
    OUTPUT.mkdir(parents=True, exist_ok=True)
    report_path = OUTPUT / "report.json"
    report = {"status": "running", "checks": 0, "os": platform.platform(), "scope": SCOPE,
              "observations": [], "cancellation": {"events": [], "errorCode": 0, "receivedBodyBytes": 0},
              "redirect": {"statusCode": 0, "followed": False}}
    write_json(report_path, report)
    if sys.platform != "darwin":
        report.update(status="skipped", reason="macOS Swift is required; compilation and Darwin wire behavior were not verified")
        write_json(report_path, report)
        print(f"SKIP native Cookie wire observation: {report['reason']} ({sys.platform})")
        return 0

    cases = fixtures()
    manifest = OUTPUT / "fixtures.json"
    write_json(manifest, cases)
    # This ATS exception belongs only to the generated observer executable.
    info_plist = OUTPUT / "observer-info.plist"
    info_plist.write_bytes(plistlib.dumps({
        "CFBundleIdentifier": "org.piliglass.fixture.cookie-wire",
        "NSAppTransportSecurity": {"NSExceptionDomains": {
            "127.0.0.1": {"NSExceptionAllowsInsecureHTTPLoads": True}
        }},
    }))
    executable = OUTPUT / "check-native-cookie-wire"
    command = ["xcrun", "swiftc", "-swift-version", "6", "-strict-concurrency=complete",
               "-parse-as-library", "-o", str(executable),
               "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist",
               "-Xlinker", str(info_plist), *(str(ROOT / source) for source in SOURCES)]
    server = None
    swift_version = None
    try:
        version = subprocess.run(["xcrun", "swiftc", "--version"], capture_output=True, text=True, timeout=15)
        swift_version = version.stdout.strip() or version.stderr.strip()
        server = WireServer(cases)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        compiled = subprocess.run(command, cwd=ROOT, capture_output=True, text=True, timeout=120)
        (OUTPUT / "compile.log").write_text(shlex.join(command) + "\n" + compiled.stdout + compiled.stderr, encoding="utf-8")
        if compiled.returncode:
            report.update(status="failed", stage="compile", exitCode=compiled.returncode)
            print(compiled.stdout + compiled.stderr, end="")
            return compiled.returncode
        endpoint = f"http://127.0.0.1:{server.server_port}/"
        result = subprocess.run([str(executable), endpoint, str(manifest), str(report_path)],
                                cwd=ROOT, capture_output=True, text=True, timeout=45)
        result_text = result.stdout + result.stderr
        (OUTPUT / "result.log").write_text(result_text, encoding="utf-8")
        print(result_text, end="")
        report = json.loads(report_path.read_text(encoding="utf-8"))
        report["exitCode"] = result.returncode
        records = server.snapshot()
        by_id = {item["id"]: item for item in records}
        followed = "redirect-target" in by_id
        report["redirect"]["followed"] = followed or report["redirect"]["followed"]
        problems = []
        if result.returncode or report.get("status") != "passed":
            problems.append("Swift wire observer failed")
        if len(records) != len(cases) or set(by_id) != {item["id"] for item in cases}:
            problems.append("Unexpected, repeated, or missing fixture request")
        for observation in report.get("observations", []):
            sent = by_id.get(observation["id"])
            if sent and observation["wireValues"] != sent["wireValues"]:
                problems.append(f"Wire values differ from server evidence: {observation['id']}")
        if followed:
            problems.append("Production redirect delegate forwarded the request")
        if by_id.get("pending-body", {}).get("bodyBytesSent") != len(PENDING_PREFIX):
            problems.append("Cancellation fixture did not retain an incomplete body")
        report["checks"] += 3
        if problems:
            report.update(status="failed", failures=problems)
        return 0 if report["status"] == "passed" else 1
    except (OSError, subprocess.TimeoutExpired, ValueError, KeyError) as error:
        report.update(status="failed", reason=str(error))
        print(f"Native Cookie wire observation failed: {error}")
        return 1
    finally:
        if server:
            server.shutdown()
            server.server_close()
            write_json(OUTPUT / "server-wire.json", server.snapshot())
        report["scope"] = SCOPE
        report["swiftVersion"] = swift_version
        write_json(report_path, report)


if __name__ == "__main__":
    raise SystemExit(main())
