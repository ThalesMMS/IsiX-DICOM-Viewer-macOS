#!/usr/bin/env python3
"""Loopback-only failure injection for a synthetic Orthanc DICOMweb fixture.

Write pass, 401, 401-wado, 401-stow, slow, or slow-wado to --mode-file. No
request headers, credentials, URLs or response bodies are logged. The upstream
must be local.

For #799 the proxy can also stand for a node that authenticates and lays out
its services differently from Orthanc:

- --auth basic|api-key|bearer with --auth-secret-file demands that credential
  from the client ("user:password" for Basic, the key, or the token) and
  answers 401 without it. The client's credential never reaches the upstream.
- --upstream-auth-file holds "user:password" for the upstream's own Basic
  authentication.
- --route PREFIX=UPSTREAM maps a path prefix to an upstream prefix, such as
  /qido=/dicom-web and /wado/rs=/dicom-web, so QIDO and WADO paths differ
  from the address. With routes, any other path is 404.
- POST (STOW-RS) is forwarded with its body, streamed.
"""
import argparse
import base64
import hmac
import http.client
import http.server
import time
from pathlib import Path
# Run as tools/serve-dicomweb-failure-proxy.py: this folder is already on the path.
from local_http import ThreadingLocalHTTPServer

MODES = ('pass', '401', '401-wado', '401-stow', 'slow', 'slow-wado')


def read_secret(parser, path):
    try:
        value = path.read_text().strip()
    except OSError:
        parser.error('cannot read a secret file')
    if not value or '\n' in value or '\r' in value:
        parser.error('a secret file must hold one non-empty line')
    return value


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--mode-file', type=Path, required=True)
    parser.add_argument('--port', type=int, default=18043)
    parser.add_argument('--upstream-port', type=int, default=18042)
    parser.add_argument('--delay', type=float, default=90)
    parser.add_argument('--auth', choices=('none', 'basic', 'api-key', 'bearer'), default='none')
    parser.add_argument('--auth-secret-file', type=Path)
    parser.add_argument('--auth-header', default='X-Api-Key', help='the API key header (default X-Api-Key)')
    parser.add_argument('--upstream-auth-file', type=Path)
    parser.add_argument('--route', action='append', default=[], metavar='PREFIX=UPSTREAM')
    args = parser.parse_args()
    if not (1 <= args.port <= 65535 and 1 <= args.upstream_port <= 65535 and args.delay >= 0):
        parser.error('Invalid port or delay')
    if (args.auth == 'none') != (args.auth_secret_file is None):
        parser.error('--auth and --auth-secret-file go together')
    expected = None
    if args.auth != 'none':
        secret = read_secret(parser, args.auth_secret_file)
        if args.auth == 'basic':
            if ':' not in secret:
                parser.error('a Basic secret file holds user:password')
            expected = ('authorization', 'Basic ' + base64.b64encode(secret.encode()).decode())
        elif args.auth == 'bearer':
            expected = ('authorization', 'Bearer ' + secret)
        else:
            expected = (args.auth_header.lower(), secret)
    upstream_authorization = None
    if args.upstream_auth_file:
        upstream_authorization = 'Basic ' + base64.b64encode(read_secret(parser, args.upstream_auth_file).encode()).decode()
    routes = []
    for route in args.route:
        prefix, _, target = route.partition('=')
        if not prefix.startswith('/') or not target.startswith('/'):
            parser.error('a route is /prefix=/upstream-prefix')
        routes.append((prefix.rstrip('/'), target.rstrip('/')))
    routes.sort(key=lambda pair: -len(pair[0]))
    # Credentials of the client never travel upstream.
    stripped = {'host', 'authorization', 'proxy-authorization', 'cookie', args.auth_header.lower()}

    class Proxy(http.server.BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def answer(self, status):
            self.send_response(status)
            self.send_header('Content-Length', '0')
            self.end_headers()

        def upstream_path(self):
            if not routes:
                return self.path
            path, mark, query = self.path.partition('?')
            for prefix, target in routes:
                if path == prefix or path.startswith(prefix + '/'):
                    return target + path[len(prefix):] + mark + query
            return None

        def authorized(self):
            if expected is None:
                return True
            sent = self.headers.get(expected[0]) or ''
            return hmac.compare_digest(sent.encode(), expected[1].encode())

        def do_GET(self):
            self.forward(False)

        def do_POST(self):
            self.forward(True)

        def forward(self, post):
            try:
                mode = args.mode_file.read_text().strip()
            except OSError:
                mode = 'invalid'
            if mode not in MODES:
                return self.answer(503)
            wado = 'multipart/' in self.headers.get('Accept', '').lower() and not post
            if not self.authorized() or mode == '401' or (mode == '401-wado' and wado) or (mode == '401-stow' and post):
                if post:
                    self.drain()
                return self.answer(401)
            target = self.upstream_path()
            if target is None:
                if post:
                    self.drain()
                return self.answer(404)
            if mode == 'slow' or (mode == 'slow-wado' and wado):
                time.sleep(args.delay)
            headers = {key: value for key, value in self.headers.items() if key.lower() not in stripped}
            if upstream_authorization:
                headers['Authorization'] = upstream_authorization
            upstream = http.client.HTTPConnection('127.0.0.1', args.upstream_port, timeout=max(10, args.delay + 10))
            try:
                if post:
                    length = int(self.headers.get('Content-Length', '0'))
                    headers['Content-Length'] = str(length)
                    upstream.request('POST', target, body=self.chunks(length), headers=headers, encode_chunked=False)
                else:
                    upstream.request('GET', target, headers=headers)
                response = upstream.getresponse()
                data = response.read()
                self.send_response(response.status)
                for key, value in response.getheaders():
                    if key.lower() not in ('connection', 'transfer-encoding', 'content-length'):
                        self.send_header(key, value)
                self.send_header('Content-Length', str(len(data)))
                self.end_headers()
                self.wfile.write(data)
            except (OSError, http.client.HTTPException, ValueError):
                # An intentionally cancelled client commonly closes this connection.
                pass
            finally:
                upstream.close()

        def chunks(self, length):
            while length > 0:
                chunk = self.rfile.read(min(length, 1 << 20))
                if not chunk:
                    return
                length -= len(chunk)
                yield chunk

        def drain(self):
            for _ in self.chunks(int(self.headers.get('Content-Length', '0') or 0)):
                pass

    server = ThreadingLocalHTTPServer(('127.0.0.1', args.port), Proxy)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == '__main__':
    main()
