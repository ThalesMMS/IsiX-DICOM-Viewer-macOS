#!/usr/bin/env python3
"""SMTPClient sends its first command to a server that greets at once (#809).

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
"""
from pathlib import Path
import os
import shutil
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

# NSData (N2) -base64, which SMTPClient reaches by selector, and N2Debug's logger.
SHIM_M = r'''
#import "Shim.h"
@implementation NSData (HarnessBase64)
- (NSString *)base64 { return [self base64EncodedStringWithOptions:0]; }
@end
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
guard NSHomeDirectory() == arguments[1] else {
    print("FAIL: the home folder is \(NSHomeDirectory()), not the temporary \(arguments[1])")
    exit(3)
}
SMTPClient.client(withServerAddress: "127.0.0.1", ports: [NSNumber(value: Int(arguments[2])!)],
                  tlsMode: 0, username: nil, password: nil)
    .sendMessage("<p>Synthetic message</p>", withSubject: "Horos #809",
                 from: "Sender <sender@example.test>", to: "user@example.test")
// The session runs on SMTPClient's own thread: the test closes stdin once
// its server has seen it through, or has given up on it.
_ = readLine()
'''


class FakeSMTPServer:
    """One SMTP session on 127.0.0.1, recorded. Nothing is relayed."""

    def __init__(self, greeting_delay):
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
            for raw in reader:
                line = raw.decode('utf-8', 'replace').rstrip('\r\n')
                if in_data:
                    if line == '.':
                        in_data = False
                        self.delivered = True
                        reply('250 queued nowhere')
                    continue
                self.commands.append(line)
                verb = line.split(' ', 1)[0].upper()
                if verb in ('HELO', 'EHLO', 'MAIL', 'RCPT'):
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
        run(['xcrun', 'swiftc', '-module-name', 'Horos', '-suppress-warnings', '-import-objc-header', str(tmp / 'Bridging.h'),
             *includes, str(tmp / 'SMTPClient.swift'), str(tmp / 'main.swift'), *objects,
             '-framework', 'Cocoa', '-o', str(harness)])
    except subprocess.CalledProcessError as e:
        print('FAIL: the harness did not build:', (e.stderr or b'').decode(errors='replace')[-3000:])
        sys.exit(1)

    home = tmp / 'home'
    home.mkdir()
    env = dict(os.environ, CFFIXED_USER_HOME=str(home))

    def session(greeting_delay):
        """None when the message went through to QUIT, else what went wrong."""
        server = FakeSMTPServer(greeting_delay)
        driver = subprocess.Popen([str(harness), str(home), str(server.port)], stdin=subprocess.PIPE,
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env)
        server.done.wait(timeout=SESSION_TIMEOUT * 2)
        try:
            out, err = driver.communicate(input='\n', timeout=5)
        except subprocess.TimeoutExpired:
            driver.kill()
            out, err = driver.communicate()
        if 'FAIL:' in out:
            return out.strip()
        expected = ['HELO', 'MAIL FROM: <sender@example.test>', 'RCPT TO: <user@example.test>', 'DATA', 'QUIT']
        got = [c.split(' ', 1)[0] if c.startswith('HELO ') else c for c in server.commands]
        if got == expected and server.delivered and server.quit:
            return None
        if not server.commands:
            return 'the server got no command after its greeting'
        return f'the server got {server.commands} (delivered: {server.delivered})'

    failures = []
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
