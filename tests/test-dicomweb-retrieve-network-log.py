#!/usr/bin/env python3
"""DICOMweb retrieves, and what the listener receives, leave their network log line.

A user who retrieved only from DICOMweb nodes found the Network Logs empty: the
WADO-RS retrieve never wrote a line, and the listener's receive line had lost
its only caller when the vendored DCMTK went away.

DICOMweb: the client's sources, HorosDICOMwebRetrieveLog and the LogManager,
compiled with the DICOM-Swift products the app links, over an in-memory
LogEntry store. Each retrieve goes over HTTP to tools/serve-dicomweb-fixture.py
or to a loopback server that fails as asked, as -[DCMTKQueryNode move:] runs
it: the line is begun before the request and ended after it. Checked:

- a whole study: "Complete", received = total, no error;
- a response cut after its first part: "Incomplete", one received, three missing;
- HTTP 401, 404 and 500, and a refused connection, before any object:
  "Incomplete" with the kind of failure and nothing received;
- a retrieve the operator cancelled: "Cancelled";
- ten retrieves in a row: ten lines, each with its own patient;
- with the network logs off, or a browser on a database that is not local,
  no line and no failure;
- no line holds the node's address, a study UID or a credential.

And in the sources: move: begins the line for a DICOMweb node before
retrieveDICOMweb and ends it in its @finally, after the inventory is judged;
the DICOMweb area of Locations has the network logs switch, bound to the key
the Listener pane's uses, beside its box rather than in it, whose title row
hid it.

Listener: the C-STORE handler hands each stored object to the database
handle's log entry, the association that its peer did not release marks the
entry "Incomplete", and the entry's copies of the sender's values are bounded.
The handle's own code is compiled with the LogManager and the real DCMTK data
dictionary: three objects make one "Complete" line with three received; an
aborted association makes it "Incomplete"; a patient name and descriptions
far longer than the buffers are cut, not overflowed.

Needs a Python with pydicom and numpy for the fixture, the prepared DICOM-Swift
products and a DCMTK build; without them this check is skipped (exit 2).
"""
import ast
import http.server
import json
import re
import select
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tests'))
from dicomweb_package import swift_flags  # noqa: E402
from dcmtk_build import dcmtk_flags  # noqa: E402
import python_with  # noqa: E402

failures = []


def check(ok, message):
    if not ok:
        failures.append(message)
        print('FAIL: ' + message)


# --- sources ------------------------------------------------------------------

node = (ROOT / 'Horos/Sources/DCMTKQueryNode.mm').read_bytes().decode('latin1')
move = node[node.index('- (void) move:(NSDictionary*) dict retrieveMode: (int) retrieveMode'):]
move = move[:move.index('\n- (OFCondition) addPresentationContext')]
begin = move.find('[[HorosDICOMwebRetrieveLog alloc] initWithNode:')
call = move.find('reportedDICOMwebFailure = ![self retrieveDICOMweb];')
final = move.find('@finally')
judged = move.find('[_retrieveInventory finish];')
finish = move.find('[dicomwebLog finishWithReceived:')
check(-1 < begin < call < final < judged < finish,
      'move: begins the DICOMweb log line before retrieveDICOMweb and ends it in @finally, after the inventory is judged')
check('[HorosDICOMwebClient logReasonForError:_reportedDICOMwebError]' in move,
      'the line says why the retrieve failed, from the error retrieveDICOMweb reported')
check('_reportedDICOMwebError = [error retain];' in node[node.index('- (BOOL)reportDICOMwebError:'):],
      'reportDICOMwebError: keeps the error for the log line')

server = (ROOT / 'Horos/Sources/HorosQueryRetrieveServer.mm').read_bytes().decode('latin1')
store = server[server.index('OFCondition HorosStoreSCP('):]
check(re.search(r'context\.getStatus\(\) == STATUS_Success\)\s*\{[^}]*updateLogEntry\(dataset\)', store, re.S) is not None,
      'a stored object is handed to the handle\'s log entry, once stored')
association = server[server.index('void handleAssociation() override'):]
association = association[:association.index('database_.reset();')]
check(re.search(r'if \(result != DUL_PEERREQUESTEDRELEASE\)\s*if \(auto\* handle = dynamic_cast<DcmQueryRetrieveOsiriXDatabaseHandle\*>\(database_\.get\(\)\)\)\s*handle->markLogIncomplete\(\);',
                association) is not None and association.index('markLogIncomplete') < association.index('result = ASC_acknowledgeRelease'),
      'an association its peer did not release marks the entry incomplete, before the release is acknowledged')

