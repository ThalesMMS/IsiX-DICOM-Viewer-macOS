#!/usr/bin/env python3
"""WADO-URI credentials: in the Keychain and the Authorization header, never in the URL.

- source: the WADO retrieve and the Locations test button build their URL from
  the protocol, host, port and path only, and read no plain WADOPassword.
- migrate: a plain WADOPassword in SERVERS moves to the Keychain (an in-memory
  one here) as a Basic credential and leaves the preferences; an entry without
  a username loses its unused password; running it again changes nothing; a
  SERVERS given as a launch argument is not written.
- basic: the production WADODownload, given the node's credential, retrieves
  from a server that demands `Authorization: Basic` (UTF-8) with a password
  holding '@', ':', '/' and a non-ASCII letter. Without the credential the
  same server refuses every request.
- redirect: a redirect to another origin (host and port) arrives without
  Authorization; one to the same origin keeps it.
- cookie: the session is ephemeral: a cookie set during one pass is not sent
  by the retry pass.
"""
import ast
import base64
import http.server
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import threading

if shutil.which("xcrun") is None:
    print("skipped: needs macOS and xcrun (Swift and Objective-C compilers)", file=sys.stderr)
    raise SystemExit(2)

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tests'))
from sources import source_text  # noqa: E402

failures = []

# --- source -----------------------------------------------------------------
query = (ROOT / 'Horos/Sources/DCMTKQueryNode.mm').read_bytes().decode('latin1')
retrieve = query[query.index('- (void) WADORetrieve: (DCMTKStudyQueryNode*) study listing:'):]
retrieve = retrieve[:retrieve.index('\n- (void) WADORetrieve: (DCMTKStudyQueryNode*) study\n')]
pane = source_text('OSILocationsPreferencePanePref')
button = pane[pane.index('public func testWADOUrl(_ sender: Any?)'):]
button = button[:button.index('\n    }\n')]
for name, text in (('WADORetrieve', retrieve), ('testWADOUrl', button)):
    if re.search(r'@?"WADOPassword"', text):
        failures.append(f'{name} still reads a plain WADOPassword from the node')
    if re.search(r'%@:%@@', text):
        failures.append(f'{name} still formats user:password@ into a URL')
    formats = re.findall(r'"(%@://[^"]*requestType=WADO)"', text)
    if formats != ['%@://%@:%d/%@?requestType=WADO']:
        failures.append(f'{name} builds its WADO URL with {formats}, not scheme://host:port/path')
if 'downloader.authorization = authorization;' not in retrieve or retrieve.count('[[WADODownload alloc] init]') != retrieve.count('downloader.authorization = authorization;'):
    failures.append('a WADO downloader of WADORetrieve does not carry the credential')

# --- harness ----------------------------------------------------------------
values = {}
for node in ast.parse((ROOT / 'tests/test-activity-progress-window.py').read_text()).body:
    if isinstance(node, ast.Assign) and isinstance(node.value, ast.Constant) and isinstance(node.value.value, str):
        for target in node.targets:
            if isinstance(target, ast.Name):
                values[target.id] = node.value.value
    elif isinstance(node, ast.Assign) and any(isinstance(t, ast.Name) and t.id == 'LOG_HEADER' for t in node.targets):
        values['LOG_HEADER'] = values['EXCEPTION_HEADER'] + ast.literal_eval(node.value.right)
# The doubles of the WADO network log test: the app around WADODownload.
for node in ast.parse((ROOT / 'tests/test-wado-network-log.py').read_text()).body:
    if isinstance(node, ast.Assign) and isinstance(node.targets[0], ast.Name) and node.targets[0].id in ('HEADER', 'DOUBLES'):
        values[node.targets[0].id] = values[node.value.left.slice.value] + ast.literal_eval(node.value.right)

USERNAME = 'reader'
PASSWORD = 'p@ss:w/rd-ção-SYNTHETIC'
EXPECTED = 'Basic ' + base64.b64encode(f'{USERNAME}:{PASSWORD}'.encode('utf-8')).decode('ascii')

