#!/usr/bin/env python3
"""The web portal's emails go through its own SMTP server when one is set,
and how each one ended is reported, never dropped.

Horos/Sources/WebPortalMailDelivery.swift is compiled as it is, twice: as the
direct build and, with -D MACAPPSTORE, as the App Store build. With it go the
SMTP client (SMTPClient.swift, SMTPConnection.swift), the IsiXMail and
IsiXPreferences modules, and a driver that sends one synthetic email to the
test SMTP server of smtp_test_server.py on 127.0.0.1. Nothing leaves the
machine, no real email is sent and the Mail application is never addressed:
the driver gives the delivery a stand-in for it, which only counts its calls.

The server is read from a preference store in memory, written the way the
pane's sheet writes it, and the password from a store the driver gives the
delivery: the source that reads the Keychain is not compiled in, so the
user's Keychain cannot be reached. The driver runs with CFFIXED_USER_HOME in
a temporary folder and refuses to go on otherwise.

Cases, each in both builds unless said:
- a server set, no authentication: the message is taken, the report has no
  failure and names the server, and the stand-in for Mail is not called;
- a server that authenticates: the password the server receives is the one of
  the given store, asked for under the account of that user at that server;
- STARTTLS required, with the test certificate trusted: taken over TLS;
- the server refuses the password: the report carries its reply (Error 535);
- nothing listens on the port: the report carries the connection's error;
- the server authenticates and the store has no password: refused before any
  connection, and known in advance to whoever asks first;
- no sender address: refused before any connection, as SMTP needs one;
- no server set: the direct build hands the message to the stand-in for Mail
  and reports what it answered; the App Store build never calls it and
  reports that no server is set, which is also known in advance;
- a server stored and then removed leaves no key of it in the preferences.
"""
from pathlib import Path
import base64
import os
import shutil
import ssl
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import former_sdk_objects  # noqa: E402
import isix_modules  # noqa: E402
from smtp_test_server import PASSWORD, SESSION_TIMEOUT, USER, TestSMTPServer, closed_port  # noqa: E402

SKIPPED = 2
root = Path(__file__).resolve().parents[1]
TARGET = ['-target', 'arm64-apple-macos15.0']

if shutil.which('xcrun') is None or shutil.which('openssl') is None:
    print('skipped: needs xcrun (swiftc, clang) and openssl', file=sys.stderr)
    sys.exit(SKIPPED)

DRIVER = r'''
import Foundation
import IsiXMail
import IsiXPreferences
import Security
import Synchronization

// home, port (0: no server set), TLS mode, user name or "-", the password the
// store holds or "-", the sender or "-", what the stand-in for Mail answers,
// the certificate to trust or "-".
let arguments = CommandLine.arguments
guard NSHomeDirectory() == arguments[1] else {
    print("FAIL: the home folder is \(NSHomeDirectory()), not the temporary \(arguments[1])")
    exit(3)
}
let port = Int(arguments[2])!
let username = arguments[4] == "-" ? "" : arguments[4]
let stored: String? = arguments[5] == "-" ? nil : arguments[5]
let sender = arguments[6] == "-" ? "" : arguments[6]
let mailAnswers = arguments[7] == "taken"
if arguments[8] != "-" {
    let der = try! Data(contentsOf: URL(fileURLWithPath: arguments[8]))
    SMTPConnection.testAnchorCertificates = [SecCertificateCreateWithData(nil, der as CFData)!]
}

// The server as the sheet stores it, read back as the delivery reads it.
let preferences = MemoryPreferences()
let set = PortalMailServer(host: port == 0 ? "" : " 127.0.0.1 ", port: port,
                           tlsMode: SMTPTLSMode(clientValue: Int(arguments[3])!), username: username)
PortalMailServer(host: "former.example.test", port: 2525, tlsMode: .ifPossible, username: "former").store(in: preferences)
set.store(in: preferences)
let keys = ["webPortalMailServerHost", "webPortalMailServerPort", "webPortalMailServerTLSMode", "webPortalMailServerUsername"]
print("stored:", keys.filter { preferences.object(forKey: $0) != nil }.count)
guard PortalMailServer(preferences: preferences) == set else {
    print("FAIL: the server read back is \(PortalMailServer(preferences: preferences)), not \(set)")
    exit(3)
}

let asked = Mutex<[String]>([])
let recorded = Mutex<[PortalMailReport]>([])
let mailCalls = Mutex(0)
let delivery = WebPortalMailDelivery(
    server: { PortalMailServer(preferences: preferences) },
    password: { account in
        asked.withLock { $0.append(account) }
        return stored
    },
    mailApplication: { mail in
        mailCalls.withLock { $0 += 1 }
        print("mail:", mail.recipients, "|", mail.sender, "|", mail.subject)
        return mailAnswers
    },
    hostname: { "client.test" },
    record: { report in recorded.withLock { $0.append(report) } })

@Sendable func text(_ route: PortalMailRoute) -> String {
    switch route {
    case let .server(server): return "server " + server.address
    case .mailApplication: return "mail"
    case .none: return "none"
    }
}

let mail = PortalMail(body: String(repeating: "<p>Mensagem sintética de teste, sem destinatário.</p>", count: 20),
                      subject: "IsiX portal test", sender: sender, recipients: "user@example.test")
print("build:", WebPortalMailDelivery.sendsThroughMailApplication ? "direct" : "store")
print("route:", text(delivery.route))
// Asked first, as the forgotten password page asks: an obstacle is recorded as a failed email.
print("refuses:", delivery.refuses(mail))
print("refusal:", recorded.withLock { $0.last?.failure?.logText ?? "-" })
let refusals = recorded.withLock { $0.count }
delivery.send(mail) { report in
    print("report:", text(report.route), "|", report.recipients, "|", report.failure?.logText ?? "-")
    print("log:", report.logMessage)
    print("recorded:", recorded.withLock { $0.count } - refusals, recorded.withLock { $0.last == report })
    print("asked:", asked.withLock { Set($0).sorted().joined(separator: ",") })
    print("mail calls:", mailCalls.withLock { $0 })
    exit(0)
}
dispatchMain()
'''


