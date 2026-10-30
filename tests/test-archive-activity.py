#!/usr/bin/env python3
"""Run the browser's archive Activity job with real threads and unzip processes.

The Activity job, the password coordinator and the error report are Swift
(BrowserController+DatabaseImport.swift, on the IsiXDatabase password rule);
the extraction is the browser's +unzipFile: (BrowserController+Files.swift). Both run verbatim
against a recording database, thread manager and alert; only the user's
answers are simulated.
"""
from pathlib import Path
import subprocess
import tempfile
import zipfile

root = Path(__file__).resolve().parents[1]
source = (root / 'Horos/Sources/BrowserController+Files.swift').read_text()
start = source.index('    // MARK: ZIP archives')
end = source.index('    /// Expands an encrypted archive, asking for its password', start)
extraction = 'extension BrowserController {\n' + source[start:end] + '}\n'

imports = (root / 'Horos/Sources/BrowserController+DatabaseImport.swift').read_text()
start = imports.index('private final class ArchivePasswordRequest')
end = imports.index('\n}\n', start) + 3
request = imports[start:end]
start = imports.index('    @objc(expandArchiveIntoIncomingFolder:)')
end = imports.index('    // MARK: Files and folders', start)
activity = request + '\nextension BrowserController {\n' + imports[start:end] + '}\n'

header = r'''#import <AppKit/AppKit.h>
#import "HorosObjCException.h"
NS_ASSUME_NONNULL_BEGIN
void HarnessSetWorkingDirectory(NSString *path);
@interface NSThread (ActivityTest)
@property(nonatomic,copy,nullable) NSString *status;
@property(nonatomic) float progress;
@property(nonatomic) BOOL supportsCancel;
@end
@interface ThreadsManager : NSObject
@property(nonatomic,retain) NSMutableArray<NSThread*> *threads;
+ (nullable ThreadsManager*)defaultManager NS_SWIFT_NAME(default());
- (void)addThreadAndStart:(NSThread*)thread;
@end
@interface DicomDatabase : NSObject
@property(nonatomic,copy) NSString *incomingFolder;
@property(nonatomic) unsigned importRequests;
- (nullable NSString*)incomingDirPath;
- (void)initiateImportFilesFromIncomingDirUnlessAlreadyImporting;
@end
NS_SWIFT_UI_ACTOR
@interface BrowserController : NSObject
+ (nullable BrowserController*)currentBrowser;
@property(nonatomic,retain,nullable) DicomDatabase *database;
@property(nonatomic,retain,nullable) id window;
@end
@interface WaitRendering : NSObject
@property(nonatomic,retain,nullable) NSWindow *window;
- (id)init:(NSString*)title;
- (void)showWindow:(nullable id)sender;
- (void)close;
@end
@interface NSFileManager (TestTemporaryDirectory)
- (NSString*)tmpDirPath;
@end
void _N2LogExceptionImpl(NSException* e, BOOL logStack, const char* pf);
void DicomDatabaseLogError(const char* function, const char* file, int line, NSString* message);
NS_ASSUME_NONNULL_END
'''

native = r'''#import "Harness.h"
#import <objc/runtime.h>
static NSString *workingDirectory;
void HarnessSetWorkingDirectory(NSString *path) { workingDirectory = [path copy]; }
static void check(BOOL ok, const char *message) {
    if (!ok) { fprintf(stderr,"FAIL: %s\n",message); exit(1); }
}
void _N2LogExceptionImpl(NSException* e, BOOL logStack, const char* pf) { NSLog(@"%s: %@", pf, e); }
void DicomDatabaseLogError(const char* function, const char* file, int line, NSString* message) { NSLog(@"%s: %@", function, message); }
@implementation NSThread (ActivityTest)
- (void)setStatus:(NSString*)v { objc_setAssociatedObject(self,@selector(status),v,OBJC_ASSOCIATION_COPY); }
- (NSString*)status { return objc_getAssociatedObject(self,@selector(status)); }
- (void)setProgress:(float)v { objc_setAssociatedObject(self,@selector(progress),@(v),OBJC_ASSOCIATION_RETAIN); }
- (float)progress { return [objc_getAssociatedObject(self,@selector(progress)) floatValue]; }
- (void)setSupportsCancel:(BOOL)v { objc_setAssociatedObject(self,@selector(supportsCancel),@(v),OBJC_ASSOCIATION_RETAIN); }
- (BOOL)supportsCancel { return [objc_getAssociatedObject(self,@selector(supportsCancel)) boolValue]; }
@end
@implementation NSFileManager (TestTemporaryDirectory)
- (NSString*)tmpDirPath { return workingDirectory; }
@end
@implementation ThreadsManager
+ (ThreadsManager*)defaultManager { static ThreadsManager *m; if (!m) { m=[ThreadsManager new];m.threads=[NSMutableArray array]; } return m; }
- (void)addThreadAndStart:(NSThread*)thread {
    check(NSThread.isMainThread,"Activity registration must happen on main");
    check([thread.name isEqualToString:@"Uncompressing..."] && thread.progress==-1 && thread.supportsCancel,
          "Activity needs an indeterminate, cancellable extraction task");
    [self.threads addObject:thread]; [thread start];
}
@end
@implementation DicomDatabase
- (NSString*)incomingDirPath { return self.incomingFolder; }
- (void)initiateImportFilesFromIncomingDirUnlessAlreadyImporting { self.importRequests++; }
@end
@implementation WaitRendering
- (id)init:(NSString*)title { check(NO,"Activity extraction created a modal progress window");return nil; }
- (void)showWindow:(id)sender { check(NO,"Activity extraction displayed a modal window"); }
- (void)close {}
@end
@interface HorosArchiveImportLedger : NSObject
+ (BOOL)unzipExpandedWholeArchive:(NSString*)archive status:(int)status into:(NSString*)destination;
@end
#define N2LogExceptionWithStackTrace(e) NSLog(@"%@",e)
@implementation BrowserController
+ (BrowserController*)currentBrowser { return nil; }
@end
'''

