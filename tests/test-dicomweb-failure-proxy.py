#!/usr/bin/env python3
"""The DICOMweb failure proxy stands for an authenticated node with its own paths.

Runs tools/serve-dicomweb-failure-proxy.py on loopback in front of a recording
fake upstream, once per credential kind, and checks that it demands Basic, an
API key or a Bearer token exactly, never passes the client's credential
upstream and sends the upstream's own Basic credential instead, maps QIDO and
WADO path prefixes and refuses other paths, forwards a STOW-RS POST with its
body intact, applies the 401, 401-wado and 401-stow modes, answers 429 and 503
with Retry-After to the next request after that mode is written and forwards
the one after it, and never prints a secret.

Pass a git revision to run that revision's proxy instead; one that predates
the DICOMweb nodes has no --auth and fails.
"""
import base64, http.client, http.server, json, os, socket, subprocess, sys, tempfile, threading, time
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
from local_http import ThreadingLocalHTTPServer

root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None
BIND_ADDRESS = os.environ.get('DICOMWEB_TEST_HOST', '127.0.0.1')
SECRETS = {'basic': 'reader:pw-SYNTHETIC-799', 'api-key': 'key-SYNTHETIC-799', 'bearer': 'tok-SYNTHETIC-799'}
UPSTREAM = 'orthanc:up-SYNTHETIC-799'
seen = []
failures = []


def check(ok, what):
    if not ok:
        failures.append(what)
        print('FAIL:', what)


class Upstream(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *_):
        pass

    def respond(self, body):
        seen.append({'method': self.command, 'path': self.path, 'body': body,
                     'headers': {k.lower(): v for k, v in self.headers.items()}})
        data = json.dumps([]).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/dicom+json')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        self.respond(b'')

    def do_POST(self):
        self.respond(self.rfile.read(int(self.headers.get('Content-Length', '0'))))


def free_port():
    with socket.socket() as s:
        s.bind(('127.0.0.1', 0))
        return s.getsockname()[1]


def request(port, method, path, headers=None, body=None, retry_after=None):
    connection = http.client.HTTPConnection(BIND_ADDRESS, port, timeout=10)
    try:
        connection.request(method, path, body=body, headers=headers or {})
        response = connection.getresponse()
        response.read()
        if retry_after is not None:
            retry_after.append(response.getheader('Retry-After'))
        return response.status
    finally:
        connection.close()


