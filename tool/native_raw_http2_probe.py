"""Real TLS/ALPN/HTTP2 duplicate fields; no system trust-store modification."""
import base64
import gzip
import json
import os
from pathlib import Path
import socket
import socketserver
import ssl
import subprocess
import sys
import threading
import time

ROOT = Path(__file__).resolve().parents[1]
PACKAGE = ROOT / 'Packages/PiliHTTPTransport'
OUTPUT = ROOT / 'build/native-raw-http2-check'


def cases():
    body = b'synthetic TLS HTTP2 body\n'
    values = [
        ('single', 200, ['one=value; Path=/'], body, 'normal'),
        ('duplicates', 200, ['same=first; Path=/', 'same=second; Path=/x', 'same=third; Path=/'], body, 'normal'),
        ('expires', 200, ['a=one; Expires=Wed, 09 Jun 2027 10:18:14 GMT', 'b=two; Path=/'], body, 'normal'),
        ('empty', 200, ['a=; Path=/', 'b=two; Path=/'], body, 'normal'),
        ('forbidden', 403, ['denied=retained; Path=/'], body, 'normal'),
        ('gzip', 200, ['gzip=raw; Path=/'], gzip.compress(body, mtime=0), 'gzip'),
        ('cancel', 200, ['cancel=head; Path=/'], b'x' * 4096, 'cancel'),
    ]
    return [dict(id=name, status=status, fields=fields, bodyBase64=base64.b64encode(data).decode(), mode=mode,
                 body=data) for name, status, fields, data, mode in values]


def run(command, name, cwd=ROOT, env=None, timeout=1200):
    result = subprocess.run(command, cwd=cwd, env=env, capture_output=True, text=True, timeout=timeout)
    (OUTPUT / name).write_text(' '.join(command) + '\n' + result.stdout + result.stderr, encoding='utf-8')
    if result.returncode:
        print((result.stdout + result.stderr)[-12000:])
        raise RuntimeError(f'{name}: failed ({result.returncode})')


def certificates():
    ca = OUTPUT / 'ca.pem'
    ca_key = OUTPUT / 'ca-key.pem'
    ca_config = OUTPUT / 'ca.cnf'
    ca_config.write_text('[req]\ndistinguished_name=dn\nx509_extensions=ca\nprompt=no\n[dn]\nCN=PiliGlass Synthetic TLS Fixture\n[ca]\nbasicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign,cRLSign\n', encoding='ascii')
    run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1', '-config', str(ca_config),
         '-keyout', str(ca_key), '-out', str(ca)], 'certificate-ca.log', timeout=60)
    for name, ip in [('server', '127.0.0.1'), ('wrong-name', '127.0.0.2')]:
        key, request, cert = [OUTPUT / (name + extension) for extension in ['-key.pem', '.csr', '.pem']]
        extensions = OUTPUT / (name + '.cnf')
        extensions.write_text('basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectAltName=IP:' + ip + '\n', encoding='ascii')
        run(['openssl', 'req', '-new', '-newkey', 'rsa:2048', '-nodes', '-subj', '/CN=Synthetic loopback fixture',
             '-keyout', str(key), '-out', str(request)], name + '-key.log', timeout=60)
        run(['openssl', 'x509', '-req', '-in', str(request), '-CA', str(ca), '-CAkey', str(ca_key),
             '-CAcreateserial', '-out', str(cert), '-days', '1', '-extfile', str(extensions)],
            name + '-certificate.log', timeout=60)
    return ca


class TLSServer(socketserver.ThreadingTCPServer):
    daemon_threads = True
    block_on_close = False
    allow_reuse_address = True

    def __init__(self, name, alpn, fixtures):
        self.name = name
        self.fixtures = {item['id']: item for item in fixtures}
        self.records = []
        self.lock = threading.Lock()
        self.context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        self.context.minimum_version = ssl.TLSVersion.TLSv1_2
        cert_name = 'wrong-name' if name == 'wrong-name' else 'server'
        self.context.load_cert_chain(str(OUTPUT / (cert_name + '.pem')), str(OUTPUT / (cert_name + '-key.pem')))
        self.context.set_alpn_protocols(alpn)
        super().__init__(('127.0.0.1', 0), TLSHandler)


