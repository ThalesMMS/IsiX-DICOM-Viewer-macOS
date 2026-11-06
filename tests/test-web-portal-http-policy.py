#!/usr/bin/env python3
"""The web portal's and XML-RPC's HTTP over SwiftNIO, on the wire.

The app's transport sources (HTTPServerListener.swift, HTTPConnectionEngine.swift,
XMLRPCListener.swift) are compiled unchanged into a test server
(tests/web_portal_transport.py), whose page code is a stand-in: it answers a
64-byte body, a chunked body, a 32 MB body, a protected path and uploads, and
records on which thread each step runs. Over loopback, with raw sockets, this
checks what the portal's former CocoaHTTPServer core did:

- GET and HEAD (Content-Length, no body), Date and Accept-Ranges, the
  response's own fields replacing the server's;
- Range: one range (206, Content-Range), several (multipart/byteranges whose
  Content-Length adds up), a suffix, one out of the body (the whole body, 200),
  and none for a chunked body;
- chunked framing: a size line in hexadecimal, the chunk, and the last chunk;
- keep-alive: two requests on one connection, also sent at once (pipelined),
  answered in order;
- refusals: HTTP/1.0 (505, connection kept), a GET with a body, a POST without
  Content-Length (400, Connection: close, closed), an unknown method (405,
  closed); a header field too long or too many (closed without an answer);
- authentication and absence answered by the page code (401, 404);
- uploads handed over in pieces of 2 MiB (2 MiB + 1 byte: 2097152 then 1), in
  order, before the answer, all on the connection's worker thread; an empty POST
  is answered;
- the header deadline: a chunk line still unsent after it (the client reads
  nothing) closes the connection, while a plain body under the same stall does
  not;
- TLS with a Keychain identity, from a disposable Keychain: the same answers,
  the certificate and the chain presented (a leaf and its CA);
- XML-RPC: the bytes reach the connection on a thread of its own, its answer
  goes out and the connection closes after it, and an incomplete request is
  closed by the connection's deadline. XML-RPC's HTTPS is the same listener
  with the web server's identity, which lives in the login Keychain: it is
  checked in the app.

Exit 2 (skipped) without the SwiftNIO checkouts of a Debug build, or openssl.
No app, no network peer beyond loopback and no login Keychain item are used.
"""
from pathlib import Path
import json
import os
import re
import select
import shutil
import socket
import ssl
import subprocess
import sys
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tests'))
from web_portal_transport import build_server  # noqa: E402

OPENSSL = shutil.which('openssl')
if not OPENSSL:
    print('skipped: openssl is needed for the TLS identity', file=sys.stderr)
    raise SystemExit(2)

