#!/usr/bin/env python3
"""SMTPClient sends over Network.framework with the same TLS modes,
authentication and error messages as the stream-based client it replaced.

SMTPClient.swift and SMTPConnection.swift are compiled as they are, with the
IsiXMail module (the conversation: commands, replies, errors), and a driver
that sends one synthetic message to a test SMTP server this script runs on
127.0.0.1. Nothing leaves the machine and no real e-mail is sent: the server
records the commands and drops the message. The driver runs with
CFFIXED_USER_HOME in a temporary folder and refuses to go on otherwise.

The server has a self-signed certificate made here with openssl. The driver
gives it to SMTPConnection.testAnchorCertificates, the only certificate
trusted besides the system's; one case leaves it out and must be refused.

Cases, each checked for the commands the server got (before and after TLS),
whether the message was delivered, and what the client logged:
- no TLS: HELO without credentials, EHLO and AUTH PLAIN with them, a refused
  password (Error 535), a server that waits for a TLS handshake (stalled);
- STARTTLS: the TLSOrClose and TLSIfPossible modes, with and without
  credentials, a refused password over TLS, an untrusted certificate, and a
  server without STARTTLS (plain text if possible, an error if required);
- TLS from the first byte (port 465): the handshake after a second of silence;
- a refused connection, alone and before a port that works;
- CRAM-MD5, without TLS and after STARTTLS, against a server that compares
  the answer as a string with the RFC 2195 digest in lower-case hexadecimal.

Every message delivered must carry its body in base64 lines of at most 76
characters (RFC 2045), which decode to the body sent: the driver's body is
long enough for several lines.

The cases without TLS also run against the stream-based client of the last
revision that had SMTPClient+CAPI.m, read from git, and must give the same
commands, delivery and messages. (That client cannot be told to trust the
test certificate, so the TLS cases run against the new client only.) It sent
the CRAM-MD5 digest in upper case, which the strict server must refuse: that
is the negative control of the CRAM-MD5 case without TLS.
"""
from pathlib import Path
import base64
import hmac
import os
import re
import shutil
import socket
import ssl
import subprocess
import sys
import tempfile
import threading
import time

sys.path.insert(0, str(Path(__file__).resolve().parent))
import history_reference  # noqa: E402
import isix_modules  # noqa: E402

SKIPPED = 2
SESSION_TIMEOUT = 8.0
USER, PASSWORD = 'tim', 'synthetic-password'
# The driver's message: long enough for its base64 to need several lines.
BODY = '<p>Mensagem sintética de teste, sem destinatário.</p>' * 20
CHALLENGE = '<1896.697170952@test.localhost>'

root = Path(__file__).resolve().parents[1]

if shutil.which('xcrun') is None or shutil.which('openssl') is None:
    print('skipped: needs xcrun (swiftc, clang) and openssl', file=sys.stderr)
    sys.exit(SKIPPED)

CAPI = 'Nitrogen/Sources/SMTPClient+CAPI.m'
reference = history_reference.before_removal(CAPI)
if reference is None and subprocess.run(['git', '-C', str(root), 'cat-file', '-e', 'HEAD:' + CAPI],
                                        capture_output=True).returncode == 0:
    reference = 'HEAD'

DRIVER = r'''
import Foundation
import Security

let arguments = CommandLine.arguments
guard NSHomeDirectory() == arguments[1] else {
    print("FAIL: the home folder is \(NSHomeDirectory()), not the temporary \(arguments[1])")
    exit(3)
}
let ports = arguments[2].split(separator: ",").map { NSNumber(value: Int($0)!) }
let username: String? = arguments[5] == "-" ? nil : arguments[5]
let password: String? = arguments[6] == "-" ? nil : arguments[6]
//ANCHOR
SMTPClient.client(withServerAddress: "127.0.0.1", ports: ports, tlsMode: Int(arguments[3])!,
                  username: username, password: password)
    .sendMessage(String(repeating: "<p>Mensagem sintética de teste, sem destinatário.</p>", count: 20), withSubject: "IsiX SMTP test",
                 from: "Sender <sender@example.test>", to: "user@example.test")
// The client sends in the background: the test closes stdin once its server
// has seen the session through, or has given up on it.
_ = readLine()
'''

ANCHOR = r'''
if arguments[4] != "-" {
    let der = try! Data(contentsOf: URL(fileURLWithPath: arguments[4]))
    SMTPConnection.testAnchorCertificates = [SecCertificateCreateWithData(nil, der as CFData)!]
}
'''


