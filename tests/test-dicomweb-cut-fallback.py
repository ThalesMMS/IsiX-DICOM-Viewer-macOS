#!/usr/bin/env python3
"""A retrieve cut after its first part asks for the rest in Explicit VR Little Endian.

A server that converts each object while it streams a WADO-RS response, as
Orthanc does, answers 200 to a node's named syntax, sends the objects it can
convert and closes the connection at the first one it cannot. DICOM-Swift's
fallback to the next Accept range applies only before any part, so the rest
never comes in that syntax. tools/serve-dicomweb-fixture.py --cut-syntax
stands for such a server.

The client's sources, compiled with the DICOM-Swift products the app links:

- a node in JPEG Baseline has Explicit VR Little Endian as its fallback
  syntax; a node in that syntax, or one that asks for the objects as stored,
  has none;
- the study retrieve in JPEG Baseline is cut after its first part: it fails
  as a network or response error that says one object was handed over;
- each missing instance asked for with fallbackOnly goes out with an Accept
  that names Explicit VR Little Endian alone, and arrives; with the first
  part, every instance of the study is there once.

And in the sources: retrieveDICOMweb keeps such a cut (a network or response
error after at least one object) to be resumed, and once the listing has
named what the study holds, on a node with a fallback syntax, asks for every
listed instance that did not arrive with fallbackOnly.

The fixture needs a Python with pydicom and numpy; without one this check is
skipped (exit 2).
"""
import json
import os
import select
import socket
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
BASELINE = '1.2.840.10008.1.2.4.50'


def check(ok, message):
    if not ok:
        failures.append(message)
        print('FAIL: ' + message)


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
  let (address, study, series, staging, taken) = (args[1], args[2], args[3], args[4], args[5])
  let uids = Array(args[6...])
  func client(_ syntax: String) throws -> DICOMwebClient {
   DICOMwebClient(node: try DICOMwebNodeConfiguration(address: address, qidoPath: "", wadoPath: "", credentialIdentifier: "",
                                                      retrieveTransferSyntax: syntax, allowInsecureHTTP: false), timeout: 10)
  }
  let done = DispatchSemaphore(value: 0)
  Thread.detachNewThread {
   defer { done.signal() }
   do {
    let named = try client("1.2.840.10008.1.2.4.50")
    check(named.retrieveFallbackTransferSyntax == "1.2.840.10008.1.2.1", "JPEG Baseline falls back to Explicit VR LE")
    check(try client("1.2.840.10008.1.2.1").retrieveFallbackTransferSyntax == nil, "Explicit VR LE has no fallback")
    check(try client("*").retrieveFallbackTransferSyntax == nil, "as stored has no fallback")
    var count = 0
    let keep: (String) -> String? = { path in
     count += 1
     do { try FileManager.default.moveItem(atPath: path, toPath: taken + "/\(count).dcm"); return nil }
     catch { return "not taken" }
    }
    do {
     _ = try named.retrieve(path: "studies/" + study, stagingDirectory: staging + "/study", objectHandler: keep)
     check(false, "the cut study retrieve succeeded")
    } catch {
     let e = error as NSError
     let kind = DICOMwebClient.errorKind(for: e)
     check(kind == .network || kind == .invalidResponse, "the cut is a network or response error: \(kind.rawValue) \(e)")
     check(e.userInfo["HorosDICOMwebObjectsHandedOver"] as? Int == 1, "one object was handed over before the cut: \(e.userInfo)")
    }
    check(count == 1, "one object arrived before the cut: \(count)")
    for (n, uid) in uids.dropFirst().enumerated() {
     let got = try named.retrieve(path: "studies/\(study)/series/\(series)/instances/\(uid)", stagingDirectory: staging + "/i\(n)",
                                  fallbackOnly: true, objectHandler: keep)
     check(got.intValue == 1, "the missing instance \(uid) arrives in the fallback syntax: \(got)")
    }
    check(count == uids.count, "every instance arrived: \(count) of \(uids.count)")
   } catch { check(false, "unexpected error \(error)") }
  }
  done.wait()
  if failed { exit(1) }
  print("PASS: a retrieve cut after its first part keeps that part; the missing instances come in Explicit VR LE alone")
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