class TLSHandler(socketserver.BaseRequestHandler):
    def handle(self):
        self.request.settimeout(10)
        connection = None
        try:
            connection = self.server.context.wrap_socket(self.request, server_side=True)
            protocol = connection.selected_alpn_protocol()
            with self.server.lock:
                self.server.records.append(dict(event='handshake', protocol=protocol, timestamp=time.monotonic()))
            if protocol == 'h2': self.http2(connection)
            elif protocol in ('http/1.1', None): self.http1(connection)
            else: raise RuntimeError('unexpected ALPN ' + str(protocol))
        except (ssl.SSLError, ConnectionError, socket.timeout) as error:
            with self.server.lock:
                self.server.records.append(dict(event='connection-ended', type=type(error).__name__))
        except Exception as error:
            with self.server.lock:
                self.server.records.append(dict(event='unexpected-error', error=repr(error)))
        finally:
            if connection is not None: connection.close()

    def fixture(self, path, protocol, headers):
        parts = path.strip('/').split('/')
        name = parts[-1]
        fixture = self.server.fixtures.get(name)
        record = dict(event='request', path=path, protocol=protocol, fixture=name, headers=headers)
        if fixture is None: record['unexpectedRequest'] = True
        with self.server.lock: self.server.records.append(record)
        return fixture

    def http1(self, connection):
        pending = b''
        while True:
            while b'\r\n\r\n' not in pending:
                data = connection.recv(65536)
                if not data: return
                pending += data
                if len(pending) > 65536: raise RuntimeError('oversized request headers')
            head, pending = pending.split(b'\r\n\r\n', 1)
            lines = head.decode('ascii').split('\r\n')
            method, path, version = lines[0].split(' ', 2)
            headers = [line.split(':', 1) for line in lines[1:]]
            fixture = self.fixture(path, 'http/1.1', headers)
            if method != 'GET' or version != 'HTTP/1.1' or fixture is None: return
            body = fixture['body']
            fields = [('Set-Cookie', value) for value in fixture['fields']]
            fields += [('Content-Type', 'application/octet-stream'), ('Content-Length', str(len(body))), ('Connection', 'keep-alive')]
            if fixture['mode'] == 'gzip': fields.append(('Content-Encoding', 'gzip'))
            response = '\r\n'.join([f"HTTP/1.1 {fixture['status']} Fixture", *(f'{key}: {value}' for key, value in fields)]) + '\r\n\r\n'
            connection.sendall(response.encode('ascii'))
            connection.sendall(body[:1] if fixture['mode'] == 'cancel' else body)

    def http2(self, connection):
        from h2.config import H2Configuration
        from h2.connection import H2Connection
        from h2.events import ConnectionTerminated, RequestReceived, StreamReset
        h2 = H2Connection(config=H2Configuration(client_side=False, header_encoding='utf-8'))
        h2.initiate_connection(); connection.sendall(h2.data_to_send())
        while True:
            data = connection.recv(65536)
            if not data: return
            for event in h2.receive_data(data):
                if isinstance(event, RequestReceived):
                    headers = list(event.headers)
                    path = next((value for key, value in headers if key == ':path'), '')
                    fixture = self.fixture(path, 'h2', headers)
                    if fixture is None: return
                    fields = [(':status', str(fixture['status'])), ('content-type', 'application/octet-stream'),
                              ('content-length', str(len(fixture['body'])))]
                    fields += [('set-cookie', value) for value in fixture['fields']]
                    if fixture['mode'] == 'gzip': fields.append(('content-encoding', 'gzip'))
                    h2.send_headers(event.stream_id, fields)
                    cancel = fixture['mode'] == 'cancel'
                    h2.send_data(event.stream_id, fixture['body'][:1] if cancel else fixture['body'], end_stream=not cancel)
                elif isinstance(event, StreamReset):
                    with self.server.lock:
                        self.server.records.append(dict(event='stream-reset', stream=event.stream_id, errorCode=int(event.error_code)))
                elif isinstance(event, ConnectionTerminated): return
            outgoing = h2.data_to_send()
            if outgoing: connection.sendall(outgoing)


