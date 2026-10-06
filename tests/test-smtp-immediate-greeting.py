#!/usr/bin/env python3
"""SMTPClient sends its first command to a server that greets at once.

SMTPClient opens an input and an output stream to the server and answers the
220 greeting from the input stream's callback. A server that greets as soon as
it accepts the connection, as a relay on the same machine or the same network
does, can have its greeting read before the output stream has reported
.hasSpaceAvailable. The HELO was then written anyway: -write:maxLength: on an
output stream without room blocks the session thread, and the event that
would free it is delivered by the run loop that thread was running. The server
never got a command and nothing was sent, in about half of the sessions.

The session now only writes when the output stream has room; otherwise the
command waits in the buffer until the .hasSpaceAvailable event, or the second
.openCompleted, sends it.

SMTPClient.swift, SMTPClient+CAPI.m and HorosObjCException.m are compiled as
they are with a driver that sends one message to a fake SMTP server this
script runs on 127.0.0.1; nothing leaves the machine and nothing reads the
user's Mail accounts or Keychain (the driver runs with CFFIXED_USER_HOME in a
temporary folder). Each session must reach QUIT:
- IMMEDIATE_RUNS sessions whose server greets the moment it accepts;
- DELAYED_RUNS sessions whose server waits 0.3 s first (control: the order of
  the stream events that worked before).

`<git revision>` as an optional argument reads SMTPClient.swift from that
revision, the negative control.

The real NSData/NSString N2 categories also verify MD5/SHA-256 known vectors
and SDK selectors. Four authenticated local sessions check CRAM-MD5
wire compatibility, including the HMAC branch for secrets longer than 64 bytes,
and AUTH in the intermediate and final EHLO lines. No command may
arrive before the server finishes its multiline EHLO response.
"""
from pathlib import Path
import os
import base64
import hashlib
import hmac
import shutil
import select
import socket
import subprocess
import sys
import tempfile
import threading
import time

SKIPPED = 2
IMMEDIATE_RUNS = 20
DELAYED_RUNS = 3
SESSION_TIMEOUT = 4.0

root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None

if shutil.which('xcrun') is None:
    print('skipped: needs xcrun (swiftc, clang)', file=sys.stderr)
    sys.exit(SKIPPED)


def smtp_source():
    path = 'Nitrogen/Sources/SMTPClient.swift'
    if revision:
        return subprocess.check_output(['git', '-C', str(root), 'show', f'{revision}:{path}'])
    return (root / path).read_bytes()


OBJC_SOURCES = ['Horos/Sources/HorosObjCException.m', 'Nitrogen/Sources/SMTPClient+CAPI.m']

SHIM_H = r'''
#import <Foundation/Foundation.h>
extern void _N2LogExceptionImpl(NSException* e, BOOL logStack, const char* pf);
'''

# Compile real NSData/NSString N2 categories; only the logger needs a shim.
SHIM_M = r'''
#import "Shim.h"
void _N2LogExceptionImpl(NSException* e, BOOL logStack, const char* pf) { NSLog(@"%s: %@", pf, e); }
'''

BRIDGING = '''#define HOROS_BRIDGING_HEADER 1
#import <Cocoa/Cocoa.h>
#import "HorosObjCException.h"
#import "SMTPClient.h"
#import "Shim.h"
'''

DRIVER = r'''
import Foundation

let arguments = CommandLine.arguments
if arguments[1] == "digests" {
    let vectors = [
        ("", "D41D8CD98F00B204E9800998ECF8427E", "E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855"),
        ("abc", "900150983CD24FB0D6963F7D28E17F72", "BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD"),
        ("message digest", "F96B697D7CB7938D525A2F31AAF161D0", "F7846F55CF23E14EEBEAB5B4E1550CAD5B509E3348FBC4EFA3A1413D393CB650")
    ]
    for (text, md5, sha256) in vectors {
        let data = NSData(data: Data(text.utf8))
        // Use selectors too: these are the SDK and SMTP contracts.
        let legacy = data.perform(NSSelectorFromString("md5"))!.takeUnretainedValue() as! NSData
        let modern = data.perform(NSSelectorFromString("sha256"))!.takeUnretainedValue() as! NSData
        precondition(legacy.length == 16 && legacy.hex() == md5)
        precondition(modern.length == 32 && modern.hex() == sha256)
        precondition((text as NSString).md5() as String == md5)
    }
    precondition(("abc\0suffix" as NSString).md5() as String == vectors[1].1)
    let binary = NSData(data: Data([0, 255, 128, 0, 1]))
    precondition(binary.md5().hex() == "0716C7949889EA26BA235A63FBFDF78C")
    precondition(binary.sha256().hex() == "F44E17001248AB2D345368DDDF19DF566246BDA5C8822752D448A0C6BE59EC43")
    print("PASS: MD5/SHA-256 vectors, SDK selectors, binary data and NSString NUL compatibility")
    exit(0)
}
guard NSHomeDirectory() == arguments[1] else {
    print("FAIL: the home folder is \(NSHomeDirectory()), not the temporary \(arguments[1])")
    exit(3)
}
SMTPClient.client(withServerAddress: "127.0.0.1", ports: [NSNumber(value: Int(arguments[2])!)],
                  tlsMode: 0, username: arguments.count > 3 ? "tim" : nil,
                  password: arguments.count > 3 ? arguments[3] : nil)
    .sendMessage("<p>Synthetic message</p>", withSubject: "Horos SMTP test",
                 from: "Sender <sender@example.test>", to: "user@example.test")
// The session runs on SMTPClient's own thread: the test closes stdin once
// its server has seen it through, or has given up on it.
_ = readLine()
'''


