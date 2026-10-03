#!/usr/bin/env python3
"""What a DICOMweb node says about a refusal reaches the user; one path rule for a node.

The client's sources, compiled with the DICOM-Swift products the app links,
over loopback, with credentials in memory only:

- a node that refuses a query, a retrieve and a send with HTTP 400 and a text
  body, an X-DICOMweb-Error-Code and a Warning: each error's message ends
  with what the node said, on one line, and the send's activity status line
  carries it; the credential the client sent, echoed in the body and in an
  Authorization line, and a Cookie line are removed, and neither the host nor
  a secret is in any message;
- a refusal with a 10 KiB body: the message keeps at most 300 characters of
  it, and the whole sanitized reason (at most 4 KiB) goes to the error's
  user info and to the log;
- a QIDO answer with a Warning 299, over two pages: the query succeeds, and
  the log has the Warning once;
- the node editor's rule and the client's resolution agree on every sample
  path, and a path with "%41" is stored as written by the editor, resolved
  without being encoded again, and requested at that path.

And in the sources: the send's activity shows the status line with the reason.
"""
import http.server
import json
import os
import subprocess
import sys
import tempfile
import threading
from pathlib import Path

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'tests'))
sys.path.insert(0, str(root / 'tools'))
from dicomweb_package import swift_flags  # noqa: E402
from local_http import ThreadingLocalHTTPServer  # noqa: E402

failures = []
SECRET = 'tok-SYNTHETIC-1155'
COOKIE = 'session=cookie-SYNTHETIC-1155'
paths = []
lock = threading.Lock()


def check(ok, message):
    if not ok:
        failures.append(message)
        print('FAIL: ' + message)


def record(uid):
    return {'0020000D': {'vr': 'UI', 'Value': [uid]}}


class Node(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *args):
        pass

    def reply(self, status, body, content_type, extra=()):
        self.send_response(status)
        for key, value in extra:
            self.send_header(key, value)
        self.send_header('Content-Type', content_type)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def answer(self):
        path = self.path.split('?')[0]
        query = self.path.partition('?')[2]
        with lock:
            paths.append(path)
        length = int(self.headers.get('Content-Length') or 0)
        if length:
            self.rfile.read(length)
        mode = path.strip('/').split('/')[0]
        if mode == 'reason':
            # The credential the client sent, echoed as a header line and in the text.
            token = (self.headers.get('Authorization') or '').split(' ')[-1]
            body = ('PatientBirthDate must be a date (YYYYMMDD).\r\nAuthorization: Bearer %s\r\nCookie: %s\r\n'
                    'Request seen with token %s.' % (token, COOKIE, token)).encode()
            return self.reply(400, body, 'text/plain', [('X-DICOMweb-Error-Code', '1155-bad-date'),
                                                         ('Warning', '299 node "Invalid date"')])
        if mode == 'long':
            return self.reply(400, ('too long ' * 1200).encode(), 'text/plain')
        if mode == 'warned':
            offset = int(dict(p.split('=', 1) for p in query.split('&') if '=' in p).get('offset', '0'))
            records = [record('2.25.1155.%d' % n) for n in range(100)] if offset == 0 else [record('2.25.1155.100')]
            return self.reply(200, json.dumps(records).encode(), 'application/dicom+json',
                              [('Warning', '299 node "The fuzzymatching parameter is not supported."')])
        if mode == 'paths':
            return self.reply(200, json.dumps([record('2.25.1155.1')]).encode(), 'application/dicom+json')
        self.reply(404, b'', 'text/plain')

    do_GET = answer
    do_POST = answer