editor = (ROOT / 'Horos/Sources/DICOMwebNodeEditor.swift').read_text()
switch = editor[editor.index('private func addNetworkLogsSwitch'):]
switch = switch[:switch.index('\n    }\n')]
check('logs.bind(.value, to: NSUserDefaultsController.shared, withKeyPath: "values.NETWORKLOGS", options: nil)' in switch
      and 'container.addSubview(logs, positioned: .above, relativeTo: box)' in switch and 'box.addSubview' not in switch,
      'the DICOMweb area has the Listener pane\'s network logs switch, beside its box, where the box\'s title row does not cover it')

# --- doubles ------------------------------------------------------------------

values = {}
for item in ast.parse((ROOT / 'tests/test-activity-progress-window.py').read_text()).body:
    if isinstance(item, ast.Assign) and isinstance(item.value, ast.Constant) and isinstance(item.value.value, str):
        for target in item.targets:
            if isinstance(target, ast.Name):
                values[target.id] = item.value.value
    elif isinstance(item, ast.Assign) and any(isinstance(t, ast.Name) and t.id == 'LOG_HEADER' for t in item.targets):
        values['LOG_HEADER'] = values['EXCEPTION_HEADER'] + ast.literal_eval(item.value.right)

HEADER = values['LOG_HEADER'] + r'''
extern BOOL HorosTestNetworkLogsActive, HorosTestDatabaseIsLocal;
@interface NSUserDefaults (HorosTest)
+ (NSString *)defaultAETitle;
@end
'''
doubles = values['LOG_DOUBLES']
for old, new in (('- (BOOL)isNetworkLogsActive { return YES; }', '- (BOOL)isNetworkLogsActive { return HorosTestNetworkLogsActive; }'),
                 ('- (BOOL)isLocal { return YES; }', '- (BOOL)isLocal { return HorosTestDatabaseIsLocal; }')):
    if old not in doubles:
        print('FAIL: the log doubles of test-activity-progress-window.py changed: ' + old)
        raise SystemExit(1)
    doubles = doubles.replace(old, new)
DOUBLES = doubles + r'''
BOOL HorosTestNetworkLogsActive = YES, HorosTestDatabaseIsLocal = YES;
@implementation NSUserDefaults (HorosTest)
+ (NSString *)defaultAETitle { return @"ISIX TEST"; }
@end
'''

# --- DICOMweb driver ----------------------------------------------------------

