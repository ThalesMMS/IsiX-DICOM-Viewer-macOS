#!/usr/bin/env python3
"""A URL import is one operation with a typed input and result.

HorosURLImportOperation (URLImportOperation.swift) holds what
-[BrowserController downloadURLs:...] did: wait for the downloads, follow
cancellation, decide by content, write, hand to the database, compose the
result. This compiles it with the production downloads and report, against a
recording double of DicomDatabase and a local HTTP peer, and checks:
- a mixed list (DICOM, archive, page, 404, DICOM) keeps every URL's entry and
  file in the order given, with its outcome, and does not claim success;
- a list that all arrives succeeds; the DICOM objects are indexed by the
  database the operation was given (an independent context of it), the rest
  handed to its import folder, never to another database;
- a cancelled import ends promptly, says so, and does not claim success;
- a write that fails is a failed entry with its reason and no file;
- the operation runs once, and not on the main thread.
The browser keeps only the intent and the result (checked in its source).
"""
from http.server import BaseHTTPRequestHandler
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'tools'))
from local_http import ThreadingLocalHTTPServer  # noqa: E402

DICOM = bytes(128) + b'DICM' + bytes(64)
ZIP = b'PK\x03\x04' + bytes(200)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        if self.path == '/never':
            time.sleep(8)
            return
        body = {'/instance': DICOM, '/archive': ZIP, '/page': b'<html><body>Sign in</body></html>'}.get(self.path)
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
@property(retain) NSMutableArray *indexed;
@property NSInteger incomingScans, contexts;
- (id)privateQueueIndependentDatabase;
- (void)performBlockAndWait:(void (NS_NOESCAPE ^)(void))block;
- (NSString *)uniquePathForNewDataFileWithExtension:(NSString *)extension;
- (NSString *)incomingDirPath;
- (NSArray *)addFilesAtPaths:(NSArray *)paths;
- (void)initiateImportFilesFromIncomingDirUnlessAlreadyImporting;
@end
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
- (NSString *)uniquePathForNewDataFileWithExtension:(NSString *)extension {
    return [[self.folder stringByAppendingPathComponent: NSUUID.UUID.UUIDString] stringByAppendingPathExtension: extension];
}
- (NSString *)incomingDirPath { return [self.folder stringByAppendingPathComponent: @"INCOMING"]; }
- (NSArray *)addFilesAtPaths:(NSArray *)paths {
    DicomDatabase *root = [self root];
    if (!root.indexed) root.indexed = [NSMutableArray array];
    [root.indexed addObjectsFromArray: paths];
    return paths;
}
- (void)initiateImportFilesFromIncomingDirUnlessAlreadyImporting { ++[self root].incomingScans; }
@end
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
check(outcomes == [.indexed, .expanded, .refused, .failed, .indexed], "outcomes out of order: \(outcomes.map { $0.rawValue })")
check(result.entries.map { $0.url } == ["instance", "archive", "page", "missing", "instance"].map { url($0).absoluteString }, "entries out of order")
check(result.files == result.entries.compactMap { $0.path } && result.files.count == 4, "files do not follow the entries")
check(result.files[0].hasPrefix(work + "/A/") && result.files[0].hasSuffix(".dcm"), "a DICOM object is not in the database folder")
check(result.files[1].hasPrefix(work + "/A/INCOMING/") && result.files[1].hasSuffix(".zip"), "an archive is not in the import folder")
check(result.files[2].hasPrefix(work + "/A/INCOMING/") && !result.files[2].hasSuffix(".dcm"), "a page is disguised or misplaced")
check(result.entries[3].reason != nil && result.entries[3].path == nil, "the 404 has no reason or has a file")
check(result.files.allSatisfy { FileManager.default.fileExists(atPath: $0) }, "a written file is missing")
check(!result.succeeded && !result.cancelled, "a mixed list claimed success")
// Downloads finish in any order; the database indexes each as it arrives.
check(Set(a.indexed as! [String]) == [result.files[0], result.files[3]], "the database indexed other files")
check(a.contexts == 1 && a.incomingScans == 2, "the import did not use one independent context or the import folder")
check(b.indexed == nil && b.contexts == 0, "another database was written")
check(result.report.contains("2 added to the database") && result.report.contains("1 handed to the import folder"), "report: " + result.report)

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
            subprocess.run(['xcrun', 'clang', '-c', '-fobjc-arc', '-I', str(work), str(work / 'Database.m'),
                            '-o', str(work / 'Database.o')], check=True)
            subprocess.run(['xcrun', 'swiftc', '-suppress-warnings', '-import-objc-header', str(work / 'Database.h'),
                            *[str(root / 'Horos/Sources' / name) for name in
                              ('URLImportOperation.swift', 'URLImportDownloads.swift', 'URLImportReport.swift')],
                            str(work / 'main.swift'), str(work / 'Database.o'), '-o', str(work / 'check')], check=True)
            run = subprocess.run([str(work / 'check'), 'http://127.0.0.1:%d' % server.server_port, str(work / 'db')],
                                 capture_output=True, text=True, timeout=60)
            if run.returncode or run.stdout.strip() != 'ok':
                failures.append((run.stdout + run.stderr).strip()[-1500:])
    finally:
        server.shutdown()

    browser = (root / 'Horos/Sources/BrowserController.m').read_bytes().decode('latin1')
    if '- (NSArray*)downloadURLs:' in browser or 'fileExtensionForPayload' in browser or 'recordFailedURL' in browser:
        failures.append('BrowserController still holds the download, classification and writing loop')
    if browser.count('[HorosURLImportOperation alloc] initWithURLs:') != 2:
        failures.append('the two entry points do not hand the import to one operation each')
    if failures:
        for failure in failures:
            print('FAIL:', failure)
        return 1
    print('url import operation: a mixed list in order with its outcomes, success only when everything arrived, the '
          'given database only, prompt cancellation, a failed write reported, one run off the main thread')
    return 0


if __name__ == '__main__':
    sys.exit(main())