MAIN = r'''
import Foundation
import IsiXHTTPServer
import IsiXKeychain
import NIOCore
import Security

let payload = Data((0..<64).map { UInt8(65 + $0 % 26) })
let big = Data(repeating: 0x5A, count: 32 * 1024 * 1024)
let workerThreadName = "transport test worker"
let threadLock = NSLock()
nonisolated(unsafe) var wrongThreads = 0
nonisolated(unsafe) var lastPieces: [Int] = []

func onWorker() {
    if Thread.current.name != workerThreadName {
        threadLock.withLock { wrongThreads += 1 }
    }
}

final class Body: HTTPServerResponse {
    let data: Data
    let isChunked: Bool
    var offset: UInt64 = 0
    init(_ data: Data, chunked: Bool = false) { self.data = data; self.isChunked = chunked }
    var contentLength: UInt64 { UInt64(data.count) }
    func readData(ofLength length: Int) -> Data? {
        onWorker()
        let start = Int(min(offset, UInt64(data.count)))
        let count = min(length, data.count - start)
        offset = UInt64(start + count)
        return data.subdata(in: start ..< start + count)
    }
    var isDone: Bool { offset >= UInt64(data.count) }
    var responseHeaderFields: [(String, String)] { [("Content-Type", "application/x-test"), ("X-Test", "1"), ("Accept-Ranges", "bytes")] }
    func connectionDidClose() {}
}

final class Page: HTTPConnectionEngineDelegate {
    weak var engine: HTTPConnectionEngine?
    var pieces: [Int] = []
    func supportsMethod(_ method: String!, atPath path: String!) -> Bool { onWorker(); return ["GET", "HEAD", "POST"].contains(method) }
    func processDataChunk(_ data: Data!) { onWorker(); pieces.append(data.count) }
    func replyToHTTPRequest() { onWorker(); engine?.replyWithResponse() }
    func isPasswordProtected(_ path: String!) -> Bool { path.hasPrefix("/protected") }
    func isAuthenticated() -> Bool { false }
    func handleAuthenticationFailed() {
        engine?.sendErrorResponse(status: 401, headers: [("Content-Length", "5")], body: Data("login".utf8), closeAfter: false)
    }
    func httpServerResponse(forMethod method: String, uri path: String) -> HTTPServerResponse? {
        onWorker()
        switch path {
        case "/data": return Body(payload)
        case "/chunked": return Body(payload, chunked: true)
        case "/big": return Body(big)
        case "/bigchunked": return Body(big, chunked: true)
        case "/empty": return Body(Data())
        case "/upload":
            let answer = "pieces=" + pieces.map(String.init).joined(separator: ",")
            pieces = []
            return Body(Data(answer.utf8))
        case "/threads": return Body(Data("wrong=\(threadLock.withLock { wrongThreads })".utf8))
        default: return nil
        }
    }
    func handleResourceNotFound() {
        engine?.sendErrorResponse(status: 404, headers: [("Content-Length", "9")], body: Data("not found".utf8), closeAfter: false)
    }
    func connectionDidDie() { onWorker() }
}

/// XML-RPC's connection, as XMLRPCInterfaceConnection uses its transport.
final class RPC: NSObject, XMLRPCServerConnection {
    let transport: XMLRPCTransport
    var answered = false
    var deadline: Timer?
    init(transport: XMLRPCTransport) { self.transport = transport }
    func open() {
        deadline = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in self?.close() }
    }
    func handle(_ data: NSMutableData!) {
        guard !answered, Thread.current.name == "XML-RPC connection" else { return }
        let bytes = data as Data
        guard let end = bytes.range(of: Data("\r\n\r\n".utf8)) else { return }
        let head = String(decoding: bytes[..<end.lowerBound], as: UTF8.self)
        let declared = head.split(separator: "\r\n").first { $0.lowercased().hasPrefix("content-length:") }
            .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
        guard bytes.count - end.upperBound >= declared else { return }
        answered = true
        let body = "peer=\(transport.peerAddress);body=\(declared)"
        transport.writeData(Data("HTTP/1.1 200 OK\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)".utf8))
    }
    func close() { deadline?.invalidate(); deadline = nil; transport.close() }
    func connectionFinishedSendingData() { close() }
}

let worker = HTTPServerWorker.detached(name: workerThreadName)
nonisolated(unsafe) var listeners: [HTTPServerListener] = []
func portal(tls: HTTPServerTLSIdentity?, deadline: TimeInterval) -> Int {
    let listener = HTTPServerListener(port: 0, tls: tls) { channel in
        channel.eventLoop.makeCompletedFuture {
            let handler = HTTPConnectionChannelHandler(headerDeadline: deadline) { channel, handler in
                let page = Page()
                let engine = HTTPConnectionEngine(channel: channel, handler: handler, worker: worker, delegate: page) { _ in }
                page.engine = engine
                return engine
            }
            try channel.pipeline.syncOperations.addHandlers(HTTPConnectionChannelHandler.decoders() + [handler])
        }
    }
    listeners.append(listener)
    return try! listener.start()
}

var ports: [String: Int] = [:]
ports["plain"] = portal(tls: nil, deadline: 240)
ports["deadline"] = portal(tls: nil, deadline: 1)
nonisolated(unsafe) var rpcListeners: [XMLRPCListener] = []
func rpc(https: Bool) -> Int {
    let listener = XMLRPCListener(port: 0, https: false) { transport in RPC(transport: transport) }!
    rpcListeners.append(listener)
    return listener.port
}
ports["rpc"] = rpc(https: false)

// TLS: an identity imported into a disposable Keychain, never into the user's.
let arguments = CommandLine.arguments
if arguments.count >= 4 {
    typealias Open = @convention(c) (UnsafePointer<CChar>, UnsafeMutablePointer<SecKeychain?>) -> OSStatus
    let open = unsafeBitCast(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "SecKeychainOpen"), to: Open.self)
    var keychain: SecKeychain?
    precondition(open(arguments[1], &keychain) == errSecSuccess && keychain != nil)
    var items: CFArray?
    let data = FileManager.default.contents(atPath: arguments[2])!
    let status = SecPKCS12Import(data as CFData, [kSecImportExportPassphrase as String: arguments[3],
                                                   kSecImportExportKeychain as String: keychain!] as CFDictionary, &items)
    precondition(status == errSecSuccess, "import \(status)")
    let item = (items as! [[String: Any]])[0]
    let identity = item[kSecImportItemIdentity as String] as! SecIdentity
    let chain = (item[kSecImportItemCertChain as String] as? [SecCertificate]) ?? []
    let tls = HTTPServerTLSIdentity(identity: identity, chain: chain)
    ports["tls"] = portal(tls: tls, deadline: 240)
    ports["chain"] = chain.count
    ports["commonNameOK"] = KeychainIdentities.certificate(of: identity).flatMap { KeychainIdentities.commonName(of: $0) } == "IsiX Transport Test" ? 1 : 0
}
print(String(decoding: try! JSONSerialization.data(withJSONObject: ports), as: UTF8.self))
fflush(stdout)
_ = readLine()
'''