DRIVER = r'''
import Foundation
import CoreData

@main struct Driver {
    static func main() throws {
        let args = CommandLine.arguments
        let (fixture, cut, failing, refused, study, cutStudy, staging) = (args[1], args[2], args[3], args[4], args[5], args[6], args[7])
        func client(_ address: String, _ syntax: String) throws -> DICOMwebClient {
            DICOMwebClient(node: try DICOMwebNodeConfiguration(address: address, qidoPath: "", wadoPath: "", credentialIdentifier: "",
                                                               retrieveTransferSyntax: syntax, allowInsecureHTTP: false), timeout: 10)
        }
        // A retrieve as move: runs it: the line begins, the request runs on a
        // thread of its own, and the line ends with what arrived and why not.
        var run = 0
        func retrieve(_ node: String, _ address: String, _ syntax: String, _ path: String, expected: Int,
                      patient: String, cancelled: Bool = false) {
            run += 1
            let log = DICOMwebRetrieveLog(node: node, patientName: patient, studyDescription: "CT CHEST " + node)
            var received = 0
            var failure: NSError?
            if !cancelled {
                let done = DispatchSemaphore(value: 0)
                Thread.detachNewThread {
                    defer { done.signal() }
                    do {
                        _ = try client(address, syntax).retrieve(path: path, stagingDirectory: staging + "/\(run)") { file in
                            received += 1
                            try? FileManager.default.removeItem(atPath: file)
                            return nil
                        }
                    } catch { failure = error as NSError }
                }
                done.wait()
            }
            let missing = failure == nil ? 0 : max(expected - received, 0)
            log.finish(received: received, expected: failure == nil && !cancelled ? received : expected, missing: missing,
                       cancelled: cancelled, reason: DICOMwebClient.logReason(for: failure))
        }
        retrieve("Complete node", fixture, "*", "studies/" + study, expected: 4, patient: "WHOLE^STUDY")
        retrieve("Cut node", cut, "1.2.840.10008.1.2.4.50", "studies/" + cutStudy, expected: 4, patient: "CUT^STUDY")
        retrieve("401 node", failing, "*", "studies/401", expected: 4, patient: "AUTH^STUDY")
        retrieve("404 node", fixture, "*", "studies/1.2.3.404", expected: 4, patient: "ABSENT^STUDY")
        retrieve("500 node", failing, "*", "studies/500", expected: 4, patient: "ERROR^STUDY")
        retrieve("Refused node", refused, "*", "studies/" + study, expected: 4, patient: "REFUSED^STUDY")
        retrieve("Cancelled node", fixture, "*", "studies/" + study, expected: 4, patient: "CANCELLED^STUDY", cancelled: true)
        for n in 0..<10 { retrieve("Batch node", fixture, "*", "studies/" + study, expected: 4, patient: "BATCH^\(n)") }
        HorosTestNetworkLogsActive = false
        retrieve("Logs off node", fixture, "*", "studies/" + study, expected: 4, patient: "OFF^STUDY")
        HorosTestNetworkLogsActive = true
        HorosTestDatabaseIsLocal = false
        retrieve("Remote database node", fixture, "*", "studies/" + study, expected: 4, patient: "REMOTE^STUDY")
        HorosTestDatabaseIsLocal = true

        let db = BrowserController.currentBrowser()!.database!
        let entries = db.objects(forEntity: db.logEntryEntity(), predicate: NSPredicate(value: true)) as! [NSManagedObject]
        let rows = entries.map { entry -> [String: Any] in
            var row: [String: Any] = [:]
            for key in ["message", "type", "originName", "destinationName", "patientName", "studyName"] {
                row[key] = entry.value(forKey: key) as? String ?? ""
            }
            for key in ["numberImages", "numberSent", "numberError"] { row[key] = entry.value(forKey: key) as? Int ?? -1 }
            row["ended"] = entry.value(forKey: "endTime") != nil
            return row
        }
        print(String(data: try JSONSerialization.data(withJSONObject: rows), encoding: .utf8)!)
    }
}
'''


class Failing(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        status = 401 if '/studies/401' in self.path else 500
        body = b'{"secret":"must-not-appear"}'
        self.send_response(status)
        if status == 401:
            self.send_header('WWW-Authenticate', 'Basic realm="must-not-appear"')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def free_port():
    with socket.socket() as probe:
        probe.bind(('127.0.0.1', 0))
        return probe.getsockname()[1]


def start_fixture(python, folder, port, *extra):
    process = subprocess.Popen([python, '-u', str(ROOT / 'tools/serve-dicomweb-fixture.py'), str(folder / 'fixture'),
                                str(folder / 'evidence'), '--port', str(port), '--instances', '4', *extra],
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    ready, _, _ = select.select([process.stdout], [], [], 60)
    line = process.stdout.readline() if ready else ''
    if not line.startswith('{'):
        process.kill()
        raise RuntimeError('the fixture did not start: ' + line + process.stderr.read()[-1000:])
    return process, json.loads(line)


def compile_swift(work, executable, sources, extra):
    build = subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library', '-suppress-warnings',
                            '-module-name', 'Horos', '-module-cache-path', str(work / 'module-cache'),
                            '-import-objc-header', str(work / 'harness.h'), *sources, *extra,
                            '-framework', 'Cocoa', '-framework', 'CoreData', '-o', str(executable)],
                           capture_output=True, text=True, timeout=900)
    check(build.returncode == 0, 'the sources and the driver compile\n' + build.stderr[-4000:])
    return build.returncode == 0


def objc_objects(work):
    for name in ('HorosObjCException.h', 'HorosObjCException.m'):
        shutil.copy(ROOT / 'Horos/Sources' / name, work / name)
    (work / 'harness.h').write_text(HEADER)
    (work / 'doubles.m').write_text(DOUBLES)
    objects = []
    for name, flags in (('HorosObjCException', []), ('doubles', ['-fobjc-arc'])):
        result = subprocess.run(['xcrun', 'clang', '-x', 'objective-c', '-fobjc-exceptions', *flags, '-c',
                                 str(work / (name + '.m')), '-o', str(work / (name + '.o'))], capture_output=True, text=True)
        check(result.returncode == 0, name + ' compiles\n' + result.stderr[-2000:])
        objects.append(str(work / (name + '.o')))
    return objects


