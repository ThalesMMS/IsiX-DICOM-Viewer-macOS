#!/usr/bin/env python3
"""WADO-URI Original Syntax: a server that refuses transferSyntax=* is asked without it.

Original Syntax asks for `transferSyntax=*&useOrig=true`. Some servers read the
wildcard as a syntax they do not have and answer 404 to every instance, where
`useOrig=true` alone - the request before the wildcard was added - gets the
file. The production WADODownload is compiled and run against a local server:

- refuse-wildcard: 404 to the wildcard, the file without it. Every instance
  arrives, those refused are asked once more without the wildcard whatever the
  retry setting, and a later retrieve from the same endpoint starts without it.
- accepts: a server that takes the wildcard is only ever asked with it.
- missing: on a server that takes the wildcard, an instance missing for good is
  asked once without it, and the endpoint is then asked with it again.
- unauthorized: a 401 is not the wildcard's doing and changes no request.
- explicit: a refused Explicit VR Little Endian request is not rewritten.
"""
import ast
import http.server
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import threading
from urllib.parse import parse_qs

if shutil.which("xcrun") is None:
    print("skipped: needs macOS and xcrun (Swift and Objective-C compilers)", file=sys.stderr)
    raise SystemExit(2)

ROOT = Path(__file__).resolve().parents[1]
failures = []

# --- source -----------------------------------------------------------------
download = (ROOT / 'Horos/Sources/WADODownload.swift').read_text()
if 'WADOOriginalSyntax.request(for: url as URL)' not in download:
    failures.append('the pass does not send the rewritten URL')
query = (ROOT / 'Horos/Sources/DCMTKQueryNode.mm').read_bytes().decode('latin1')
if 'return @"&transferSyntax=*&useOrig=true";' not in query:
    failures.append('Original Syntax no longer asks for transferSyntax=*&useOrig=true')

# --- harness: the doubles of the WADO network log test ------------------------
values = {}
for node in ast.parse((ROOT / 'tests/test-activity-progress-window.py').read_text()).body:
    if isinstance(node, ast.Assign) and isinstance(node.value, ast.Constant) and isinstance(node.value.value, str):
        for target in node.targets:
            if isinstance(target, ast.Name):
                values[target.id] = node.value.value
    elif isinstance(node, ast.Assign) and any(isinstance(t, ast.Name) and t.id == 'LOG_HEADER' for t in node.targets):
        values['LOG_HEADER'] = values['EXCEPTION_HEADER'] + ast.literal_eval(node.value.right)
for node in ast.parse((ROOT / 'tests/test-wado-network-log.py').read_text()).body:
    if isinstance(node, ast.Assign) and isinstance(node.targets[0], ast.Name) and node.targets[0].id in ('HEADER', 'DOUBLES'):
        values[node.targets[0].id] = values[node.value.left.slice.value] + ast.literal_eval(node.value.right)

WILDCARD = '&transferSyntax=*&useOrig=true'
EXPLICIT = '&transferSyntax=1.2.840.10008.1.2.1'

DRIVER = r'''
import Cocoa
final class HorosAlertPanel {
    static func runCritical(title: String?, message: String, defaultButton: String?, alternateButton: String?, otherButton: String?) {}
}

@main struct Driver {
    static func main() throws {
        let args = CommandLine.arguments
        let base = args[1], work = args[2], mode = args[3], syntax = args[4]
        try FileManager.default.createDirectory(atPath: work + "/incoming", withIntermediateDirectories: true)
        // No repeat of a refusal: what asks again here is the wildcard rule alone.
        UserDefaults.standard.set(0, forKey: "WADORetryAttempts")
        UserDefaults.standard.set(2, forKey: "WADOMaximumConcurrentDownloads")
        var received: [Int32] = []
        // Two retrieves from the same endpoint, as one study after another.
        for batch in [["1", "2", "3", "4"], ["5", "6"]] {
            let downloader = WADODownload()
            downloader.showErrorMessage = false
            let urls = batch.map { URL(string: base + "/" + mode + "?requestType=WADO&studyUID=1.2&seriesUID=1.2.3&objectUID=" + $0
                                       + "&contentType=application/dicom" + syntax)! }
            downloader.WADODownload(urls)
            received.append(downloader.countOfSuccesses)
        }
        print(String(data: try JSONSerialization.data(withJSONObject: ["received": received]), encoding: .utf8)!)
    }
}
'''