def run(command, **kwargs):
    return subprocess.run(command, check=True, capture_output=True, **kwargs)


def build(folder, modules, store):
    """The driver with the delivery, the SMTP client and the two modules; as
    the App Store build compiles it when `store`."""
    folder.mkdir()
    (folder / 'Bridging.h').write_text('#define HOROS_BRIDGING_HEADER 1\n#import <Cocoa/Cocoa.h>\n#import "SMTPClient.h"\n')
    (folder / 'main.swift').write_text(DRIVER)
    flags = isix_modules.module_flags('IsiXMail', modules, TARGET)
    flags += [flag for flag in isix_modules.module_flags('IsiXPreferences', modules, TARGET) if flag not in flags]
    harness = folder / 'portal-mail-harness'
    run(['xcrun', 'swiftc', '-swift-version', '6', '-module-name', 'Horos', *TARGET, *(['-D', 'MACAPPSTORE'] if store else []),
         '-import-objc-header', str(folder / 'Bridging.h'), '-I', str(root / 'Nitrogen/Sources'), *flags,
         str(root / 'Horos/Sources/WebPortalMailDelivery.swift'), str(root / 'Nitrogen/Sources/SMTPClient.swift'),
         str(root / 'Nitrogen/Sources/SMTPConnection.swift'), str(folder / 'main.swift'),
         former_sdk_objects.nitrogen(folder), former_sdk_objects.bezier_stubs(folder), '-o', str(harness)])
    return harness


def session(harness, env, home, mode, port, tls_mode, user, stored, sender, mail, certificate, context):
    """What the driver printed, by label, and the server of the session if one listened."""
    server = None
    if mode in ('plain', 'starttls'):
        server = TestSMTPServer(mode, context, auth=user is not None)
        port = server.port
    driver = subprocess.run([str(harness), str(home), str(port), str(tls_mode), user or '-', stored or '-', sender or '-',
                             mail, str(certificate) if certificate else '-'],
                            capture_output=True, text=True, env=env, timeout=SESSION_TIMEOUT * 4)
    if driver.returncode != 0 or 'FAIL:' in driver.stdout:
        raise SystemExit('FAIL: the driver ended with %d: %s%s' % (driver.returncode, driver.stdout, driver.stderr[-2000:]))
    if server:
        server.done.wait(timeout=SESSION_TIMEOUT)
    printed = {}
    for line in driver.stdout.splitlines():
        label, _, value = line.partition(': ')
        printed.setdefault(label, []).append(value)
    return {label: values[0] if len(values) == 1 else values for label, values in printed.items()}, server


SENDER = 'Portal <portal@example.test>'
PLAIN_SESSION = ['MAIL FROM: <portal@example.test>', 'RCPT TO: <user@example.test>', 'DATA', 'QUIT']
AUTH_LINE = 'AUTH PLAIN ' + base64.b64encode(f'{USER}\0{USER}\0{PASSWORD}'.encode()).decode()
WRONG_AUTH = 'AUTH PLAIN ' + base64.b64encode(f'{USER}\0{USER}\0wrong'.encode()).decode()
ACCOUNT = USER + '@127.0.0.1'
REFUSED = 'The operation couldn’t be completed. Connection refused'


def plain(commands):
    return [('plain', c) for c in commands]


def tls(commands):
    return [('tls', c) for c in commands]


failures = []


def check(name, condition, detail):
    if condition:
        print('ok:', name)
    else:
        failures.append('%s: %s' % (name, detail))


