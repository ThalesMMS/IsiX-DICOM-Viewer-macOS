#!/usr/bin/env python3
"""A URL import is one operation with a typed input and result.

HorosURLImportOperation (URLImportOperation.swift) holds what
-[BrowserController downloadURLs:...] did: wait for the downloads, follow
cancellation, decide by content, publish to the import folder, compose the
result. This compiles it with the production downloads and report and the part
of DatabaseIngest it uses, against a double of DicomDatabase whose scan moves
what it takes and a local HTTP peer, and checks:
- a mixed list (DICOM, archive, page, 404, DICOM) keeps every URL's entry and
  file in the order given, with its outcome, and does not claim success;
- a list that all arrives succeeds; the DICOM objects go through the import
  folder of the database the operation was given (an independent context of it),
  are imported before the operation answers, and name the file the image has,
  never another database's;
- only what the database took is counted as added: an object the import keeps
  aside is refused and the import does not claim success, and one it has not
  finished with stays with the folder, which is asked for a pass;
- an object DCMTK cannot read and the import repairs is indexed, not refused, and
  a pass cancelled while it holds one gives it back as queued, not refused;
- a cancelled import ends promptly, says so, and does not claim success;
- a write that fails is a failed entry with its reason and no file;
- the operation runs once, and not on the main thread.
The browser keeps only the intent and the result (checked in its source).
"""
from http.server import BaseHTTPRequestHandler
from sources import class_text
from pathlib import Path
import importlib.util
import subprocess
import sys
import tempfile
import threading
import time
import uuid

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'tools'))
sys.path.insert(0, str(root / 'tests'))
from local_http import ThreadingLocalHTTPServer  # noqa: E402
import isix_modules  # noqa: E402

spec = importlib.util.spec_from_file_location('swift_idiom_indicator', root / 'tools/swift-idiom-indicator.py')
indicator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(indicator)


def dicom(kind):
    """An object with its own instance UID, and what the scan is to do with it."""
    return bytes(128) + b'DICM' + f'{kind}:{uuid.uuid4()}'.encode() + bytes(64)


def member(source, signature):
    """A member of a Swift type, from `signature` through its closing brace."""
    at = source.index(signature)
    code = indicator.swift_code(source)
    depth, index = 0, code.index('{', at)
    while True:
        depth += {'{': 1, '}': -1}.get(code[index], 0)
        index += 1
        if depth == 0:
            return source[at:index]


ZIP = b'PK\x03\x04' + bytes(200)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        if self.path == '/never':
            time.sleep(8)
            return
        body = {'/instance': dicom('take'), '/unreadable': dicom('refuse'), '/stopped': dicom('stay'), '/converted': dicom('convert'), '/deleted': dicom('delete'),
                '/repaired': dicom('repair'), '/returned': dicom('return'),
                '/archive': ZIP, '/page': b'<html><body>Sign in</body></html>'}.get(self.path)
        self.send_response(200 if body else 404)
        self.end_headers()
        try:
            self.wfile.write(body or b'<html>not found</html>')
        except BrokenPipeError:
            pass


HEADER = r'''
#import <Foundation/Foundation.h>
@interface DicomDatabase : NSObject
@property(retain) NSString *name, *folder;
@property(retain) DicomDatabase *parent;
@property(retain) NSMutableArray *indexed, *images;
@property NSInteger incomingScans, contexts, passes;
- (id)privateQueueIndependentDatabase;
- (void)performBlockAndWait:(void (NS_NOESCAPE ^)(void))block;
- (NSString *)incomingDirPath;
- (NSString *)errorsDirPath;
- (NSString *)decompressionDirPath;
- (NSInteger)importFilesFromIncomingDir;
- (NSArray *)objectsForEntity:(id)entity predicate:(NSPredicate *)predicate;
- (void)initiateImportFilesFromIncomingDirUnlessAlreadyImporting;
@end
@interface DicomImage : NSObject
@property(retain) NSData *compressedSopInstanceUID;
@property(retain) NSString *path;
+ (NSData *)sopInstanceUIDEncode:(NSString *)uid;
- (NSString *)sopInstanceUID;
- (NSString *)completePath;
@end
extern NSString *const DicomDatabaseImageEntityName;
'''

