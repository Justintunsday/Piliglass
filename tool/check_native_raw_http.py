"""Real raw H1 fields, compression bytes, idle timeout and iOS package builds."""
import base64
import errno
import gzip
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import shutil
import socket
from socketserver import BaseRequestHandler, ThreadingTCPServer
import subprocess
import sys
import threading
import time

ROOT = Path(__file__).resolve().parents[1]
PACKAGE = ROOT / 'Packages/PiliHTTPTransport'
OUTPUT = ROOT / 'build/native-raw-http-check'

RETRY_CASES = {
    'closed-before-head': {'error': 'connectionError', 'attempts': 3},
    'incomplete-head': {'error': 'connectionError', 'attempts': 3},
    'wait-before-head': {'error': 'receiveTimeout', 'attempts': 1},
    'early-eof': {'error': 'unknown', 'attempts': 3},
    'chunked-eof': {'error': 'unknown', 'attempts': 3},
    'follow-closed': {'error': 'connectionError', 'attempts': 3},
    'follow-body-eof': {'error': 'unknown', 'attempts': 3},
}
CLOSED_HEAD_MODES = ('closed-before-head', 'incomplete-head')
TRUNCATED_BODY_MODES = ('eof', 'chunked-eof')


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
        ('closed-before-head', [], None, 'closed-before-head', b''),
        ('incomplete-head', [], None, 'incomplete-head', b''),
        ('wait-before-head', [], None, 'wait-before-head', b''),
        ('early-eof', ['eof=retained; Path=/'], 200, 'eof', body),
        ('chunked-eof', ['cut=chunked; Path=/'], 200, 'chunked-eof', body),
        ('connection-delimited', ['complete=close; Path=/'], 200, 'connection-delimited', body),
        ('keepalive-one', ['keep=one; Path=/'], 200, 'keepalive', body),
        ('keepalive-two', ['keep=two; Path=/'], 200, 'keepalive', body),
        ('gzip-raw', ['gzip=raw; Path=/'], 200, 'gzip', gzip.compress(body, mtime=0)),
        # Total exceeds default resource=10s; each real network chunk gap < idle=10s.
        ('long-stream', ['long=head; Path=/'], 200, 'long-stream', b'x' * 12),
        ('idle-timeout', ['idle=head; Path=/'], 200, 'idle-timeout', body),
    ]
    return [dict(id=name, wireValues=cookies, statusCode=status, mode=mode,
                 locationValues=['/unexpected-redirect,kept', 'unfollowed/next'] if name == 'redirect' else None,
                 nativeError=('remoteConnectionClosed' if mode in CLOSED_HEAD_MODES else
                              'receiveIdleTimeout' if mode == 'wait-before-head' else None),
                 retryReason=('closedBeforeResponseHead' if mode in CLOSED_HEAD_MODES else
                              'incompleteResponseBody' if mode in TRUNCATED_BODY_MODES else None),
                 dartRetry=RETRY_CASES.get(name),
                 expectedBodyBase64=base64.b64encode(data).decode() if status is not None else None, body=data)
            for name, cookies, status, mode, data in values]


