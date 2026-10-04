"""Real raw H1 fields, compression bytes, idle timeout and iOS package builds."""
import base64
import gzip
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import threading
import time

ROOT = Path(__file__).resolve().parents[1]
PACKAGE = ROOT / 'Packages/PiliHTTPTransport'
OUTPUT = ROOT / 'build/native-raw-http-check'


def cases():
    body = b'raw transfer synthetic body\n'
    values = [
        ('single', ['one=value; Path=/'], 200, 'normal', body),
        ('path-boundary', ['same=path; Path=/x', 'same=root; Path=/'], 200, 'normal', body),
        ('expires-boundary', ['a=one; Expires=Wed, 09 Jun 2027 10:18:14 GMT', 'b=two'], 200, 'normal', body),
        ('empty-field', ['a=; Path=/', 'b=value; Path=/x'], 200, 'normal', body),
        ('forbidden', ['denied=saved; Path=/'], 403, 'normal', body),
        ('redirect', ['redirect=original; Path=/'], 302, 'normal', body),
        ('cancel-head', ['cancel=retained; Path=/'], 200, 'pending', body),
        ('cancel-before', [], 200, 'no-head', body),
        ('early-eof', ['eof=retained; Path=/'], 200, 'eof', body),
        ('keepalive-one', ['keep=one; Path=/'], 200, 'keepalive', body),
        ('keepalive-two', ['keep=two; Path=/'], 200, 'keepalive', body),
        ('gzip-raw', ['gzip=raw; Path=/'], 200, 'gzip', gzip.compress(body, mtime=0)),
        # Total exceeds default resource=10s; each real network chunk gap < idle=10s.
        ('long-stream', ['long=head; Path=/'], 200, 'long-stream', b'x' * 12),
        ('idle-timeout', ['idle=head; Path=/'], 200, 'idle-timeout', body),
    ]
    return [dict(id=name, wireValues=cookies, statusCode=status, mode=mode,
                 expectedBodyBase64=base64.b64encode(data).decode(), body=data)
            for name, cookies, status, mode, data in values]


class Server(ThreadingHTTPServer):
    daemon_threads = True
    block_on_close = False

    def __init__(self, fixtures):
        self.fixtures = {item['id']: item for item in fixtures}
        self.records = []
        self.lock = threading.Lock()
        self.connection_ids = {}
        super().__init__(('127.0.0.1', 0), Handler)

    def get_request(self):
        connection, address = super().get_request()
        with self.lock:
            self.connection_ids[connection] = len(self.connection_ids) + 1
        return connection, address


class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def log_message(self, *_): pass

    def do_GET(self):
        name = self.path.lstrip('/')
        item = self.server.fixtures.get(name)
        if item is None:
            with self.server.lock:
                self.server.records.append(dict(id=name, unexpectedRequest=True))
            self.send_error(404)
            return
        mode, body = item['mode'], item['body']
        record = dict(id=name, connectionID=self.server.connection_ids[self.connection],
                      received=time.monotonic(), cookieFields=item['wireValues'], chunks=[])
        with self.server.lock: self.server.records.append(record)
        (OUTPUT / ('seen-' + name)).write_text('received', encoding='ascii')
        self.close_connection = mode != 'keepalive'
        self.connection.settimeout(15)
        try:
            if mode == 'no-head':
                self.connection.recv(1)
                return
            fields = [('Set-Cookie', v) for v in item['wireValues']]
            fields += [('Content-Length', str(4096 if mode in ('pending', 'eof') else len(body))),
                       ('Content-Type', 'application/octet-stream'),
                       ('Connection', 'keep-alive' if mode == 'keepalive' else 'close')]
            if mode == 'gzip': fields += [('Content-Encoding', 'gzip')]
            if name == 'redirect': fields += [('Location', f'http://127.0.0.1:{self.server.server_port}/unexpected-redirect')]
            head = '\r\n'.join([f"HTTP/1.1 {item['statusCode']} Fixture", *(f'{k}: {v}' for k,v in fields)])+'\r\n\r\n'
            self.connection.sendall(head.encode('ascii'))
            record['headSent'] = time.monotonic()
            if mode == 'long-stream':
                for byte in body:
                    self.connection.sendall(bytes([byte]))
                    record['chunks'].append(time.monotonic())
                    time.sleep(1)
            elif mode == 'idle-timeout':
                self.connection.sendall(body[:1]); record['chunks'].append(time.monotonic())
                time.sleep(11)
                self.connection.sendall(body[1:])
            else:
                self.connection.sendall(b'x' * 1024 if mode in ('pending', 'eof') else body)
                record['chunks'].append(time.monotonic())
                if mode == 'pending': self.connection.recv(1)
        except (ConnectionError, socket.timeout):
            record['closedDuringTransfer'] = True


