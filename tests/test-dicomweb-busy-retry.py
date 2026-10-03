#!/usr/bin/env python3
"""A busy DICOMweb node is waited out, then asked again, in QIDO, WADO and STOW.

The client's sources, compiled with the DICOM-Swift products the app links,
against tools/serve-dicomweb-fixture.py answering busy (--throttle-first):

- one 429 with Retry-After: 1 to the first QIDO-RS, WADO-RS and STOW-RS
  request: the query, the retrieve (fixed mode) and the send each complete,
  after waiting the second, with the request asked again once;
- a STOW-RS node answering 503 to every request: the first batch is tried
  three times, then fails as busy, and the batches after it are reported as
  not sent, without being sent;
- a client whose repetition is off, as the automatic request limit sets it,
  sends a busy retrieve once and hands the Retry-After over with its error;
- cancelling while the client waits out a Retry-After of 30 s ends at once.

And in the sources: the retrieve turns the client's repetition off in the
automatic mode, and Test never repeats.

The fixture needs a Python with pydicom and numpy; without one this check is
skipped (exit 2).
"""
import json
import os
import select
import socket
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'tests'))
from dicomweb_package import swift_flags  # noqa: E402
import python_with  # noqa: E402

failures = []
EXPLICIT = '1.2.840.10008.1.2.1'


def check(ok, message):
    if not ok:
        failures.append(message)
        print('FAIL: ' + message)


def element(group, elem, vr, value):
    if len(value) % 2:
        value += b'\0' if vr == b'UI' else b' '
    if vr in (b'OB', b'OW', b'SQ', b'UN', b'UT'):
        return struct.pack('<HH', group, elem) + vr + b'\0\0' + struct.pack('<I', len(value)) + value
    return struct.pack('<HH', group, elem) + vr + struct.pack('<H', len(value)) + value


def part10(uid):
    sop_class = b'1.2.840.10008.5.1.4.1.1.7'
    meta = (element(2, 1, b'OB', b'\0\1') + element(2, 2, b'UI', sop_class)
            + element(2, 3, b'UI', uid.encode()) + element(2, 0x10, b'UI', EXPLICIT.encode()))
    data = (element(8, 0x16, b'UI', sop_class) + element(8, 0x18, b'UI', uid.encode())
            + element(0x10, 0x10, b'PN', b'SYNTHETIC^BUSY') + element(0x20, 0x0D, b'UI', b'2.25.1151.1')
            + element(0x20, 0x0E, b'UI', b'2.25.1151.2'))
    return b'\0' * 128 + b'DICM' + element(2, 0, b'UL', struct.pack('<I', len(meta))) + meta + data