def redirects():
    body = b'final redirect body\n'
    # Each route specifies the logical case to which its server event belongs.
    routes = {
        'follow-chain': ('follow-chain', 302, 'follow-next?hop=1', ['first=ignored']),
        'follow-next?hop=1': ('follow-chain', 307, 'follow-result?limit=10', ['next=ignored']),
        'follow-result?limit=10': ('follow-chain', 200, None, ['final=retained; Path=/']),
        'follow-nested': ('follow-nested', 302, 'follow-stage/nested', ['first=ignored']),
        'follow-stage/nested': ('follow-nested', 307, 'terminal', ['next=ignored']),
        'follow-stage/terminal': ('follow-nested', 200, None, ['final=retained']),
        'follow-forbidden': ('follow-forbidden', 303, 'follow-denied', ['first=ignored']),
        'follow-denied': ('follow-forbidden', 403, None, ['denied=retained; Path=/']),
        'follow-terminal': ('follow-terminal', 302, 'follow-terminal-last', ['first=ignored']),
        'follow-terminal-last': ('follow-terminal', 300, None, ['terminal=retained']),
        'follow-limit': ('follow-limit', 308, 'follow-limit-next', ['first=ignored']),
        'follow-limit-next': ('follow-limit', 302, 'unexpected-redirect', ['next=ignored']),
        'follow-zero': ('follow-zero', 302, 'unexpected-redirect', ['zero=ignored']),
        'follow-loop': ('follow-loop', 301, 'follow-loop', ['loop=ignored']),
        'follow-missing': ('follow-missing', 302, None, ['missing=ignored']),
        'follow-other-port': ('follow-other-port', 302, '@other-port', ['first=ignored']),
        'follow-other-target': ('follow-other-port', 200, None, ['other=retained; Path=/']),
        'follow-cancel': ('follow-cancel', 302, 'unexpected-redirect', ['pending=ignored']),
        'follow-closed': ('follow-closed', 302, 'follow-closed-destination', ['first=ignored']),
        'follow-closed-destination': ('follow-closed', None, None, []),
        'follow-body-eof': ('follow-body-eof', 302, 'unexpected-redirect', ['cut=ignored']),
    }
    terminal_locations = {'follow-terminal-last': ['/unused,one/next', '/unused/two/next']}
    modes = [
        (2, ['follow-chain', 'follow-next?hop=1', 'follow-result?limit=10'], None, None),
        (2, ['follow-nested', 'follow-stage/nested', 'follow-stage/terminal'], None, None),
        (1, ['follow-forbidden', 'follow-denied'], None, 'badResponse'),
        (1, ['follow-terminal', 'follow-terminal-last'], None, 'badResponse'),
        (1, ['follow-limit', 'follow-limit-next'], 'redirectLimit', 'unknown'),
        (0, ['follow-zero'], 'redirectLimit', 'unknown'),
        (5, ['follow-loop', 'follow-loop'], 'redirectLoop', 'unknown'),
        (5, ['follow-missing'], 'invalidRedirect', 'unknown'),
        (1, ['follow-other-port', 'follow-other-target'], 'redirectOutsideOrigin', None),
        (2, ['follow-cancel'], 'cancelled', 'cancel'),
        (1, ['follow-closed', 'follow-closed-destination'], 'remoteConnectionClosed', 'connectionError'),
        (1, ['follow-body-eof'], 'remoteConnectionClosed', 'unknown'),
    ]
    fixtures = []
    for limit, paths, native_error, dart_error in modes:
        case_id = paths[0]
        _, status, _, cookies = routes[paths[-1]]
        terminal = dart_error in (None, 'badResponse')
        native_targets = paths[:1] if native_error == 'redirectOutsideOrigin' else paths
        fixtures.append(dict(id=case_id, mode='cancel-redirect' if case_id == 'follow-cancel' else 'follow',
            redirectLimit=limit, nativeError=native_error, dartError=dart_error,
            retryReason=('closedBeforeResponseHead' if case_id == 'follow-closed' else
                         'incompleteResponseBody' if case_id == 'follow-body-eof' else None),
            dartRetry=RETRY_CASES.get(case_id),
            nativeTargets=native_targets, dartTargets=paths,
            redirectLocations=[routes[path][2] for path in paths[:-1]] if native_error is None else None,
            locationValues=terminal_locations.get(paths[-1]),
            legacyCookieTarget='terminal' if case_id == 'follow-nested' else paths[-1],
            statusCode=status if terminal else None, wireValues=cookies if terminal else [],
            expectedBodyBase64=base64.b64encode(body).decode() if terminal else None))
    return fixtures, {
        path: dict(redirectCase=case_id, statusCode=status, location=location, wireValues=cookies,
                   locationValues=terminal_locations.get(path),
                   mode=('pending' if case_id == 'follow-cancel' else 'eof' if case_id == 'follow-body-eof' else
                         'closed-before-head' if status is None else 'keepalive'),
                   body=body if status in (200, 300, 403) else b'intermediate redirect body\n')
        for path, (case_id, status, location, cookies) in routes.items()
    }