failures = []


def check(condition, message):
    if not condition:
        failures.append(message)


def exchange(port, payload, tls=None, read_timeout=5.0, slow=False):
    """Write `payload`; read until the server closes or goes quiet. (bytes, closed)."""
    sock = socket.create_connection(('127.0.0.1', port), timeout=read_timeout)
    if tls:
        sock = tls.wrap_socket(sock, server_hostname='127.0.0.1')
    sock.sendall(payload)
    data, closed = b'', False
    try:
        while True:
            chunk = sock.recv(65536)
            if not chunk:
                closed = True
                break
            data += chunk
    except (socket.timeout, TimeoutError, ssl.SSLError):
        pass
    sock.close()
    return data, closed


def responses(data):
    """The responses in `data`: (status, {field: value}, body), framed by Content-Length or chunks."""
    found = []
    while data.startswith(b'HTTP/'):
        head, _, rest = data.partition(b'\r\n\r\n')
        lines = head.decode('latin1').split('\r\n')
        status = int(lines[0].split(' ')[1])
        fields = {}
        for line in lines[1:]:
            name, _, value = line.partition(':')
            fields[name.strip().lower()] = value.strip()
        if fields.get('transfer-encoding') == 'chunked':
            end = rest.find(b'\r\n0\r\n\r\n')
            body, data = rest[:end + 7], rest[end + 7:]
        else:
            length = int(fields.get('content-length', '0'))
            body, data = rest[:length], rest[length:]
        found.append((status, fields, body))
    return found


def get(port, path, extra='', method='GET', tls=None):
    data, closed = exchange(port, f'{method} {path} HTTP/1.1\r\nHost: test\r\n{extra}\r\n'.encode(), tls)
    answers = responses(data)
    return (answers[0] if answers else (None, {}, b'')), closed


PAYLOAD = bytes(65 + i % 26 for i in range(64))