BODY = b'\0' * 128 + b'DICM' + b'fixture'


class Handler(http.server.BaseHTTPRequestHandler):
    seen = []
    lock = threading.Lock()

    def log_message(self, *args):
        pass

    def answer(self, status, body=b''):
        self.send_response(status)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path, _, raw = self.path.partition('?')
        mode = path[1:]
        query = parse_qs(raw)
        uid = query.get('objectUID', [''])[0]
        syntax = query.get('transferSyntax', [''])[0]
        orig = query.get('useOrig', [''])[0]
        with self.lock:
            self.seen.append({'mode': mode, 'uid': uid, 'transferSyntax': syntax, 'useOrig': orig})
        if mode == 'refuse-wildcard':
            return self.answer(404) if syntax == '*' else self.answer(200, BODY)
        if mode == 'accepts':
            return self.answer(200, BODY)
        if mode == 'missing':
            return self.answer(404) if uid == '2' else self.answer(200, BODY)
        if mode == 'unauthorized':
            return self.answer(401)
        if mode == 'explicit':
            return self.answer(404)
        return self.answer(500)


with tempfile.TemporaryDirectory(prefix='wado-original-syntax-') as directory:
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

    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f'http://127.0.0.1:{server.server_port}'

    def drive(mode, syntax=WILDCARD):
        Handler.seen.clear()
        result = run([str(executable), base, str(work / mode), mode, syntax])
        return json.loads(result.stdout.splitlines()[-1])['received'], list(Handler.seen)

    def asked(seen, uids):
        return [r for r in seen if r['uid'] in uids]

    try:
        received, seen = drive('refuse-wildcard')
        first, second = asked(seen, {'1', '2', '3', '4'}), asked(seen, {'5', '6'})
        if received != [4, 2]:
            failures.append(f'refuse-wildcard: received {received}, not [4, 2]')
        for uid in '1234':
            plain = [r for r in first if r['uid'] == uid and r['transferSyntax'] == '' and r['useOrig'] == 'true']
            if len(plain) != 1:
                failures.append(f'refuse-wildcard: instance {uid} was asked {len(plain)} times without the wildcard, not once')
        if any(r['transferSyntax'] for r in second) or len(second) != 2:
            failures.append(f'refuse-wildcard: the next retrieve from the endpoint still sent the wildcard: {second}')
        if not any(r['transferSyntax'] == '*' for r in first):
            failures.append('refuse-wildcard: the wildcard was never sent; the scenario proves nothing')

        received, seen = drive('accepts')
        if received != [4, 2] or len(seen) != 6 or any(r['transferSyntax'] != '*' for r in seen):
            failures.append(f'accepts: {received} received in {len(seen)} requests; every one must carry the wildcard, once')

        received, seen = drive('missing')
        two = asked(seen, {'2'})
        if received != [3, 2]:
            failures.append(f'missing: received {received}, not [3, 2]')
        if sorted(r['transferSyntax'] for r in two) != ['', '*']:
            failures.append(f'missing: the missing instance was asked {[r["transferSyntax"] for r in two]}, not once with and once without the wildcard')
        if any(r['transferSyntax'] != '*' for r in asked(seen, {'5', '6'})):
            failures.append('missing: an instance missing for good left the endpoint asked without the wildcard')

        received, seen = drive('unauthorized')
        if received != [0, 0] or len(seen) != 6 or any(r['transferSyntax'] != '*' for r in seen):
            failures.append(f'unauthorized: {len(seen)} requests for 6 instances, or one without the wildcard')

        received, seen = drive('explicit', EXPLICIT)
        if received != [0, 0] or len(seen) != 6 or any(r['transferSyntax'] != '1.2.840.10008.1.2.1' for r in seen):
            failures.append(f'explicit: a refused Explicit VR Little Endian request was rewritten or repeated ({len(seen)} requests)')
    finally:
        server.shutdown()
        server.server_close()

for failure in failures:
    print('FAIL:', failure)
if not failures:
    print('PASS: a refused wildcard is asked again with useOrig=true alone and remembered per endpoint; '
          'servers that take it, credentials and explicit syntaxes are unchanged')
sys.exit(1 if failures else 0)