def verify_redirect_requests(fixtures, records, client):
    for fixture in fixtures:
        hops = [event for event in records if event.get('redirectCase') == fixture['id'] and event['client'] == client
                and not event['retryProbe']]
        if [hop['id'] for hop in hops] != fixture[client + 'Targets']:
            raise RuntimeError(f"{client} redirect request sequence differed for {fixture['id']}")
        for hop in hops:
            # The pinned Dart SDK may reach the second port, with both
            # credential fields stripped. Swift stops before that request.
            valid = (not hop['hasCredentialHeaders'] if hop['id'] == 'follow-other-target'
                     else hop['retainedFixtureHeaders'])
            if not valid:
                raise RuntimeError(f"{client} redirected headers differed at {hop['id']}")


def verify_retry_requests(fixtures, records, *, check_native=True):
    for fixture in fixtures:
        if not (retry := fixture.get('dartRetry')): continue
        dart_targets = fixture.get('dartTargets', [fixture['id']])
        observed_dart = [event['id'] for event in records if event.get('client') == 'dart'
                         and event['retryProbe'] and event['id'] in dart_targets]
        if observed_dart != dart_targets * retry['attempts']:
            raise RuntimeError(f"Dart retry request sequence differed for {fixture['id']}")
        if check_native:
            native_targets = fixture.get('nativeTargets', [fixture['id']])
            observed_native = [event['id'] for event in records if event.get('client') == 'native'
                               and event['id'] in native_targets]
            if observed_native != native_targets:
                raise RuntimeError(f"Raw client silently resent {fixture['id']}")


class TLSStallHandler(BaseRequestHandler):
    def handle(self):
        self.request.settimeout(10)
        try:
            if self.request.recv(1) != b'\x16': return
            with self.server.lock:
                self.server.handshakes += 1
            # Read the ClientHello without ever completing the handshake.
            while self.request.recv(4096): pass
        except (ConnectionError, socket.timeout):
            pass


class TLSStallServer(ThreadingTCPServer):
    daemon_threads = True
    block_on_close = False

    def __init__(self):
        self.lock = threading.Lock()
        self.handshakes = 0
        super().__init__(('127.0.0.1', 0), TLSStallHandler)