def dicomweb(work):
    python = python_with.interpreter('import pydicom', 'import numpy')
    if python is None:
        print('skipped: needs a Python with pydicom and numpy for tools/serve-dicomweb-fixture.py', file=sys.stderr)
        raise SystemExit(2)
    product_flags = swift_flags(work)
    objects = objc_objects(work)
    (work / 'driver.swift').write_text(DRIVER)
    sources = [str(ROOT / 'Horos/Sources' / name) for name in
               ('DICOMwebClient.swift', 'DICOMwebNode.swift', 'DICOMwebCredentials.swift', 'DICOMwebMultipart.swift',
                'NonInteractiveKeychainRead.swift', 'LogManager.swift', 'DICOMwebRetrieveLog.swift')]
    executable = work / 'dicomweb'
    if failures or not compile_swift(work, executable, sources + [str(work / 'driver.swift'), *objects], product_flags):
        return
    processes = []
    failing = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Failing)
    threading.Thread(target=failing.serve_forever, daemon=True).start()
    try:
        (work / 'whole').mkdir()
        (work / 'cut').mkdir()
        whole_port, cut_port, refused_port = free_port(), free_port(), free_port()
        whole, started = start_fixture(python, work / 'whole', whole_port)
        processes.append(whole)
        # Each fixture generates its own study: the cut one is asked for its own.
        cut, cut_started = start_fixture(python, work / 'cut', cut_port, '--cut-syntax', '1.2.840.10008.1.2.4.50')
        processes.append(cut)
        study, cut_study = started['studyInstanceUID'], cut_started['studyInstanceUID']
        (work / 'staging').mkdir()
        result = subprocess.run([str(executable), f'http://127.0.0.1:{whole_port}', f'http://127.0.0.1:{cut_port}',
                                 f'http://127.0.0.1:{failing.server_port}', f'http://127.0.0.1:{refused_port}',
                                 study, cut_study, str(work / 'staging')],
                                capture_output=True, text=True, timeout=300)
        check(result.returncode == 0, 'the driver runs\n' + result.stderr[-3000:])
        if result.returncode:
            return
        rows = json.loads(result.stdout.splitlines()[-1])
    finally:
        failing.shutdown()
        failing.server_close()
        for process in processes:
            process.kill()
            process.wait()
    by_patient = {}
    for row in rows:
        by_patient.setdefault(row['patientName'], []).append(row)
    print(f'{len(rows)} DICOMweb log lines')

    def line(patient):
        found = by_patient.get(patient, [])
        check(len(found) == 1, f'{patient}: one line, not {len(found)}')
        return found[0] if found else None

    def expect(patient, state, received, total, errors, *details):
        row = line(patient)
        if not row:
            return
        got = (row['message'].split(' — ')[0], row['numberSent'], row['numberImages'], row['numberError'], row['ended'])
        check(got == (state, received, total, errors, True), f'{patient}: {got} != {(state, received, total, errors, True)}: {row}')
        check(row['type'] == 'Receive', f'{patient}: type {row["type"]}')
        check(row['destinationName'] == 'ISIX TEST', f'{patient}: destination {row["destinationName"]}')
        check(row['studyName'].startswith('CT CHEST '), f'{patient}: study {row["studyName"]}')
        for detail in details:
            check(detail in row['message'], f'{patient}: "{detail}" in {row["message"]}')
        print(f'PASS: {patient}: {row["message"]}')

    expect('WHOLE^STUDY', 'Complete', 4, 4, 0, 'DICOMweb; received=4/4; missing=0')
    expect('CUT^STUDY', 'Incomplete', 1, 4, 3, 'received=1/4', 'missing=3', 'after 1 objects')
    expect('AUTH^STUDY', 'Incomplete', 0, 4, 4, 'HTTP 401')
    expect('ABSENT^STUDY', 'Incomplete', 0, 4, 4, 'HTTP 404')
    expect('ERROR^STUDY', 'Incomplete', 0, 4, 4, 'HTTP 500')
    expect('REFUSED^STUDY', 'Incomplete', 0, 4, 4, 'Network')
    expect('CANCELLED^STUDY', 'Cancelled', 0, 4, 0)
    for n in range(10):
        expect(f'BATCH^{n}', 'Complete', 4, 4, 0)
    check('OFF^STUDY' not in by_patient, 'no line while the network logs are off')
    check('REMOTE^STUDY' not in by_patient, 'no line while the browser shows a database that is not local')
    check(len(rows) == 17, f'17 lines: {len(rows)}')
    text = json.dumps(rows)
    for secret in ('127.0.0.1', study, cut_study, 'must-not-appear', 'realm', 'studies/'):
        check(secret not in text, f'no line holds {secret!r}')