with tempfile.TemporaryDirectory(prefix='isix-portal-mail-') as tmp:
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
        builds = {'direct': build(tmp / 'direct', tmp / 'modules', store=False),
                  'store': build(tmp / 'store', tmp / 'modules', store=True)}
    except subprocess.CalledProcessError as e:
        print('FAIL: a harness did not build:', (e.stderr or b'').decode(errors='replace')[-4000:])
        sys.exit(1)

    for channel, harness in builds.items():
        def case(mode, port=0, tls_mode=0, user=None, stored=None, sender=SENDER, mail='taken', trusted=False):
            return session(harness, env, home, mode, port, tls_mode, user, stored, sender, mail, der if trusted else None, context)

        got, server = case('plain')
        address = 'server 127.0.0.1:%d' % server.port
        check(f'{channel}: a server set, no authentication: sent through it',
              got['build'] == channel and got['route'] == address and got['refuses'] == 'false'
              and got['report'] == f'{address} | user@example.test | -' and got['recorded'] == '1 true'
              and got['log'] == 'email to user@example.test sent through 127.0.0.1:%d' % server.port
              and got['mail calls'] == '0' and got['asked'] == '' and got['stored'] == '4'
              and server.commands == plain(['HELO'] + PLAIN_SESSION) and server.delivered, (got, server.commands))

        got, server = case('plain', user=USER, stored=PASSWORD)
        check(f'{channel}: the password is the one of the given store, asked for the user at the server',
              got['report'].endswith('| -') and got['asked'] == ACCOUNT and got['mail calls'] == '0'
              and server.commands == plain(['EHLO', AUTH_LINE] + PLAIN_SESSION) and server.delivered, (got, server.commands))

        got, server = case('starttls', tls_mode=2, user=USER, stored=PASSWORD, trusted=True)
        check(f'{channel}: STARTTLS required: sent over TLS',
              got['report'].endswith('| -') and server.delivered
              and server.commands == plain(['EHLO', 'STARTTLS']) + tls(['EHLO', AUTH_LINE] + PLAIN_SESSION), (got, server.commands))

        got, server = case('plain', user=USER, stored='wrong')
        check(f'{channel}: the server refuses the password: reported with its reply',
              got['refuses'] == 'false' and got['recorded'] == '1 true' and not server.delivered
              and got['report'].endswith('| user@example.test | Error 535: 5.7.8 Authentication credentials invalid')
              and got['log'] == 'email to user@example.test not sent: Error 535: 5.7.8 Authentication credentials invalid'
              and server.commands == plain(['EHLO', WRONG_AUTH]) and got['mail calls'] == '0', (got, server.commands))

        got, _ = case('refused', port=closed_port())
        check(f'{channel}: nothing listens on the port: reported with the connection\'s error',
              got['refuses'] == 'false' and got['recorded'] == '1 true' and got['mail calls'] == '0'
              and got['report'].endswith('| user@example.test | ' + REFUSED), got)

        got, _ = case('refused', port=closed_port(), user=USER)
        missing = 'the password of the mail server is not in the Keychain'
        check(f'{channel}: no password for a server that authenticates: refused before any connection',
              got['refuses'] == 'true' and got['refusal'] == missing and got['report'].endswith('| ' + missing)
              and got['recorded'] == '1 true' and got['asked'] == ACCOUNT and got['mail calls'] == '0', got)

        got, _ = case('refused', port=closed_port(), sender=None)
        check(f'{channel}: no sender address: refused before any connection',
              got['refuses'] == 'true' and got['refusal'] == 'Empty sender email address'
              and got['report'].endswith('| Empty sender email address') and got['mail calls'] == '0', got)

        if channel == 'direct':
            got, _ = case('none')
            check('direct: no server set: handed to the Mail application',
                  got['route'] == 'mail' and got['refuses'] == 'false' and got['mail calls'] == '1' and got['stored'] == '0'
                  and got['mail'] == f'user@example.test | {SENDER} | IsiX portal test'
                  and got['report'] == 'mail | user@example.test | -' and got['recorded'] == '1 true'
                  and got['log'] == 'email to user@example.test handed to the Mail application' and got['asked'] == '', got)
            got, _ = case('none', mail='refused')
            check('direct: no server set and Mail does not take the message: reported',
                  got['mail calls'] == '1' and got['recorded'] == '1 true'
                  and got['report'] == 'mail | user@example.test | the Mail application did not take the message', got)
        else:
            got, _ = case('none')
            check('store: no server set: no Mail route, reported as no server set',
                  got['build'] == 'store' and got['route'] == 'none' and got['refuses'] == 'true'
                  and got['refusal'] == 'no mail server is set' and got['mail calls'] == '0' and got['stored'] == '0'
                  and 'mail' not in got and got['report'] == 'none | user@example.test | no mail server is set'
                  and got['recorded'] == '1 true'
                  and got['log'] == 'email to user@example.test not sent: no mail server is set', got)

# What the two builds differ by is one condition of the delivery, and the
# source that reads the Keychain is not the one compiled here.
delivery = (root / 'Horos/Sources/WebPortalMailDelivery.swift').read_text()
check('the delivery reads no Keychain item and no preference of the process by itself',
      'import Security' not in delivery and 'SecItem' not in delivery and 'PreferencesSource' not in delivery
      and 'CSMailMailClient' not in delivery and delivery.count('#if MACAPPSTORE') == 1, 'WebPortalMailDelivery.swift')

for failure in failures:
    print('FAIL:', failure)
if failures:
    sys.exit(1)
print('PASS: the portal\'s emails by SMTP in both builds: sent, refused by the server, unreachable, without password, '
      'without sender, and without a server (Mail in the direct build, reported in the App Store build)')