class Server(ThreadingHTTPServer):
    daemon_threads = True
    block_on_close = False

    def __init__(self, routes, *, redirect_port=None):
        self.routes = routes
        self.redirect_port = redirect_port
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
        client = 'dart' if name.startswith('dart/') else 'native'
        if client == 'dart': name = name.removeprefix('dart/')
        item = self.server.routes.get(name)
        if item is None:
            with self.server.lock:
                self.server.records.append(dict(id=name, unexpectedRequest=True))
            self.send_error(404)
            return
        mode, body = item['mode'], item['body']
        record = dict(id=name, client=client, connectionID=self.server.connection_ids[self.connection],
                      received=time.monotonic(), cookieFields=item['wireValues'], chunks=[],
                      retryProbe=self.headers.get('X-Wire-Retry') == '1')
        if 'redirectCase' in item:
            cookie = self.headers.get('Cookie')
            authorization = self.headers.get('Authorization')
            record.update(redirectCase=item['redirectCase'],
                hasCredentialHeaders=cookie is not None or authorization is not None,
                retainedFixtureHeaders=cookie == 'wire=synthetic' and authorization == 'Bearer synthetic')
        with self.server.lock: self.server.records.append(record)
        marker = 'seen-' + ('dart-' if client == 'dart' else '') + name
        self.close_connection = mode != 'keepalive'
        self.connection.settimeout(15)
        try:
            if mode == 'closed-before-head': return
            if mode == 'incomplete-head':
                self.connection.sendall(b'HTTP/1.1 200 Fixture\r\nContent-Type: application/octet-stream\r\n')
                return
            if mode in ('no-head', 'wait-before-head'):
                if mode == 'no-head': (OUTPUT / marker).write_text('received', encoding='ascii')
                self.connection.recv(1)
                return
            fields = [('Set-Cookie', v) for v in item['wireValues']]
            if mode == 'chunked-eof':
                fields.append(('Transfer-Encoding', 'chunked'))
            elif mode != 'connection-delimited':
                fields.append(('Content-Length', str(4096 if mode in ('pending', 'eof') else len(body))))
            fields += [('Content-Type', 'application/octet-stream'),
                       ('Connection', 'keep-alive' if mode == 'keepalive' else 'close')]
            if mode == 'gzip': fields += [('Content-Encoding', 'gzip')]
            fields.extend(('Location', value) for value in (item.get('locationValues') or ()))
            if location := item.get('location'):
                if location == '@other-port':
                    child = '/dart' if client == 'dart' else ''
                    location = f'http://127.0.0.1:{self.server.redirect_port}{child}/follow-other-target'
                fields.append(('Location', location))
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
                if mode == 'chunked-eof':
                    self.connection.sendall(b'100\r\npartial chunk')
                else:
                    self.connection.sendall(b'x' * 1024 if mode in ('pending', 'eof') else body)
                record['chunks'].append(time.monotonic())
                if item.get('redirectCase') == 'follow-cancel':
                    (OUTPUT / marker).write_text('first hop sent', encoding='ascii')
                if mode == 'pending': self.connection.recv(1)
        except (ConnectionError, socket.timeout):
            record['closedDuringTransfer'] = True


def run(command, log, timeout=1200, env=None, cwd=PACKAGE):
    result = subprocess.run(command, cwd=cwd, capture_output=True, text=True, timeout=timeout, env=env)
    (OUTPUT/log).write_text(' '.join(command)+'\n'+result.stdout+result.stderr, encoding='utf-8')
    if result.returncode:
        # Swift Testing reports assertions on stdout, while long compiler
        # progress goes to stderr. Preserve both when a command fails.
        print(result.stdout[-8000:])
        print(result.stderr[-8000:])
        raise RuntimeError(f'{log}: command failed ({result.returncode})')


def verify_connection_refusal(port):
    with socket.socket() as probe:
        probe.settimeout(5)
        if probe.connect_ex(('127.0.0.1', port)) != errno.ECONNREFUSED:
            raise RuntimeError('Expected the unused loopback port to reject a TCP connection')


