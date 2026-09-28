#!/usr/bin/env python3
"""DICOMweb nodes in the Query/Retrieve window, the Send sheet and Locations' Test (#799, part 3).

Object level, with the DICOMweb sources compiled together and preferences in
a defaults domain of this check's own name, removed when it ends:

- the Query/Retrieve window's sources are the valid nodes with Q&R on, as
  server dictionaries that name the node and ask for no listener; the Send
  sheet's destinations are the valid nodes with Send on; a SERVERS entry left
  with the former DICOMweb mode, or a DIMSE node, is never taken for one, and
  keeps its host:port address;
- a node's client goes to its QIDO and WADO paths with its Retrieve Syntax,
  the inventory is kept under its WADO endpoint, a node removed from
  Locations is refused with a message saying so;
- Locations' Test gives a message of its own for network, TLS, timeout,
  401/403, 404, redirect and HTTP errors, against a loopback server;
- STOW-RS through the sender, against tools/serve-dicomweb-fixture.py: "As
  stored" sends the files as they are, with a refused instance reported with
  its reason; another Send Syntax converts only the files in another syntax,
  sends the converted ones, reports a file that cannot be converted as not
  stored, and leaves no temporary folder; a cancelled send says what was not
  sent. The conversion stands for DCMTK's (HorosDICOMWriter), which needs the
  application; the fixture needs a Python with pydicom and numpy, and without
  one this part is skipped (exit 2 once the rest passed).

Source level: the Query window appends the DICOMweb sources to the DIMSE ones
and keeps DIMSE retrieve destinations, matches a saved DICOMweb source by its
identifier and follows DICOMWEB_SERVERS; DCMTKQueryNode queries, retrieves and
verifies through the node's client and no longer reads the pilot's
DICOMwebURL or compares the retrieve mode with DICOMwebRetrieveMode; the Send
sheet lists the DICOMweb destinations after the DIMSE ones and sends to them
by STOW-RS, converting with HorosDICOMWriter; Test maps the error kinds; the
new file is in the target and its strings are in the Italian and Spanish
catalogs.

Pass a git revision to run everything against that revision's sources (the
one before this part fails: it has no DICOMwebIntegration.swift).
"""
from pathlib import Path
import http.server
import json
import os
import re
import select
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'tools'))
sys.path.insert(0, str(root / 'tests'))
from local_http import ThreadingLocalHTTPServer  # noqa: E402
import python_with  # noqa: E402

revision = sys.argv[1] if len(sys.argv) > 1 else None
failures = []
UNIQUE = 'org.horos.test.dicomweb-integration'
JPEG_LOSSLESS = '1.2.840.10008.1.2.4.70'
EXPLICIT = '1.2.840.10008.1.2.1'


def check(ok, message):
    if not ok:
        failures.append(message)
        print('FAIL: ' + message)


def text(path):
    if revision:
        result = subprocess.run(['git', '-C', str(root), 'show', f'{revision}:{path}'], capture_output=True)
        return result.stdout.decode('latin1') if result.returncode == 0 else None
    full = root / path
    return full.read_bytes().decode('latin1') if full.exists() else None


if shutil.which('xcrun') is None:
    print('skipped: xcrun is needed to compile the DICOMweb sources', file=sys.stderr)
    sys.exit(2)


# --- DICOM files -----------------------------------------------------------

def element(group, elem, vr, value):
    if len(value) % 2:
        value += b'\0' if vr == b'UI' else b' '
    if vr in (b'OB', b'OW', b'SQ', b'UN', b'UT'):
        return struct.pack('<HH', group, elem) + vr + b'\0\0' + struct.pack('<I', len(value)) + value
    return struct.pack('<HH', group, elem) + vr + struct.pack('<H', len(value)) + value