class LineSocket:
    """CRLF lines over a socket, plain or TLS."""

    def __init__(self, sock):
        self.sock = sock
        self.buffer = b''

    def readline(self):
        while b'\r\n' not in self.buffer:
            chunk = self.sock.recv(4096)
            if not chunk:
                return None
            self.buffer += chunk
        line, self.buffer = self.buffer.split(b'\r\n', 1)
        return line.decode('utf-8', 'replace')

    def send(self, line):
        self.sock.sendall(line.encode() + b'\r\n')


class TestSMTPServer:
    """One session on 127.0.0.1, recorded; nothing is relayed.

    mode: 'plain' (no STARTTLS), 'starttls' (offers it) or 'implicit' (TLS
    from the first byte). auth: offer AUTH PLAIN LOGIN on EHLO, or, 'cram',
    AUTH CRAM-MD5 PLAIN LOGIN, with a CRAM-MD5 answer compared as a string
    with the RFC 2195 digest in lower-case hexadecimal, as a strict server
    does. The lines of the message are kept in `data`."""

    def __init__(self, mode, context, auth=False):
        self.mode = mode
        self.context = context
        self.auth = auth
        self.listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.listener.bind(('127.0.0.1', 0))
        self.listener.listen(1)
        self.listener.settimeout(SESSION_TIMEOUT)
        self.port = self.listener.getsockname()[1]
        self.commands = []  # (layer, command)
        self.data = []
        self.delivered = False
        self.done = threading.Event()
        threading.Thread(target=self.serve, daemon=True).start()

    def serve(self):
        try:
            connection, _ = self.listener.accept()
        except OSError:
            self.done.set()
            return
        connection.settimeout(SESSION_TIMEOUT)
        layer = 'plain'
        try:
            if self.mode == 'implicit':
                connection = self.context.wrap_socket(connection, server_side=True)
                layer = 'tls'
            io = LineSocket(connection)
            io.send('220 test.localhost ESMTP')
            in_data = False
            cram = False
            while True:
                line = io.readline()
                if line is None:
                    break
                if in_data:
                    if line == '.':
                        in_data = False
                        self.delivered = True
                        io.send('250 2.0.0 dropped, nothing relayed')
                    else:
                        self.data.append(line)
                    continue
                if cram:
                    cram = False
                    self.commands.append((layer, line))
                    digest = hmac.new(PASSWORD.encode(), CHALLENGE.encode(), 'md5').hexdigest()
                    if base64.b64decode(line).decode() == f'{USER} {digest}':
                        io.send('235 2.7.0 accepted')
                    else:
                        io.send('535 5.7.8 Authentication credentials invalid')
                    continue
                verb = line.split(' ', 1)[0].upper()
                self.commands.append((layer, 'HELO' if verb == 'HELO' else 'EHLO' if verb == 'EHLO' else line))
                if verb == 'EHLO':
                    io.send('250-test.localhost')
                    if self.mode == 'starttls' and layer == 'plain':
                        io.send('250-STARTTLS')
                    if self.auth == 'cram':
                        io.send('250-AUTH CRAM-MD5 PLAIN LOGIN')
                    elif self.auth:
                        io.send('250-AUTH PLAIN LOGIN')
                    io.send('250 8BITMIME')
                elif verb == 'STARTTLS' and self.mode == 'starttls' and layer == 'plain':
                    io.send('220 2.0.0 ready to start TLS')
                    connection = self.context.wrap_socket(connection, server_side=True)
                    io = LineSocket(connection)
                    layer = 'tls'
                elif verb == 'AUTH' and line == 'AUTH CRAM-MD5':
                    cram = True
                    io.send('334 ' + base64.b64encode(CHALLENGE.encode()).decode())
                elif verb == 'AUTH' and line.startswith('AUTH PLAIN '):
                    given = base64.b64decode(line[len('AUTH PLAIN '):]).split(b'\0')
                    if given[1:] == [USER.encode(), PASSWORD.encode()]:
                        io.send('235 2.7.0 accepted')
                    else:
                        io.send('535 5.7.8 Authentication credentials invalid')
                elif verb in ('HELO', 'MAIL', 'RCPT'):
                    io.send('250 ok')
                elif verb == 'DATA':
                    in_data = True
                    io.send('354 go on')
                elif verb == 'QUIT':
                    io.send('221 bye')
                    break
                else:
                    io.send('502 not here')
        except (OSError, ssl.SSLError):
            pass
        finally:
            connection.close()
            self.listener.close()
            self.done.set()


def closed_port():
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.bind(('127.0.0.1', 0))
    port = sock.getsockname()[1]
    sock.close()
    return port


LOG_LINE = re.compile(r'^\S+ \S+ [^\]]*\] (.*)$')