driver = r'''import AppKit
func check(_ ok: Bool, _ message: String) { if !ok { FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8)); exit(1) } }
nonisolated(unsafe) var prompts = 0, errors = 0, ticks = 0
// Each prompt takes the next answer; nil leaves the sheet open; none left: "secret".
nonisolated(unsafe) var answers: [String?] = []

// Only user decisions are simulated: this NSAlert stands in for AppKit's in
// the code under test, records what it is asked and answers like a user.
@MainActor final class FakeWindow: NSObject {
    weak var owner: NSAlert?
    var sheetParent: FakeWindow?
    func makeFirstResponder(_ responder: Any?) { check(Thread.isMainThread, "password field accessed off main") }
    func endSheet(_ sheet: FakeWindow, returnCode: NSApplication.ModalResponse) {
        check(Thread.isMainThread, "password sheet dismissed off main")
        let callback = sheet.owner?.completion
        sheet.sheetParent = nil
        callback?(returnCode)
    }
}
@MainActor final class NSAlert: NSObject {
    var messageText = "", informativeText = ""
    var accessoryView: NSView?
    var showsSuppressionButton = false
    var suppressionButton: NSButton? { nil }
    let window = FakeWindow()
    var completion: ((NSApplication.ModalResponse) -> Void)?
    override init() { super.init(); window.owner = self }
    @discardableResult func addButton(withTitle title: String) -> NSButton? { nil }
    func runModal() -> NSApplication.ModalResponse { check(false, "an alert ran app-modally"); return .alertSecondButtonReturn }
    func beginSheetModal(for parent: Any, completionHandler: ((NSApplication.ModalResponse) -> Void)?) {
        check(Thread.isMainThread, "alert created off main")
        guard let completionHandler else { errors += 1; return }
        prompts += 1
        completion = completionHandler
        window.sheetParent = parent as? FakeWindow
        let answer: String? = answers.isEmpty ? "secret" : answers.removeFirst()
        guard let answer else { return } // The user leaves the password sheet open.
        (accessoryView as? NSTextField)?.stringValue = answer
        DispatchQueue.main.async { self.window.sheetParent?.endSheet(self.window, returnCode: .alertFirstButtonReturn) }
    }
}

ACTIVITY

EXTRACTION

@MainActor func pumpUntil(_ ready: () -> Bool) {
    let deadline = Date(timeIntervalSinceNow: 10)
    while !ready() && deadline.timeIntervalSinceNow > 0 { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005)) }
    check(ready(), "background operation or password callback timed out")
}
@MainActor func lastThread() -> Thread { ThreadsManager.default()!.threads.lastObject as! Thread }
@MainActor func finish(_ thread: Thread) {
    pumpUntil { thread.isFinished }
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
}
func entries(_ path: String) -> [String] { (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? [] }

let arguments = CommandLine.arguments
MainActor.assumeIsolated {
    _ = NSApplication.shared
    UserDefaults.standard.setVolatileDomain(["HideZIPSuppressionMessage": true, "deleteZIPfile": false], forName: UserDefaults.argumentDomain)
    let root = arguments[1], zip = arguments[2], encrypted = arguments[3], corrupt = arguments[4], warned = arguments[6]
    let files = FileManager.default
    let working = (root as NSString).appendingPathComponent("working")
    try? files.createDirectory(atPath: working, withIntermediateDirectories: true)
    HarnessSetWorkingDirectory(working)
    let original = DicomDatabase(), other = DicomDatabase()
    original.incomingFolder = (root as NSString).appendingPathComponent("original")
    other.incomingFolder = (root as NSString).appendingPathComponent("other")
    let originalIncoming = original.incomingFolder, otherIncoming = other.incomingFolder
    for path in [originalIncoming, otherIncoming] { try? files.createDirectory(atPath: path, withIntermediateDirectories: true) }
    func stagingFolders() -> [String] {
        [originalIncoming, otherIncoming].flatMap { incoming in
            entries(incoming).filter { $0.hasPrefix(".horos-extract-") }.map { (incoming as NSString).appendingPathComponent($0) }
        }
    }
    let browser = BrowserController()
    browser.database = original
    browser.window = FakeWindow()
    let timer = Timer(timeInterval: 0.01, repeats: true) { _ in ticks += 1 }
    RunLoop.main.add(timer, forMode: .common)
    let before = Date.timeIntervalSinceReferenceDate
    browser.expandArchiveIntoIncomingFolder(zip); let first = lastThread()
    check(Date.timeIntervalSinceReferenceDate - before < 0.1, "Import blocked the main thread")
    browser.database = other
    finish(first)
    check(ticks > 0, "main loop did not respond while extraction ran")
    check(entries(originalIncoming).count == 1 && entries(otherIncoming).isEmpty, "switching database redirected extraction")
    let folder = (originalIncoming as NSString).appendingPathComponent(entries(originalIncoming)[0])
    let payload = (try? Data(contentsOf: URL(fileURLWithPath: (folder as NSString).appendingPathComponent("image.dcm")))) ?? Data()
    check(payload.count == 64 * 1024 * 1024 && payload.last == UInt8(ascii: "x"), "published incomplete data")
    let permissions = ((try? files.attributesOfItem(atPath: folder))?[.posixPermissions] as? Int) ?? 0
    check(permissions & 0o777 == 0o700, "staging lost private permissions")
    check(original.importRequests == 1 && other.importRequests == 0, "import resumed in another database")

    browser.database = original
    browser.expandArchiveIntoIncomingFolder(zip); let second = lastThread()
    browser.expandArchiveIntoIncomingFolder(zip); let third = lastThread()
    finish(second); finish(third)
    check(entries(originalIncoming).count == 3, "concurrent archives collided")

    let oldErrors = errors, oldPrompts = prompts
    browser.expandArchiveIntoIncomingFolder(corrupt); finish(lastThread())
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    check(errors == oldErrors + 1 && prompts == oldPrompts, "corrupt ZIP requested a password instead of an error")
    check(entries(originalIncoming).count == 3 && stagingFolders().isEmpty, "partial corrupt extraction was published or left behind")

    // unzip warns and ends with 1, having extracted every entry: imported, no error, no password.
    browser.expandArchiveIntoIncomingFolder(warned); finish(lastThread())
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    check(errors == oldErrors + 1 && prompts == oldPrompts && entries(originalIncoming).count == 4,
          "an archive unzip only warned about was refused")
    let warnedFolder = entries(originalIncoming).map { (originalIncoming as NSString).appendingPathComponent($0) }
        .first { files.fileExists(atPath: ($0 as NSString).appendingPathComponent("abs/IMG1.dcm")) }
    check(warnedFolder != nil && files.fileExists(atPath: (warnedFolder! as NSString).appendingPathComponent("ok/IMG2.dcm")),
          "the warned archive was not published whole")

    // A wrong password leaves the encrypted entry out of a mixed archive, also with 1.
    answers = ["wrong", "secret"]
    browser.expandArchiveIntoIncomingFolder(encrypted); finish(lastThread())
    check(prompts == oldPrompts + 2 && entries(originalIncoming).count == 5, "password retry did not extract successfully")

    // ZIP's short password check can accept an incorrect password, then fail CRC.
    let promptsBeforeCRC = prompts
    answers = [arguments[5], "secret"]
    browser.expandArchiveIntoIncomingFolder(encrypted); finish(lastThread())
    check(prompts == promptsBeforeCRC + 2 && entries(originalIncoming).count == 6,
          "password producing a CRC error did not allow another attempt")

    answers = [nil]
    let promptBefore = prompts
    browser.expandArchiveIntoIncomingFolder(encrypted); let waiting = lastThread()
    pumpUntil { prompts > promptBefore }; waiting.cancel(); finish(waiting)
    check(entries(originalIncoming).count == 6 && stagingFolders().isEmpty, "cancelling a password request leaked staging or published data")

    browser.expandArchiveIntoIncomingFolder(zip); let running = lastThread()
    pumpUntil { stagingFolders().contains { files.fileExists(atPath: ($0 as NSString).appendingPathComponent("image.dcm")) } }
    running.cancel(); finish(running)
    check(entries(originalIncoming).count == 6 && stagingFolders().isEmpty, "cancelling unzip published partial data or left staging")
    for file in [zip, encrypted, corrupt, warned] { check(files.fileExists(atPath: file), "source archive deleted") }
    timer.invalidate()
    print("PASS: Activity returns immediately; main loop, pinned database, concurrent jobs, private complete files, corrupt ZIP, archive with warnings, password retry and both cancellation paths work")
}
'''.replace('ACTIVITY', activity).replace('EXTRACTION', extraction)

