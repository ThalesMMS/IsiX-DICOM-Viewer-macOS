#!/usr/bin/env python3
"""The web portal's e-mails keep every recipient, parse any recipient list and
go out over SMTP from a sender (#763).

CSMailMailClient sends the portal's e-mails through Mail.app, with an
AppleScript, or through SMTPClient with the account Mail keeps. Three defects,
already in the Objective-C class and carried into Swift by #716:

1. -recipientListFromString: builds the AppleScript list of {name, address}
   records for Mail. It inserted them at positions 0, 1, 2...; the list's
   positions start at 1, 0 appends, and 1 replaces the first: with two
   recipients the second took the first one's place and Mail got one.
   Records now go at the end of the list.
2. Its parsing loop only moved when it scanned a name or an address. An empty
   entry (", ,") or an entry that starts with "<" left the scanner where it
   was, and the loop never ended: the main thread hung. Every pass now
   consumes the entry up to its comma; entries without an address ("<>",
   ", ,") are left out.
3. The SMTP path chose a sender, the Sender header or else the Mail account's
   own address, then passed SMTPClient the Sender header alone. The portal
   puts an empty Sender there when notificationsEmailsSender is not set:
   SMTPClient raised "Empty sender email address" and nothing was sent. The
   sender chosen is now the one sent, in MAIL FROM and in the From header.
   SMTPClient also leaves out empty recipient entries, which went out as
   "RCPT TO: <>", refused by servers, losing the whole message.

CSMailMailClient.swift, SMTPClient.swift, HorosObjCException.m and the two
+CAPI.m files are compiled as they are with a driver. Nothing talks to Mail
and nothing leaves the machine:
- recipients: the list for each string, read from the descriptor and by a
  local AppleScript handler with the same `|name| of rec`/`|address| of rec`
  loop as the real script's (the real script, which tells Mail, is not run
  or compiled). A run that does not end in 10 s is a hang.
- SMTP: -deliverMessage:headers:withMailApp:NO, the path the portal takes,
  against a fake SMTP server this script runs on 127.0.0.1. The driver runs
  with CFFIXED_USER_HOME set to a temporary folder holding the Mail account
  (~/Library/Mail/V2/MailData/Accounts.plist) that points at that server; it
  has no user name, so no Keychain lookup is made, and the driver refuses to
  go on unless its home folder is the temporary one.

`<git revision>` as an optional argument reads the two Swift sources from that
revision, the negative control.
"""
from pathlib import Path
import base64
import json
import os
import plistlib
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time

SKIPPED = 2
root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None


def source(path):
    if revision:
        return subprocess.check_output(['git', '-C', str(root), 'show', f'{revision}:{path}'])
    return (root / path).read_bytes()


if shutil.which('xcrun') is None:
    print('skipped: needs xcrun (swiftc, clang)', file=sys.stderr)
    sys.exit(SKIPPED)

# The loop the harness's AppleScript copies is the one Mail's script runs.
mail_client = source('Horos/Sources/CSMailMailClient.swift').decode()
for recipients in ('recip', 'ccrec', 'bccrec'):
    assert f'repeat with rec in {recipients}' in mail_client, recipients
assert mail_client.count('name: |name| of rec, address: |address| of rec') == 3

SWIFT_SOURCES = ['Horos/Sources/CSMailMailClient.swift', 'Nitrogen/Sources/SMTPClient.swift']
OBJC_SOURCES = ['Horos/Sources/HorosObjCException.m', 'Horos/Sources/CSMailMailClient+CAPI.m',
                'Nitrogen/Sources/SMTPClient+CAPI.m']

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
#import "CSMailMailClient.h"
#import "Shim.h"
'''

DRIVER = r'''
import AppKit
import Carbon

func fail(_ message: String) -> Never {
    print("FAIL: \(message)")
    exit(1)
}

// Nothing may read the user's Mail accounts or preferences.
let arguments = CommandLine.arguments
let fakeHome = arguments[1]
guard NSHomeDirectory() == fakeHome,
      ("~/Library/Mail" as NSString).expandingTildeInPath == fakeHome + "/Library/Mail" else {
    print("FAIL: the home folder is \(NSHomeDirectory()), not the temporary \(fakeHome)")
    exit(3)
}