def protocol_matrix(port, tls=None, label='http'):
    (status, fields, body), closed = get(port, '/data', tls=tls)
    check(status == 200 and body == PAYLOAD and fields.get('content-length') == '64' and not closed,
          f'{label}: GET answered {status} {fields} closed={closed}')
    check('date' in fields and fields.get('accept-ranges') == 'bytes' and fields.get('content-type') == 'application/x-test'
          and fields.get('x-test') == '1', f'{label}: the standard and the response fields are not all there: {fields}')
    check(re.fullmatch(r'[A-Z][a-z]{2}, \d{2} [A-Z][a-z]{2} \d{4} \d{2}:\d{2}:\d{2} GMT', fields.get('date', '')),
          f'{label}: the Date field is not an HTTP date: {fields.get("date")}')
    data, _ = exchange(port, b'HEAD /data HTTP/1.1\r\nHost: test\r\n\r\n', tls)
    head = data.split(b'\r\n\r\n', 1)
    check(head[0].startswith(b'HTTP/1.1 200') and b'Content-Length: 64' in head[0] and head[1] == b'',
          f'{label}: HEAD sent {data[:200]!r}')
    (status, fields, body), _ = get(port, '/data', 'Range: bytes=5-9\r\n', tls=tls)
    check(status == 206 and body == PAYLOAD[5:10] and fields.get('content-range') == 'bytes 5-9/64',
          f'{label}: one range answered {status} {fields} {body!r}')
    (status, fields, body), _ = get(port, '/data', 'Range: bytes=-4\r\n', tls=tls)
    check(status == 206 and body == PAYLOAD[-4:] and fields.get('content-range') == 'bytes 60-63/64',
          f'{label}: a suffix range answered {status} {fields}')
    (status, fields, body), _ = get(port, '/data', 'Range: bytes=64-\r\n', tls=tls)
    check(status == 200 and body == PAYLOAD, f'{label}: a range out of the body answered {status}')
    (status, fields, body), _ = get(port, '/data', 'Range: bytes=0-1,4-5\r\n', tls=tls)
    text = body.decode('latin1')
    check(status == 206 and 'Content-Range: bytes 0-1/64\r\n\r\nAB' in text and 'Content-Range: bytes 4-5/64\r\n\r\nEF' in text
          and fields.get('content-length') == str(len(body)) and text.rstrip().endswith('--'),
          f'{label}: several ranges answered {status} {fields} {text!r}')
    # The response's own Content-Type replaces the multipart one, as the former core did.
    check(fields.get('content-type') == 'application/x-test', f'{label}: multipart type {fields.get("content-type")}')
    (status, fields, body), _ = get(port, '/chunked', 'Range: bytes=0-1\r\n', tls=tls)
    check(status == 200 and fields.get('transfer-encoding') == 'chunked' and 'content-length' not in fields
          and body == b'40\r\n' + PAYLOAD + b'\r\n0\r\n\r\n', f'{label}: chunked answered {status} {fields} {body!r}')
    data, _ = exchange(port, b'HEAD /chunked HTTP/1.1\r\nHost: test\r\n\r\n', tls)
    check(data.endswith(b'\r\n\r\n') and b'Transfer-Encoding: chunked' in data, f'{label}: HEAD of a chunked body sent {data!r}')
    (status, fields, body), _ = get(port, '/empty', tls=tls)
    check(status == 200 and fields.get('content-length') == '0' and body == b'', f'{label}: an empty body answered {status} {fields}')
    # Keep-alive, one request after the other and both at once.
    sock = socket.create_connection(('127.0.0.1', port), timeout=5)
    if tls:
        sock = tls.wrap_socket(sock, server_hostname='127.0.0.1')
    sock.sendall(b'GET /data HTTP/1.1\r\nHost: test\r\n\r\n')
    first = b''
    while len(responses(first)) < 1 or len(responses(first)[0][2]) < 64:
        first += sock.recv(65536)
    sock.sendall(b'GET /data HTTP/1.1\r\nHost: test\r\n\r\nGET /missing HTTP/1.1\r\nHost: test\r\n\r\n')
    rest = b''
    deadline = time.time() + 5
    while len(responses(rest)) < 2 and time.time() < deadline:
        chunk = sock.recv(65536)
        if not chunk:
            break
        rest += chunk
    sock.close()
    answers = responses(rest)
    check([a[0] for a in answers] == [200, 404] and answers[0][2] == PAYLOAD and answers[1][2] == b'not found',
          f'{label}: kept-alive and pipelined requests answered {[(a[0], a[2][:20]) for a in answers]}')
    (status, fields, body), closed = get(port, '/protected', tls=tls)
    check(status == 401 and body == b'login' and not closed, f'{label}: a protected path answered {status} {body!r}')
    (status, fields, body), closed = get(port, '/missing', tls=tls)
    check(status == 404 and body == b'not found' and 'date' in fields, f'{label}: a missing path answered {status} {body!r}')
    # Refusals.
    data, closed = exchange(port, b'GET /data HTTP/1.0\r\n\r\n', tls, read_timeout=2)
    check(data.startswith(b'HTTP/1.1 505') and not closed, f'{label}: HTTP/1.0 answered {data[:40]!r} closed={closed}')
    for request, status, name in ((b'GET /data HTTP/1.1\r\nHost: t\r\nContent-Length: 5\r\n\r\nhello', 400, 'a GET with a body'),
                                  (b'POST /upload HTTP/1.1\r\nHost: t\r\n\r\n', 400, 'a POST without Content-Length'),
                                  (b'DELETE /data HTTP/1.1\r\nHost: t\r\n\r\n', 405, 'an unknown method'),
                                  (b'GET /data HTTP/1.1\r\nHost: t\r\nX\x00Y: z\r\n\r\n', 400, 'a header the parser refuses')):
        data, closed = exchange(port, request, tls)
        answers = responses(data)
        check(answers and answers[0][0] == status and answers[0][1].get('connection') == 'close' and closed,
              f'{label}: {name} answered {data[:120]!r} closed={closed}')
    data, closed = exchange(port, b'GET /data HTTP/1.1\r\nHost: t\r\nX-Long: ' + b'a' * 9000 + b'\r\n\r\n', tls)
    check(data == b'' and closed, f'{label}: a header field too long answered {data[:60]!r} closed={closed}')
    data, closed = exchange(port, b'GET /data HTTP/1.1\r\n' + b''.join(b'X-%d: 1\r\n' % i for i in range(101)) + b'\r\n', tls)
    check(data == b'' and closed, f'{label}: too many header fields answered {data[:60]!r} closed={closed}')
    data, closed = exchange(port, b'GET /data HTTP/1.1\r\nHost: t\r\nX-Fine: ' + b'a' * 8000 + b'\r\n\r\n', tls)
    check(data.startswith(b'HTTP/1.1 200'), f'{label}: a long header within the limit answered {data[:40]!r}')
    # Uploads: pieces of 2 MiB, before the answer.
    for size, pieces in ((2 * 1024 * 1024 + 1, '2097152,1'), (100, '100'), (5 * 1024 * 1024, '2097152,2097152,1048576'),
                         (0, '')):
        body = os.urandom(size)
        data, _ = exchange(port, b'POST /upload HTTP/1.1\r\nHost: t\r\nContent-Length: %d\r\n\r\n' % size + body, tls,
                           read_timeout=10)
        answers = responses(data)
        check(answers and answers[0][0] == 200 and answers[0][2] == f'pieces={pieces}'.encode(),
              f'{label}: an upload of {size} bytes was handed over as {answers[0][2] if answers else data[:80]!r}')
    (status, fields, body), _ = get(port, '/threads', tls=tls)
    check(body == b'wrong=0', f'{label}: page code ran off its worker thread: {body!r}')


