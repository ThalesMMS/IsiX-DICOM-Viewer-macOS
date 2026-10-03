#!/usr/bin/env python3
"""A converted copy that names nothing it came from counts for its one match.

Orthanc 1.13.0 converts some objects to a lossy syntax (JPEG Baseline)
through GDCM: the copy has a new SOP Instance UID and no Source Image
Sequence, Derivation Description or Lossy Image Compression, while its series,
SOP class and Instance Number stay the original's. The listing names only the
original. Counted by UID, the original stayed missing, was asked for again in
Explicit VR Little Endian after a cut response, and the database ended with
both versions. tools/serve-dicomweb-fixture.py --cut-syntax --derive-first
--derive-unreferenced stands for such a server: its cut response in JPEG
Baseline brings the first instance as such a copy.

The client's and the inventory's sources, compiled with the DICOM-Swift
products the app links:

- the listing gives each instance's SOP class and Instance Number;
- the cut study retrieve hands over the copy, under its new UID;
- recorded with its series, SOP class and Instance Number, the copy counts for
  the one listed instance that has the same three: once the listing is
  confirmed, that instance is not among what is left to ask for, only the
  other instances are;
- those come in the fallback syntax; with the copy imported in place of the
  original, the inventory is complete, nothing missing, unexpected or
  duplicated, and the copy and three others are all that arrived;
- a later retrieve finds the copy's match through the persisted inventory;
- with --repeat-first-number two listed instances have the copy's Instance
  Number: the tie matches nothing, every listed instance is asked for, and the
  copy stays unexpected;
- no Instance Number on the copy, another SOP class, or a match that already
  arrived under its own UID, matches nothing either; the listing may confirm
  before or after the copy arrives.

The fixture's copy is read back with pydicom: a new UID, the original's
Instance Number, no Source Image Sequence and no Lossy Image Compression.

And in the sources: retrieveDICOMweb asks the listing for the Instance Number,
gives it with each listed instance, and records an object with no Source Image
Sequence that arrived in a lossy syntax it asked for with its series, SOP class
and Instance Number.

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
BASELINE = '1.2.840.10008.1.2.4.50'
CT = '1.2.840.10008.5.1.4.1.1.2'


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

/// The first value of `tag` in a QIDO-RS record, a string or a number.
func value(_ record: [String: Any], _ tag: String) -> String {
 guard let first = ((record[tag] as? [String: Any])?["Value"] as? [Any])?.first else { return "" }
 return "\(first)"
}

@main struct Check {
 static func main() {
  if NonInteractiveKeychainRead.runHelperIfRequested() { exit(0) }
  let args = CommandLine.arguments
  let (mode, address, study, series, staging, taken, database, copy) = (args[1], args[2], args[3], args[4], args[5], args[6], args[7], args[8])
  let uids = Array(args[9...])
  let source = uids[0]
  let named = try! DICOMwebClient(node: DICOMwebNodeConfiguration(address: address, qidoPath: "", wadoPath: "", credentialIdentifier: "",
                                                                  retrieveTransferSyntax: "1.2.840.10008.1.2.4.50", allowInsecureHTTP: false),
                                  timeout: 10)
  let done = DispatchSemaphore(value: 0)
  Thread.detachNewThread {
   defer { done.signal() }
   do {
    // The listing as retrieveDICOMweb reads it: UID, series, SOP class and Instance Number.
    let records = try named.query(path: "studies/\(study)/series/\(series)/instances",
                                  parameters: ["includefield": "00080016,00200013"])
    let listing = records.map { ["uid": value($0, "00080018"), "series": value($0, "0020000E"),
                                 "sopClass": value($0, "00080016"), "number": value($0, "00200013")] }
    check(Set(listing.map { $0["uid"]! }) == Set(uids), "the listing names the four originals: \(listing)")
    check(listing.allSatisfy { !($0["number"] ?? "").isEmpty && !($0["sopClass"] ?? "").isEmpty },
          "the listing gives each instance's SOP class and Instance Number")
    let number = listing.first { $0["uid"] == source }?["number"] ?? ""
    let sopClass = listing.first { $0["uid"] == source }?["sopClass"] ?? ""

    let inventory = RetrieveInventory.begin(study: study, series: "", endpoint: "fixture-" + mode, database: database, instances: [], confirmed: false)
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
    // What retrieveDICOMweb records for an object with no Source Image Sequence in a lossy syntax it asked for.
    inventory.record(uid: copy, status: 0, series: series, sopClass: sopClass, instanceNumber: number)
    inventory.confirm(instances: listing, confirmed: true, reported: uids.count, seriesReported: [:], discovery: "confirmed")
    let left = inventory.unreceivedSeries[series] ?? []
    let tie = mode == "tie"
    if tie {
     check(Set(left) == Set(uids), "a tie matches nothing, every listed instance is asked for: \(left)")
    } else {
     check(Set(left) == Set(uids.dropFirst()), "the copy counts for its match, which is not asked for again: \(left)")
    }
    for (n, uid) in left.enumerated() {
     let got = try named.retrieve(path: "studies/\(study)/series/\(series)/instances/\(uid)", stagingDirectory: staging + "/i\(n)",
                                  fallbackOnly: true, objectHandler: keep)
     check(got.intValue == 1, "the missing instance \(uid) arrives in the fallback syntax")
     inventory.record(uid: uid, status: 0, sources: [])
    }
    check(inventory.unreceivedSeries.isEmpty && inventory.nothingLeftToAsk, "nothing is left to ask for")
    if tie {
     check(count == uids.count + 1, "the copy and every listed instance arrived: \(count)")
     inventory.updateImportedUIDs([copy] + uids)
     check(inventory.isComplete && inventory.missingUIDs.isEmpty, "complete with the originals: \(inventory.summary)")
     check(inventory.unexpectedUIDs == [copy] && inventory.duplicateUIDs.isEmpty, "the copy stays unexpected, not a duplicate")
     inventory.finish()
     return
    }
    check(count == uids.count, "the copy and the other instances are all that arrived: \(count) of \(uids.count)")
    check(inventory.receivedAwaitingImportCount == uids.count, "every received instance awaits import: \(inventory.receivedAwaitingImportCount)")
    inventory.updateImportedUIDs([copy] + uids.dropFirst())
    check(inventory.isComplete && inventory.missingUIDs.isEmpty && !inventory.needsAttention, "complete with the copy: \(inventory.summary)")
    check(inventory.importedCount == uids.count && inventory.receivedAwaitingImportCount == 0, "\(uids.count) of \(uids.count) imported")
    check(inventory.unexpectedUIDs.isEmpty && inventory.duplicateUIDs.isEmpty, "the copy is neither unexpected nor a duplicate")
    check(inventory.summary.hasPrefix("Complete: \(uids.count) of \(uids.count) unique instances imported"), inventory.summary)
    inventory.finish()
    let again = RetrieveInventory.begin(study: study, series: "", endpoint: "fixture-" + mode, database: database, instances: [], confirmed: false)
    check(again.sourceUIDs(ofDerived: [copy] + uids.dropFirst()) == [source], "the copy's match is local to a later retrieve")
    again.finish()

    // Listing confirmed before the copy arrives: matched as it is recorded.
    let early = RetrieveInventory.begin(study: "7.1", series: "", endpoint: "fixture", database: database,
                                        instances: [["uid": "7.1.1", "series": "7.2", "sopClass": CTClass, "number": "3"],
                                                    ["uid": "7.1.2", "series": "7.2", "sopClass": CTClass, "number": "4"]],
                                        confirmed: true)
    early.record(uid: "7.1.9", status: 0, series: "7.2", sopClass: CTClass, instanceNumber: " 3")
    check(early.unreceivedSeries["7.2"] == ["7.1.2"], "matched on arrival, by the number's value: \(early.unreceivedSeries)")
    early.finish()

    // No Instance Number, another class, another series, or a match already arrived: nothing matches.
    let listed = [["uid": "6.1.1", "series": "6.2", "sopClass": CTClass, "number": "1"],
                  ["uid": "6.1.2", "series": "6.2", "sopClass": CTClass, "number": "2"]]
    for (name, copySeries, copyClass, copyNumber, before) in [("no number", "6.2", CTClass, "", false),
                                                             ("another class", "6.2", "1.2.840.10008.5.1.4.1.1.4", "1", false),
                                                             ("another series", "6.3", CTClass, "1", false),
                                                             ("already arrived", "6.2", CTClass, "1", true)] {
     let inventory = RetrieveInventory.begin(study: "6.1", series: "", endpoint: "fixture-" + name, database: database, instances: [], confirmed: false)
     if before { inventory.record(uid: "6.1.1", status: 0, sources: []) }
     inventory.record(uid: "6.1.9", status: 0, series: copySeries, sopClass: copyClass, instanceNumber: copyNumber)
     inventory.confirm(instances: listed, confirmed: true, reported: 2, seriesReported: [:], discovery: "confirmed")
     check(inventory.unreceivedSeries["6.2"] == (before ? ["6.1.2"] : ["6.1.1", "6.1.2"]), "\(name): nothing matches: \(inventory.unreceivedSeries)")
     check(inventory.sourceUIDs(ofDerived: ["6.1.9"]).isEmpty, "\(name): the copy stands for itself")
     inventory.finish()
    }
   } catch { check(false, "unexpected error \(error)") }
  }
  done.wait()
  if failed { exit(1) }
  print("PASS: \(mode): a copy with no Source Image Sequence counts for its one listed match, and a tie for none")
 }
}
let CTClass = "1.2.840.10008.5.1.4.1.1.2"
'''


def free_port():
    with socket.socket() as probe:
        probe.bind(('127.0.0.1', 0))
        return probe.getsockname()[1]


def stop(process):
    process.terminate()
    try:
        process.wait(timeout=10)
    except subprocess.TimeoutExpired:
        process.kill()


fixture_python = python_with.interpreter('import pydicom', 'import numpy')
if fixture_python is None:
    print('skipped: needs a Python with pydicom and numpy for tools/serve-dicomweb-fixture.py', file=sys.stderr)
    raise SystemExit(2)

with tempfile.TemporaryDirectory(prefix='horos-dicomweb-unreferenced-') as folder:
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

    for mode, extra in (('match', []), ('tie', ['--repeat-first-number'])):
        if failures:
            break
        port = free_port()
        work = temporary / mode
        evidence = work / 'evidence'
        process = subprocess.Popen([fixture_python, '-u', str(root / 'tools/serve-dicomweb-fixture.py'), str(work / 'fixture'),
                                    str(evidence), '--port', str(port), '--instances', '4', '--cut-syntax', BASELINE,
                                    '--derive-first', '--derive-unreferenced', *extra],
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            ready, _, _ = select.select([process.stdout], [], [], 60)
            line = process.stdout.readline() if ready else ''
            check(line.startswith('{'), f'{mode}: the fixture started: ' + line)
            if failures:
                break
            started = json.loads(line)
            record = json.loads((evidence / 'dicomweb-fixture.json').read_text())
            uids = [item['sopInstanceUID'] for item in record['instances']]
            copy = record['derived']['sopInstanceUID']
            check(record['derived']['source'] == uids[0] and copy not in uids, f'{mode}: the fixture names its copy: {record["derived"]}')
            for name in ('staging', 'taken', 'database'):
                (work / name).mkdir()
            run = subprocess.run([str(executable), mode, f'http://127.0.0.1:{port}', started['studyInstanceUID'],
                                  started['seriesInstanceUID'], str(work / 'staging'), str(work / 'taken'),
                                  str(work / 'database'), copy, *uids],
                                 capture_output=True, text=True, timeout=180)
            sys.stdout.write(run.stdout)
            check(run.returncode == 0, f'{mode}: the client and inventory checks\n' + run.stderr[-2000:])

            requests = json.loads((evidence / 'dicomweb-fixture.json').read_text())['requests']
            asked = [r['path'].rsplit('/', 1)[-1] for r in requests if '/instances/' in r.get('path', '')]
            check(sorted(asked) == sorted(uids if mode == 'tie' else uids[1:]),
                  f'{mode}: the instances asked for one by one: {asked}')
            got = subprocess.run([fixture_python, '-c', 'import sys, json, pydicom\nfor f in sys.argv[1:]:\n'
                                  ' d = pydicom.dcmread(f, stop_before_pixels=True)\n'
                                  ' print(json.dumps([d.SOPInstanceUID, int(d.InstanceNumber), "SourceImageSequence" in d,'
                                  ' d.get("LossyImageCompression", "")]))',
                                  *sorted(str(f) for f in (work / 'taken').iterdir())], capture_output=True, text=True, timeout=60)
            arrived = {uid: rest for uid, *rest in (json.loads(line) for line in got.stdout.splitlines())}
            expected = [copy] + (uids if mode == 'tie' else uids[1:])
            check(sorted(arrived) == sorted(expected), f'{mode}: what arrived: {arrived}')
            check(arrived.get(copy) == [1, False, ''], f'{mode}: the copy has the first Instance Number and names nothing: {arrived.get(copy)}')
        finally:
            stop(process)

node = (root / 'Horos/Sources/DCMTKQueryNode.mm').read_text()
retrieve = node[node.index('- (BOOL)retrieveDICOMweb'):]
retrieve = retrieve[:retrieve.index('\n}\n')]
listing = retrieve[retrieve.index('NSThread *listing = '):retrieve.index('[listing start];')]
check('query.insertEmptyElement(DCM_InstanceNumber, OFTrue);' in listing, 'a series listing asks for the Instance Number')
images = node[node.index('- (BOOL) queryDICOMwebImagesOfSeries:'):node.index('- (BOOL) queryImagesHierarchicallyForStudy:')]
check('dataset.insertEmptyElement( DCM_InstanceNumber, OFTrue);' in images, 'a study listing asks each series for the Instance Number')
check('[instance setObject:image.name forKey:@"number"]' in retrieve, 'each listed instance is given with its Instance Number')
handler = retrieve[retrieve.index('NSString *(^queue)(NSString *)'):retrieve.index('NSError *requestError = nil;')]
check('!sources.count && wantedSyntax.length && DcmXfer(syntax.c_str()).isPixelDataLossyCompressed()' in handler,
      'only an object with no Source Image Sequence, in a lossy syntax asked for, is recorded for a match')
check('recordUID:objectUID status:0 series:' in handler and 'instanceNumber:' in handler,
      'such an object is recorded with its series, SOP class and Instance Number')

for failure in failures:
    print('FAIL:', failure)
if not failures:
    print('PASS: sources: the listing gives Instance Numbers, and a copy naming nothing is recorded for its match')
sys.exit(1 if failures else 0)