def part10(uid, syntax):
    sop_class = b'1.2.840.10008.5.1.4.1.1.7'
    meta = (element(2, 1, b'OB', b'\0\1') + element(2, 2, b'UI', sop_class)
            + element(2, 3, b'UI', uid.encode()) + element(2, 0x10, b'UI', syntax.encode()))
    data = (element(8, 0x16, b'UI', sop_class) + element(8, 0x18, b'UI', uid.encode())
            + element(0x10, 0x10, b'PN', b'SYNTHETIC^STOW799') + element(0x20, 0x0D, b'UI', b'2.25.799.1')
            + element(0x20, 0x0E, b'UI', b'2.25.799.2'))
    return b'\0' * 128 + b'DICM' + element(2, 0, b'UL', struct.pack('<I', len(meta))) + meta + data


# --- a node that answers the Test query in every way it can fail -----------

class Node(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *_):
        pass

    def answer(self, status, extra=()):
        self.send_response(status)
        for key, value in extra:
            self.send_header(key, value)
        self.send_header('Content-Length', '0')
        self.end_headers()

    def do_GET(self):
        path = self.path.split('?')[0]
        if path in ('/ok/studies', '/ok/qido/studies'):
            return self.answer(204)
        if path.startswith('/auth/'):
            return self.answer(401)
        if path.startswith('/forbidden/'):
            return self.answer(403)
        if path.startswith('/redirect/'):
            return self.answer(302, [('Location', '/ok/studies')])
        if path.startswith('/broken/'):
            return self.answer(500)
        if path.startswith('/html/'):
            body = b'<html>not QIDO</html>'
            self.send_response(200)
            self.send_header('Content-Type', 'text/html')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            return self.wfile.write(body)
        if path.startswith('/slow/'):
            time.sleep(3)
            return self.answer(204)
        return self.answer(404)


