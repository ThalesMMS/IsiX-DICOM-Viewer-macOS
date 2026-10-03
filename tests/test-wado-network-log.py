#!/usr/bin/env python3
"""Exercise the production WADO downloader and Core Data network logger.

Reuse the Objective-C/Core Data doubles from the activity-log regression test;
only app integration dependencies are doubled. HTTP and TLS failures travel
through the real URLSession callbacks, and final rows are read from Core Data.
"""
import ast
import http.server
import json
from pathlib import Path
import shutil
import ssl
import subprocess
import tempfile
import threading
import sys

if shutil.which("xcrun") is None:
    print("skipped: needs macOS and xcrun (Swift and Objective-C compilers)", file=sys.stderr)
    raise SystemExit(2)

ROOT = Path(__file__).resolve().parents[1]
values = {}
for node in ast.parse((ROOT / 'tests/test-activity-progress-window.py').read_text()).body:
    if isinstance(node, ast.Assign) and isinstance(node.value, ast.Constant) and isinstance(node.value.value, str):
        for target in node.targets:
            if isinstance(target, ast.Name):
                values[target.id] = node.value.value
    elif isinstance(node, ast.Assign) and any(isinstance(t, ast.Name) and t.id == 'LOG_HEADER' for t in node.targets):
        values['LOG_HEADER'] = values['EXCEPTION_HEADER'] + ast.literal_eval(node.value.right)

HEADER = values['LOG_HEADER'] + r'''
int HorosDICOMGlobalAbortRequested(void);
void WADODownloadLogStackTrace(NSString *message);
@interface DicomDatabase (WADOTest)
+ (DicomDatabase *)activeLocal;
- (NSString *)incomingDirPath;
- (void)initiateImportFilesFromIncomingDirUnlessAlreadyImporting;
@end
@interface DicomFile : NSObject
+ (BOOL)isDICOMFile:(NSString *)file;
- (instancetype)init:(NSString *)file;
- (id)elementForKey:(NSString *)key;
@end
@interface NSString (WADOTest)
+ (NSString *)sizeString:(unsigned long long)size;
@end
@interface NSThread (WADOTest)
@property CGFloat progress;
@property (copy) NSString *status;
@end
'''
DOUBLES = values['LOG_DOUBLES'] + r'''
int HorosDICOMGlobalAbortRequested(void) { return 0; }
void WADODownloadLogStackTrace(NSString *message) { NSLog(@"%@", message); }
@implementation DicomDatabase (WADOTest)
+ (DicomDatabase *)activeLocal { return BrowserController.currentBrowser.database; }
- (NSString *)incomingDirPath { return [NSProcessInfo.processInfo.arguments[2] stringByAppendingPathComponent:@"incoming"]; }
- (void)initiateImportFilesFromIncomingDirUnlessAlreadyImporting {}
@end
@implementation DicomFile
+ (BOOL)isDICOMFile:(NSString *)file { return YES; }
- (instancetype)init:(NSString *)file { return [super init]; }
- (id)elementForKey:(NSString *)key { return @"Synthetic"; }
@end
@implementation NSString (WADOTest)
+ (NSString *)sizeString:(unsigned long long)size { return @"bytes"; }
@end
@implementation NSThread (WADOTest)
- (CGFloat)progress { return 0; }
- (void)setProgress:(CGFloat)value {}
- (NSString *)status { return @"WADO test"; }
- (void)setStatus:(NSString *)value {}
@end
'''
DRIVER = r'''
import Cocoa
final class HorosAlertPanel {
    static func runCritical(title: String?, message: String, defaultButton: String?, alternateButton: String?, otherButton: String?) {}
}
@main struct Driver {
    static func main() throws {
        let args = CommandLine.arguments
        try FileManager.default.createDirectory(atPath: args[2] + "/incoming", withIntermediateDirectories: true)
        UserDefaults.standard.set(1, forKey: "WADORetryAttempts")
        UserDefaults.standard.set(1, forKey: "WADOMaximumConcurrentDownloads")
        let downloader = WADODownload()
        downloader.showErrorMessage = false
        if args[3] == "cancel" { downloader._abortAssociation = true }
        let urls = ["1", "2"].map { URL(string: args[1] + "/" + args[3] + "?objectUID=" + $0 + "&transferSyntax=*&useOrig=true&secret=must-not-appear")! }
        downloader.WADODownload(urls)
        let db = BrowserController.currentBrowser()!.database!
        let entries = db.objects(forEntity: db.logEntryEntity(), predicate: NSPredicate(value: true)) as! [NSManagedObject]
        let result = entries.map { entry in
            ["message": entry.value(forKey: "message") ?? "", "sent": entry.value(forKey: "numberSent") ?? -1,
             "total": entry.value(forKey: "numberImages") ?? -1, "errors": entry.value(forKey: "numberError") ?? -1,
             "ended": entry.value(forKey: "endTime") != nil] as [String: Any]
        }
        print(String(data: try JSONSerialization.data(withJSONObject: result), encoding: .utf8)!)
    }
}
'''