# --- listener -----------------------------------------------------------------

HANDLE_DRIVER = r'''
import Foundation
import CoreData

@main struct Driver {
    static func main() throws {
        HorosTestStoreObjects(3, false, "SMALL^STORE", 0)
        HorosTestStoreObjects(2, true, "ABORTED^STORE", 0)
        HorosTestStoreObjects(1, false, "LONG", 5000)
        HorosTestNetworkLogsActive = false
        HorosTestStoreObjects(2, false, "OFF^STORE", 0)
        HorosTestNetworkLogsActive = true
        let db = BrowserController.currentBrowser()!.database!
        let entries = db.objects(forEntity: db.logEntryEntity(), predicate: NSPredicate(value: true)) as! [NSManagedObject]
        let rows = entries.map { entry -> [String: Any] in
            ["message": entry.value(forKey: "message") as? String ?? "", "type": entry.value(forKey: "type") as? String ?? "",
             "origin": entry.value(forKey: "originName") as? String ?? "", "patient": entry.value(forKey: "patientName") as? String ?? "",
             "study": entry.value(forKey: "studyName") as? String ?? "",
             "received": entry.value(forKey: "numberSent") as? Int ?? -1, "total": entry.value(forKey: "numberImages") as? Int ?? -1]
        }
        print(String(data: try JSONSerialization.data(withJSONObject: rows), encoding: .utf8)!)
    }
}
'''


def between(text, start, end):
    a = text.index(start)
    return text[a:text.index(end, a) + len(end)]