def main():
    OUTPUT.mkdir(parents=True, exist_ok=True)
    summary = dict(status='failed', platform=sys.platform, runtimeEnabled=False,
                   scope='actual TLS/ALPN HTTP2 and HTTP11 fields, hostname/system trust, fallback; proxy unsupported')
    servers = []
    try:
        if sys.platform != 'darwin': raise RuntimeError('macOS/Xcode required; native HTTP2 acceptance not verified')
        runtime = OUTPUT / 'python-runtime'
        run([sys.executable, '-m', 'pip', 'install', '--quiet', '--target', str(runtime), 'h2==4.3.0', 'hpack==4.1.0', 'hyperframe==6.1.0'],
            'python-dependencies.log', timeout=180)
        sys.path.insert(0, str(runtime))
        fixtures = cases()
        (OUTPUT / 'fixtures.json').write_text(json.dumps([{key: value for key, value in item.items() if key != 'body'} for item in fixtures], indent=2) + '\n', encoding='utf-8')
        ca = certificates()
        for name, alpn in [('dual', ['h2', 'http/1.1']), ('h1', ['http/1.1']), ('wrong-name', ['h2', 'http/1.1'])]:
            server = TLSServer(name, alpn, fixtures); servers.append(server)
            threading.Thread(target=server.serve_forever, daemon=True).start()
        env = {**os.environ, 'PILI_RAW_TLS_BASE': f'https://127.0.0.1:{servers[0].server_address[1]}',
               'PILI_RAW_TLS_H1_BASE': f'https://127.0.0.1:{servers[1].server_address[1]}',
               'PILI_RAW_TLS_BAD_NAME_BASE': f'https://127.0.0.1:{servers[2].server_address[1]}',
               'PILI_RAW_TLS_TRUST_ROOT': str(ca), 'PILI_RAW_TLS_OUTPUT': str(OUTPUT)}
        run(['swift', 'test', '--filter', 'rawTLSAndHTTP2Probe'], 'http2-wire.log', cwd=PACKAGE, env=env)
        observations = json.loads((OUTPUT / 'observations.json').read_text(encoding='utf-8'))
        if len(observations) != 19: raise RuntimeError('expected 14 transfer + 4 trust/name + 1 fallback observations')
        dual_records = servers[0].records
        for label, protocol in [('automatic', 'h2'), ('http11', 'http/1.1')]:
            for fixture in fixtures:
                path = '/' + label + '/' + fixture['id']
                records = [item for item in dual_records if item.get('path') == path]
                if len(records) != 1 or records[0]['protocol'] != protocol:
                    raise RuntimeError(f'actual TLS ALPN request mismatch: {path}')
                observation = next(item for item in observations if item['id'] == fixture['id'] and item['protocolMode'] == label)
                if observation['fields'] != fixture['fields'] or observation['status'] != fixture['status']:
                    raise RuntimeError(f'raw repeated field order/status mismatch: {path}')
                if fixture['mode'] != 'cancel' and observation.get('bodyBase64') != fixture['bodyBase64']:
                    raise RuntimeError(f'compression/body mismatch: {path}')
            if any(item.get('path') == '/' + label + '/untrusted' for item in dual_records):
                raise RuntimeError('public system trust unexpectedly accepted synthetic CA')
        if any(item.get('event') == 'request' for item in servers[2].records):
            raise RuntimeError('trusted wrong-host certificate accepted')
        fallback = [item for item in servers[1].records if item.get('path') == '/fallback/single']
        if len(fallback) != 1 or fallback[0]['protocol'] != 'http/1.1': raise RuntimeError('automatic HTTP11 fallback not observed')
        for server in servers:
            if any(item.get('event') == 'unexpected-error' or item.get('unexpectedRequest') for item in server.records):
                raise RuntimeError('server encountered an unexpected protocol event/request')
        summary.update(status='passed', transfers=14, trust_rejections=2, hostname_rejections=2,
                       automatic_h1_fallback=1, http2Requests=7, http11Requests=8)
    except (OSError, RuntimeError, subprocess.TimeoutExpired, json.JSONDecodeError) as error:
        summary['reason'] = str(error); print(f'FAIL native raw HTTP2: {error}')
    finally:
        records = {}
        for server in servers:
            server.shutdown(); server.server_close(); records[server.name] = server.records
        (OUTPUT / 'server-records.json').write_text(json.dumps(records, indent=2) + '\n', encoding='utf-8')
        (OUTPUT / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(summary, indent=2))
    return 0 if summary['status'] == 'passed' else 1


if __name__ == '__main__':
    raise SystemExit(main())