DRIVER = r'''
import Cocoa
final class HorosAlertPanel {
    static func runCritical(title: String?, message: String, defaultButton: String?, alternateButton: String?, otherButton: String?) {}
}
final class Memory: @unchecked Sendable { var items: [String: Data] = [:] }
let memory = Memory()

@main struct Driver {
    static func main() throws {
        let args = CommandLine.arguments
        DICOMwebCredentials.backend = DICOMwebCredentials.Backend(
            read: { id, wantData in memory.items[id].map { (wantData ? $0 : nil, nil) } },
            add: { id, data, _ in memory.items[id] = data },
            update: { id, data, _ in
                guard memory.items[id] != nil else { return false }
                if let data { memory.items[id] = data }
                return true
            },
            delete: { id in memory.items[id] = nil })
        let mode = args[3]
        if mode == "argument" {
            // Launched with -SERVERS: that list is not the preferences'.
            let moved = WADOCredentials.migrateServers(in: .standard)
            print(moved == 0 && memory.items.isEmpty ? "argument-ok" : "argument-written")
            return
        }
        let suite = "wado-credentials-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set([["Description": "with", "WADOUsername": "USERNAME", "WADOPassword": "PASSWORD"],
                      ["Description": "plain"],
                      ["Description": "orphan", "WADOPassword": "unused"]], forKey: "SERVERS")
        let moved = WADOCredentials.migrateServers(in: defaults)
        let servers = defaults.array(forKey: "SERVERS") as! [NSDictionary]
        let again = WADOCredentials.migrateServers(in: defaults)
        let authorization = try WADOCredentials.authorization(forServer: servers[0])
        if mode == "migrate" {
            let result: [String: Any] = [
                "moved": moved, "again": again,
                "plain": servers.map { $0["WADOPassword"] != nil },
                "identifier": servers[0]["WADOCredential"] as? String ?? "",
                "username": servers[0]["WADOUsername"] as? String ?? "",
                "orphanCredential": servers[2]["WADOCredential"] != nil,
                "items": memory.items.count,
                "authorization": authorization,
                "plainAuthorization": try WADOCredentials.authorization(forServer: ["WADOUsername": "USERNAME", "WADOPassword": "PASSWORD"]),
                "noneAuthorization": try WADOCredentials.authorization(forServer: servers[1]),
            ]
            print(String(data: try JSONSerialization.data(withJSONObject: result), encoding: .utf8)!)
            return
        }
        try FileManager.default.createDirectory(atPath: args[2] + "/incoming", withIntermediateDirectories: true)
        UserDefaults.standard.set(1, forKey: "WADORetryAttempts")
        UserDefaults.standard.set(1, forKey: "WADOMaximumConcurrentDownloads")
        let downloader = WADODownload()
        downloader.showErrorMessage = false
        downloader.authorization = mode == "none" ? nil : authorization
        let urls = ["1", "2"].map { URL(string: args[1] + "/" + mode + "?requestType=WADO&objectUID=" + $0)! }
        downloader.WADODownload(urls)
        print(String(data: try JSONSerialization.data(withJSONObject: [
            "received": downloader.countOfSuccesses,
            "userinfo": urls.contains { $0.user != nil || $0.password != nil }]), encoding: .utf8)!)
    }
}
'''.replace('USERNAME', USERNAME).replace('PASSWORD', PASSWORD)

BODY = b'\0' * 128 + b'DICM' + b'fixture'


class Handler(http.server.BaseHTTPRequestHandler):
    seen = []
    other_port = 0
    cookie_sent = set()
    lock = threading.Lock()

    def log_message(self, *args):
        pass

    def answer(self, status, body=b'', headers=()):
        self.send_response(status)
        for name, value in headers:
            self.send_header(name, value)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path, _, query = self.path.partition('?')
        mode = path[1:]
        authorization = self.headers.get('Authorization')
        with self.lock:
            self.seen.append({'port': self.server.server_port, 'mode': mode, 'query': query,
                              'authorization': authorization, 'cookie': self.headers.get('Cookie')})
            first_cookie = mode == 'cookie' and query not in self.cookie_sent
            if first_cookie:
                self.cookie_sent.add(query)
        if mode == 'redirect-cross':
            return self.answer(302, headers=[('Location', f'http://localhost:{self.other_port}/landing?{query}')])
        if mode == 'redirect-same':
            return self.answer(302, headers=[('Location', f'/basic?{query}')])
        if mode == 'landing':
            return self.answer(200, BODY)
        if authorization != EXPECTED:
            return self.answer(401, b'Unauthorized', [('WWW-Authenticate', 'Basic realm="wado"')])
        if first_cookie:
            return self.answer(503, b'Try again', [('Set-Cookie', 'wadosession=SYNTHETIC; Path=/')])
        return self.answer(200, BODY)