DRIVER = r'''
import Foundation
var failed = false
func check(_ ok: Bool, _ what: String) { if !ok { print("FAIL: " + what); failed = true } }
func kind(_ error: Error?) -> DICOMwebErrorKind { DICOMwebClient.errorKind(for: error as NSError?) }
func make(_ name: String, _ address: String, qr: Bool, send: Bool, qido: String = "", wado: String = "",
          retrieve: String = DICOMwebNode.asStored, sendSyntax: String = DICOMwebNode.asStored) -> DICOMwebNode {
 let node = DICOMwebNode()
 node.name = name; node.address = address; node.queryRetrieve = qr; node.send = send
 node.qidoPath = qido; node.wadoPath = wado; node.retrieveSyntax = retrieve; node.sendSyntax = sendSyntax
 return node
}

@main struct Check {
 static func main() {
  let arguments = CommandLine.arguments
  let suite = arguments[1], base = arguments[2], closedPort = arguments[3], stowBase = arguments[4]
  let files = URL(fileURLWithPath: arguments[5]), temporaryRoot = URL(fileURLWithPath: arguments[6])
  let tlsBase = base.replacingOccurrences(of: "http://", with: "https://")
  let defaults = UserDefaults(suiteName: suite)!
  defaults.removePersistentDomain(forName: suite)
  defer { defaults.removePersistentDomain(forName: suite); defaults.synchronize() }

  // The lists the windows show.
  let alpha = make("Alpha", base + "/ok", qr: true, send: false, qido: "qido", wado: "wado/rs", retrieve: "1.2.840.10008.1.2.4.50")
  let beta = make("Beta", base + "/ok", qr: false, send: true)
  let gamma = make("Gamma", "ftp://127.0.0.1/nothing", qr: true, send: true)
  let delta = make("Delta", base + "/ok", qr: true, send: true)
  DICOMwebNode.save([alpha, beta, gamma, delta], to: defaults)
  let sources = DICOMwebSources.queryRetrieveServers(in: defaults)
  check(sources.compactMap { $0["Description"] as? String } == ["Alpha", "Delta"], "Q&R sources are the valid nodes with Q&R on: \(sources)")
  for source in sources {
   check(DICOMwebSources.isDICOMwebServer(source), "a source names its node")
   check((source["retrieveMode"] as? Int) == 3 && (source["AETitle"] as? String) == "DICOMweb" && (source["QR"] as? Bool) == true,
         "a source asks for no listener and shows DICOMweb as its AE title: \(source)")
   check(Set(source.keys) == ["DICOMwebNode", "Description", "AETitle", "Address", "QR", "Send", "Activated", "retrieveMode"],
         "a source carries no path, syntax or credential: \(source.keys.sorted())")
   check(DicomNodeConfiguration.address(forServer: source) == (source["Address"] as? String), "the Address column shows the node's address")
  }
  let destinations = DICOMwebSources.sendDestinations(in: defaults)
  check(destinations.compactMap { $0["Description"] as? String } == ["Beta", "Delta"], "Send destinations are the valid nodes with Send on")
  let dimse: [String: Any] = ["AETitle": "MAIN", "Address": "10.0.0.4", "Port": 104, "retrieveMode": 0]
  let stray: [String: Any] = ["AETitle": "OLD", "Address": "10.0.0.5", "Port": 104, "retrieveMode": 3,
                              "DICOMwebURL": "https://pacs.example/dicomweb", "DICOMwebCredentialID": UUID().uuidString]
  check(!DICOMwebSources.isDICOMwebServer(dimse) && !DICOMwebSources.isDICOMwebServer(stray) && !DICOMwebSources.isDICOMwebServer(nil),
        "a DIMSE entry, even one left with the former DICOMweb mode, is not a DICOMweb node")
  check(DicomNodeConfiguration.address(forServer: dimse) == "10.0.0.4:104" && DicomNodeConfiguration.address(forServer: stray) == "10.0.0.5:104",
        "DIMSE entries keep host:port in the Address column")

  // What a request is made with.
  do {
   let configuration = try DICOMwebSources.configuration(for: alpha)
   check(configuration.qidoURLString == base + "/ok/qido" && configuration.wadoURLString == base + "/ok/wado/rs"
         && configuration.storeURLString == base + "/ok/studies", "the node's QIDO, WADO and STOW URLs")
   check(configuration.retrieveTransferSyntax == "1.2.840.10008.1.2.4.50", "the node's Retrieve Syntax")
   let client = DICOMwebClient(node: configuration, timeout: 5)
   check(client.retrieveAcceptHeader.hasSuffix("transfer-syntax=1.2.840.10008.1.2.4.50"), "WADO-RS asks for the Retrieve Syntax")
   check(DICOMwebClient(node: try DICOMwebSources.configuration(for: delta), timeout: 5).retrieveAcceptHeader.hasSuffix("transfer-syntax=*"),
         "As stored asks for transfer-syntax=*")
  } catch { check(false, "a valid node's configuration: \(error)") }
  do { _ = try DICOMwebSources.configuration(for: gamma); check(false, "an invalid node is refused") }
  catch { check(kind(error) == .configuration, "an invalid node is a configuration error") }
  do { _ = try DICOMwebSources.client(forServer: [DICOMwebSources.nodeKey: UUID().uuidString], timeout: 1, in: defaults); check(false, "a removed node is refused") }
  catch { check(kind(error) == .configuration && (error as NSError).localizedDescription.contains("no longer in Locations"), "a removed node says so: \(error)") }
  let alphaServer = DICOMwebSources.server(for: alpha), deltaServer = DICOMwebSources.server(for: delta)
  check(DICOMwebSources.inventoryEndpoint(forServer: alphaServer, in: defaults) == base + "/ok/wado/rs"
        && DICOMwebSources.inventoryEndpoint(forServer: deltaServer, in: defaults) == base + "/ok",
        "the inventory is kept under the WADO endpoint, the address without a WADO path")
  check(DICOMwebSources.storeURL(forServer: deltaServer, in: defaults) == base + "/ok/studies", "the Send sheet shows {address}/studies")

  // Test's messages: one per kind.
  let kinds: [DICOMwebErrorKind] = [.network, .tls, .timeout, .authentication, .notFound, .redirect, .http, .invalidResponse, .credentials, .cancelled]
  let messages = kinds.map { DICOMwebVerification.message(for: DICOMwebClient.failure(401, "raw", kind: $0)) }
  check(Set(messages).count == kinds.count && !messages.contains("") && !messages.contains("raw"), "a distinct message per kind: \(messages)")
  check(DICOMwebVerification.message(for: DICOMwebClient.failure(403, "raw", kind: .authentication)).contains("403"), "403 is named")
  check(DICOMwebVerification.message(for: DICOMwebClient.failure(401, "raw", kind: .authentication)).contains("401"), "401 is named")
  check(DICOMwebVerification.message(for: DICOMwebClient.failure(1, "The address is wrong.", kind: .configuration)) == "The address is wrong.",
        "a configuration error keeps its own message")

  let done = DispatchSemaphore(value: 0)
  Thread.detachNewThread {
   defer { done.signal() }
   // Test against the loopback node, as Locations runs it.
   func verify(_ address: String, qido: String = "") -> NSError? {
    let node = make("Test", address, qr: true, send: false, qido: qido)
    do { try DICOMwebClient(node: try DICOMwebSources.configuration(for: node), timeout: 1).verify(); return nil }
    catch { return error as NSError }
   }
   check(verify(base + "/ok", qido: "qido") == nil, "Test passes at the QIDO path")
   let expected: [(String, DICOMwebErrorKind, String)] = [
    ("http://127.0.0.1:" + closedPort + "/ok", .network, "network"), (base + "/missing", .notFound, "404"),
    (base + "/auth", .authentication, "401"), (base + "/forbidden", .authentication, "403"), (base + "/slow", .timeout, "timeout"),
    (base + "/redirect", .redirect, "redirect"), (base + "/broken", .http, "500"), (base + "/html", .invalidResponse, "not QIDO"),
    (tlsBase + "/ok", .tls, "TLS"),
   ]
   var seen: [String] = []
   for (address, wanted, label) in expected {
    let error = verify(address)
    check(kind(error) == wanted, "Test \(label): kind \(kind(error).rawValue), wanted \(wanted.rawValue): \(error?.localizedDescription ?? "none")")
    let message = DICOMwebVerification.message(for: error)
    check(!message.contains("127.0.0.1"), "Test \(label): no address in the message")
    seen.append(message)
   }
   check(verify(base + "/forbidden").map { DICOMwebVerification.message(for: $0).contains("403") } == true, "Test names 403")
   check(Set(seen).count == seen.count, "each Test failure has its own message: \(seen)")

   guard stowBase != "-" else { return }
   func leftovers() -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: temporaryRoot.path)) ?? []).filter { $0.hasPrefix("horos-dicomweb-send-") }
   }
   func path(_ name: String) -> String { files.appendingPathComponent(name).path }
   var calls: [String] = []
   let transcoder: DICOMwebSender.Transcoder = { source, destination, syntax in
    let name = (source as NSString).lastPathComponent
    calls.append(name)
    check(syntax == "1.2.840.10008.1.2.4.70", "the transcoder is asked for the Send Syntax")
    check((destination as NSString).deletingLastPathComponent.hasPrefix(temporaryRoot.appendingPathComponent("horos-dicomweb-send-").path),
          "the converted file goes to the send's own folder")
    let converted = files.appendingPathComponent("converted").appendingPathComponent(name)
    guard FileManager.default.fileExists(atPath: converted.path) else {
     throw NSError(domain: "HorosDICOMTranscoding", code: 1, userInfo: [NSLocalizedDescriptionKey: "no codec"])
    }
    try FileManager.default.copyItem(at: converted, to: URL(fileURLWithPath: destination))
   }

   // As stored: the files as they are; the refused instance is reported per instance.
   let asStored = make("Store", stowBase, qr: false, send: true)
   let plain = DICOMwebSender(node: asStored, transcoder: transcoder)
   plain.temporaryRoot = temporaryRoot
   var fractions: [Double] = []
   plain.progress = { _, fraction in fractions.append(fraction) }
   do {
    let report = try plain.send(files: [path("plain-1.dcm"), path("plain-2.dcm"), path("refused.dcm")], cancelled: { false })
    check(report.sentCount == 2 && report.failedCount == 1 && !report.cancelled, "as stored: two stored, one refused: \(report.summary)")
    check(report.results.map(\.path) == [path("plain-1.dcm"), path("plain-2.dcm"), path("refused.dcm")], "one result per file, in order, with its own path")
    check(report.results[2].status == .failure && report.results[2].reasonCode == 0x0110 && report.results[2].reason.contains("0x0110"),
          "the refused instance has its Failure Reason: \(report.results[2].reason)")
    check(report.results[2].sopInstanceUID == "2.25.799.13", "the refused instance is named by its SOP Instance UID")
    check(report.detail(limit: 5).contains("2.25.799.13"), "the detail lists the refused instance")
    check(calls.isEmpty && leftovers().isEmpty, "as stored converts nothing and makes no folder")
    check(fractions.last == 1.0 && fractions == fractions.sorted(), "progress rises to 1: \(fractions)")
   } catch { check(false, "as stored: \(error)") }

   // Another Send Syntax: only the files in another syntax are converted.
   let converting = make("Convert", stowBase, qr: false, send: true, sendSyntax: "1.2.840.10008.1.2.4.70")
   let sender = DICOMwebSender(node: converting, transcoder: transcoder)
   sender.temporaryRoot = temporaryRoot
   calls = []
   do {
    let report = try sender.send(files: [path("plain-1.dcm"), path("lossless.dcm"), path("plain-3.dcm"), path("unconvertible.dcm")], cancelled: { false })
    check(calls == ["plain-1.dcm", "plain-3.dcm", "unconvertible.dcm"], "only the files in another syntax are converted: \(calls)")
    check(report.results.map(\.status) == [.success, .success, .success, .failure], "three stored, the unconvertible one not: \(report.detail(limit: 9))")
    check(report.results[3].reason.contains("could not be converted") && report.results[3].sopInstanceUID == "2.25.799.16",
          "the unconvertible file is reported: \(report.results[3].reason)")
    check(report.results.map(\.path) == [path("plain-1.dcm"), path("lossless.dcm"), path("plain-3.dcm"), path("unconvertible.dcm")],
          "results name the original files, not the converted copies")
    check(leftovers().isEmpty, "the converted files' folder is removed")
   } catch { check(false, "converting send: \(error)") }

   // Cancelled while converting: nothing more is sent, and what was not is said.
   calls = []
   var progressCalls = 0
   sender.progress = { _, _ in progressCalls += 1 }
   do {
    let report = try sender.send(files: [path("plain-1.dcm"), path("plain-2.dcm"), path("plain-3.dcm")], cancelled: { progressCalls >= 1 })
    check(report.cancelled && report.sentCount == 0 && report.failedCount == 3, "a cancelled send stores nothing more: \(report.summary)")
    check(report.results.allSatisfy { $0.reason.contains("cancelled") }, "each file not sent says the send was cancelled")
    check(leftovers().isEmpty, "a cancelled send removes its folder")
   } catch { check(false, "cancelled send: \(error)") }
   print("PASS: STOW-RS as stored and converted, per-instance results, cancellation, no folder left")
  }
  done.wait()
  if failed { exit(1) }
  print("PASS: sources, destinations, node clients and Test messages")
 }
}
'''