process = None
try:
    with tempfile.TemporaryDirectory(prefix='horos-dicomweb-cut-') as folder:
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

        port = free_port()
        evidence = temporary / 'evidence'
        if not failures:
            process = subprocess.Popen([fixture_python, '-u', str(root / 'tools/serve-dicomweb-fixture.py'), str(temporary / 'fixture'),
                                        str(evidence), '--port', str(port), '--instances', '4', '--cut-syntax', BASELINE],
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            ready, _, _ = select.select([process.stdout], [], [], 60)
            line = process.stdout.readline() if ready else ''
            check(line.startswith('{'), 'the fixture started: ' + line)
        if not failures:
            started = json.loads(line)
            uids = [item['sopInstanceUID'] for item in json.loads((evidence / 'dicomweb-fixture.json').read_text())['instances']]
            (temporary / 'staging').mkdir()
            taken = temporary / 'taken'
            taken.mkdir()
            run = subprocess.run([str(executable), f'http://127.0.0.1:{port}', started['studyInstanceUID'],
                                  started['seriesInstanceUID'], str(temporary / 'staging'), str(taken), *uids],
                                 capture_output=True, text=True, timeout=180)
            sys.stdout.write(run.stdout)
            check(run.returncode == 0, 'the client checks\n' + run.stderr[-2000:])

            requests = json.loads((evidence / 'dicomweb-fixture.json').read_text())['requests']
            cuts = [r for r in requests if r.get('path') == 'cut-syntax']
            check([(c['status'], c['partsSent'], c['of']) for c in cuts] == [(200, 1, 4)],
                  f'the study response was cut once, after its first part of four: {cuts}')
            asked = [r for r in requests if '/instances/' in r.get('path', '')]
            check(len(asked) == 3 and all(EXPLICIT in r['accept'] and BASELINE not in r['accept'] for r in asked),
                  f'three instance requests, each naming Explicit VR LE alone: {[r["accept"] for r in asked]}')
            check(not any((temporary / 'staging').iterdir()), 'no staging folder is left')
            got = subprocess.run([fixture_python, '-c', 'import sys, pydicom\nfor f in sys.argv[1:]:\n'
                                  ' d = pydicom.dcmread(f, stop_before_pixels=True); print(d.SOPInstanceUID, d.file_meta.TransferSyntaxUID)',
                                  *sorted(str(f) for f in taken.iterdir())], capture_output=True, text=True, timeout=60)
            arrived = [line.split() for line in got.stdout.splitlines()]
            check(sorted(uid for uid, _ in arrived) == sorted(uids) and all(syntax == EXPLICIT for _, syntax in arrived),
                  f'every instance arrived once, in Explicit VR LE: {arrived}')
finally:
    if process:
        process.terminate()
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()

node = (root / 'Horos/Sources/DCMTKQueryNode.mm').read_text()
retrieve = node[node.index('- (BOOL)retrieveDICOMweb'):]
retrieve = retrieve[:retrieve.index('\n}\n')]
listed = retrieve.index('[_retrieveInventory confirmInstances:')
turn = retrieve.find('fallbackOnly = YES;')
second = retrieve.find('NSDictionary *left = _retrieveInventory.unreceivedSeries;')
check(listed < turn < second, 'the fallback is decided once the listing has ended and before the second pass')
guard = retrieve[retrieve.rfind('if (cut', 0, turn):turn]
check('succeeded' in guard and 'client.retrieveFallbackTransferSyntax' in guard and 'HorosDICOMwebObjectsHandedOver' in guard
      and 'HorosDICOMwebErrorKindNetwork' in guard and 'HorosDICOMwebErrorKindInvalidResponse' in guard and '!failed()' in guard,
      'only a cut after some objects, with a listing and a fallback syntax, turns the pass for what is missing to that syntax')
check("cut = [[[interrupted.firstObject objectForKey:@\"error\"] retain] autorelease];" in retrieve,
      'a cut is a request kept to be resumed, not an error that stops the retrieve')
check('fallbackOnly || ![asked containsObject:uid]' in retrieve[second:], 'that pass asks again for what was asked before the cut')
check("[request setObject:@YES forKey:@\"fallback\"]" in retrieve and 'fallbackOnly:fallback objectHandler:queue' in retrieve,
      'its requests ask the client for the fallback syntax alone')
check(retrieve.count('fallbackOnly = YES;') == 1, 'the fallback pass runs once per retrieve')

for failure in failures:
    print('FAIL:', failure)
if not failures:
    print('PASS: sources: one fallback pass after a cut, for what the listing names and did not arrive')
sys.exit(1 if failures else 0)