def messages(stderr):
    """What the client logged, without the NSLog prefix, once each."""
    found = []
    for line in stderr.splitlines():
        match = LOG_LINE.match(line)
        if match and match.group(1) not in found:
            found.append(match.group(1))
    return found


def run(command, **kwargs):
    return subprocess.run(command, check=True, capture_output=True, **kwargs)


def build_current(folder):
    folder.mkdir()
    for name in ('SMTPClient.swift', 'SMTPConnection.swift', 'SMTPClient.h'):
        shutil.copy(root / 'Nitrogen/Sources' / name, folder / name)
    (folder / 'Bridging.h').write_text('#define HOROS_BRIDGING_HEADER 1\n#import <Cocoa/Cocoa.h>\n#import "SMTPClient.h"\n')
    (folder / 'main.swift').write_text(DRIVER.replace('//ANCHOR', ANCHOR))
    harness = folder / 'smtp-harness'
    run(['xcrun', 'swiftc', '-swift-version', '6', '-module-name', 'Horos', '-target', 'arm64-apple-macos15.0',
         '-import-objc-header', str(folder / 'Bridging.h'), '-I', str(folder),
         *isix_modules.module_flags('IsiXMail', folder / 'modules', ['-target', 'arm64-apple-macos15.0']),
         str(folder / 'SMTPClient.swift'), str(folder / 'SMTPConnection.swift'), str(folder / 'main.swift'),
         '-o', str(harness)])
    return harness


def build_reference(folder, revision):
    """The stream-based client of `revision`, as the app compiled it then."""
    folder.mkdir()
    for path in ('Nitrogen/Sources/SMTPClient.swift', 'Nitrogen/Sources/SMTPClient.h', CAPI,
                 'Nitrogen/Sources/NSData+N2.swift', 'Nitrogen/Sources/NSString+N2.swift',
                 'Nitrogen/Sources/NSMutableString+N2.swift', 'Horos/Sources/HorosObjCException.h',
                 'Horos/Sources/HorosObjCException.m'):
        (folder / Path(path).name).write_bytes(history_reference.show(revision, path))
    (folder / 'Shim.h').write_text('#import <Foundation/Foundation.h>\n'
                                   'extern void _N2LogExceptionImpl(NSException* e, BOOL logStack, const char* pf);\n')
    (folder / 'Shim.m').write_text('#import "Shim.h"\nvoid _N2LogExceptionImpl(NSException* e, BOOL logStack, const char* pf) '
                                   '{ NSLog(@"%s: %@", pf, e); }\n')
    (folder / 'Bridging.h').write_text('#define HOROS_BRIDGING_HEADER 1\n#import <Cocoa/Cocoa.h>\n#import "HorosObjCException.h"\n'
                                       '#import "SMTPClient.h"\n#import "Shim.h"\n')
    (folder / 'main.swift').write_text(DRIVER.replace('//ANCHOR', ''))
    objects = []
    for name in ('HorosObjCException.m', 'SMTPClient+CAPI.m', 'Shim.m'):
        obj = folder / (Path(name).stem.replace('+', '_') + '.o')
        run(['xcrun', 'clang', '-c', '-w', '-fno-objc-arc', '-DHOROS_BRIDGING_HEADER=1', '-I', str(folder),
             str(folder / name), '-o', str(obj)])
        objects.append(str(obj))
    harness = folder / 'smtp-harness'
    run(['xcrun', 'swiftc', '-module-name', 'Horos', '-suppress-warnings', '-import-objc-header', str(folder / 'Bridging.h'),
         '-I', str(folder), *[str(folder / n) for n in ('SMTPClient.swift', 'NSData+N2.swift', 'NSString+N2.swift',
                                                        'NSMutableString+N2.swift', 'main.swift')],
         *objects, '-framework', 'Cocoa', '-o', str(harness)])
    return harness


# The lines of the message the server received in the last session.
received_data = []


def session(harness, env, home, case, context, certificate):
    """(commands, delivered, messages) of one case. A server mode ending with
    '+cram' offers CRAM-MD5 first."""
    mode, tls_mode, credentials, trusted, ports = case
    mode, _, kind = mode.partition('+')
    server = None
    received_data.clear()
    if mode == 'refused':
        port_list = [closed_port()]
    else:
        server = TestSMTPServer(mode, context, auth='cram' if kind == 'cram' else credentials is not None)
        port_list = [server.port]
    if ports == 'refused-first':
        port_list = [closed_port()] + port_list
    user, password = credentials or ('-', '-')
    driver = subprocess.Popen([str(harness), str(home), ','.join(map(str, port_list)), str(tls_mode),
                               str(certificate) if trusted else '-', user, password],
                              stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env)
    if server:
        server.done.wait(timeout=SESSION_TIMEOUT * 2)
        time.sleep(0.3)
    else:
        time.sleep(2.0)
    try:
        out, err = driver.communicate(input='\n', timeout=10)
    except subprocess.TimeoutExpired:
        driver.kill()
        out, err = driver.communicate()
    if 'FAIL:' in out:
        raise SystemExit(out.strip())
    received_data.extend(server.data if server else [])
    return (server.commands if server else []), (server.delivered if server else False), messages(err)