STUB = r'''
#import "Database.h"
@implementation DicomDatabase
- (void)performBlockAndWait:(void (NS_NOESCAPE ^)(void))block { block(); }
- (id)privateQueueIndependentDatabase {
    DicomDatabase *child = [DicomDatabase new];
    child.name = self.name; child.folder = self.folder; child.parent = self; ++self.contexts;
    return child;
}
- (DicomDatabase *)root { return self.parent ?: self; }
- (NSString *)incomingDirPath { return [self.folder stringByAppendingPathComponent: @"INCOMING"]; }
- (NSString *)errorsDirPath {
    NSString *path = [self.folder stringByAppendingPathComponent: @"NOT READABLE"];
    [NSFileManager.defaultManager createDirectoryAtPath: path withIntermediateDirectories: YES attributes: nil error: NULL];
    return path;
}
- (NSString *)decompressionDirPath {
    NSString *path = [self.folder stringByAppendingPathComponent: @"DECOMPRESS"];
    [NSFileManager.defaultManager createDirectoryAtPath: path withIntermediateDirectories: YES attributes: nil error: NULL];
    return path;
}
// The scan: what it takes goes to the data folder under a new name, and only
// what the name of a file does not decide is decided by what the file says.
- (NSInteger)importFilesFromIncomingDir {
    DicomDatabase *root = [self root];
    ++root.passes;
    NSFileManager *files = NSFileManager.defaultManager;
    NSInteger added = 0;
    NSString *data = [self.folder stringByAppendingPathComponent: @"DATA"];
    [files createDirectoryAtPath: data withIntermediateDirectories: YES attributes: nil error: NULL];
    for (NSString *name in [files contentsOfDirectoryAtPath: self.incomingDirPath error: NULL]) {
        if ([name hasPrefix: @"."]) continue;
        NSString *path = [self.incomingDirPath stringByAppendingPathComponent: name];
        NSString *text = [[NSString alloc] initWithData: [NSData dataWithContentsOfFile: path] encoding: NSISOLatin1StringEncoding];
        NSRange magic = [text rangeOfString: @"DICM"];
        if (magic.location == NSNotFound) continue; // what the content says is not an object waits, as far as this test goes
        NSString *rest = [[text substringFromIndex: NSMaxRange(magic)] stringByTrimmingCharactersInSet: [NSCharacterSet characterSetWithRange: NSMakeRange(0, 1)]];
        NSString *kind = [rest componentsSeparatedByString: @":"].firstObject;
        if ([kind isEqual: @"stay"]) continue;
        if ([kind isEqual: @"return"]) {
            [files moveItemAtPath: path toPath: [[self.incomingDirPath stringByAppendingPathComponent: NSUUID.UUID.UUIDString] stringByAppendingPathExtension: @"dcm"] error: NULL];
            [NSThread.currentThread cancel];
            return added;
        }
        if ([kind isEqual: @"convert"]) { [files moveItemAtPath: path toPath: [self.decompressionDirPath stringByAppendingPathComponent: name] error: NULL]; continue; }
        if ([kind isEqual: @"delete"]) { [files removeItemAtPath: path error: NULL]; continue; }
        if ([kind isEqual: @"refuse"]) { [files moveItemAtPath: path toPath: [self.errorsDirPath stringByAppendingPathComponent: name] error: NULL]; continue; }
        NSString *stored = [[data stringByAppendingPathComponent: NSUUID.UUID.UUIDString] stringByAppendingPathExtension: @"dcm"];
        [files moveItemAtPath: path toPath: stored error: NULL];
        DicomImage *image = [DicomImage new];
        image.path = stored;
        image.compressedSopInstanceUID = [DicomImage sopInstanceUIDEncode: rest];
        if (!root.indexed) { root.indexed = [NSMutableArray array]; root.images = [NSMutableArray array]; }
        [root.indexed addObject: stored];
        [root.images addObject: image];
        ++added;
    }
    return added;
}
- (NSArray *)objectsForEntity:(id)entity predicate:(NSPredicate *)predicate {
    return [[self root].images ?: @[] filteredArrayUsingPredicate: predicate];
}
- (void)initiateImportFilesFromIncomingDirUnlessAlreadyImporting { ++[self root].incomingScans; }
@end
NSString *const DicomDatabaseImageEntityName = @"Image";
@implementation DicomImage
+ (NSData *)sopInstanceUIDEncode:(NSString *)uid { return [uid dataUsingEncoding: NSUTF8StringEncoding]; }
- (NSString *)sopInstanceUID { return [[NSString alloc] initWithData: self.compressedSopInstanceUID encoding: NSUTF8StringEncoding]; }
- (NSString *)completePath { return self.path; }
@end
'''