def deadline_checks(port):
    # The client reads nothing: the chunk lines (written with the header deadline)
    # wait behind the body and the connection is closed after the deadline.
    sock = socket.create_connection(('127.0.0.1', port), timeout=30)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4096)
    sock.sendall(b'GET /bigchunked HTTP/1.1\r\nHost: t\r\n\r\n')
    time.sleep(4)
    received, closed = 0, False
    sock.settimeout(10)
    try:
        while True:
            chunk = sock.recv(1 << 20)
            if not chunk:
                closed = True
                break
            received += len(chunk)
    except (socket.timeout, ConnectionResetError):
        closed = True
    sock.close()
    check(closed and received < 32 * 1024 * 1024, f'chunked body under a stalled reader: received {received}, closed={closed}')
    # A plain body has no deadline: the same stall, then the whole body.
    sock = socket.create_connection(('127.0.0.1', port), timeout=30)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4096)
    sock.sendall(b'GET /big HTTP/1.1\r\nHost: t\r\n\r\n')
    time.sleep(4)
    data = b''
    sock.settimeout(20)
    try:
        while True:
            head_end = data.find(b'\r\n\r\n')
            if head_end >= 0 and len(data) - head_end - 4 >= 32 * 1024 * 1024:
                break
            chunk = sock.recv(1 << 20)
            if not chunk:
                break
            data += chunk
    except socket.timeout:
        pass
    sock.close()
    head_end = data.find(b'\r\n\r\n')
    check(head_end >= 0 and len(data) - head_end - 4 == 32 * 1024 * 1024,
          f'plain body under a stalled reader: received {len(data)} bytes')