PLAIN_SESSION = ['MAIL FROM: <sender@example.test>', 'RCPT TO: <user@example.test>', 'DATA', 'QUIT']
AUTH_LINE = 'AUTH PLAIN ' + base64.b64encode(f'{USER}\0{USER}\0{PASSWORD}'.encode()).decode()
WRONG_AUTH = 'AUTH PLAIN ' + base64.b64encode(f'{USER}\0{USER}\0wrong'.encode()).decode()
# RFC 2195: the user, a space and the HMAC-MD5 of the challenge in lower-case hexadecimal.
CRAM_ANSWER = base64.b64encode(
    f'{USER} {hmac.new(PASSWORD.encode(), CHALLENGE.encode(), "md5").hexdigest()}'.encode()).decode()
REFUSED = 'Stream error: The operation couldn’t be completed. Connection refused'


def plain(commands):
    return [('plain', c) for c in commands]


def tls(commands):
    return [('tls', c) for c in commands]


# name: (server mode, client TLS mode, credentials, certificate trusted, ports), expected
# (commands, delivered, messages); a message is matched by its beginning.
CASES = {
    'no TLS, no credentials: HELO': (('plain', 0, None, False, 'one'), (plain(['HELO'] + PLAIN_SESSION), True, [])),
    'no TLS, credentials: EHLO and AUTH PLAIN': (('plain', 0, (USER, PASSWORD), False, 'one'),
                                                 (plain(['EHLO', AUTH_LINE] + PLAIN_SESSION), True, [])),
    'no TLS, refused password': (('plain', 0, (USER, 'wrong'), False, 'one'),
                                 (plain(['EHLO', WRONG_AUTH]), False,
                                  ['SMTP Exception: Error 535: 5.7.8 Authentication credentials invalid',
                                   '******* SMTPClient exception: Error 535: 5.7.8 Authentication credentials invalid'])),
    'TLS if possible, server without STARTTLS: plain text': (('plain', 1, None, False, 'one'),
                                                             (plain(['EHLO'] + PLAIN_SESSION), True, [])),
    'TLS required, server without STARTTLS: refused': (('plain', 2, None, False, 'one'),
                                                       (plain(['EHLO']), False,
                                                        ["SMTP Exception: Server doesn't support STARTTLS",
                                                         "******* SMTPClient exception: Server doesn't support STARTTLS"])),
    'no TLS, server waiting for a handshake: stalled': (('implicit', 0, None, False, 'one'),
                                                        ([], False,
                                                         ['SMTP Exception: Connection stalled, probably wants TLS handshake, user said no TLS',
                                                          '******* SMTPClient exception: Connection stalled, probably wants TLS handshake, user said no TLS'])),
    'connection refused': (('refused', 0, None, False, 'one'), ([], False, [REFUSED])),
    'connection refused, then a port that works': (('plain', 0, None, False, 'refused-first'),
                                                   (plain(['HELO'] + PLAIN_SESSION), True, [REFUSED])),
}
TLS_CASES = {
    'STARTTLS required': (('starttls', 2, None, True, 'one'),
                          (plain(['EHLO', 'STARTTLS']) + tls(['EHLO'] + PLAIN_SESSION), True, [])),
    'STARTTLS if possible, with credentials': (('starttls', 1, (USER, PASSWORD), True, 'one'),
                                               (plain(['EHLO', 'STARTTLS']) + tls(['EHLO', AUTH_LINE] + PLAIN_SESSION), True, [])),
    'STARTTLS, refused password': (('starttls', 2, (USER, 'wrong'), True, 'one'),
                                   (plain(['EHLO', 'STARTTLS']) + tls(['EHLO', WRONG_AUTH]), False,
                                    ['SMTP Exception: Error 535: 5.7.8 Authentication credentials invalid',
                                     '******* SMTPClient exception: Error 535: 5.7.8 Authentication credentials invalid'])),
    'STARTTLS, untrusted certificate': (('starttls', 2, None, False, 'one'),
                                        (plain(['EHLO', 'STARTTLS']), False, ['Stream error: '])),
    'TLS from the first byte': (('implicit', 1, None, True, 'one'), (tls(['HELO'] + PLAIN_SESSION), True, [])),
    'TLS from the first byte, with credentials': (('implicit', 2, (USER, PASSWORD), True, 'one'),
                                                  (tls(['EHLO', AUTH_LINE] + PLAIN_SESSION), True, [])),
}