func recipients(_ string: String) {
    UserDefaults.standard.register(defaults: ["WebServerUseMailAppForEmails": true])
    let list = CSMailMailClient.mailClient().recipientList(from: string)!
    var fromDescriptor: [String] = []
    if list.numberOfItems > 0 {
        for i in 1...list.numberOfItems {
            guard let fields = list.atIndex(i)?.forKeyword(AEKeyword(keyASUserRecordFields)),
                  fields.numberOfItems == 4,
                  fields.atIndex(1)?.stringValue == "name", fields.atIndex(3)?.stringValue == "address" else {
                fail("item \(i) is not a {name, address} record: \(String(describing: list.atIndex(i)))")
            }
            fromDescriptor.append("\(fields.atIndex(2)?.stringValue ?? "?")|\(fields.atIndex(4)?.stringValue ?? "?")")
        }
    }

    // What the script's `repeat with rec in recip` reads, without Mail.
    let source = """
    on read_recipients(recip)
      set out to {}
      repeat with rec in recip
        set end of out to (|name| of rec) & "|" & (|address| of rec)
      end repeat
      return out
    end read_recipients
    """
    let script = NSAppleScript(source: source)!
    var errorInfo: NSDictionary?
    guard script.compileAndReturnError(&errorInfo) else { fail("the reading script did not compile: \(String(describing: errorInfo))") }
    let event = NSAppleEventDescriptor.appleEvent(withEventClass: AEEventClass(0x61736372) /* 'ascr' */,
                                                  eventID: AEEventID(kASSubroutineEvent),
                                                  targetDescriptor: NSAppleEventDescriptor.currentProcess(),
                                                  returnID: AEReturnID(kAutoGenerateReturnID),
                                                  transactionID: AETransactionID(kAnyTransactionID))
    event.setParam(NSAppleEventDescriptor(string: "read_recipients"), forKeyword: AEKeyword(keyASSubroutineName))
    let parameters = NSAppleEventDescriptor.list()
    parameters.insert(list, at: 1)
    event.setParam(parameters, forKeyword: AEKeyword(keyDirectObject))
    let answer: NSAppleEventDescriptor? = script.executeAppleEvent(event, error: &errorInfo)
    guard let result = answer, errorInfo == nil else {
        fail("AppleScript could not read the list: \(String(describing: errorInfo))")
    }
    var fromScript: [String] = []
    if result.numberOfItems > 0 {
        for i in 1...result.numberOfItems { fromScript.append(result.atIndex(i)?.stringValue ?? "?") }
    }
    if fromScript != fromDescriptor {
        fail("AppleScript read \(fromScript), the descriptor holds \(fromDescriptor)")
    }
    let json = try! JSONSerialization.data(withJSONObject: fromDescriptor)
    print("records: " + String(data: json, encoding: .utf8)!)
}

func smtp(sender: String?, to: String) {
    UserDefaults.standard.register(defaults: ["WebServerUseMailAppForEmails": false])
    let client = CSMailMailClient.mailClient()!
    let headers = NSMutableDictionary()
    headers["To"] = to
    headers["Subject"] = "Horos #763"
    if let sender = sender { headers["Sender"] = sender }
    print("step: deliver over SMTP")
    let queued = client.deliverMessage("<p>Synthetic message</p>", headers: headers, withMailApp: false)
    print("queued: \(queued)")
    // The session runs on SMTPClient's own thread: the test closes stdin
    // once its server has seen it through.
    _ = readLine()
}