def main():
    import os
    OUTPUT.mkdir(parents=True, exist_ok=True)
    summary = dict(status='failed', platform=sys.platform, runtimeEnabled=False)
    try:
        if sys.platform != 'darwin': raise RuntimeError('macOS/Xcode required; transport unverified')
        fixtures = cases()
        redirect_fixtures, redirect_routes = redirects()
        route_map = {item['id']: item for item in fixtures}
        fixtures += redirect_fixtures
        (OUTPUT/'fixtures.json').write_text(json.dumps([{k:v for k,v in item.items() if k!='body'} for item in fixtures],indent=2)+'\n',encoding='utf-8')
        for item in fixtures:
            (OUTPUT/('seen-'+item['id'])).unlink(missing_ok=True)
            (OUTPUT/('seen-dart-'+item['id'])).unlink(missing_ok=True)
        run(['swift','package','resolve'], 'resolve.log')
        resolved = PACKAGE/'Package.resolved'
        if resolved.exists(): shutil.copy2(resolved, OUTPUT/'Package.resolved')
        cross_origin = Server({'follow-other-target': redirect_routes.pop('follow-other-target')})
        server = Server(route_map | redirect_routes, redirect_port=cross_origin.server_port)
        tls_stall = TLSStallServer()
        servers = (server, cross_origin, tls_stall)
        threads = [threading.Thread(target=listener.serve_forever, daemon=True) for listener in servers]
        for thread in threads: thread.start()
        try:
            # Darwin can time out on a bound, unlistened socket. Release the
            # assigned port and check for refusal before and after verification.
            with socket.socket() as reserved:
                reserved.bind(('127.0.0.1', 0))
                refused_port = reserved.getsockname()[1]
            env = {**os.environ, 'PILI_RAW_WIRE_BASE': f'http://127.0.0.1:{server.server_port}',
                   'PILI_RAW_WIRE_OUTPUT': str(OUTPUT), 'PILI_RAW_REFUSED_PORT': str(refused_port),
                   'PILI_RAW_TLS_STALL_PORT': str(tls_stall.server_address[1])}
            verify_connection_refusal(refused_port)
            run(['flutter','test','--no-pub','--reporter','expanded','test/http/native_transport_wire_test.dart'],
                'dart-wire.log',timeout=300,env=env,cwd=ROOT)
            if tls_stall.handshakes != 3: raise RuntimeError('Dart TLS stall did not reach three real handshakes')
            verify_connection_refusal(refused_port)
            run(['swift','test','--filter',
                 'rawHeaderAndIdleWire|rawConfigurationRejectsUnknownSemantics|rawInitialConnectionRefused|rawTLSHandshakeDeadline'],
                'wire.log', env=env)
            if tls_stall.handshakes != 4: raise RuntimeError('Raw TLS stall did not add exactly one handshake')
            verify_connection_refusal(refused_port)
        finally:
            for listener, thread in zip(servers, threads):
                listener.shutdown(); listener.server_close(); thread.join(timeout=2)
            records = server.records + cross_origin.records
            (OUTPUT/'server-events.json').write_text(json.dumps(records,indent=2)+'\n',encoding='utf-8')
        observations = json.loads((OUTPUT/'observations.json').read_text(encoding='utf-8'))
        if len(observations) != len(fixtures): raise RuntimeError('Missing raw wire observations')
        if any(record.get('unexpectedRequest') for record in records): raise RuntimeError('Client requested an unexpected URL')
        dart_observations = json.loads((OUTPUT/'dart-observations.json').read_text(encoding='utf-8'))
        if len(dart_observations) != len(fixtures): raise RuntimeError('Missing actual Dart wire observations')
        # Failed-body Dart responses may lack a head while Native retains it;
        # record that difference rather than inventing old behavior equivalence.
        (OUTPUT/'comparison.json').write_text(json.dumps([
            dict(id=n['id'], native=n, dart=d) for n,d in zip(observations,dart_observations)
        ],indent=2)+'\n',encoding='utf-8')
        for client in ('native', 'dart'):
            verify_redirect_requests(redirect_fixtures, records, client)
        verify_retry_requests(fixtures, records)
        records = {record['id']:record for record in server.records if record.get('client')=='native'}
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
        summary.update(status='passed', wireCases=len(observations), actualDartWireCases=len(dart_observations),
                       redirectCases=len(redirect_fixtures), initialConnectionRefusal=True,
                       retryWireCases=len(RETRY_CASES) + 1, tlsStallHandshakes=tls_stall.handshakes,
                       ios16Device=True, ios16Simulator=True,
                       knownPending=['br decoder','H2/TLS trust/proxy/pool expiry','response decoder errors and other Dio retries',
                                     'cross-origin redirects','actual API/account acceptance'])
    except (OSError,RuntimeError,subprocess.TimeoutExpired) as error:
        summary['reason']=str(error); print(f'FAIL raw HTTP: {error}')
    (OUTPUT/'summary.json').write_text(json.dumps(summary,indent=2)+'\n',encoding='utf-8')
    return 0 if summary['status']=='passed' else 1


if __name__ == '__main__': raise SystemExit(main())