# What DatabaseIngest asks of the parts of the application it does not bring here.
INGEST = r'''
import Foundation
import IsiXContracts

final class DicomFile {
    private let instance: String?
    init?(_ path: String, dicomOnly: Bool) {
        guard let data = FileManager.default.contents(atPath: path), let text = String(data: data, encoding: .isoLatin1),
              let magic = text.range(of: "DICM") else { return nil }
        instance = text[magic.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
        if instance!.hasPrefix("repair:") { return nil }
    }
    func element(forKey key: String) -> Any? { key == "SOPUID" ? instance : nil }
}

struct DICOMTriageMetadata {
    let instance: String
    static func parse(_ data: Data) -> Self? {
        guard let text = String(data: data, encoding: .isoLatin1), let magic = text.range(of: "DICM") else { return nil }
        return Self(instance: text[magic.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: "\0")))
    }
    func string(group: UInt16, element: UInt16) -> String? { group == 0x0008 && element == 0x0018 ? instance : nil }
}

struct DatabaseIngest {
    static let process = DatabaseIngest()

    func admissionFolder(of database: DicomDatabase?) -> IngestFolder {
        IngestFolder(path: database?.incomingDirPath() ?? "")
    }

@MEMBERS@
}
'''

DRIVER = r'''
import Foundation

// NSThread+N2's status, which the operation sets for the activity window.
extension Thread {
    @objc var status: String? { get { nil } set {} }
}

func check(_ ok: Bool, _ message: String) { if !ok { print("FAIL: " + message); exit(1) } }

func database(_ name: String, _ folder: String) -> DicomDatabase {
    let db = DicomDatabase()
    db.name = name; db.folder = folder
    try! FileManager.default.createDirectory(atPath: folder + "/INCOMING", withIntermediateDirectories: true)
    return db
}

func run(_ operation: URLImportOperation, cancelAfter: TimeInterval? = nil) -> URLImportResult {
    var result: URLImportResult?
    let done = DispatchSemaphore(value: 0)
    let worker = Thread { result = operation.run(); done.signal() }
    worker.start()
    if let cancelAfter { Thread.sleep(forTimeInterval: cancelAfter); worker.cancel() }
    check(done.wait(timeout: .now() + 20) == .success, "the import did not end")
    return result!
}

let base = CommandLine.arguments[1], work = CommandLine.arguments[2]
func url(_ path: String) -> URL { URL(string: base + "/" + path)! }

// --- a mixed list ------------------------------------------------------------
let a = database("A", work + "/A"), b = database("B", work + "/B")
let mixed = URLImportOperation(urls: ["instance", "archive", "page", "missing", "instance"].map(url), database: a,
                               requestTimeout: 5, totalTimeout: 10)
check(mixed.state == .ready, "a new operation is not ready")
let result = run(mixed)
check(mixed.state == .finished, "the operation did not finish")
let outcomes = result.entries.map { $0.outcome }
check(a.passes == 2, "each DICOM object asked for one import, and this took \(a.passes)")
check(outcomes == [.indexed, .expanded, .refused, .failed, .indexed], "outcomes out of order: \(outcomes.map { $0.rawValue })")
check(result.entries.map { $0.url } == ["instance", "archive", "page", "missing", "instance"].map { url($0).absoluteString }, "entries out of order")
check(result.files == result.entries.compactMap { $0.path } && result.files.count == 4, "files do not follow the entries")
check(result.files[0].hasPrefix(work + "/A/DATA/") && result.files[0].hasSuffix(".dcm"), "a DICOM object does not name its image's file")
check(result.files[1].hasPrefix(work + "/A/INCOMING/") && result.files[1].hasSuffix(".zip"), "an archive is not in the import folder")
check(result.files[2].hasPrefix(work + "/A/INCOMING/") && !result.files[2].hasSuffix(".dcm"), "a page is disguised or misplaced")
check(result.entries[3].reason != nil && result.entries[3].path == nil, "the 404 has no reason or has a file")
check(result.files.allSatisfy { FileManager.default.fileExists(atPath: $0) }, "a written file is missing")
check(!((try? FileManager.default.contentsOfDirectory(atPath: work + "/A/INCOMING")) ?? []).contains { $0.hasPrefix(".") }, "a draft stayed behind")
check(!result.succeeded && !result.cancelled, "a mixed list claimed success")
// Downloads finish in any order; the database indexes each as it arrives.
check(Set(a.indexed as! [String]) == [result.files[0], result.files[3]], "the database indexed other files")
check(a.contexts == 1 && a.incomingScans == 2, "the import did not use one independent context, or the archive and the page did not ask for a pass")
check(b.indexed == nil && b.contexts == 0, "another database was written")
check(result.report.contains("2 added to the database") && result.report.contains("1 handed to the import folder"), "report: " + result.report)

// --- what the database did not take is not counted --------------------------------
let d = database("D", work + "/D")
let judged = run(URLImportOperation(urls: ["unreadable", "stopped", "converted", "instance", "deleted"].map(url), database: d,
                                    requestTimeout: 5, totalTimeout: 10))
check(judged.entries.map { $0.outcome } == [.refused, .queued, .queued, .indexed, .refused], "verdicts: \(judged.entries.map { $0.outcome.rawValue })")
check(judged.entries[4].path == nil && judged.entries[4].reason != nil, "a refused object the import deleted names a file, or no reason")
check(judged.entries[0].path!.hasPrefix(work + "/D/NOT READABLE/") && judged.entries[0].reason != nil, "a refused object does not say where it is and why")
check(judged.entries[1].path!.hasPrefix(work + "/D/INCOMING/"), "an object left in the queue is not named there")
check(d.incomingScans == 2, "each object left to the folder asks for a pass, once: \(d.incomingScans)")
check(d.passes == 5, "an object was imported more than once: \(d.passes)")
check(judged.report.contains("1 added to the database") && judged.report.contains("2 handed to the import folder"), "report: " + judged.report)
check(!judged.succeeded, "an object the import refused still claimed success")
let pending = run(URLImportOperation(urls: [url("stopped")], database: database("E", work + "/E"), requestTimeout: 5, totalTimeout: 10))
check(pending.succeeded && !pending.report.contains("added to the database"), "an object still queued is reported as added, or as a failure: " + pending.report)

let repaired = run(URLImportOperation(urls: [url("repaired")], database: database("F", work + "/F"), requestTimeout: 5, totalTimeout: 10))
check(repaired.entries.first?.outcome == .indexed && repaired.succeeded, "an object DCMTK cannot read, which the import took, is not indexed: \(repaired.report)")
let returned = run(URLImportOperation(urls: [url("returned")], database: database("G", work + "/G"), requestTimeout: 5, totalTimeout: 10))
check(returned.entries.first?.outcome == .queued, "an object a cancelled pass gave back is not on its way: \(returned.report)")

// --- once, and not on the main thread -----------------------------------------
check(mixed.run().report == "This import has already run.", "the operation ran twice")
let main = URLImportOperation(urls: [url("instance")], database: b, requestTimeout: 5, totalTimeout: 10)
check(main.run().report == "Use asynchronous URL import on the main thread." && b.contexts == 0, "the import ran on the main thread")

// --- all of it arrives ----------------------------------------------------------
let clean = run(URLImportOperation(urls: [url("instance"), url("archive")], database: b, requestTimeout: 5, totalTimeout: 10))
check(clean.succeeded && clean.files.count == 2, "a clean list did not succeed")

// --- cancelled --------------------------------------------------------------------
let started = Date()
let cancelled = run(URLImportOperation(urls: [url("never"), url("instance")], database: b, requestTimeout: 30, totalTimeout: 60),
                    cancelAfter: 0.5)
check(Date().timeIntervalSince(started) < 5, "the cancellation was not prompt")
check(cancelled.cancelled && !cancelled.succeeded, "a cancelled import claimed success")
check(cancelled.entries[0].outcome == .failed, "the stalled URL is not a failure")

// --- a write that fails ---------------------------------------------------------------
let broken = database("C", work + "/C")
try! FileManager.default.removeItem(atPath: work + "/C/INCOMING")
let failed = run(URLImportOperation(urls: [url("page")], database: broken, requestTimeout: 5, totalTimeout: 10))
check(failed.entries.first?.outcome == .failed && failed.entries.first?.reason != nil && failed.files.isEmpty && !failed.succeeded,
      "a failed write is not a failed entry")
check(broken.incomingScans == 0, "the import folder was asked to scan a file that was not written")
print("ok")
'''