with tempfile.TemporaryDirectory(prefix='wado-uri-credentials-') as directory:
    work = Path(directory)
    for name in ('HorosObjCException.h', 'HorosObjCException.m'):
        shutil.copy(ROOT / 'Horos/Sources' / name, work / name)
    (work / 'harness.h').write_text(values['HEADER'])
    (work / 'doubles.m').write_text(values['DOUBLES'])
    (work / 'driver.swift').write_text(DRIVER)

    def run(command, **kwargs):
        result = subprocess.run(command, capture_output=True, text=True, timeout=300, **kwargs)
        assert result.returncode == 0, result.stdout + result.stderr
        return result

    for name, flags in [('HorosObjCException', []), ('doubles', ['-fobjc-arc'])]:
        run(['xcrun', 'clang', '-x', 'objective-c', '-fobjc-exceptions', *flags, '-c',
             str(work / (name + '.m')), '-o', str(work / (name + '.o'))])
    executable = work / 'test'
    run(['xcrun', 'swiftc', '-suppress-warnings', '-swift-version', '5', '-parse-as-library', '-module-name', 'Horos',
         '-import-objc-header', str(work / 'harness.h'),
         *[str(ROOT / 'Horos/Sources' / name) for name in ('WADODownload.swift', 'WADOCredentials.swift', 'DICOMwebCredentials.swift',
                                                         'NonInteractiveKeychainRead.swift', 'RetrieveManifest.swift', 'LogManager.swift',
                                                         'NodeRequestLimiter.swift', 'RetrievePlan.swift')],
         str(work / 'driver.swift'), str(work / 'HorosObjCException.o'), str(work / 'doubles.o'),
         '-framework', 'Cocoa', '-framework', 'CoreData', '-o', str(executable)])

    servers = [http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler) for _ in range(2)]
    for server in servers:
        threading.Thread(target=server.serve_forever, daemon=True).start()
    Handler.other_port = servers[1].server_port
    base = f'http://127.0.0.1:{servers[0].server_port}'

    def drive(mode):
        Handler.seen.clear()
        result = run([str(executable), base, str(work / mode), mode])
        return json.loads(result.stdout.splitlines()[-1]), list(Handler.seen)

    try:
        migrated, _ = drive('migrate')
        if migrated['moved'] != 2 or migrated['again'] != 0:
            failures.append(f"migration moved {migrated['moved']} then {migrated['again']} entries, not 2 then 0")
        if any(migrated['plain']):
            failures.append(f"a WADOPassword stayed in SERVERS after the migration: {migrated['plain']}")
        if not re.fullmatch(r'[0-9A-F-]{36}', migrated['identifier']) or migrated['username'] != USERNAME or migrated['items'] != 1:
            failures.append('the migrated node has no Keychain credential, or lost its username')
        if migrated['orphanCredential']:
            failures.append('a password without a username was stored')
        if migrated['authorization'] != EXPECTED or migrated['plainAuthorization'] != EXPECTED:
            failures.append('the Authorization of a node is not Basic base64(username:password) in UTF-8')
        if migrated['noneAuthorization'] != '':
            failures.append('a node without credentials has an Authorization')

        argument = subprocess.run([str(executable), base, str(work / 'argument'), 'argument',
                                   '-SERVERS', '({WADOUsername="u";WADOPassword="SYNTHETIC";})'],
                                  capture_output=True, text=True, timeout=60)
        if argument.stdout.strip().splitlines()[-1:] != ['argument-ok']:
            failures.append('a SERVERS given as a launch argument was migrated: ' + argument.stdout + argument.stderr)

        result, seen = drive('basic')
        if result['received'] != 2 or result['userinfo']:
            failures.append(f'Basic retrieve received {result["received"]} of 2')
        if not seen or any(r['authorization'] != EXPECTED for r in seen):
            failures.append('a WADO request went without the Basic header')

        result, seen = drive('none')
        if result['received'] != 0 or not seen or any(r['authorization'] for r in seen):
            failures.append('the fixture let a request without credentials through; the Basic check proves nothing')

        result, seen = drive('redirect-cross')
        landing = [r for r in seen if r['mode'] == 'landing']
        if result['received'] != 2 or len(landing) != 2:
            failures.append(f'the cross-origin redirect was not followed ({result["received"]} received)')
        if any(r['authorization'] for r in landing):
            failures.append('a redirect to another origin carried Authorization')
        if any(r['authorization'] != EXPECTED for r in seen if r['mode'] == 'redirect-cross'):
            failures.append('the request before the redirect went without the Basic header')

        result, seen = drive('redirect-same')
        if result['received'] != 2 or any(r['authorization'] != EXPECTED for r in seen):
            failures.append('a redirect to the same origin lost Authorization')

        result, seen = drive('cookie')
        if result['received'] != 2 or len(seen) != 4:
            failures.append(f'the cookie scenario received {result["received"]} of 2 in {len(seen)} requests')
        # One request at a time: both instances fail once in the first pass,
        # each setting the cookie, and the retry pass asks for them again.
        if any(r['cookie'] for r in seen[2:]):
            failures.append('a cookie set in one pass was sent by the next: the session is not ephemeral')
        if not seen[1:2] or not seen[1]['cookie']:
            failures.append('the cookie was not kept even within its pass; this scenario proves nothing')
    finally:
        for server in servers:
            server.shutdown()
            server.server_close()

for failure in failures:
    print('FAIL:', failure)
if not failures:
    print('PASS: no credentials in WADO URLs; Keychain migration; Basic in UTF-8 with @ : /; '
          'no Authorization across origins; ephemeral session')
sys.exit(1 if failures else 0)