upstream = ThreadingLocalHTTPServer(('127.0.0.1', 0), Upstream)
threading.Thread(target=upstream.serve_forever, daemon=True).start()
processes = []
try:
    with tempfile.TemporaryDirectory(prefix='horos-dicomweb-proxy-') as tmp:
        tmp = Path(tmp)
        proxy = tmp / 'proxy.py'
        if revision:
            proxy.write_bytes(subprocess.check_output(['git', 'show', f'{revision}:tools/serve-dicomweb-failure-proxy.py'], cwd=root))
        else:
            proxy.write_bytes((root / 'tools/serve-dicomweb-failure-proxy.py').read_bytes())
        (tmp / 'local_http.py').write_bytes((root / 'tools/local_http.py').read_bytes())
        mode = tmp / 'mode'
        mode.write_text('pass')
        (tmp / 'upstream').write_text(UPSTREAM + '\n')
        ports = {}
        for kind, secret in SECRETS.items():
            (tmp / kind).write_text(secret + '\n')
            ports[kind] = free_port()
            processes.append(subprocess.Popen(
                [sys.executable, str(proxy), '--mode-file', str(mode), '--port', str(ports[kind]),
                 '--upstream-port', str(upstream.server_port), '--delay', '0', '--auth', kind,
                 *(['--bind-address', BIND_ADDRESS] if not revision else []),
                 '--auth-secret-file', str(tmp / kind), '--upstream-auth-file', str(tmp / 'upstream'),
                 '--route', '/qido=/dicom-web', '--route', '/wado/rs=/dicom-web', '--route', '/dicom-web=/dicom-web'],
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True))
        for kind, port in ports.items():
            for _ in range(100):
                try:
                    socket.create_connection((BIND_ADDRESS, port), timeout=0.2).close()
                    break
                except OSError:
                    if processes[list(ports).index(kind)].poll() is not None:
                        break
                    time.sleep(0.05)
        credential = {
            'basic': {'Authorization': 'Basic ' + base64.b64encode(SECRETS['basic'].encode()).decode()},
            'api-key': {'X-Api-Key': SECRETS['api-key']},
            'bearer': {'Authorization': 'Bearer ' + SECRETS['bearer']},
        }
        upstream_basic = 'Basic ' + base64.b64encode(UPSTREAM.encode()).decode()
        for kind, port in ports.items():
            try:
                request(port, 'GET', '/qido/studies?limit=1')
            except OSError:
                check(False, kind + ' proxy did not start')
                continue
            check(request(port, 'GET', '/qido/studies?limit=1') == 401, kind + ': no credential is 401')
            wrong = {key: value + 'x' for key, value in credential[kind].items()}
            check(request(port, 'GET', '/qido/studies?limit=1', wrong) == 401, kind + ': a wrong credential is 401')
            others = [c for k, c in credential.items() if k != kind]
            check(all(request(port, 'GET', '/qido/studies', other) == 401 for other in others), kind + ': another kind is 401')
            seen.clear()
            check(request(port, 'GET', '/qido/studies?limit=1', credential[kind]) == 200, kind + ': the credential passes')
            check(request(port, 'GET', '/wado/rs/studies/1.2.3',
                          dict(credential[kind], Accept='multipart/related; type="application/dicom"; transfer-syntax=*')) == 200,
                  kind + ': WADO passes')
            check([r['path'] for r in seen] == ['/dicom-web/studies?limit=1', '/dicom-web/studies/1.2.3'],
                  kind + ': routes map to the upstream prefix: ' + str([r['path'] for r in seen]))
            for r in seen:
                check(r['headers'].get('authorization') == upstream_basic, kind + ': the upstream gets its own Basic credential')
                check('x-api-key' not in r['headers'] and not any(s in json.dumps(r['headers']) for s in SECRETS.values()),
                      kind + ': the client credential does not reach the upstream')
            check(request(port, 'GET', '/other/studies', credential[kind]) == 404, kind + ': an unrouted path is 404')
            body = b'--b\r\nContent-Type: application/dicom\r\n\r\n' + bytes(range(256)) * 64 + b'\r\n--b--\r\n'
            seen.clear()
            check(request(port, 'POST', '/dicom-web/studies', dict(credential[kind], **{
                'Content-Type': 'multipart/related; type="application/dicom"; boundary=b'}), body) == 200, kind + ': STOW passes')
            check(len(seen) == 1 and seen[0]['body'] == body and seen[0]['path'] == '/dicom-web/studies'
                  and seen[0]['headers'].get('content-type', '').endswith('boundary=b'), kind + ': the STOW body arrives intact')
        port = ports['api-key']
        headers = credential['api-key']
        accept = dict(headers, Accept='multipart/related; type="application/dicom"')
        stow = dict(headers, **{'Content-Type': 'multipart/related; boundary=b'})
        for current, qido, wado, post in (('401', 401, 401, 401), ('401-wado', 200, 401, 200), ('401-stow', 200, 200, 401)):
            if failures:
                break
            mode.write_text(current)
            check(request(port, 'GET', '/qido/studies', headers) == qido, current + ': QIDO')
            check(request(port, 'GET', '/wado/rs/studies/1', accept) == wado, current + ': WADO')
            check(request(port, 'POST', '/dicom-web/studies', stow, b'--b--\r\n') == post, current + ': STOW')
        for current in ('429', '503'):
            if failures:
                break
            for method, path, headers_sent, body in (('GET', '/qido/studies', headers, None),
                                                     ('POST', '/dicom-web/studies', stow, b'--b--\r\n')):
                mode.write_text(current)
                seen.clear()
                waits = []
                check(request(port, method, path, headers_sent, body, waits) == int(current) and waits == ['1'],
                      current + ': the first ' + method + ' is busy with Retry-After 1: ' + str(waits))
                check(not seen, current + ': a busy answer does not reach the upstream')
                check(request(port, method, path, headers_sent, body, waits) == 200 and waits[1] is None,
                      current + ': the next ' + method + ' is forwarded')
        mode.write_text('pass')
finally:
    for process in processes:
        process.terminate()
    output = ''
    for process in processes:
        try:
            output += process.communicate(timeout=5)[0] or ''
        except subprocess.TimeoutExpired:
            process.kill()
    upstream.shutdown()
    upstream.server_close()
check(not any(secret in output for secret in list(SECRETS.values()) + [UPSTREAM, 'SYNTHETIC']), 'the proxy printed a secret')
if failures:
    sys.exit(1)
print('PASS: Basic, API key and Bearer demanded exactly and never forwarded, upstream Basic, QIDO/WADO routes, STOW POST, 401/401-wado/401-stow, 429/503 with Retry-After, nothing secret printed')