def main():
    server = ThreadingLocalHTTPServer(('127.0.0.1', 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    failures = []
    try:
        with tempfile.TemporaryDirectory(prefix='horos-url-operation-') as tmp:
            work = Path(tmp)
            (work / 'Database.h').write_text(HEADER)
            (work / 'Database.m').write_text(STUB)
            (work / 'main.swift').write_text(DRIVER)
            # The members of the single entry the operation uses, as they are.
            ingest = (root / 'Horos/Sources/DatabaseIngest.swift').read_text(encoding='utf-8')
            members = [member(ingest, signature) for signature in (
                'enum Verdict {',
                'func publish(fileAt path: String, named name: String, into folder: IngestFolder, preset: IngestPreset) -> IngestPublication {',
                'func publish(_ draft: IngestDraft, preset: IngestPreset) -> IngestPublication {',
                'func discard(_ draft: IngestDraft) {',
                'func publishAndImport(_ draft: IngestDraft, preset: IngestPreset, in database: DicomDatabase) -> Verdict {',
                'private func instanceUID(ofFileAt path: String) -> String? {',
                'private func storedPath(ofInstance uid: String, in database: DicomDatabase) -> String? {',
                'func requestImport(of database: DicomDatabase?) {',
                'func importQueueNow(in database: DicomDatabase?) -> Int {')]
            (work / 'ingest.swift').write_text(INGEST.replace('@MEMBERS@', '\n\n'.join(members)))
            subprocess.run(['xcrun', 'clang', '-c', '-fobjc-arc', '-I', str(work), str(work / 'Database.m'),
                            '-o', str(work / 'Database.o')], check=True)
            subprocess.run(['xcrun', 'swiftc', '-suppress-warnings', '-import-objc-header', str(work / 'Database.h'),
                            *isix_modules.module_flags('IsiXContracts', work / 'modules'),
                            *[str(root / 'Horos/Sources' / name) for name in
                              ('URLImportOperation.swift', 'URLImportDownloads.swift', 'URLImportReport.swift')],
                            str(work / 'ingest.swift'), str(work / 'main.swift'), str(work / 'Database.o'), '-o', str(work / 'check')], check=True)
            run = subprocess.run([str(work / 'check'), 'http://127.0.0.1:%d' % server.server_port, str(work / 'db')],
                                 capture_output=True, text=True, timeout=60)
            if run.returncode or run.stdout.strip() != 'ok':
                failures.append((run.stdout + run.stderr).strip()[-1500:])
    finally:
        server.shutdown()

    # The URL entry points are DroppedFilesImport.swift, behind the browser's
    # selectors.
    browser = class_text('BrowserController') + (root / 'Horos/Sources/DroppedFilesImport.swift').read_text(encoding='utf-8')
    if '- (NSArray*)downloadURLs:' in browser or 'fileExtensionForPayload' in browser or 'recordFailedURL' in browser:
        failures.append('BrowserController still holds the download, classification and writing loop')
    if browser.count('URLImportOperation(urls: urls, database: database)') != 2:
        failures.append('the two entry points do not hand the import to one operation each')
    operation = (root / 'Horos/Sources/URLImportOperation.swift').read_text(encoding='utf-8')
    if 'case .notPublished(let errorNumber):' not in operation or 'addFiles' in indicator.swift_code(operation):
        failures.append('the operation does not go through the single entry, or does not report a file it could not publish')
    if failures:
        for failure in failures:
            print('FAIL:', failure)
        return 1
    print('url import operation: a mixed list in order with its outcomes, success only when everything arrived, the '
          'given database only, added only what the database took, prompt cancellation, a failed write reported, one run '
          'off the main thread')
    return 0


if __name__ == '__main__':
    sys.exit(main())