def sources_at(folder):
    names = ['Horos/Sources/DICOMwebIntegration.swift', 'Horos/Sources/DICOMwebNode.swift', 'Horos/Sources/DICOMwebClient.swift',
             'Horos/Sources/DICOMwebCredentials.swift', 'Horos/Sources/DICOMwebMultipart.swift',
             'Horos/Sources/DicomNodeConfiguration.swift']
    if revision:
        listed = subprocess.run(['git', 'ls-tree', '--name-only', revision, 'Horos/Sources/DICOM-Swift/'], cwd=root,
                                capture_output=True, text=True).stdout.split()
        names += [n for n in listed if n.endswith('.swift')]
    else:
        names += [str(p.relative_to(root)) for p in sorted((root / 'Horos/Sources/DICOM-Swift').glob('*.swift'))]
    paths = []
    for name in names:
        content = text(name)
        if content is None:
            check(False, f'{name} exists')
            continue
        target = folder / name.replace('/', '_')
        target.write_bytes(content.encode('latin1'))
        paths.append(str(target))
    return paths


def free_port():
    with socket.socket() as probe:
        probe.bind(('127.0.0.1', 0))
        return probe.getsockname()[1]


stow_skipped = False
node_server = ThreadingLocalHTTPServer(('127.0.0.1', 0), Node)
threading.Thread(target=node_server.serve_forever, daemon=True).start()
fixture = None
try:
    with tempfile.TemporaryDirectory(prefix='horos-dicomweb-integration-') as folder:
        temporary = Path(folder)
        (temporary / 'src').mkdir()
        sources = sources_at(temporary / 'src')
        (temporary / 'check.swift').write_text(DRIVER)
        executable = temporary / f'{UNIQUE}-check'
        if not failures:
            build = subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-suppress-warnings',
                                    '-module-cache-path', str(temporary / 'module-cache'), *sources,
                                    str(temporary / 'check.swift'), '-o', str(executable)], capture_output=True, text=True)
            check(build.returncode == 0, 'the DICOMweb sources and the check compile\n' + build.stderr[-3000:])

        # Files to send: Explicit VR Little Endian, one refused by the fixture,
        # one already in the Send Syntax, one the stand-in cannot convert.
        files = temporary / 'files'
        (files / 'converted').mkdir(parents=True)
        for name, uid, syntax, convertible in (('plain-1.dcm', '2.25.799.11', EXPLICIT, True),
                                               ('plain-2.dcm', '2.25.799.12', EXPLICIT, True),
                                               ('refused.dcm', '2.25.799.13', EXPLICIT, True),
                                               ('plain-3.dcm', '2.25.799.14', EXPLICIT, True),
                                               ('lossless.dcm', '2.25.799.15', JPEG_LOSSLESS, False),
                                               ('unconvertible.dcm', '2.25.799.16', EXPLICIT, False)):
            (files / name).write_bytes(part10(uid, syntax))
            if convertible:
                (files / 'converted' / name).write_bytes(part10(uid, JPEG_LOSSLESS))

        stow_base = '-'
        fixture_python = python_with.interpreter('import pydicom', 'import numpy')
        record = temporary / 'evidence' / 'dicomweb-fixture.json'
        if fixture_python is None:
            stow_skipped = True
        elif not failures:
            (temporary / 'refuse.txt').write_text('2.25.799.13\n')
            port = free_port()
            fixture = subprocess.Popen([fixture_python, '-u', str(root / 'tools/serve-dicomweb-fixture.py'), str(temporary / 'fixture'),
                                        str(temporary / 'evidence'), '--port', str(port), '--instances', '1',
                                        '--store', str(temporary / 'stored'), '--refuse-uids-file', str(temporary / 'refuse.txt')],
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            # The fixture prints one line once it listens; a minute is ample for pydicom to load.
            ready, _, _ = select.select([fixture.stdout], [], [], 60)
            line = fixture.stdout.readline() if ready else ''
            check(line.startswith('{'), 'the fixture started: ' + line + (fixture.stderr.read() if fixture.poll() is not None else ''))
            stow_base = f'http://127.0.0.1:{port}'

        closed = free_port()
        (temporary / 'send-temp').mkdir()
        (temporary / 'tmp').mkdir()
        if not failures:
            try:
                run = subprocess.run([str(executable), UNIQUE, f'http://127.0.0.1:{node_server.server_port}', str(closed), stow_base,
                                      str(files), str(temporary / 'send-temp')], capture_output=True, text=True, timeout=180,
                                     env=dict(os.environ, TMPDIR=f"{temporary / 'tmp'}/"))
                sys.stdout.write(run.stdout)
                check(run.returncode == 0, 'the object-level checks\n' + run.stderr[-2000:])
            finally:
                # cfprefsd writes a removed domain back as an empty file some seconds later.
                for _ in range(40):
                    time.sleep(0.25)
                    for leftover in (Path.home() / 'Library/Preferences').glob(UNIQUE + '*.plist'):
                        leftover.unlink(missing_ok=True)
            check(not any((temporary / 'tmp').iterdir()), 'the client left nothing in TMPDIR')

        if stow_base != '-' and not failures:
            posts = [r for r in json.loads(record.read_text())['requests'] if r.get('method') == 'POST']
            check(all(r['path'] == 'studies' for r in posts), 'STOW-RS posts to {address}/studies')
            sent = [i for r in posts for i in r['instances']]
            first = [i for i in sent if i['sop'] in ('2.25.799.11', '2.25.799.12', '2.25.799.13')][:3]
            check([i['transferSyntax'] for i in first] == [EXPLICIT] * 3, 'as stored sends the files unchanged')
            converted = [i for i in sent if i['transferSyntax'] == JPEG_LOSSLESS]
            check(sorted(i['sop'] for i in converted) == ['2.25.799.11', '2.25.799.14', '2.25.799.15'],
                  'the converting send sent the converted files and the one already in the syntax: '
                  + str(sorted(i['sop'] for i in converted)))
            check(all(i['partType'] == f'application/dicom; transfer-syntax={JPEG_LOSSLESS}' for i in converted),
                  'each converted part is typed with the Send Syntax')
            check('2.25.799.16' not in {i['sop'] for i in sent}, 'the unconvertible file was not sent')
            check([i['status'] for i in sent if i['sop'] == '2.25.799.13'] == ['refused'], 'the fixture refused the listed instance')
            stored = sorted(p.stem for p in (temporary / 'stored').glob('*.dcm'))
            check(stored == ['2.25.799.11', '2.25.799.12', '2.25.799.14', '2.25.799.15'], f'the node stored: {stored}')
finally:
    node_server.shutdown()
    node_server.server_close()
    if fixture is not None:
        fixture.terminate()
        try:
            fixture.wait(timeout=10)
        except subprocess.TimeoutExpired:
            fixture.kill()
        fixture.stdout.close()
        fixture.stderr.close()

# --- source level ------------------------------------------------------------
query = text('Horos/Sources/QueryController.mm') or ''
refresh = query[query.find('- (void) refreshSources'):query.find('- (NSArray*) prepareDICOMFieldsArrays')]
popup = refresh.find('Update Send To popup menu')
check('[serversArray addObjectsFromArray: [HorosDICOMwebSources queryRetrieveServers]]' in refresh[:popup],
      'the Query window appends the DICOMweb Q&R nodes to its sources')
check(refresh.find('[DCMNetServiceDelegate DICOMServersList]') < refresh.find('HorosDICOMwebSources queryRetrieveServers')
      and 'HorosDICOMwebSources' not in refresh[popup:] and '[DCMNetServiceDelegate DICOMServersList]' in refresh[popup:],
      'the DIMSE sources come first and the retrieve destinations stay DIMSE')
matcher = query[query.find('- (NSDictionary*) findCorrespondingServer'):query.find('- (void) refreshSources')]
check('HorosDICOMwebSources.nodeKey' in matcher and 'continue;' in matcher,
      'a saved DICOMweb source is matched by its identifier and never taken for a DIMSE one')
check('values.DICOMWEB_SERVERS' in query and 'forValuesKey:@"DICOMWEB_SERVERS"' in query, 'the Query window follows DICOMWEB_SERVERS')
check('[HorosDICOMwebSources isDICOMwebServer:serverParameters]' in query, 'Verify in the Query window reaches the node')
node = text('Horos/Sources/DCMTKQueryNode.mm') or ''
for pilot in ('DICOMwebURL', 'DICOMwebCredentialID', 'initWithEndpoint:', '== DICOMwebRetrieveMode'):
    check(pilot not in node, f'DCMTKQueryNode no longer uses the pilot\'s {pilot}')
check('== DICOMwebRetrieveMode' not in query, 'QueryController no longer compares the retrieve mode with the pilot\'s')
check(node.count('[HorosDICOMwebSources clientForServer:') == 3, 'query, retrieve and verify use the node\'s client')
move = node[node.find('- (void) move:(NSDictionary*) dict retrieveMode:'):]
check('BOOL dicomweb = [HorosDICOMwebSources isDICOMwebServer:_extraParameters];' in move and 'if (dicomweb)' in move,
      'a retrieve goes to DICOMweb only for a DICOMweb node')
listener = text('Horos/Sources/RetrieveListenerRequirement.swift') or ''
check(re.search(r'case wado, dicomweb:\s*return false', listener) is not None, 'a DICOMweb source needs no listener')
send = text('Horos/Sources/SendController.swift') or ''
check('DICOMwebSources.sendDestinations()' in send and send.count('SendController.destinations()') >= 5
      and send.count('dicomServersListSendOnly(true') == 1, 'the Send sheet lists DIMSE then DICOMweb destinations everywhere')
offis = send[send.find('public func sendDICOMFilesOffis'):send.find('// MARK: DICOMweb')]
check(offis.find('isDICOMwebServer') < offis.find('DirectTransferPolicy.route'), 'a DICOMweb destination is sent to before any DIMSE path')
check('DICOMwebSendActivity.send(files:' in send and 'thread: Thread.current' in send, 'the send runs on the activity thread')
activity = text('Horos/Sources/DICOMwebSendActivity.swift') or ''
check('DICOMwebSender(node: node)' in activity and 'HorosDICOMWriter.transcodeFile(atPath:' in activity
      and 'cancelled: { thread.isCancelled }' in activity and 'thread.progress = CGFloat(fraction)' in activity,
      'STOW-RS with DCMTK conversion, progress and the activity panel\'s Cancel')
check('addLogLine' in activity and 'report.detail(limit: 20)' in activity and 'runCritical' in activity,
      'per-instance results reach the log, the network log and an alert')
writer = text('Horos/Sources/HorosDICOMWriter.mm') or ''
transcode = writer[writer.find('+ (BOOL)transcodeFileAtPath:'):]
check('HorosChooseDICOMRepresentation(file, target' in transcode and 'file.saveFile(temporary.fileSystemRepresentation, target)' in transcode
      and 'rename(' in transcode, 'the conversion uses the host\'s DCMTK codecs and publishes a complete file')
check('transcodeFileAtPath:(NSString *)source toPath:' in (text('Horos/Sources/HorosDICOMWriter.h') or ''), 'the conversion is declared')
editor = text('Horos/Sources/DICOMwebNodeEditor.swift') or ''
check('DICOMwebSources.configuration(for: node)' in editor and 'DICOMwebClient(node: configuration' in editor
      and 'DICOMwebVerification.message(for: failure)' in editor and 'DICOMwebClient(endpoint:' not in editor,
      'Test uses the node\'s paths and maps the error kinds')
pbx = text('Horos.xcodeproj/project.pbxproj') or ''
check('DICOMwebIntegration.swift in Sources' in pbx and 'DICOMwebSendActivity.swift in Sources' in pbx,
      'the new files are in the Horos target')
integration = text('Horos/Sources/DICOMwebIntegration.swift') or ''
for name, content in (('DICOMwebIntegration.swift', integration), ('DICOMwebSendActivity.swift', activity)):
    check(content.startswith('//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)\n//\n//  This file is part of a fork of Horos'),
          f'{name} has the fork\'s header')
check(not re.search(r'NSLog\([^)]*(secret|password|token|credential)', send + integration + activity, re.I), 'no secret is logged')
if not revision:
    result = subprocess.run([sys.executable, str(root / 'tools/collect-localized-strings.py'), '--check'], capture_output=True, text=True)
    check(result.returncode == 0, 'every new string is in the Italian and Spanish catalogs\n' + result.stdout[-2000:])

if failures:
    print(f'FAIL: {len(failures)} check(s) failed')
    sys.exit(1)
if stow_skipped:
    print('skipped: the STOW-RS part needs a Python with pydicom and numpy for tools/serve-dicomweb-fixture.py; '
          'for example local-validation/fixture-venv', file=sys.stderr)
    sys.exit(2)
print('PASS: DICOMweb Q&R sources and Send destinations beside the DIMSE ones, node clients, Test messages, STOW-RS with conversion')