DRIVER = r'''
import Foundation
import DicomWebClient
import DicomData

nonisolated(unsafe) var failed = false
func check(_ ok: Bool, _ what: String) { if !ok { print("FAIL: \(what)"); failed = true } }
final class Memory: @unchecked Sendable { var items: [String: (Data, Data?)] = [:] }
let memory = Memory()

@main struct Check {
 static func main() {
  if NonInteractiveKeychainRead.runHelperIfRequested() { exit(0) }
  DICOMwebCredentials.backend = DICOMwebCredentials.Backend(
   read: { id, wantData in memory.items[id].map { (wantData ? $0.0 : nil, $0.1) } },
   add: { id, data, generic in memory.items[id] = (data, generic) },
   update: { id, data, generic in guard let item = memory.items[id] else { return false }; memory.items[id] = (data ?? item.0, generic); return true },
   delete: { id in memory.items[id] = nil })
  let base = CommandLine.arguments[1], file = CommandLine.arguments[2], staging = CommandLine.arguments[3]
  let secret = "tok-SYNTHETIC-1155", cookie = "cookie-SYNTHETIC-1155"
  let host = URL(string: base)!.host!
  func client(_ mode: String, qido: String = "", credential: String = "") throws -> DICOMwebClient {
   let client = DICOMwebClient(node: try DICOMwebNodeConfiguration(address: base + "/" + mode, qidoPath: qido, wadoPath: "",
                                                                  credentialIdentifier: credential, retrieveTransferSyntax: "",
                                                                  allowInsecureHTTP: false), timeout: 10)
   client.repeatsBusyRequests = false
   return client
  }
  func clean(_ text: String) -> Bool { !text.contains(secret) && !text.contains(cookie) && !text.contains(host) }
  let done = DispatchSemaphore(value: 0)
  Thread.detachNewThread {
   defer { done.signal() }
   do {
    let bearer = try DICOMwebCredentials.store(kind: .bearer, username: "", secret: secret, headerName: "")
    let said = "The node said: error code 1155-bad-date; Warning: 299 node \"Invalid date\"; PatientBirthDate must be a date (YYYYMMDD). Authorization: [redacted] Cookie: [redacted] Request seen with token [redacted]."
    let refusing = try client("reason", credential: bearer)
    var errors: [NSError] = []
    do { _ = try refusing.query(path: "studies", parameters: [:]); check(false, "the refused query succeeded") } catch { errors.append(error as NSError) }
    do { _ = try refusing.retrieve(path: "studies/2.25.1155", stagingDirectory: staging, cancelled: { false }); check(false, "the refused retrieve succeeded") }
    catch { errors.append(error as NSError) }
    for e in errors {
     let message = e.localizedDescription
     check(message.hasPrefix("DICOMweb returned HTTP 400.") && message.hasSuffix(said), "the message ends with what the node said: \(message)")
     check(clean(message) && clean(String(describing: e.userInfo)), "no secret, cookie or host: \(e.userInfo)")
     check((e.userInfo[DICOMwebClient.serverReasonKey] as? String).map { said.hasSuffix($0) } == true, "the whole reason is in the user info")
    }
    let stored = try refusing.store(files: [file], cancelled: { false })
    check(stored.count == 1 && stored[0].status == .failure && stored[0].reason.hasSuffix(said) && clean(stored[0].reason),
          "the refused send says why: \(stored.map { $0.reason })")
    let report = DICOMwebSendReport(results: stored, cancelled: false)
    check(report.statusLine == report.summary + " " + stored[0].reason, "the activity status line carries the reason: \(report.statusLine)")
    let fine = DICOMwebSendReport(results: [DICOMwebStoreResult(path: file, sopInstanceUID: "2.25.1", status: .success, reason: "")], cancelled: false)
    check(fine.statusLine == fine.summary, "a complete send shows its summary alone")

    // A long refusal: a short part in the message, the whole in the user info.
    do { _ = try client("long").query(path: "studies", parameters: [:]); check(false, "the long refusal succeeded") }
    catch {
     let e = error as NSError
     let shown = e.localizedDescription.components(separatedBy: "The node said: ").last ?? ""
     let whole = e.userInfo[DICOMwebClient.serverReasonKey] as? String ?? ""
     check(shown.count <= DICOMwebClient.messageReasonLength + 1 && shown.hasSuffix("…") && shown.hasPrefix("too long too long"), "the message keeps a short part: \(shown.count)")
     check(whole.count > 3000 && whole.utf8.count <= 4096 && whole.hasPrefix("too long"), "the user info keeps the sanitized whole: \(whole.count)")
    }

    // A Warning 299 with the results, on two pages: logged once.
    check(try client("warned").query(path: "studies", parameters: [:]).count == 101, "the warned query has its two pages")

    // One rule for a path: the editor's and the resolution's agree.
    for sample in ["", "a%41b/qido", "/rs/qido/", "a:b", "x;y=1", "~user", "%2e%2e/x", "a%2Fb", "%zz", "a b", "a?x=1", "a#b",
                   "../x", "./a", "a\\b", "a\"b", "a|b", "a{b}", "é", "https://other/x", "//other/x"] {
     let editor = DICOMwebNode.relativePath(sample) != nil
     let resolved = (try? DICOMwebNodeConfiguration(address: base, qidoPath: sample, wadoPath: sample, credentialIdentifier: "",
                                                   retrieveTransferSyntax: "", allowInsecureHTTP: false)) != nil
     check(editor == resolved, "editor (\(editor)) and resolution (\(resolved)) agree on \(sample)")
    }
    check(try DICOMwebNode.normalizedPath(" /a%41b/qido/ ") == "a%41b/qido", "the editor keeps %41 as written")
    let escaped = try DICOMwebNodeConfiguration(address: base + "/paths", qidoPath: "a%41b/qido", wadoPath: "a%41b",
                                                credentialIdentifier: "", retrieveTransferSyntax: "", allowInsecureHTTP: false)
    check(escaped.qidoURLString == base + "/paths/a%41b/qido" && escaped.wadoURLString == base + "/paths/a%41b",
          "the resolution keeps %41 as written: \(escaped.qidoURLString)")
    check(try client("paths", qido: "a%41b/qido").query(path: "studies", parameters: [:]).count == 1, "a query below a %41 path")
   } catch { check(false, "unexpected error \(error)") }
  }
  done.wait()
  if failed { exit(1) }
  print("PASS: what the node said in each error and the send's status line, sanitized and cut short; the QIDO Warning; one path rule with %41")
 }
}
'''