class FakeSMTPServer:
    """One SMTP session on 127.0.0.1, recorded. Nothing is relayed."""

    def __init__(self, greeting_delay, secret=None, auth_on_final_line=False):
        self.secret = secret
        self.auth_on_final_line = auth_on_final_line
        self.early_command = False
        self.authenticated = False
        self.greeting_delay = greeting_delay
        self.listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.listener.bind(('127.0.0.1', 0))
        self.listener.listen(1)
        self.listener.settimeout(SESSION_TIMEOUT)
        self.port = self.listener.getsockname()[1]
        self.commands = []
        self.delivered = False
        self.quit = False
        self.done = threading.Event()
        threading.Thread(target=self.serve, daemon=True).start()

    def serve(self):
        try:
            connection, _ = self.listener.accept()
        except OSError:
            self.done.set()
            return
        connection.settimeout(SESSION_TIMEOUT)
        reader = connection.makefile('rb')

        def reply(line):
            connection.sendall(line.encode() + b'\r\n')

        try:
            if self.greeting_delay:
                time.sleep(self.greeting_delay)
            reply('220 fake.localhost ESMTP test server')
            in_data = False
            awaiting_auth = False
            for raw in reader:
                line = raw.decode('utf-8', 'replace').rstrip('\r\n')
                if in_data:
                    if line == '.':
                        in_data = False
                        self.delivered = True
                        reply('250 queued nowhere')
                    continue
                self.commands.append(line)
                if awaiting_auth:
                    challenge = b'<1896.697170952@postoffice.reston.mci.net>'
                    digest = hmac.new(self.secret.encode(), challenge, hashlib.md5).hexdigest().upper()
                    self.authenticated = base64.b64decode(line).decode() == 'tim ' + digest
                    reply('235 authenticated' if self.authenticated else '535 invalid response')
                    awaiting_auth = False
                    continue
                verb = line.split(' ', 1)[0].upper()
                if verb == 'EHLO' and self.secret is not None:
                    reply('250-fake.localhost')
                    if not self.auth_on_final_line:
                        reply('250-AUTH CRAM-MD5')
                    # Leave the response incomplete briefly: the client must
                    # collect capabilities without advancing to AUTH yet.
                    self.early_command = bool(select.select([connection], [], [], 0.05)[0])
                    reply('250 AUTH CRAM-MD5' if self.auth_on_final_line else '250 ok')
                elif line == 'AUTH CRAM-MD5':
                    awaiting_auth = True
                    reply('334 ' + base64.b64encode(b'<1896.697170952@postoffice.reston.mci.net>').decode())
                elif verb in ('HELO', 'EHLO', 'MAIL', 'RCPT'):
                    reply('250 ok')
                elif verb == 'DATA':
                    in_data = True
                    reply('354 go on')
                elif verb == 'QUIT':
                    self.quit = True
                    reply('221 bye')
                    break
                else:
                    reply('502 not here')
        except OSError:
            pass
        finally:
            connection.close()
            self.listener.close()
            self.done.set()


def run(command):
    return subprocess.run(command, check=True, capture_output=True)