def listener(work):
    flags = dcmtk_flags('dcmqrdb', 'dcmnet')
    handle = (ROOT / 'Horos/Sources/dcmqrdbq.mm').read_bytes().decode('latin1')
    update = between(handle, 'OFCondition DcmQueryRetrieveOsiriXDatabaseHandle::updateLogEntry(DcmDataset *dataset)', '\n}\n')
    mark = between(handle, 'void DcmQueryRetrieveOsiriXDatabaseHandle::markLogIncomplete()', '\n}\n')
    ending = between(handle, '\t   if ( handle->logDictionary)', '\t\t}\n')
    creating = between(handle, '        handle -> callingAET = [[NSString alloc]', ';\n')
    code = r'''
#include <dcmtk/config/osconfig.h>
#include <dcmtk/dcmdata/dctk.h>
#include "HorosDCMTKCompatibility.h"
#import "harness.h"
#include <string>
@interface LogManager : NSObject
+ (id)currentLogManager;
- (void)addLogLine:(NSDictionary *)line;
@end
@interface DicomFile : NSObject
+ (NSString *)stringWithBytes:(char *)bytes encodings:(NSStringEncoding *)encodings;
@end
@implementation DicomFile
+ (NSString *)stringWithBytes:(char *)bytes encodings:(NSStringEncoding *)encodings
{ return [[[NSString alloc] initWithBytes:bytes length:strlen(bytes) encoding:encodings[0] ?: NSISOLatin1StringEncoding] autorelease]; }
@end
@interface NSString (HorosTest)
+ (NSStringEncoding)encodingForDICOMCharacterSet:(NSString *)name;
@end
@implementation NSString (HorosTest)
+ (NSStringEncoding)encodingForDICOMCharacterSet:(NSString *)name { return NSISOLatin1StringEncoding; }
@end
struct DB_OsiriX_Handle { NSString *callingAET; int imageCount; BOOL logCreated; BOOL logIncomplete; NSMutableDictionary *logDictionary; };
struct DcmQueryRetrieveOsiriXDatabaseHandle {
    DB_OsiriX_Handle *handle;
    explicit DcmQueryRetrieveOsiriXDatabaseHandle(const char *callingAET) {
        handle = (DB_OsiriX_Handle *)calloc(1, sizeof(DB_OsiriX_Handle));
CREATING
    }
    ~DcmQueryRetrieveOsiriXDatabaseHandle() {
ENDING
        [handle->callingAET release];
        free(handle);
    }
    OFCondition updateLogEntry(DcmDataset *dataset);
    void markLogIncomplete();
};
UPDATE
MARK
extern "C" void HorosTestStoreObjects(int count, BOOL aborted, const char *patient, int padding) {
    @autoreleasepool {
        DcmQueryRetrieveOsiriXDatabaseHandle *database = nullptr;
        @autoreleasepool { database = new DcmQueryRetrieveOsiriXDatabaseHandle("SENDER AE"); }
        std::string name(patient), description("BRAIN"), series("AXIAL");
        if (padding) { name += std::string(padding, 'P'); description += std::string(padding, 'D'); series += std::string(padding, 'S'); }
        for (int i = 0; i < count; i++) @autoreleasepool {
            DcmDataset dataset;
            dataset.putAndInsertString(DCM_PatientName, name.c_str());
            dataset.putAndInsertString(DCM_StudyDescription, description.c_str());
            dataset.putAndInsertString(DCM_SeriesDescription, series.c_str());
            dataset.putAndInsertString(DCM_SeriesInstanceUID, padding ? std::string(padding, '1').c_str() : "1.2.3");
            database->updateLogEntry(&dataset);
        }
        if (aborted) database->markLogIncomplete();
        delete database;
    }
}
'''.replace('CREATING', creating).replace('ENDING', ending).replace('UPDATE', update).replace('MARK', mark)
    (work / 'handle.mm').write_text(code)
    header = HEADER + ('#ifdef __cplusplus\nextern "C"\n#endif\n'
                       'void HorosTestStoreObjects(int count, BOOL aborted, const char *patient, int padding);\n')
    (work / 'harness.h').write_text(header)
    objects = objc_objects(work)
    (work / 'harness.h').write_text(header)
    result = subprocess.run(['xcrun', 'clang++', '-std=c++17', '-x', 'objective-c++', '-fobjc-exceptions', '-w', '-c',
                             '-I', str(work), str(work / 'handle.mm'), '-o', str(work / 'handle.o'),
                             *[flag for flag in flags if flag.startswith('-I')]], capture_output=True, text=True)
    check(result.returncode == 0, 'the handle\'s log code compiles\n' + result.stderr[-3000:])
    if failures:
        return
    (work / 'handle-driver.swift').write_text(HANDLE_DRIVER)
    executable = work / 'handle'
    archives = [flag for flag in flags if not flag.startswith('-I')]
    if not compile_swift(work, executable, [str(ROOT / 'Horos/Sources/LogManager.swift'), str(work / 'handle-driver.swift'),
                                            *objects, str(work / 'handle.o')], [*archives, '-lc++']):
        return
    result = subprocess.run([str(executable)], capture_output=True, text=True, timeout=120)
    check(result.returncode == 0, 'the listener driver runs\n' + result.stderr[-3000:])
    if result.returncode:
        return
    rows = json.loads(result.stdout.splitlines()[-1])
    by_patient = {row['patient'][:13]: row for row in rows}
    check(len(rows) == 3, f'three listener lines: {rows}')
    small = by_patient.get('SMALL^STORE')
    check(small is not None and (small['message'], small['type'], small['origin'], small['received'], small['total'], small['study'])
          == ('Complete', 'Receive', 'SENDER AE', 3, 3, 'BRAIN AXIAL'), f'three objects, one Complete line: {small}')
    aborted = by_patient.get('ABORTED^STORE')
    check(aborted is not None and (aborted['message'], aborted['received']) == ('Incomplete', 2),
          f'an aborted association: Incomplete: {aborted}')
    long = next((row for row in rows if row['patient'].startswith('LONG')), None)
    check(long is not None and long['message'] == 'Complete' and len(long['patient']) == 1023 and len(long['study']) == 1023,
          f'long values are cut to the 1024-byte buffers: {long and (len(long["patient"]), len(long["study"]))}')
    check(not any(row['patient'].startswith('OFF') for row in rows), 'no listener line while the network logs are off')
    if not failures:
        print('PASS: listener: one Complete line per association, Incomplete when aborted, values bounded, nothing while off')


with tempfile.TemporaryDirectory(prefix='horos-dicomweb-network-log-') as folder:
    work = Path(folder)
    (work / 'dicomweb').mkdir()
    (work / 'listener').mkdir()
    if not failures:
        dicomweb(work / 'dicomweb')
    if not failures:
        listener(work / 'listener')

if failures:
    raise SystemExit(1)
print('PASS: DICOMweb retrieves and listener receives leave their network log lines')