class Handler(http.server.BaseHTTPRequestHandler):
    calls = {}
    def log_message(self, *args):
        pass
    def do_GET(self):
        self.calls[self.path] = self.calls.get(self.path, 0) + 1
        mode = self.path.split('?')[0][1:]
        status, body = 200, b'\0' * 128 + b'DICM' + b'fixture'
        if mode == 'refuse':
            status, body = 400, b'Unsupported syntax'
        elif mode == 'retry' and self.calls[self.path] == 1:
            status, body = 503, b'Try again'
        elif mode == 'partial' and 'objectUID=2' in self.path:
            status, body = 404, b'Absent'
        elif mode == 'invalid':
            body = b'<html>login page</html>'
        elif mode == 'empty':
            body = b''
        self.send_response(status)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

with tempfile.TemporaryDirectory(prefix='wado-network-log-') as directory:
    work = Path(directory)
    for name in ('HorosObjCException.h', 'HorosObjCException.m'):
        shutil.copy(ROOT / 'Horos/Sources' / name, work / name)
    (work / 'harness.h').write_text(HEADER)
    (work / 'doubles.m').write_text(DOUBLES)
    (work / 'driver.swift').write_text(DRIVER)
    def run(command):
        result = subprocess.run(command, capture_output=True, text=True)
        assert result.returncode == 0, result.stdout + result.stderr
        return result
    for name, flags in [('HorosObjCException', []), ('doubles', ['-fobjc-arc'])]:
        run(['xcrun', 'clang', '-x', 'objective-c', '-fobjc-exceptions', *flags, '-c',
             str(work / (name + '.m')), '-o', str(work / (name + '.o'))])
    executable = work / 'test'
    run(['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library', '-module-name', 'Horos',
         '-import-objc-header', str(work / 'harness.h'),
         *[str(ROOT / 'Horos/Sources' / name) for name in ('WADODownload.swift', 'WADOCredentials.swift', 'DICOMwebCredentials.swift', 'NonInteractiveKeychainRead.swift', 'RetrieveManifest.swift', 'LogManager.swift', 'NodeRequestLimiter.swift', 'RetrievePlan.swift')],
         str(work / 'driver.swift'), str(work / 'HorosObjCException.o'), str(work / 'doubles.o'),
         '-framework', 'Cocoa', '-framework', 'CoreData', '-o', str(executable)])
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    def check(mode, base=None, sent=0, errors=2, state='Incomplete', details=()):
        folder = work / mode
        result = run([str(executable), base or f'http://127.0.0.1:{server.server_port}', str(folder), mode])
        rows = json.loads(result.stdout.splitlines()[-1])
        assert len(rows) == 1, rows
        row = rows[0]
        assert (row['sent'], row['total'], row['errors'], row['ended']) == (sent, 2, errors, True), row
        assert row['message'].startswith(state + ' — WADO;'), row
        for detail in details:
            assert detail in row['message'], row
        assert 'must-not-appear' not in row['message'] and 'objectUID' not in row['message'], row
        assert not any(c in row['message'] for c in '\r\n,\"'), row
        print('PASS:', mode, row['message'])
    try:
        check('complete', sent=2, errors=0, state='Complete', details=('requests=2', 'retries=0'))
        check('refuse', details=('HTTP 400 x2', 'requests=2', 'retries=0'))
        check('partial', sent=1, errors=1, details=('HTTP 404 x1', 'received=1/2'))
        check('retry', sent=2, errors=0, state='Complete', details=('HTTP 503 x2', 'requests=4', 'retries=1'))
        check('invalid', details=('Invalid DICOM response x4',))
        check('empty', details=('Empty or short response x4',))
        check('cancel', state='Cancelled', details=('Cancelled x1', 'requests=0'))
        # A closed loopback listener proves a transport failure before any HTTP response.
        closed = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        port = closed.server_port
        closed.server_close()
        check('transport', base=f'http://127.0.0.1:{port}', details=('Transport NSURLErrorDomain -1004',))
        cert, key = work / 'cert.pem', work / 'key.pem'
        run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
             '-subj', '/CN=localhost', '-keyout', str(key), '-out', str(cert)])
        tls = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(cert, key)
        tls.socket = context.wrap_socket(tls.socket, server_side=True)
        threading.Thread(target=tls.serve_forever, daemon=True).start()
        try:
            check('tls', base=f'https://127.0.0.1:{tls.server_port}', details=('TLS NSURLErrorDomain -1202', 'retries=0'))
        finally:
            tls.shutdown()
            tls.server_close()
    finally:
        server.shutdown()
        server.server_close()