with tempfile.TemporaryDirectory(prefix='horos-archive-activity-') as temporary:
    folder = Path(temporary)
    with zipfile.ZipFile(folder/'input.zip', 'w', compression=zipfile.ZIP_DEFLATED) as zipped:
        zipped.writestr('image.dcm', b'x'*(64*1024*1024))
    (folder/'image.dcm').write_bytes(b'encrypted synthetic DICOM')
    (folder/'plain.dcm').write_bytes(b'plain synthetic DICOM')
    subprocess.run(['/usr/bin/zip','-q',str(folder/'encrypted.zip'),'plain.dcm'],cwd=folder,check=True)
    subprocess.run(['/usr/bin/zip','-q','-P','secret',str(folder/'encrypted.zip'),'image.dcm'],cwd=folder,check=True)
    # Find an incorrect password accepted by ZIP's one-byte header check.
    # Use the real archive reader to select it, then confirm unzip reports 2.
    crc_password = None
    with zipfile.ZipFile(folder/'encrypted.zip') as zipped:
        for attempt in range(8192):
            candidate = f'incorrect-{attempt}'
            try:
                zipped.read('image.dcm', pwd=candidate.encode())
            except zipfile.BadZipFile:
                probe = subprocess.run(['/usr/bin/unzip','-qq','-o','-P',candidate,
                                        str(folder/'encrypted.zip'),'-d',str(folder/'probe')],
                                       stdin=subprocess.DEVNULL, capture_output=True)
                if probe.returncode == 2:
                    crc_password = candidate
                    break
            except RuntimeError:
                pass
    assert crc_password is not None, 'could not reproduce incorrect-password CRC status'
    with zipfile.ZipFile(folder/'corrupt.zip','w') as zipped:
        zipped.writestr('valid.dcm',b'valid synthetic DICOM')
        zipped.writestr('broken.dcm',b'CRC must fail')
    with zipfile.ZipFile(folder/'corrupt.zip') as zipped:
        info=zipped.getinfo('broken.dcm')
        offset=info.header_offset+30+len(info.filename.encode())+len(info.extra)
    damaged=bytearray((folder/'corrupt.zip').read_bytes());damaged[offset]^=1
    (folder/'corrupt.zip').write_bytes(damaged)
    # An entry under an absolute path and bytes before the archive: unzip warns
    # about both, extracts everything and ends with 1.
    with zipfile.ZipFile(folder/'absolute.zip','w') as zipped:
        zipped.writestr('/abs/IMG1.dcm',b'first synthetic DICOM')
        zipped.writestr('ok/IMG2.dcm',b'second synthetic DICOM')
    (folder/'warned.zip').write_bytes(b'preamble'+(folder/'absolute.zip').read_bytes())
    (folder/'Harness.h').write_text(header)
    (folder/'native.m').write_text(native)
    (folder/'main.swift').write_text(driver)
    sources = root/'Horos/Sources'
    for command in (['xcrun','clang','-c','-fblocks','-I',str(folder),'-I',str(sources),str(folder/'native.m'),'-o',str(folder/'native.o')],
                    ['xcrun','clang','-c','-fobjc-arc','-I',str(sources),str(sources/'HorosObjCException.m'),'-o',str(folder/'exception.o')],
                    ['xcrun','swiftc','-swift-version','6','-import-objc-header',str(folder/'Harness.h'),'-Xcc','-I','-Xcc',str(sources),
                     str(root/'Modules/IsiXDatabase/Sources/ImportRules.swift'),str(sources/'ArchiveImportLedger.swift'),
                     str(sources/'BrowserController+DatabaseSupport.swift'),str(folder/'main.swift'),
                     str(folder/'native.o'),str(folder/'exception.o'),'-framework','AppKit','-o',str(folder/'check')],
                    [str(folder/'check'),str(folder),str(folder/'input.zip'),str(folder/'encrypted.zip'),str(folder/'corrupt.zip'),crc_password,
                     str(folder/'warned.zip')]):
        result=subprocess.run(command,capture_output=True,text=True,timeout=300)
        if result.returncode:
            print(result.stdout);print(result.stderr);raise SystemExit(result.returncode)
        if result.stdout:print(result.stdout.strip())