def rpc_checks(port, tls=None, label='XML-RPC'):
    body = b'<?xml version="1.0"?><methodCall><methodName>x</methodName></methodCall>'
    request = b'POST / HTTP/1.1\r\nHost: t\r\nContent-Length: %d\r\n\r\n' % len(body)
    # In two writes: the connection waits for the whole body.
    sock = socket.create_connection(('127.0.0.1', port), timeout=10)
    if tls:
        sock = tls.wrap_socket(sock, server_hostname='127.0.0.1')
    sock.sendall(request + body[:10])
    time.sleep(0.3)
    sock.sendall(body[10:])
    data = b''
    closed = False
    try:
        while True:
            chunk = sock.recv(65536)
            if not chunk:
                closed = True
                break
            data += chunk
    except socket.timeout:
        pass
    sock.close()
    check(data.endswith(b'peer=127.0.0.1;body=%d' % len(body)) and closed,
          f'{label}: answered {data!r} closed={closed}')
    data, closed = exchange(port, b'POST / HTTP/1.1\r\nHost: t\r\nContent-Length: 100\r\n\r\nshort', tls, read_timeout=8)
    check(data == b'' and closed, f'{label}: an incomplete request was not closed by its deadline: {data!r} {closed}')


def main():
    work = Path(tempfile.mkdtemp(prefix='isix-transport-'))
    keychain = work / f'transport-{uuid.uuid4()}.keychain-db'
    server = None
    try:
        binary = build_server(MAIN)
        # A CA and a leaf it signs, in a PKCS#12 file with the CA as chain.
        def run(*args):
            subprocess.run([OPENSSL, *args], check=True, capture_output=True, cwd=work)
        run('req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-keyout', 'ca.key', '-out', 'ca.pem', '-days', '2',
            '-subj', '/CN=IsiX Transport Test CA', '-sha256')
        run('req', '-newkey', 'rsa:2048', '-nodes', '-keyout', 'leaf.key', '-out', 'leaf.csr', '-subj', '/CN=IsiX Transport Test')
        run('x509', '-req', '-in', 'leaf.csr', '-CA', 'ca.pem', '-CAkey', 'ca.key', '-CAcreateserial', '-out', 'leaf.pem',
            '-days', '2', '-sha256')
        run('pkcs12', '-export', '-in', 'leaf.pem', '-inkey', 'leaf.key', '-certfile', 'ca.pem', '-out', 'id.p12',
            '-passout', 'pass:transport')
        before = subprocess.run(['security', 'list-keychains', '-d', 'user'], capture_output=True, text=True).stdout
        subprocess.run(['security', 'create-keychain', '-p', 'transport', str(keychain)], check=True, capture_output=True)
        subprocess.run(['security', 'unlock-keychain', '-p', 'transport', str(keychain)], check=True, capture_output=True)
        after = subprocess.run(['security', 'list-keychains', '-d', 'user'], capture_output=True, text=True).stdout
        check(before == after, 'the disposable Keychain entered the user\'s search list')
        server = subprocess.Popen([str(binary), str(keychain), str(work / 'id.p12'), 'transport'], stdin=subprocess.PIPE,
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        ready, _, _ = select.select([server.stdout], [], [], 60)
        if not ready:
            raise RuntimeError('the test server did not start: ' + server.stderr.read() if server.poll() is not None else '')
        ports = json.loads(server.stdout.readline())
        protocol_matrix(ports['plain'])
        deadline_checks(ports['deadline'])
        rpc_checks(ports['rpc'])
        tls = ssl._create_unverified_context()
        protocol_matrix(ports['tls'], tls, 'https')
        check(ports.get('chain') == 2 and ports.get('commonNameOK') == 1,
              f'the identity was not read from the Keychain with its chain: {ports}')
        shown = subprocess.run([OPENSSL, 's_client', '-connect', f'127.0.0.1:{ports["tls"]}', '-showcerts'],
                               input='', capture_output=True, text=True, timeout=30).stdout
        check(shown.count('-----BEGIN CERTIFICATE-----') == 2 and 'IsiX Transport Test' in shown,
              f'the TLS listener did not present the leaf and its CA ({shown.count("BEGIN CERTIFICATE")} certificates)')
    finally:
        if server and server.poll() is None:
            server.stdin.close()
            try:
                server.wait(10)
            except subprocess.TimeoutExpired:
                server.kill()
        subprocess.run(['security', 'delete-keychain', str(keychain)], capture_output=True)
        shutil.rmtree(work, ignore_errors=True)
    if failures:
        for failure in failures:
            print('FAIL: ' + failure)
        return 1
    print('PASS: GET/HEAD, ranges, chunks, keep-alive and pipelining, refusals and header limits, 401/404, '
          '2 MiB upload pieces on the worker thread, the header deadline, TLS with a Keychain identity and its chain, '
          'and XML-RPC over the SwiftNIO transport')
    return 0


if __name__ == '__main__':
    sys.exit(main())
