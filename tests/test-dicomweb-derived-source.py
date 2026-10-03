#!/usr/bin/env python3
"""An object a server converted under a new UID counts for the instance it came from.

Orthanc gives an object it converts to a lossy syntax (JPEG Baseline) a new
SOP Instance UID, and names the original in Source Image Sequence
(0008,2112). The listing names only the original. Counted by UID, the
original stayed missing, was asked for again in Explicit VR Little Endian
after a cut response, and the database ended with both versions.
tools/serve-dicomweb-fixture.py --cut-syntax --derive-first stands for such a
server: its cut response in JPEG Baseline brings the first instance as such a
copy.

The client's and the inventory's sources, compiled with the DICOM-Swift
products the app links:

- the cut study retrieve hands over the copy, under its new UID;
- recorded with the UIDs its Source Image Sequence names, the copy counts
  for the listed original: once the listing is confirmed, the original is not
  among what is left to ask for, only the other instances are;
- those come in the fallback syntax; with the copy imported in place of the
  original, the inventory is complete, nothing missing, unexpected or
  duplicated, and the copy and three others are all that arrived;
- an object the listing does name stands for itself, even with a Source
  Image Sequence: its source is still asked for;
- received both ways, the original and its copy count as a duplicate;
- a later retrieve finds the copy's source through the persisted inventory.

The fixture's copy is read back with pydicom: a new UID, a Source Image
Sequence that names the first listed instance, Lossy Image Compression 01.

And in the sources: retrieveDICOMweb reads each object's Source Image
Sequence with its identifiers, takes an object for the instance it was asked
for when that sequence names it, records the sources with the object, and
counts the sources of local copies as local.

The fixture needs a Python with pydicom and numpy; without one this check is
skipped (exit 2).
"""
import json
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
  let (address, study, series, staging, taken, database, copy) = (args[1], args[2], args[3], args[4], args[5], args[6], args[7])
  let uids = Array(args[8...])
  let source = uids[0]
  let listing = uids.map { ["uid": $0, "series": series] }
  let named = try! DICOMwebClient(node: DICOMwebNodeConfiguration(address: address, qidoPath: "", wadoPath: "", credentialIdentifier: "",
                                                                  retrieveTransferSyntax: "1.2.840.10008.1.2.4.50", allowInsecureHTTP: false),
                                  timeout: 10)
  let done = DispatchSemaphore(value: 0)
  Thread.detachNewThread {
   defer { done.signal() }
   do {
    let inventory = RetrieveInventory.begin(study: study, series: "", endpoint: "fixture", database: database, instances: [], confirmed: false)
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
     check((error as NSError).userInfo["HorosDICOMwebObjectsHandedOver"] as? Int == 1, "the copy was handed over before the cut")
    }
    check(count == 1, "one object arrived before the cut: \(count)")
    // What retrieveDICOMweb records: the copy, with the UID its Source Image Sequence names.
    inventory.record(uid: copy, status: 0, sources: [source])
    inventory.confirm(instances: listing, confirmed: true, reported: uids.count, seriesReported: [:], discovery: "confirmed")
    let left = inventory.unreceivedSeries[series] ?? []
    check(Set(left) == Set(uids.dropFirst()), "the copy counts for its source, which is not asked for again: \(left)")
    for (n, uid) in left.enumerated() {
     let got = try named.retrieve(path: "studies/\(study)/series/\(series)/instances/\(uid)", stagingDirectory: staging + "/i\(n)",
                                  fallbackOnly: true, objectHandler: keep)
     check(got.intValue == 1, "the missing instance \(uid) arrives in the fallback syntax")
     inventory.record(uid: uid, status: 0, sources: [])
    }
    check(count == uids.count, "the copy and the other instances are all that arrived: \(count) of \(uids.count)")
    check(inventory.unreceivedSeries.isEmpty && inventory.nothingLeftToAsk, "nothing is left to ask for")
    check(inventory.receivedAwaitingImportCount == uids.count, "every received instance awaits import: \(inventory.receivedAwaitingImportCount)")
    inventory.updateImportedUIDs([copy] + uids.dropFirst())
    check(inventory.isComplete && inventory.missingUIDs.isEmpty && !inventory.needsAttention, "complete with the copy: \(inventory.summary)")
    check(inventory.importedCount == uids.count && inventory.receivedAwaitingImportCount == 0, "\(uids.count) of \(uids.count) imported")
    check(inventory.unexpectedUIDs.isEmpty && inventory.duplicateUIDs.isEmpty, "the copy is neither unexpected nor a duplicate")
    check(inventory.summary.hasPrefix("Complete: \(uids.count) of \(uids.count) unique instances imported"), inventory.summary)
    // A later retrieve of the same study finds the copy's source as local.
    inventory.finish()
    let again = RetrieveInventory.begin(study: study, series: "", endpoint: "fixture", database: database, instances: [], confirmed: false)
    check(again.sourceUIDs(ofDerived: [copy] + uids.dropFirst()) == [source], "the copy's source is local to a later retrieve")
    again.finish()
    let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: inventory.path))) as? [String: Any]
    check((saved?["derived"] as? [String: [String]])?[copy] == [source], "the inventory keeps what the copy came from")

    // Listed itself, an object with a Source Image Sequence stands for itself.
    let derivedListed = RetrieveInventory.begin(study: "9.1", series: "", endpoint: "fixture", database: database, instances: [], confirmed: false)
    derivedListed.record(uid: "9.1.2", status: 0, sources: ["9.1.1"])
    derivedListed.confirm(instances: [["uid": "9.1.1", "series": "9.2"], ["uid": "9.1.2", "series": "9.2"]], confirmed: true,
                          reported: 2, seriesReported: [:], discovery: "confirmed")
    check(derivedListed.unreceivedSeries["9.2"] == ["9.1.1"], "a listed derived object does not stand for its listed source")
    derivedListed.updateImportedUIDs(["9.1.2"])
    check(derivedListed.missingUIDs == ["9.1.1"], "its source stays missing: \(derivedListed.missingUIDs)")
    derivedListed.finish()

    // Both versions received: one instance, received twice.
    let both = RetrieveInventory.begin(study: "8.1", series: "", endpoint: "fixture", database: database, instances: [], confirmed: false)
    both.record(uid: "8.1.9", status: 0, sources: ["8.1.1"])
    both.record(uid: "8.1.1", status: 0, sources: [])
    both.confirm(instances: [["uid": "8.1.1", "series": "8.2"]], confirmed: true, reported: 1, seriesReported: [:], discovery: "confirmed")
    check(both.duplicateUIDs == ["8.1.1"], "the original and its copy are a duplicate: \(both.duplicateUIDs)")
    both.finish()
   } catch { check(false, "unexpected error \(error)") }
  }
  done.wait()
  if failed { exit(1) }
  print("PASS: a copy under a new UID counts for the listed instance its Source Image Sequence names")
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
    with tempfile.TemporaryDirectory(prefix='horos-dicomweb-derived-') as folder:
        temporary = Path(folder)
        sources = [str(root / 'Horos/Sources' / name) for name in
                   ('DICOMwebClient.swift', 'DICOMwebNode.swift', 'DICOMwebCredentials.swift', 'DICOMwebMultipart.swift',
                    'NonInteractiveKeychainRead.swift', 'RetrieveInventory.swift')]
        (temporary / 'check.swift').write_text(DRIVER)
        executable = temporary / 'check'
        build = subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-suppress-warnings',
                                '-module-cache-path', str(temporary / 'module-cache'), *sources,
                                *swift_flags(temporary), str(temporary / 'check.swift'), '-o', str(executable)],
                               capture_output=True, text=True, timeout=600)
        check(build.returncode == 0, 'the DICOMweb and inventory sources and the check compile\n' + build.stderr[-3000:])

        port = free_port()
        evidence = temporary / 'evidence'
        if not failures:
            process = subprocess.Popen([fixture_python, '-u', str(root / 'tools/serve-dicomweb-fixture.py'), str(temporary / 'fixture'),
                                        str(evidence), '--port', str(port), '--instances', '4', '--cut-syntax', BASELINE,
                                        '--derive-first'],
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            ready, _, _ = select.select([process.stdout], [], [], 60)
            line = process.stdout.readline() if ready else ''
            check(line.startswith('{'), 'the fixture started: ' + line)
        if not failures:
            started = json.loads(line)
            record = json.loads((evidence / 'dicomweb-fixture.json').read_text())
            uids = [item['sopInstanceUID'] for item in record['instances']]
            copy = record['derived']['sopInstanceUID']
            check(record['derived']['source'] == uids[0] and copy not in uids, f'the fixture names its copy: {record["derived"]}')
            for name in ('staging', 'taken', 'database'):
                (temporary / name).mkdir()
            run = subprocess.run([str(executable), f'http://127.0.0.1:{port}', started['studyInstanceUID'],
                                  started['seriesInstanceUID'], str(temporary / 'staging'), str(temporary / 'taken'),
                                  str(temporary / 'database'), copy, *uids],
                                 capture_output=True, text=True, timeout=180)
            sys.stdout.write(run.stdout)
            check(run.returncode == 0, 'the client and inventory checks\n' + run.stderr[-2000:])

            requests = json.loads((evidence / 'dicomweb-fixture.json').read_text())['requests']
            asked = [r['path'].rsplit('/', 1)[-1] for r in requests if '/instances/' in r.get('path', '')]
            check(sorted(asked) == sorted(uids[1:]), f'the source of the copy was not asked for: {asked}')
            got = subprocess.run([fixture_python, '-c', 'import sys, json, pydicom\nfor f in sys.argv[1:]:\n'
                                  ' d = pydicom.dcmread(f, stop_before_pixels=True)\n'
                                  ' s = [i.ReferencedSOPInstanceUID for i in d.get("SourceImageSequence", [])]\n'
                                  ' print(json.dumps([d.SOPInstanceUID, s, d.get("LossyImageCompression", "")]))',
                                  *sorted(str(f) for f in (temporary / 'taken').iterdir())], capture_output=True, text=True, timeout=60)
            arrived = [json.loads(line) for line in got.stdout.splitlines()]
            check(sorted(uid for uid, _, _ in arrived) == sorted([copy] + uids[1:]), f'the copy and three others arrived: {arrived}')
            check([s for uid, s, lossy in arrived if uid == copy and lossy == '01'] == [[uids[0]]],
                  f'the copy names its source in Source Image Sequence, lossy: {arrived}')
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
handler = retrieve[retrieve.index('NSString *(^queue)(NSString *)'):retrieve.index('NSError *requestError = nil;')]
check('findAndGetSequenceItem(DCM_SourceImageSequence' in handler and 'DCM_ReferencedSOPInstanceUID' in handler,
      'each object\'s Source Image Sequence is read with its identifiers')
check('[expectedUID isEqualToString:objectUID] || [sources containsObject:expectedUID]' in handler,
      'an instance asked for may come as a copy that names it')
check('recordUID:objectUID status:0 sources:sources]' in handler, 'the object is recorded with its sources')
local = retrieve[:retrieve.index('BOOL whole = localUIDs.count == 0;')]
check('sourceUIDsOfDerivedUIDs:localList' in local and local.index('beginStudy:') < local.index('sourceUIDsOfDerivedUIDs:'),
      'the sources of local copies count as local, read from the inventory this retrieve begins')

for failure in failures:
    print('FAIL:', failure)
if not failures:
    print('PASS: sources: a copy\'s Source Image Sequence is read, recorded and counted for its source')
sys.exit(1 if failures else 0)