with tempfile.TemporaryDirectory(prefix='horos-smtp-809-') as tmp:
    tmp = Path(tmp)
    (tmp / 'SMTPClient.swift').write_bytes(smtp_source())
    for name in ('NSData+N2.swift', 'NSString+N2.swift', 'NSMutableString+N2.swift'):
        (tmp / name).write_bytes((root / 'Nitrogen/Sources' / name).read_bytes())
    for path in OBJC_SOURCES:
        (tmp / Path(path).name).write_bytes((root / path).read_bytes())
    (tmp / 'Shim.h').write_text(SHIM_H)
    (tmp / 'Shim.m').write_text(SHIM_M)
    (tmp / 'Bridging.h').write_text(BRIDGING)
    (tmp / 'main.swift').write_text(DRIVER)
    harness = tmp / 'horos-smtp-809-harness'
    includes = ['-I', str(tmp), '-I', str(root / 'Horos/Sources'), '-I', str(root / 'Nitrogen/Sources')]
    try:
        objects = []
        for name in [Path(path).name for path in OBJC_SOURCES] + ['Shim.m']:
            obj = tmp / (Path(name).stem.replace('+', '_') + '.o')
            run(['xcrun', 'clang', '-c', '-w', '-fno-objc-arc', '-DHOROS_BRIDGING_HEADER=1',
                 '-iquote', str(tmp), *includes, str(tmp / name), '-o', str(obj)])
            objects.append(str(obj))
        run(['xcrun', 'swiftc', '-module-name', 'Horos', '-import-objc-header', str(tmp / 'Bridging.h'),
             *includes, str(tmp / 'SMTPClient.swift'), str(tmp / 'NSData+N2.swift'),
             str(tmp / 'NSString+N2.swift'), str(tmp / 'NSMutableString+N2.swift'), str(tmp / 'main.swift'), *objects,
             '-framework', 'Cocoa', '-o', str(harness)])
    except subprocess.CalledProcessError as e:
        print('FAIL: the harness did not build:', (e.stderr or b'').decode(errors='replace')[-3000:])
        sys.exit(1)

    print(run([str(harness), 'digests']).stdout.decode().strip())

    home = tmp / 'home'
    home.mkdir()
    env = dict(os.environ, CFFIXED_USER_HOME=str(home))

    def session(greeting_delay, secret=None, auth_on_final_line=False):
        """None when the message went through to QUIT, else what went wrong."""
        server = FakeSMTPServer(greeting_delay, secret, auth_on_final_line)
        driver = subprocess.Popen([str(harness), str(home), str(server.port)] + ([secret] if secret is not None else []), stdin=subprocess.PIPE,
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env)
        server.done.wait(timeout=SESSION_TIMEOUT * 2)
        try:
            out, err = driver.communicate(input='\n', timeout=5)
        except subprocess.TimeoutExpired:
            driver.kill()
            out, err = driver.communicate()
        if 'FAIL:' in out:
            return out.strip()
        if secret is not None:
            if server.early_command:
                return "client sent a command before the final EHLO line"
            if server.authenticated and server.delivered and server.quit:
                return None
            return f'CRAM-MD5 failed (authenticated: {server.authenticated}, delivered: {server.delivered}, commands: {server.commands}, driver: {err[-1000:]})'
        expected = ['HELO', 'MAIL FROM: <sender@example.test>', 'RCPT TO: <user@example.test>', 'DATA', 'QUIT']
        got = [c.split(' ', 1)[0] if c.startswith('HELO ') else c for c in server.commands]
        if got == expected and server.delivered and server.quit:
            return None
        if not server.commands:
            return 'the server got no command after its greeting'
        return f'the server got {server.commands} (delivered: {server.delivered})'

    failures = []
    for final in (False, True):
        position = 'final' if final else 'intermediate'
        for secret in ('tanstaaf', 'x' * 100):
            problem = session(0.0, secret, final)
            if problem:
                failures.append(f'AUTH on {position} EHLO line: {problem}')
            else:
                print(f'ok: CRAM-MD5 compatibility, {len(secret)}-byte secret, AUTH on {position} EHLO line, no early command')
    for claim, delay, runs in (('greeting at once', 0.0, IMMEDIATE_RUNS),
                               ('greeting after 0.3 s (control)', 0.3, DELAYED_RUNS)):
        problems = [p for p in (session(delay) for _ in range(runs)) if p is not None]
        if problems:
            first = max(set(problems), key=problems.count)
            failures.append(f'{claim}: {len(problems)} of {runs} sessions did not reach QUIT; {first}')
        else:
            print(f'ok: {claim} - {runs} of {runs} sessions sent HELO, MAIL, RCPT, DATA and QUIT')

for failure in failures:
    print('FAIL:', failure)
if failures:
    sys.exit(1)
print('PASS: SMTPClient answers a server that greets at once, and one that waits')