# The new client only: the stream-based one sent the digest in upper case,
# which the strict server refuses (checked below as a negative control).
CRAM_CASES = {
    'no TLS, CRAM-MD5: lower-case digest': (('plain+cram', 0, (USER, PASSWORD), False, 'one'),
                                            (plain(['EHLO', 'AUTH CRAM-MD5', CRAM_ANSWER] + PLAIN_SESSION), True, [])),
    'STARTTLS, CRAM-MD5: lower-case digest': (('starttls+cram', 2, (USER, PASSWORD), True, 'one'),
                                              (plain(['EHLO', 'STARTTLS']) + tls(['EHLO', 'AUTH CRAM-MD5', CRAM_ANSWER]
                                                                                 + PLAIN_SESSION), True, [])),
}


def body_lines_fit(lines):
    """Whether the message's body is BODY in base64 lines of at most 76
    characters, all of 76 but the last."""
    if '' not in lines:
        return False
    body = lines[lines.index('') + 1:]
    return (bool(body) and all(len(line) == 76 for line in body[:-1]) and 0 < len(body[-1]) <= 76
            and base64.b64decode(''.join(body)) == BODY.encode())


def matches(expected, got):
    commands, delivered, logged = got
    want_commands, want_delivered, want_messages = expected
    return (commands == want_commands and delivered == want_delivered and len(logged) == len(want_messages)
            and all(line.startswith(prefix) for line, prefix in zip(logged, want_messages)))


failures = []
with tempfile.TemporaryDirectory(prefix='isix-smtp-nw-') as tmp:
    tmp = Path(tmp)
    key, certificate, der = tmp / 'key.pem', tmp / 'cert.pem', tmp / 'cert.der'
    run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-keyout', str(key), '-out', str(certificate),
         '-days', '1', '-subj', '/CN=127.0.0.1', '-addext', 'subjectAltName=IP:127.0.0.1,DNS:localhost',
         '-addext', 'extendedKeyUsage=serverAuth'])
    run(['openssl', 'x509', '-in', str(certificate), '-outform', 'DER', '-out', str(der)])
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(str(certificate), str(key))

    home = tmp / 'home'
    home.mkdir()
    env = dict(os.environ, CFFIXED_USER_HOME=str(home))
    try:
        current = build_current(tmp / 'current')
        previous = build_reference(tmp / 'reference', reference) if reference else None
    except subprocess.CalledProcessError as e:
        print('FAIL: a harness did not build:', (e.stderr or b'').decode(errors='replace')[-3000:])
        sys.exit(1)

    for name, (case, expected) in {**CASES, **TLS_CASES, **CRAM_CASES}.items():
        got = session(current, env, home, case, context, der)
        if matches(expected, got):
            print(f'ok: {name}')
        else:
            failures.append(f'{name}: expected {expected}, got {got}')
        if got[1]:
            if body_lines_fit(received_data):
                print(f'ok: {name}: the body in base64 lines of at most 76 characters')
            else:
                failures.append(f'{name}: the body is not in base64 lines of at most 76 characters: {received_data}')
        if previous and case[0] == 'plain+cram':
            # The negative control: the upper-case digest is refused.
            before = session(previous, env, home, case, context, der)
            if not before[1] and any(line.startswith('SMTP Exception: Error 535') for line in before[2]):
                print(f'ok: {name}: the strict server refuses the upper-case digest of {reference[:10]}')
            else:
                failures.append(f'{name}: the strict server did not refuse the client of {reference[:10]}: {before}')
        if previous and name in CASES:
            before = session(previous, env, home, case, context, der)
            if before == got:
                print(f'ok: {name}: the same as the stream-based client of {reference[:10]}')
            else:
                failures.append(f'{name}: the stream-based client of {reference[:10]} gave {before}, this one {got}')
    if not previous:
        print('note: no revision of this history has the stream-based client; the comparison was not run')

for failure in failures:
    print('FAIL:', failure)
if failures:
    sys.exit(1)
print('PASS: SMTP over Network.framework: no TLS, STARTTLS and TLS, authentication (CRAM-MD5 in lower case), '
      'refused password and connection, the body in base64 lines of 76 characters')