DRIVER = r'''
import Foundation
import DicomWebClient
import DicomData

func check(_ ok: Bool, _ what: String) { if !ok { print("FAIL: \(what)"); failed = true } }
nonisolated(unsafe) var failed = false

@main struct Check {
 static func main() {
  if NonInteractiveKeychainRead.runHelperIfRequested() { exit(0) }
  let args = CommandLine.arguments
  let (once, onceStudy, persistent, persistentStudy, waiting, files, staging) = (args[1], args[2], args[3], args[4], args[5], args[6], args[7])
  func client(_ address: String) throws -> DICOMwebClient {
   DICOMwebClient(node: try DICOMwebNodeConfiguration(address: address, qidoPath: "", wadoPath: "", credentialIdentifier: "",
                                                      retrieveTransferSyntax: "", allowInsecureHTTP: false), timeout: 10)
  }
  let sendable = (1...3).map { files + "/busy-\($0).dcm" }
  let done = DispatchSemaphore(value: 0)
  Thread.detachNewThread {
   defer { done.signal() }
   do {
    // One busy answer to each service, Retry-After: 1.
    var started = Date()
    let records = try client(once).query(path: "studies", parameters: [:])
    check(records.count == 1 && (0.9..<4).contains(Date().timeIntervalSince(started)), "QIDO completes after the wait: \(records.count) in \(Date().timeIntervalSince(started)) s")
    started = Date()
    let retrieved = try client(once).retrieve(path: "studies/" + onceStudy, stagingDirectory: staging + "/once", cancelled: { false })
    check(retrieved.count == 3 && (0.9..<4).contains(Date().timeIntervalSince(started)), "the fixed-mode retrieve completes after the wait: \(retrieved.count) in \(Date().timeIntervalSince(started)) s")
    let sender = try client(once)
    sender.storeBatchMaximumCount = 2
    started = Date()
    let sent = try sender.store(files: sendable, cancelled: { false })
    check(sent.allSatisfy { $0.status == .success } && (0.9..<4).contains(Date().timeIntervalSince(started)),
          "STOW completes after the wait: \(sent.map { $0.reason }) in \(Date().timeIntervalSince(started)) s")

    // 503 to every request: the first batch is tried three times, the rest is not sent.
    let stopping = try client(persistent)
    stopping.storeBatchMaximumCount = 1
    let stopped = try stopping.store(files: sendable, cancelled: { false })
    check(stopped[0].status == .failure && stopped[0].httpStatus == 503 && stopped[0].reason.contains("busy"),
          "the first batch fails as busy: \(stopped[0].reason)")
    check(stopped.dropFirst().allSatisfy { $0.status == .failure && $0.reason.hasPrefix("Not sent.") && $0.reason.contains("busy") },
          "the batches after it are not sent: \(stopped.map { $0.reason })")

    // Repetition off, as in the automatic mode: one request, Retry-After handed over.
    let single = try client(persistent)
    single.repeatsBusyRequests = false
    do { _ = try single.retrieve(path: "studies/" + persistentStudy, stagingDirectory: staging + "/single", cancelled: { false }); check(false, "a busy retrieve succeeded") }
    catch {
     let e = error as NSError
     check(e.code == 503 && DICOMwebClient.errorKind(for: e) == .http && e.userInfo[DICOMwebClient.retryAfterKey] as? String == "0",
           "the single attempt reports the busy answer and its Retry-After: \(e.code) \(e.userInfo)")
    }

    // Cancelled while waiting out Retry-After: 30.
    let cancelAt = Date().addingTimeInterval(1)
    do { _ = try client(waiting).query(path: "studies", parameters: [:], cancelled: { Date() >= cancelAt }); check(false, "the wait was not cancelled") }
    catch {
     check((error as NSError).code == NSURLErrorCancelled && DICOMwebClient.errorKind(for: error as NSError) == .cancelled, "cancelled: \(error)")
     check(Date().timeIntervalSince(cancelAt) < 0.5, "the cancelled wait ends at once: \(Date().timeIntervalSince(cancelAt)) s")
    }
    check(!FileManager.default.fileExists(atPath: staging + "/single"), "no staging folder is left")
   } catch { check(false, "unexpected error \(error)") }
  }
  done.wait()
  if failed { exit(1) }
  print("PASS: QIDO, fixed-mode WADO and STOW wait out one busy answer; a busy STOW stops the batches after it; one attempt without repetition; cancelling ends the wait")
 }
}
'''


def free_port():
    with socket.socket() as probe:
        probe.bind(('127.0.0.1', 0))
        return probe.getsockname()[1]


fixture_python = python_with.interpreter('import pydicom', 'import numpy')
if fixture_python is None:
    print('skipped: needs a Python with pydicom and numpy for tools/serve-dicomweb-fixture.py', file=sys.stderr)
    raise SystemExit(2)