switch arguments[2] {
case "recipients":
    recipients(arguments[3])
case "smtp":
    smtp(sender: arguments[3] == "-" ? nil : arguments[3], to: arguments[4])
default:
    fail("unknown mode \(arguments[2])")
}
'''

RECIPIENT_CASES = [
    ('First <first@example.test>, second@example.test',
     ['First|first@example.test', '|second@example.test'], 'two recipients are both kept'),
    ('a@example.test, b@example.test, c@example.test',
     ['|a@example.test', '|b@example.test', '|c@example.test'], 'three recipients are all kept, in order'),
    ('first@example.test, ,second@example.test',
     ['|first@example.test', '|second@example.test'], 'an empty entry between two is skipped'),
    (', ,', [], 'a list of empty entries ends empty'),
    ('<first@example.test>, Second <second@example.test>',
     ['|first@example.test', 'Second|second@example.test'], 'an entry that starts with "<" is parsed'),
    ('x@example.test, Nobody <>', ['|x@example.test'], 'an entry with an empty address is skipped'),
    ('solo@example.test', ['|solo@example.test'], 'a single recipient (control)'),
    ('', [], 'an empty string (control)'),
]

ACCOUNT_ADDRESS = 'account@example.test'
ACCOUNT_NAME = 'Account Name'


def encoded(text):
    return '=?UTF-8?B?' + base64.b64encode(text.encode()).decode() + '?='


# sender header ('-' for none), To, expected MAIL FROM, expected From header,
# expected RCPT TO addresses, claim
SMTP_CASES = [
    ('Portal Sender <portal@example.test>', 'user@example.test', 'portal@example.test',
     f'{encoded("Portal Sender")} <portal@example.test>', ['user@example.test'],
     'the Sender header is the sender (control)'),
    ('', 'user@example.test', ACCOUNT_ADDRESS, f'{encoded(ACCOUNT_NAME)} <{ACCOUNT_ADDRESS}>',
     ['user@example.test'], 'an empty Sender, as the portal sends it, falls back to the account'),
    ('-', 'user@example.test', ACCOUNT_ADDRESS, f'{encoded(ACCOUNT_NAME)} <{ACCOUNT_ADDRESS}>',
     ['user@example.test'], 'no Sender falls back to the account'),
    ('Portal Sender <portal@example.test>', 'first@example.test, ,second@example.test', 'portal@example.test',
     f'{encoded("Portal Sender")} <portal@example.test>', ['first@example.test', 'second@example.test'],
     'an empty To entry is no RCPT TO'),
]


class FakeSMTPServer:
    """One SMTP session on 127.0.0.1, recorded. Nothing is relayed."""

    def __init__(self):
        self.listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.listener.bind(('127.0.0.1', 0))
        self.listener.listen(1)
        self.listener.settimeout(20)
        self.port = self.listener.getsockname()[1]
        self.commands = []
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
        connection.settimeout(20)
        reader = connection.makefile('rb')

        def reply(line):
            connection.sendall(line.encode() + b'\r\n')

        try:
            # At once, as a relay on the same machine greets: since #809
            # SMTPClient holds its answer until its output stream has room
            # (tests/test-smtp-immediate-greeting.py).
            reply('220 fake.localhost ESMTP test server')
            in_data = False
            for raw in reader:
                line = raw.decode('utf-8', 'replace').rstrip('\r\n')
                if in_data:
                    if line == '.':
                        in_data = False
                        self.delivered = True
                        reply('250 queued nowhere')
                    else:
                        self.data.append(line)
                    continue
                self.commands.append(line)
                verb = line.split(' ', 1)[0].upper()
                if verb in ('HELO', 'EHLO'):
                    reply('250 fake.localhost')
                elif verb == 'MAIL':
                    reply('250 ok')
                elif verb == 'RCPT':
                    reply('501 empty recipient' if line.replace(' ', '').upper() == 'RCPTTO:<>' else '250 ok')
                elif verb == 'DATA':
                    in_data = True
                    reply('354 go on')
                elif verb == 'QUIT':
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


def run(command, **kwargs):
    return subprocess.run(command, check=True, capture_output=True, **kwargs)


failures = []
with tempfile.TemporaryDirectory(prefix='horos-mail-763-') as tmp:
    tmp = Path(tmp)
    for path in SWIFT_SOURCES + OBJC_SOURCES:
        (tmp / Path(path).name).write_bytes(source(path) if path in SWIFT_SOURCES else (root / path).read_bytes())
    (tmp / 'Shim.h').write_text(SHIM_H)
    (tmp / 'Shim.m').write_text(SHIM_M)
    (tmp / 'Bridging.h').write_text(BRIDGING)
    (tmp / 'main.swift').write_text(DRIVER)
    harness = tmp / 'horos-mail-763-harness'
    includes = ['-I', str(tmp), '-I', str(root / 'Horos/Sources'), '-I', str(root / 'Nitrogen/Sources')]
    try:
        objects = []
        for name in [Path(path).name for path in OBJC_SOURCES] + ['Shim.m']:
            obj = tmp / (Path(name).stem.replace('+', '_') + '.o')
            # Beside the Swift, as in the application: the headers name the
            # classes instead of importing the generated interface.
            run(['xcrun', 'clang', '-c', '-w', '-fno-objc-arc', '-DHOROS_BRIDGING_HEADER=1',
                 '-iquote', str(tmp), *includes, str(tmp / name), '-o', str(obj)])
            objects.append(str(obj))
        run(['xcrun', 'swiftc', '-module-name', 'Horos', '-suppress-warnings', '-import-objc-header', str(tmp / 'Bridging.h'),
             *includes, *[str(tmp / Path(path).name) for path in SWIFT_SOURCES], str(tmp / 'main.swift'),
             *objects, '-framework', 'Cocoa', '-framework', 'Carbon', '-framework', 'Security', '-o', str(harness)])
    except subprocess.CalledProcessError as e:
        print('FAIL: the harness did not build:', (e.stderr or b'').decode(errors='replace')[-3000:])
        sys.exit(1)

    home = tmp / 'home'
    (home / 'Library/Mail/V2/MailData').mkdir(parents=True)
    env = dict(os.environ, CFFIXED_USER_HOME=str(home))

    def last_word(result_text):
        lines = [line for line in result_text.splitlines() if line.strip()]
        return next((line[len('FAIL: '):] for line in lines if line.startswith('FAIL:')), None) or \
            next((line.strip() for line in lines if 'Terminating app' in line or 'uncaught exception' in line), None) or \
            (lines[-1] if lines else '')

    for string, expected, claim in RECIPIENT_CASES:
        try:
            result = subprocess.run([str(harness), str(home), 'recipients', string],
                                    capture_output=True, text=True, timeout=10, env=env)
        except subprocess.TimeoutExpired:
            failures.append(f'{claim} ({string!r}): the parser did not end in 10 s')
            continue
        line = next((l for l in result.stdout.splitlines() if l.startswith('records: ')), None)
        if result.returncode != 0 or line is None:
            failures.append(f'{claim} ({string!r}): {last_word(result.stdout + result.stderr)} (exit {result.returncode})')
            continue
        records = json.loads(line[len('records: '):])
        if records != expected:
            failures.append(f'{claim} ({string!r}): Mail would get {records}, expected {expected}')
        else:
            print(f'ok: {claim} - {records}')

    for sender, to, mail_from, from_header, rcpts, claim in SMTP_CASES:
        server = FakeSMTPServer()
        with open(home / 'Library/Mail/V2/MailData/Accounts.plist', 'wb') as f:
            plistlib.dump({
                'DeliveryAccounts': [{'Hostname': '127.0.0.1', 'PortNumber': server.port}],
                'MailAccounts': [{'SMTPIdentifier': '127.0.0.1', 'EmailAddresses': [ACCOUNT_ADDRESS],
                                  'FullUserName': ACCOUNT_NAME}],
            }, f)
        driver = subprocess.Popen([str(harness), str(home), 'smtp', sender, to], stdin=subprocess.PIPE,
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env)
        deadline = time.monotonic() + 20
        while not server.done.is_set() and driver.poll() is None and time.monotonic() < deadline:
            time.sleep(0.05)
        server.done.wait(timeout=max(0.0, deadline - time.monotonic()) if driver.poll() is None else 0.5)
        try:
            out, err = driver.communicate(input='\n', timeout=10)
        except subprocess.TimeoutExpired:
            driver.kill()
            out, err = driver.communicate()
        problems = []
        if not server.commands:
            problems.append(f'no SMTP session: {last_word(out + err)} (exit {driver.returncode})')
        else:
            mails = [c for c in server.commands if c.upper().startswith('MAIL FROM')]
            got_rcpts = [c.split(':', 1)[1].strip() for c in server.commands if c.upper().startswith('RCPT TO')]
            if mails != [f'MAIL FROM: <{mail_from}>']:
                problems.append(f'MAIL FROM was {mails}, expected <{mail_from}>')
            if got_rcpts != [f'<{r}>' for r in rcpts]:
                problems.append(f'RCPT TO was {got_rcpts}, expected {[f"<{r}>" for r in rcpts]}')
            froms = [line for line in server.data if line.startswith('From:')]
            if froms != [f'From: {from_header}']:
                problems.append(f'the From header was {froms}, expected "From: {from_header}"')
            if not server.delivered:
                problems.append('the message was not delivered to the fake server')
        if driver.returncode not in (0, None) and not problems:
            problems.append(f'the driver exited {driver.returncode}: {last_word(out + err)}')
        if problems:
            failures.append(f'{claim}: ' + '; '.join(problems))
        else:
            print(f'ok: {claim} - MAIL FROM <{mail_from}>, RCPT TO {rcpts}')

for failure in failures:
    print('FAIL:', failure)
if failures:
    sys.exit(1)
print('PASS: Mail gets every recipient, any recipient list parses to its end, and SMTP sends from the chosen sender')