def run(command, log, timeout=1200, env=None):
    result = subprocess.run(command, cwd=PACKAGE, capture_output=True, text=True, timeout=timeout, env=env)
    (OUTPUT/log).write_text(' '.join(command)+'\n'+result.stdout+result.stderr, encoding='utf-8')
    if result.returncode:
        print((result.stdout+result.stderr)[-16000:])
        raise RuntimeError(f'{log}: command failed ({result.returncode})')


def main():
    import os
    OUTPUT.mkdir(parents=True, exist_ok=True)
    summary = dict(status='failed', platform=sys.platform, runtimeEnabled=False)
    try:
        if sys.platform != 'darwin': raise RuntimeError('macOS/Xcode required; transport unverified')
        fixtures = cases()
        (OUTPUT/'fixtures.json').write_text(json.dumps([{k:v for k,v in item.items() if k!='body'} for item in fixtures],indent=2)+'\n',encoding='utf-8')
        for item in fixtures:
            (OUTPUT/('seen-'+item['id'])).unlink(missing_ok=True)
        run(['swift','package','resolve'], 'resolve.log')
        resolved = PACKAGE/'Package.resolved'
        if resolved.exists(): shutil.copy2(resolved, OUTPUT/'Package.resolved')
        server = Server(fixtures)
        thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
        try:
            env = {**os.environ, 'PILI_RAW_WIRE_BASE': f'http://127.0.0.1:{server.server_port}', 'PILI_RAW_WIRE_OUTPUT':str(OUTPUT)}
            run(['swift','test'], 'wire.log', env=env)
        finally:
            server.shutdown(); server.server_close(); thread.join(timeout=2)
            (OUTPUT/'server-events.json').write_text(json.dumps(server.records,indent=2)+'\n',encoding='utf-8')
        observations = json.loads((OUTPUT/'observations.json').read_text(encoding='utf-8'))
        if len(observations) != len(fixtures): raise RuntimeError('Missing raw wire observations')
        if any(record.get('unexpectedRequest') for record in server.records): raise RuntimeError('Client followed redirect')
        records = {record['id']:record for record in server.records}
        if records['keepalive-one']['connectionID'] != records['keepalive-two']['connectionID']:
            raise RuntimeError('Default pool did not reuse actual keepalive socket')
        if records['long-stream']['chunks'][-1] - records['long-stream']['chunks'][0] <= 10:
            raise RuntimeError('Long body fixture did not exercise total vs idle timeout')
        # Standalone module device and simulator builds prove the same package
        # against iOS16 SDK targets independently of macOS wire behavior.
        for destination,label in [('generic/platform=iOS','device'),('generic/platform=iOS Simulator','simulator')]:
            run(['xcodebuild','-scheme','PiliHTTPTransport','-destination',destination,
                 '-derivedDataPath',str(OUTPUT/'DerivedData'), 'IPHONEOS_DEPLOYMENT_TARGET=16.0',
                 'CODE_SIGNING_ALLOWED=NO','build'],f'{label}-build.log',timeout=1800)
        summary.update(status='passed', wireCases=len(observations), ios16Device=True, ios16Simulator=True,
                       knownPending=['Dio wire comparison','br decoder','H2/TLS/proxy/pool expiry','retry','actual API/account acceptance'])
    except (OSError,RuntimeError,subprocess.TimeoutExpired) as error:
        summary['reason']=str(error); print(f'FAIL raw HTTP: {error}')
    (OUTPUT/'summary.json').write_text(json.dumps(summary,indent=2)+'\n',encoding='utf-8')
    return 0 if summary['status']=='passed' else 1


if __name__ == '__main__': raise SystemExit(main())