fixtures = []
try:
    with tempfile.TemporaryDirectory(prefix='horos-dicomweb-busy-') as folder:
        temporary = Path(folder)
        sources = [str(root / 'Horos/Sources' / name) for name in
                   ('DICOMwebClient.swift', 'DICOMwebNode.swift', 'DICOMwebCredentials.swift', 'DICOMwebMultipart.swift',
                    'NonInteractiveKeychainRead.swift')]
        (temporary / 'check.swift').write_text(DRIVER)
        executable = temporary / 'check'
        build = subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-suppress-warnings',
                                '-module-cache-path', str(temporary / 'module-cache'), *sources,
                                *swift_flags(temporary), str(temporary / 'check.swift'), '-o', str(executable)],
                               capture_output=True, text=True, timeout=600)
        check(build.returncode == 0, 'the DICOMweb sources and the check compile\n' + build.stderr[-3000:])

        studies = {}
        addresses = {}
        for name, options in (('once', ['--throttle-first', '1', '--throttle-status', '429', '--retry-after', '1']),
                              ('persistent', ['--throttle-first', '1000', '--throttle-status', '503', '--retry-after', '0']),
                              ('waiting', ['--throttle-first', '1000', '--throttle-status', '429', '--retry-after', '30'])):
            if failures:
                break
            port = free_port()
            process = subprocess.Popen([fixture_python, '-u', str(root / 'tools/serve-dicomweb-fixture.py'), str(temporary / name),
                                        str(temporary / (name + '-evidence')), '--port', str(port), '--instances', '3', *options],
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            fixtures.append(process)
            ready, _, _ = select.select([process.stdout], [], [], 60)
            line = process.stdout.readline() if ready else ''
            check(line.startswith('{'), f'the {name} fixture started: ' + line)
            if line.startswith('{'):
                studies[name] = json.loads(line)['studyInstanceUID']
                addresses[name] = f'http://127.0.0.1:{port}'

        files = temporary / 'files'
        files.mkdir()
        for n in range(1, 4):
            (files / f'busy-{n}.dcm').write_bytes(part10(f'2.25.1151.{n}'))
        (temporary / 'staging').mkdir()
        (temporary / 'tmp').mkdir()
        if not failures:
            run = subprocess.run([str(executable), addresses['once'], studies['once'], addresses['persistent'], studies['persistent'],
                                  addresses['waiting'],
                                  str(files), str(temporary / 'staging')], capture_output=True, text=True, timeout=180,
                                 env=dict(os.environ, TMPDIR=f"{temporary / 'tmp'}/"))
            sys.stdout.write(run.stdout)
            check(run.returncode == 0, 'the client checks\n' + run.stderr[-2000:])

            def requests(name):
                return json.loads((temporary / (name + '-evidence') / 'dicomweb-fixture.json').read_text())['requests']
            once = requests('once')
            throttled = sorted(r['service'] for r in once if r.get('path') == 'throttled')
            check(throttled == ['qido', 'stow', 'wado'], f'one busy answer to each service: {throttled}')
            posts = [r for r in once if r.get('method') == 'POST']
            check([len(r['instances']) for r in posts] == [2, 1], f'both STOW batches stored after the wait: {posts}')
            persistent = requests('persistent')
            busy_posts = [r for r in persistent if r.get('path') == 'throttled' and r['service'] == 'stow']
            check(len(busy_posts) == 3 and not [r for r in persistent if r.get('method') == 'POST'],
                  f'the first batch was tried three times and nothing after it was sent: {len(busy_posts)}')
            busy_wado = [r for r in persistent if r.get('path') == 'throttled' and r['service'] == 'wado']
            check(len(busy_wado) == 1, f'the retrieve without repetition was sent once: {len(busy_wado)}')
            check(not any((temporary / 'tmp').iterdir()), 'the client left nothing in TMPDIR')
finally:
    for process in fixtures:
        process.terminate()
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()

node = (root / 'Horos/Sources/DCMTKQueryNode.mm').read_text()
retrieve = node[node.index('- (BOOL)retrieveDICOMweb'):]
retrieve = retrieve[:retrieve.index('\n}\n')]
check(retrieve.index('client.repeatsBusyRequests = !adaptive;') > retrieve.index('BOOL adaptive = node.adaptiveRequests;'),
      'the automatic mode turns the client repetition off')
client = (root / 'Horos/Sources/DICOMwebClient.swift').read_text()
verify = client[client.index('func verify(cancelled: () -> Bool)'):]
check('repeats: false' in verify[:verify.index('\n    }\n')], 'Test never repeats')

for failure in failures:
    print('FAIL:', failure)
if not failures:
    print('PASS: sources: automatic mode without client repetition, Test without repetition')
sys.exit(1 if failures else 0)