def part10(uid):
    import struct

    def element(group, elem, vr, value):
        if len(value) % 2:
            value += b'\0' if vr == b'UI' else b' '
        if vr == b'OB':
            return struct.pack('<HH', group, elem) + vr + b'\0\0' + struct.pack('<I', len(value)) + value
        return struct.pack('<HH', group, elem) + vr + struct.pack('<H', len(value)) + value
    meta = (element(2, 1, b'OB', b'\0\1') + element(2, 2, b'UI', b'1.2.840.10008.5.1.4.1.1.7')
            + element(2, 3, b'UI', uid.encode()) + element(2, 0x10, b'UI', b'1.2.840.10008.1.2.1'))
    data = element(8, 0x16, b'UI', b'1.2.840.10008.5.1.4.1.1.7') + element(8, 0x18, b'UI', uid.encode())
    return b'\0' * 128 + b'DICM' + element(2, 0, b'UL', struct.pack('<I', len(meta))) + meta + data


server = ThreadingLocalHTTPServer(('127.0.0.1', 0), Node)
threading.Thread(target=server.serve_forever, daemon=True).start()
try:
    with tempfile.TemporaryDirectory(prefix='horos-dicomweb-diagnostics-') as folder:
        temporary = Path(folder)
        sources = [str(root / 'Horos/Sources' / name) for name in
                   ('DICOMwebClient.swift', 'DICOMwebNode.swift', 'DICOMwebIntegration.swift', 'DICOMwebCredentials.swift',
                    'DICOMwebMultipart.swift', 'DicomNodeConfiguration.swift', 'NonInteractiveKeychainRead.swift',
                    'DICOMwebOIDC.swift')]
        (temporary / 'check.swift').write_text(DRIVER)
        executable = temporary / 'check'
        build = subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-suppress-warnings',
                                '-module-cache-path', str(temporary / 'module-cache'), *sources,
                                *swift_flags(temporary), str(temporary / 'check.swift'), '-o', str(executable)],
                               capture_output=True, text=True, timeout=600)
        check(build.returncode == 0, 'the DICOMweb sources and the check compile\n' + build.stderr[-3000:])
        (temporary / 'refused.dcm').write_bytes(part10('2.25.1155.9'))
        (temporary / 'tmp').mkdir()
        if not failures:
            run = subprocess.run([str(executable), f'http://127.0.0.1:{server.server_port}', str(temporary / 'refused.dcm'),
                                  str(temporary / 'staging')], capture_output=True, text=True, timeout=120,
                                 env=dict(os.environ, TMPDIR=f"{temporary / 'tmp'}/"))
            sys.stdout.write(run.stdout)
            check(run.returncode == 0, 'the client checks\n' + run.stderr[-2000:])
            log = run.stderr
            check(log.count('DICOMweb query: the node answered with Warning: 299 node "The fuzzymatching parameter is not supported."') == 1,
                  'the QIDO Warning is logged once: ' + log[-1500:])
            check('DICOMweb HTTP 400: the node said: error code 1155-bad-date' in log, 'the refusal is logged')
            reasons = [line for line in log.splitlines() if 'the node said: too long' in line]
            check(len(reasons) == 1 and len(reasons[0].split('the node said: ')[1]) > 3000, 'the long refusal is logged whole')
            check(SECRET not in log + run.stdout and 'cookie-SYNTHETIC-1155' not in log + run.stdout, 'no secret in the log')
            check('/paths/a%41b/qido/studies' in paths, 'the %41 path was requested as written: ' + str(paths[-3:]))
            check(not any((temporary / 'tmp').iterdir()), 'the client left nothing in TMPDIR')
finally:
    server.shutdown()
    server.server_close()

activity = (root / 'Horos/Sources/DICOMwebSendActivity.swift').read_text()
check('thread.status = report.statusLine' in activity, 'the send activity shows the status line')

for failure in failures:
    print('FAIL:', failure)
if not failures:
    print('PASS: sources: the send activity shows the reason')
sys.exit(1 if failures else 0)
