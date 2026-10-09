#!/usr/bin/env python3
"""A minimal DICOMweb node: no transfer-syntax=*, no series or instance listing.

Some PACS implement only the search for studies and the retrieve of a study
in named transfer syntaxes: they refuse `transfer-syntax=*` and answer 501 to
the QIDO-RS listing of a study's series or instances. tools/serve-dicomweb-
fixture.py stands for one with --refuse-syntax '*' --refuse-syntax-status 501
--listing-status 501.

The client's sources, compiled with the DICOM-Swift products the app links:

- a node that asks for the objects as stored sends transfer-syntax=*, then
  JPEG Lossless, then Explicit VR Little Endian, and has no cut fallback;
- against that node, the study retrieve is refused once for `*`, asked again
  from JPEG Lossless on, and brings every instance;
- the series listing fails with HTTP 501, which the client reads as a search
  the node does not implement; a timeout, a connection failure, an
  authentication failure or another server error is not one;
- a node in JPEG Baseline whose server answers 415 to it moves on to Explicit
  VR Little Endian;
- a 500 to `*` still ends the retrieve at once, as before.

And, without the fixture: the inventory of a retrieve whose listing the node
does not support is not reported incomplete, while a failed one still is; and
in the sources, the series and instance queries do not repeat as match
filters the UIDs their path names, the retrieve's series listing shows no
alert of its own, and retrieveDICOMweb records the listing as not supported
only after every request has ended without error and brought objects.

The fixture needs a Python with pydicom and numpy; without one, or without
the DICOM-Swift products, the fixture part is skipped (exit 2) once the rest
has passed.
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
import python_with  # noqa: E402

failures = []
EXPLICIT = '1.2.840.10008.1.2.1'
LOSSLESS = '1.2.840.10008.1.2.4.70'
BASELINE = '1.2.840.10008.1.2.4.50'
RANGE = 'multipart/related; type="application/dicom"; transfer-syntax='


def check(ok, message):
    if not ok:
        failures.append(message)
        print('FAIL: ' + message)


def block(text, start, end='\n}\n'):
    body = text[text.index(start):]
    return body[:body.index(end)]


# Sources: what the ObjC++ query node does, which no driver here can run.
node = (root / 'Horos/Sources/DCMTKQueryNode.mm').read_text()
query = block(node, '- (BOOL)queryDICOMwebWithDataset:(DcmDataset *)dataset')
check('BOOL studyInPath = [path hasPrefix:@"studies/"];' in query and 'BOOL seriesInPath = level == "IMAGE" && studyInPath;' in query,
      'the query knows which UIDs its path names')
skip = '(studyInPath && element->getTag() == DCM_StudyInstanceUID) || (seriesInPath && element->getTag() == DCM_SeriesInstanceUID)) continue;'
check(skip in query and query.index(skip) < query.index('[parameters setObject:text forKey:key];'),
      'a UID the path names is not sent as a match filter')
check('response.putAndInsertString(DCM_StudyInstanceUID, study.c_str());' in query
      and 'response.putAndInsertString(DCM_SeriesInstanceUID, series.c_str());' in query,
      'a result without the path\'s UIDs gets them from the path')
check('_lastQueryNotImplemented = [HorosDICOMwebClient errorMeansSearchNotImplemented:error];' in query,
      'a failed search records whether the node does not implement it')
walk = block(node, '- (BOOL) queryImagesHierarchicallyForStudy:(NSString*) studyInstanceUID')
check('[subQuery setShowErrorMessage: showErrorMessage];' in walk
      and walk.index('[subQuery setShowErrorMessage: showErrorMessage];') < walk.index('[subQuery queryWithValues: nil dataset: &seriesDataset];'),
      'the series listing alerts only when the walk\'s own node does')
check(walk.count('[self noteFailedListing:') == 5, 'every failure of the walk is sorted: %d' % walk.count('[self noteFailedListing:'))
parallel = block(node, '- (BOOL) queryDICOMwebImagesOfSeries:(NSArray*) seriesInstanceUIDs study:(NSString*) studyInstanceUID')
check('[self noteFailedListing: listingNotImplemented];' in parallel, 'the parallel instance listings sort their failures')
check('return !_imageInventoryConfirmed && _listingNotImplemented && !_listingFailedOtherwise;' in node,
      'a walk is "not implemented" only when no failure of it was of another kind')
retrieve = block(node, '- (BOOL)retrieveDICOMweb')
mark = retrieve.find('[_retrieveInventory markDiscovery:@"not supported"];')
guard = retrieve[retrieve.rfind('if (', 0, mark):mark]
check(mark > 0 and all(term in guard for term in ('!succeeded', 'notImplemented', '!failed()', '!thread.isCancelled',
                                                  'self.countOfSuccessfulSuboperations > 0')),
      'the listing is recorded as not supported only after a retrieve without error that brought objects: ' + guard)
second = retrieve.find('NSDictionary *left = _retrieveInventory.unreceivedSeries;')
check(0 < second < mark and retrieve.rfind('drain();', 0, mark) > second, 'that is decided once every request has ended')
check('notImplemented = !succeeded && collector.imageListingNotImplemented;' in retrieve
      and 'notImplemented = !succeeded && collector.lastQueryNotImplemented;' in retrieve,
      'the study and the series listing both say when the node does not implement them')

# The inventory: compiled on its own, as the app does.
INVENTORY = r'''
import Foundation
let directory = CommandLine.arguments[1]
let rows: [[String: String]] = []
var failed = false
func check(_ ok: Bool, _ what: String) { if !ok { print("FAIL: \(what)"); failed = true } }
for (study, state) in [("1.1", "not supported"), ("1.2", "failed")] {
 let m = RetrieveInventory.begin(study: study, series: "", endpoint: "DICOMweb node", database: directory, instances: rows, confirmed: false)
 m.markDiscovery("in progress")
 m.confirm(instances: [], confirmed: false, reported: 4, seriesReported: [:], discovery: "failed")
 m.record(uid: study + ".1", status: 0)
 m.markDiscovery(state)
 m.updateImportedUIDs([study + ".1"])
 check(!m.inventoryConfirmed && !m.isComplete, "\(state): the inventory stays unconfirmed")
 check(m.needsAttention == (state == "failed"), "\(state): reported incomplete only when the listing failed")
 let said = state == "failed" ? "The listing of the server's instances failed." : "The server does not implement the listing of its series or instances"
 check(m.summary.contains(said), "\(state): the summary says so: \(m.summary)")
 m.finish()
 let saved = try! JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: m.path))) as! [String: Any]
 check(saved["discovery"] as? String == state, "\(state): the manifest keeps it")
}
if failed { exit(1) }
print("PASS: a listing the node does not support is no incomplete retrieve; a failed one still is")
'''

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
  let (mode, address, study, staging, taken, expected) = (args[1], args[2], args[3], args[4], args[5], Int(args[6])!)
  func client(_ syntax: String) throws -> DICOMwebClient {
   DICOMwebClient(node: try DICOMwebNodeConfiguration(address: address, qidoPath: "", wadoPath: "", credentialIdentifier: "",
                                                      retrieveTransferSyntax: syntax, allowInsecureHTTP: false), timeout: 10)
  }
  var count = 0
  let keep: (URL) -> String? = { url in
   count += 1
   do { try FileManager.default.moveItem(atPath: url.path, toPath: taken + "/\(count).dcm"); return nil }
   catch { return "not taken" }
  }
  let done = DispatchSemaphore(value: 0)
  Thread.detachNewThread {
   defer { done.signal() }
   do {
    switch mode {
    case "minimal":
     let asStored = try client("")
     let range = "multipart/related; type=\"application/dicom\"; transfer-syntax="
     check(asStored.retrieveAcceptHeader == range + "*, " + range + "1.2.840.10008.1.2.4.70; q=0.9, " + range + "1.2.840.10008.1.2.1; q=0.8",
           "as stored asks for *, then JPEG Lossless, then Explicit VR LE: \(asStored.retrieveAcceptHeader)")
     check(asStored.retrieveFallbackTransferSyntax == nil, "as stored has no cut fallback")
     check(asStored.accepts(retrievedTransferSyntax: "1.2.840.10008.1.2.4.90"), "as stored takes any syntax")
     let got = try asStored.retrieve(path: "studies/" + study, stagingDirectory: staging + "/study", objectHandler: keep, cancelled: { false })
     check(got.handedOver == expected && count == expected, "every instance arrives once * is refused: \(got.handedOver) of \(expected)")
     do {
      _ = try asStored.query(path: "studies/\(study)/series", parameters: ["includefield": "0020000E"])
      check(false, "the series listing succeeded")
     } catch {
      let e = error as NSError
      check(e.code == 501 && DICOMwebClient.searchNotImplemented(e), "a 501 to the listing is a search the node does not implement: \(e)")
     }
     let http = { (status: Int, kind: DICOMwebErrorKind) in DICOMwebClient.failure(status, "HTTP \(status)", kind: kind) }
     for (status, kind) in [(400, DICOMwebErrorKind.http), (404, .notFound), (405, .http), (501, .http)] {
      check(DICOMwebClient.searchNotImplemented(http(status, kind)), "HTTP \(status) says the search is not implemented")
     }
     for (status, kind) in [(500, DICOMwebErrorKind.http), (502, .http), (503, .http), (429, .http), (401, .authentication),
                            (403, .authentication), (3, .network), (4, .invalidResponse), (6, .tls), (1, .configuration)] {
      check(!DICOMwebClient.searchNotImplemented(http(status, kind)), "\(status) \(kind.rawValue) is a failure, not a missing search")
     }
     check(!DICOMwebClient.searchNotImplemented(DICOMwebClient.timedOutError) && !DICOMwebClient.searchNotImplemented(nil)
           && !DICOMwebClient.searchNotImplemented(NSError(domain: NSURLErrorDomain, code: 501)), "a timeout, nothing or another domain is not one")
    case "named":
     let named = try client("1.2.840.10008.1.2.4.50")
     check((try? named.retrieveAccept().fallbackStatuses) == [400, 406, 415, 500, 501], "a named node moves on after 400, 406, 415, 500 and 501")
     let got = try named.retrieve(path: "studies/" + study, stagingDirectory: staging + "/study", objectHandler: keep, cancelled: { false })
     check(got.handedOver == expected, "a 415 to JPEG Baseline moves on to Explicit VR LE: \(got.handedOver) of \(expected)")
    default:
     do {
      _ = try client("").retrieve(path: "studies/" + study, stagingDirectory: staging + "/study", objectHandler: keep, cancelled: { false })
      check(false, "a 500 to * was taken for a refusal of the range")
     } catch { check((error as NSError).code == 500 && count == 0, "a 500 to * ends the retrieve: \(error)") }
    }
   } catch { check(false, "unexpected error \(error)") }
  }
  done.wait()
  if failed { exit(1) }
  print("PASS: \(mode)")
 }
}
'''


def free_port():
    with socket.socket() as probe:
        probe.bind(('127.0.0.1', 0))
        return probe.getsockname()[1]


with tempfile.TemporaryDirectory(prefix='horos-dicomweb-minimal-') as folder:
    temporary = Path(folder)
    (temporary / 'inventory').mkdir()
    (temporary / 'inventory/main.swift').write_text(INVENTORY)
    build = subprocess.run(['xcrun', 'swiftc', '-suppress-warnings', '-module-cache-path', str(temporary / 'module-cache'),
                            str(root / 'Horos/Sources/RetrieveInventory.swift'), str(temporary / 'inventory/main.swift'),
                            '-o', str(temporary / 'inventory/check')], capture_output=True, text=True, timeout=600)
    check(build.returncode == 0, 'the inventory compiles\n' + build.stderr[-3000:])
    if build.returncode == 0:
        (temporary / 'manifests').mkdir()
        run = subprocess.run([str(temporary / 'inventory/check'), str(temporary / 'manifests')],
                             capture_output=True, text=True, timeout=120)
        sys.stdout.write(run.stdout)
        check(run.returncode == 0, 'the inventory checks\n' + run.stderr[-2000:])

if failures:
    sys.exit(1)
print('PASS: sources: path UIDs are not match filters; the retrieve\'s listing is silent and "not supported" only after a clean retrieve')

fixture_python = python_with.interpreter('import pydicom', 'import numpy')
if fixture_python is None:
    print('skipped: needs a Python with pydicom and numpy for tools/serve-dicomweb-fixture.py', file=sys.stderr)
    raise SystemExit(2)
from dicomweb_package import swift_flags  # noqa: E402


def serve(temporary, name, *options):
    """Start the fixture with `options`; its port, start line and record."""
    port, evidence = free_port(), temporary / (name + '-evidence')
    process = subprocess.Popen([fixture_python, '-u', str(root / 'tools/serve-dicomweb-fixture.py'), str(temporary / (name + '-fixture')),
                                str(evidence), '--port', str(port), '--instances', '4', '--series', '2', *options],
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    ready, _, _ = select.select([process.stdout], [], [], 60)
    line = process.stdout.readline() if ready else ''
    check(line.startswith('{'), name + ': the fixture started: ' + line)
    return process, port, (json.loads(line) if line.startswith('{') else None), evidence / 'dicomweb-fixture.json'


processes = []
try:
    with tempfile.TemporaryDirectory(prefix='horos-dicomweb-minimal-') as folder:
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

        for mode, options in (('minimal', ('--refuse-syntax', '*', '--refuse-syntax-status', '501', '--listing-status', '501')),
                              ('named', ('--refuse-syntax', BASELINE, '--refuse-syntax-status', '415')),
                              ('server-error', ('--refuse-syntax', '*', '--refuse-syntax-status', '500'))):
            if failures:
                break
            process, port, started, record = serve(temporary, mode, *options)
            processes.append(process)
            if not started:
                break
            (temporary / (mode + '-staging')).mkdir()
            taken = temporary / (mode + '-taken')
            taken.mkdir()
            run = subprocess.run([str(executable), mode, f'http://127.0.0.1:{port}', started['studyInstanceUID'],
                                  str(temporary / (mode + '-staging')), str(taken), str(started['instances'])],
                                 capture_output=True, text=True, timeout=180)
            sys.stdout.write(run.stdout)
            check(run.returncode == 0, mode + ': the client checks\n' + run.stderr[-2000:])
            requests = json.loads(record.read_text())['requests']
            wado = [r for r in requests if r.get('path') == 'refused-syntax' or 'multipart/related' in r.get('accept', '')]
            if mode == 'minimal':
                accepts = [r['accept'] for r in wado if r.get('path') != 'refused-syntax']
                refused = [r for r in wado if r.get('path') == 'refused-syntax']
                check(len(accepts) == 2 and accepts[0].startswith(RANGE + '*,') and accepts[1] == RANGE + LOSSLESS + ', ' + RANGE + EXPLICIT + '; q=0.9',
                      f'the study is asked for with *, then from JPEG Lossless on: {accepts}')
                check([r['status'] for r in refused] == [501], f'* was refused once with 501: {refused}')
                listings = [r for r in requests if r.get('path', '').endswith('/series')]
                check(len(listings) == 1 and listings[0].get('status') == 501, f'the series listing was refused with 501: {listings}')
            elif mode == 'named':
                accepts = [r['accept'] for r in wado if r.get('path') != 'refused-syntax']
                refused = [r['status'] for r in wado if r.get('path') == 'refused-syntax']
                check(refused == [415] and accepts[-1:] == [RANGE + EXPLICIT], f'a 415 to JPEG Baseline, then Explicit VR LE: {refused} {accepts}')
            else:
                refused = [r['status'] for r in wado if r.get('path') == 'refused-syntax']
                check(refused == [500] and len(wado) == 2, f'one 500 to *, asked nothing more: {wado}')
            check(not any((temporary / (mode + '-staging')).iterdir()), mode + ': no staging folder is left')
finally:
    for process in processes:
        process.terminate()
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()

for failure in failures:
    print('FAIL:', failure)
if not failures:
    print('PASS: a node without * or listings: the study arrives through the named ranges, and 501 reads as no listing')
sys.exit(1 if failures else 0)
