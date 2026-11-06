#!/usr/bin/env python3
"""Compile the real incoming scheduler; verify preservation, retry and warning episodes.
The worker is a scheduling probe. Full DICOM import is validated separately in the app.
An optional git revision reproduces the previous destructive scheduler.

DicomDatabase is Swift. In the checkout the scheduling is DatabaseIngest.swift,
over IsiXDatabase's IngestScheduler, on threads of ActivityThread.swift, behind
IncomingImportGate.swift: all compiled as they are, with
-updateStorageAvailabilityWarning (ImportFeedback.swift) pasted into
a stand-in DicomDatabase, in Swift 6 as the app is, and the @try of
HorosObjCException.caught (HorosObjCException.m). A pass is a real pass of the
adapter over a probe of the database, on a real thread: what it must keep is
what the timer of the main run loop did, and what it must add is that the
scheduling needs no run loop on the thread that asks.

- full volume: queued, partial and nested files stay, the pass retries, the
  warning shows once per episode, on the main thread;
- a viewer loading series postpones the pass, and quitting refuses it;
- a pass waits for the import lock a rebuild or a synchronous import holds,
  instead of being dropped;
- requests during a pass come to one more pass, also from a thread with no run
  loop, the case the old `afterDelay` never served, and an independent
  database asks for the pass of its main database;
- a remote database overrides the dynamic method, and the adapter respects that;
- the timer reaches every local database and follows the preference;
- the Dock shows the count of the database the browser works with, on the main
  thread, through the graph;
- quitting cancels a pass that is running and waits for it, through the gate.

A revision from before DatabaseIngest compiles the methods it had in an
@implementation of a DicomDatabase declared as the probe needs it, and one from
before the conversion the Objective-C of DicomDatabase.mm.
"""
import sys
sys.path.insert(0, str(__import__('pathlib').Path(__file__).resolve().parent))
import objc_exception_guards
from pathlib import Path
import shutil,subprocess,sys,tempfile
import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs
import harness_defaults  # the harness's preferences stay in its own process
import isix_modules
root=Path(__file__).resolve().parents[1]


def read(path):
    if len(sys.argv)>1:
        shown=subprocess.run(['git','-C',str(root),'show',sys.argv[1]+':'+path],capture_output=True)
        return shown.stdout.decode() if shown.returncode==0 else None
    file=root/path
    return file.read_text() if file.exists() else None


def member(text,opening,closing='\n    }\n'):
    at=text.index(opening)
    return text[at:text.index(closing,at)+len(closing)]


SWIFT_DRIVER=r'''
int main(int argc,char **argv) { @autoreleasepool {
    DicomDatabase *db=[DicomDatabase new];db.main=YES;db.incomingDirPath=[NSString stringWithUTF8String:argv[1]];
    ((BrowserController *)[BrowserController currentBrowser]).database=db;
    NSFileManager *fm=NSFileManager.defaultManager;
    [fm createDirectoryAtPath:[db.incomingDirPath stringByAppendingPathComponent:@"nested"] withIntermediateDirectories:YES attributes:nil error:NULL];
    NSArray *names=@[@"received.dcm",@"upload.dcm.part",@"nested/received2.dcm"];
    NSData *original=[@"accepted bytes including a partially written transfer" dataUsingEncoding:NSUTF8StringEncoding];
    for(NSString *name in names)check([original writeToFile:[db.incomingDirPath stringByAppendingPathComponent:name] atomically:YES],@"fixture write");
    db.full=YES;
    [db initiateImportFilesFromIncomingDirUnlessAlreadyImporting];
    [db initiateImportFilesFromIncomingDirUnlessAlreadyImporting];
    for(NSString *name in names)check([[NSData dataWithContentsOfFile:[db.incomingDirPath stringByAppendingPathComponent:name]] isEqual:original],@"full volume preserves received, partial and nested files");
    check(db.workerRequests==2,@"worker retries while storage is full");
    check(notices==1 && [lastNotice containsString:@"preserved"] && [lastNotice containsString:@"retry"],@"one actionable warning per full-volume episode");
    db.full=NO;[db initiateImportFilesFromIncomingDirUnlessAlreadyImporting];
    check(db.workerRequests==3,@"automatic retry resumes when capacity returns");
    db.full=YES;[db initiateImportFilesFromIncomingDirUnlessAlreadyImporting];
    check(notices==2,@"new capacity failure starts a new warning episode");
    check(refreshes==3,@"browser refreshes on pause, recovery and next pause only");
    loading=YES;[db initiateImportFilesFromIncomingDirUnlessAlreadyImporting];
    check(db.workerRequests==4,@"viewer loading still postpones scheduling");loading=NO;
    dispatch_semaphore_t locked=dispatch_semaphore_create(0),release=dispatch_semaphore_create(0),done=dispatch_semaphore_create(0);
    NSRecursiveLock *importLock=db.importFilesFromIncomingDirLock;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT,0),^{[importLock lock];dispatch_semaphore_signal(locked);dispatch_semaphore_wait(release,DISPATCH_TIME_FOREVER);[importLock unlock];dispatch_semaphore_signal(done);});
    dispatch_semaphore_wait(locked,DISPATCH_TIME_FOREVER);
    [db initiateImportFilesFromIncomingDirUnlessAlreadyImporting];check(db.workerRequests==4,@"existing import lock postpones scheduling");
    dispatch_semaphore_signal(release);dispatch_semaphore_wait(done,DISPATCH_TIME_FOREVER);
    db.full=NO;[db initiateImportFilesFromIncomingDirUnlessAlreadyImporting];db.full=YES;throwNotification=YES;
    @try {[db initiateImportFilesFromIncomingDirUnlessAlreadyImporting];} @catch(NSException *e) {check(NO,@"warning failure must not escape the scheduler");}
    __block BOOL lockAvailable=NO;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT,0),^{lockAvailable=[importLock tryLock];if(lockAvailable)[importLock unlock];dispatch_semaphore_signal(done);});
    dispatch_semaphore_wait(done,DISPATCH_TIME_FOREVER);check(lockAvailable,@"notification failure releases import lock");
    for(NSString *name in names)check([[NSData dataWithContentsOfFile:[db.incomingDirPath stringByAppendingPathComponent:name]] isEqual:original],@"all scheduler paths preserve queue contents");
    throwNotification=NO;
    DicomDatabase *independent=[DicomDatabase new];independent.mainDatabase=db;
    int previousNotices=notices;
    [independent updateStorageAvailabilityWarning];[db updateStorageAvailabilityWarning];
    check(notices==previousNotices,@"cleanup and independent contexts share one warning episode");
    db.full=NO;[independent updateStorageAvailabilityWarning];
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"hideListenerError"];
    db.full=YES;[independent updateStorageAvailabilityWarning];
    check(notices==previousNotices && db.incomingImportSpaceWarningShown,@"server mode suppresses notification but preserves status");
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"hideListenerError"];
    puts("PASS: queued bytes, retries, warning throttling, browser state transitions, viewer/lock guards and exception unlock");
} }
'''

SWIFT_BRIDGE=r'''
#import <Foundation/Foundation.h>
#import "HorosObjCException.h"
#pragma clang diagnostic ignored "-Wnullability-completeness"
@interface ViewerController : NSObject
+ (BOOL)areLoadingViewers;
@end
NS_SWIFT_NAME(IncomingImportGate)
@interface HorosIncomingImportGate : NSObject
@property(class, readonly) HorosIncomingImportGate *shared;
@property(readonly) BOOL isStopped;
@end
@class DicomDatabase;
@interface BrowserController : NSObject
@property(assign) DicomDatabase *database;
+ (BrowserController *)currentBrowser;
- (void)outlineViewRefresh;
@end
@interface AppController : NSObject
+ (AppController *)sharedAppController NS_SWIFT_NAME(shared());
- (void)notificationTitle:(NSString *)title description:(NSString *)description name:(NSString *)name;
@end
// The members the two methods read, and those the probe drives.
@interface DicomDatabase : NSObject
@property(retain) NSRecursiveLock *importFilesFromIncomingDirLock;
@property BOOL incomingImportSpaceWarningShown;
@property(assign) NSObject *mainDatabase;
@property(copy) NSString *incomingDirPath;
@property BOOL full;
@property BOOL main;
@property int workerRequests;
- (BOOL)isMainDatabase;
- (BOOL)isFileSystemFreeSizeLimitReached;
- (void)updateStorageAvailabilityWarning;
- (void)initiateImportFilesFromIncomingDirUnlessAlreadyImporting;
- (void)importFilesFromIncomingDirThread;
@end
void _N2LogExceptionImpl(NSException* e, BOOL logStack, const char* pf);
'''

SWIFT_PROBE=r'''
import Foundation
enum DicomDatabaseObjC {
HELPERS
}
@objc @implementation extension DicomDatabase {
    var importFilesFromIncomingDirLock: NSRecursiveLock? = NSRecursiveLock()
    var incomingImportSpaceWarningShown = false
    unowned(unsafe) var mainDatabase: NSObject? = nil
    var incomingDirPath: String? = nil
    var full = false
    var main = false
    var workerRequests: Int32 = 0
    func isMainDatabase() -> Bool { main }
    func isFileSystemFreeSizeLimitReached() -> Bool { full }
    func importFilesFromIncomingDirThread() {}
METHODS
}
'''

SWIFT_STUBS=r'''
#import "Bridge.h"
#import <dispatch/dispatch.h>
static BOOL loading, throwNotification;
static int notices, refreshes;
static NSString *lastNotice;
static void check(BOOL ok,NSString *message) { if(!ok) { NSLog(@"FAIL: %@",message);exit(1); } }
void _N2LogExceptionImpl(NSException* e, BOOL logStack, const char* pf) { NSLog(@"Caught fixture exception: %@",e); }
@implementation ViewerController
+ (BOOL)areLoadingViewers {return loading;}
@end
@implementation HorosIncomingImportGate
+ (HorosIncomingImportGate *)shared {static id gate;if(!gate)gate=[self new];return gate;}
- (BOOL)isStopped {return NO;}
@end
@implementation BrowserController
+ (BrowserController *)currentBrowser {static id browser;if(!browser)browser=[self new];return browser;}
- (void)outlineViewRefresh {}
- (void)performSelector:(SEL)sel withObject:(id)obj afterDelay:(NSTimeInterval)delay {refreshes++;}
@end
@implementation AppController
+ (AppController *)sharedAppController {static id app;if(!app)app=[self new];return app;}
- (void)notificationTitle:(NSString *)title description:(NSString *)description name:(NSString *)name {
    notices++;lastNotice=[description copy];
    if(throwNotification)[NSException raise:@"FixtureNotificationFailure" format:@"Notification unavailable"];
}
@end
// The worker the scheduler starts is counted, not run.
@implementation DicomDatabase (Probe)
- (void)performSelectorInBackground:(SEL)selector withObject:(id)object {self.workerRequests++;}
@end
'''

ACTOR_STANDINS=r'''
import AppKit
import Foundation

// What DatabaseIngest and ActivityThread use from the rest of the application.

let DicomDatabaseImageEntityName = "Image"
final class DicomFile {
    init?(_ path: String, dicomOnly: Bool) { nil }
    func element(forKey key: String) -> Any? { nil }
}
final class DicomImage: NSObject {
    static func sopInstanceUIDEncode(_ uid: String) -> Data? { nil }
    func sopInstanceUID() -> String? { nil }
    func completePath() -> String? { nil }
}

nonisolated(unsafe) var loading = false
nonisolated(unsafe) var notices = 0, refreshes = 0
nonisolated(unsafe) var lastNotice: String?
nonisolated(unsafe) var throwNotification = false

enum Probe {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var counts: [String: Int] = [:]
    static func add(_ name: String) { lock.withLock { counts[name, default: 0] += 1 } }
    static func count(_ name: String) -> Int { lock.withLock { counts[name, default: 0] } }
}

enum DicomDatabaseObjC {
HELPERS
    static func isEqual(_ string: String?, _ other: String?) -> Bool {
        guard let string, let other else { return false }
        return (string as NSString).isEqual(to: other)
    }
}

extension Thread {
    func enterOperation() {}
    func exitOperation() {}
    var status: String? { get { nil } set {} }
    var progress: CGFloat { get { 0 } set {} }
    var supportsCancel: Bool { get { false } set {} }
}

final class ThreadsManager: NSObject {
    static func `default`() -> ThreadsManager? { nil }
    func addThreadAndStart(_ thread: Thread) {}
}


final class DockProbe {
    nonisolated(unsafe) static var badgeLabel: String?
}

struct DICOMTriageMetadata {
    static func parse(_ data: Data) -> DICOMTriageMetadata? { nil }
    func string(group: UInt16, element: UInt16) -> String? { nil }
}

@MainActor final class BrowserController: NSObject {
    nonisolated(unsafe) static var current: BrowserController?
    nonisolated static func currentBrowser() -> BrowserController! { current }
    nonisolated(unsafe) var database: DicomDatabase?
    @objc func outlineViewRefresh() {}
    override func perform(_ selector: Selector, with argument: Any?, afterDelay delay: TimeInterval) { refreshes += 1 }
}

@MainActor final class AppController: NSObject {
    nonisolated(unsafe) static var instance: AppController?
    nonisolated static func shared() -> AppController! { instance }
    nonisolated func notificationTitle(_ title: String!, description: String!, name: String!) {
        notices += 1
        lastNotice = description
        if throwNotification {
            NSException(name: NSExceptionName("FixtureNotificationFailure"), reason: "Notification unavailable", userInfo: nil).raise()
        }
    }
    func setBadgeLabel(_ label: String?) {
        dispatchPrecondition(condition: .onQueue(.main))
        Probe.add("badge")
        DockProbe.badgeLabel = label
    }
}

final class ProcessGraph: Sendable {
    static let process = ProcessGraph()
    let ingestScheduler = IngestScheduler()
    var databaseIngest: DatabaseIngest { DatabaseIngest(processGraph: self) }
    var browserDatabase: DicomDatabase? { nil }
    var preferences: UserDefaults { UserDefaults.standard }
    @MainActor var viewersAreLoading: Bool {
        if !Thread.isMainThread { Probe.add("viewers asked off the main thread") }
        return loading
    }
    @MainActor var appController: AppController? { AppController.shared() }
    @MainActor var currentBrowser: BrowserController? { BrowserController.current }
}

class DicomDatabase: NSObject, @unchecked Sendable {
    nonisolated(unsafe) static var active: DicomDatabase?
    nonisolated(unsafe) static var registered: [DicomDatabase] = []
    static func activeLocal() -> DicomDatabase! { active }
    static func allDatabases() -> [Any]! { registered }

    var importFilesFromIncomingDirLock: NSRecursiveLock? = NSRecursiveLock()
    var incomingImportSpaceWarningShown = false
    weak var main: DicomDatabase?
    var mainDatabase: NSObject? { main }
    let name: String
    let incoming: String
    nonisolated(unsafe) var full = false
    nonisolated(unsafe) var files = false
    nonisolated(unsafe) var imports: (DicomDatabase) -> Int = { _ in 0 }

    init(name: String, incoming: String) {
        self.name = name
        self.incoming = incoming
    }

    var sqlFilePath: String { main?.sqlFilePath ?? name }
    func isMainDatabase() -> Bool { main == nil }
    func isLocal() -> Bool { true }
    func isFileSystemFreeSizeLimitReached() -> Bool { full }
    func incomingDirPath() -> String! { incoming }
    func incomingDirPathC() -> UnsafePointer<CChar>! { UnsafePointer(strdup(incoming)) }
    func errorsDirPath() -> String! { incoming }
    func decompressionDirPath() -> String! { incoming }
    func objects(forEntity entity: Any!, predicate: NSPredicate!) -> [Any]! { [] }
    func tempDirPathC() -> UnsafePointer<CChar>! { nil }
    func performBlockAndWait(_ block: () -> Void) { block() }
    func privateQueueIndependentDatabase() -> AnyObject! {
        let worker = DicomDatabase(name: name, incoming: incoming)
        worker.main = self
        worker.importFilesFromIncomingDirLock = importFilesFromIncomingDirLock
        worker.imports = imports
        return worker
    }
    // One per pass, on the pass's thread.
    func hasFilesToImport() -> Bool {
        Probe.add("pass \(sqlFilePath)")
        return files
    }
    func importFiles(fromIncomingDir showGUI: NSNumber!) -> Int { imports(self) }
    func importFilesFromIncomingDir() -> Int { imports(self) }
    var incomingImportInProgress: Bool { false }
    nonisolated(unsafe) var indexed: [String: Any] = [:]
    func addFilesDescribed(inDictionaries entries: [Any]!, postNotifications: Bool, rereadExistingItems: Bool, generatedByOsiriX: Bool,
                           importedFiles: Bool, returnArray: Bool) -> [Any]! { nil }
    func addFiles(atPaths paths: NSArray?, postNotifications: Bool, dicomOnly: Bool, rereadExistingItems: Bool, generatedByOsiriX: Bool,
                  importedFiles: Bool, returnArray: Bool, unindexedPaths: NSMutableArray?) -> NSArray? {
        indexed = ["post": postNotifications, "dicomOnly": dicomOnly, "reread": rereadExistingItems, "generated": generatedByOsiriX,
                   "imported": importedFiles, "returned": returnArray, "thread": Thread.current.description]
        unindexedPaths?.add("left.dcm")
        return (paths?.subarray(with: NSRange(location: 0, length: 1)) as NSArray?)
    }
    func initiateImportFilesFromIncomingDirUnlessAlreadyImporting() {
        ProcessGraph.process.databaseIngest.schedulePass(over: self)
    }
ALERTS
}

// A remote database imports nothing.
final class RemoteDatabase: DicomDatabase, @unchecked Sendable {
    override func isLocal() -> Bool { false }
    override func initiateImportFilesFromIncomingDirUnlessAlreadyImporting() {}
}
'''

ACTOR_DRIVER=r'''
import AppKit
import Foundation
SWIFT_DEFAULTS

func check(_ ok: Bool, _ message: String) {
    if !ok {
        print("FAIL: " + message)
        exit(1)
    }
}

/// The main run loop keeps running while the test waits: the warning needs it.
func spin(seconds: TimeInterval = 0.1) {
    RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
}

func eventually(_ what: String, seconds: TimeInterval = 5, _ condition: () -> Bool) {
    let end = Date(timeIntervalSinceNow: seconds)
    while !condition() && Date() < end { spin(seconds: 0.01) }
    check(condition(), what)
}

/// The scheduler has nothing running over `database`, and nothing left to run.
func idle(_ database: DicomDatabase) {
    var quiet = 0
    let end = Date(timeIntervalSinceNow: 5)
    while quiet < 10 && Date() < end {
        spin(seconds: 0.01)
        quiet = ingest.isPassRunning(over: database) ? 0 : quiet + 1
    }
    check(quiet >= 10, "the pass over \(database.sqlFilePath) did not end")
}

func passes(_ database: DicomDatabase) -> Int { Probe.count("pass \(database.sqlFilePath)") }

let folder = CommandLine.arguments[1]
let ingest = ProcessGraph.process.databaseIngest
let db = DicomDatabase(name: "db", incoming: folder)
DicomDatabase.active = db
DicomDatabase.registered = [db]
AppController.instance = MainActor.assumeIsolated { AppController() }
BrowserController.current = MainActor.assumeIsolated {
    let browser = BrowserController()
    browser.database = db
    return browser
}
try! FileManager.default.createDirectory(atPath: folder + "/nested", withIntermediateDirectories: true)
let names = ["received.dcm", "upload.dcm.part", "nested/received2.dcm"]
let original = Data("accepted bytes including a partially written transfer".utf8)
for name in names { check(FileManager.default.createFile(atPath: folder + "/" + name, contents: original), "fixture write") }
@MainActor func queueIsIntact() -> Bool { names.allSatisfy { FileManager.default.contents(atPath: folder + "/" + $0) == original } }

// A full volume keeps the queue, tries again, and says so once per episode.
db.full = true
db.initiateImportFilesFromIncomingDirUnlessAlreadyImporting()
eventually("a pass with the volume full") { passes(db) == 1 }
idle(db)
db.initiateImportFilesFromIncomingDirUnlessAlreadyImporting()
eventually("the pass retries while storage is full") { passes(db) == 2 }
idle(db)
check(queueIsIntact(), "full volume preserves received, partial and nested files")
eventually("the warning") { notices == 1 }
check(lastNotice?.contains("preserved") == true && lastNotice?.contains("retry") == true, "one actionable warning per full-volume episode")
db.full = false
db.initiateImportFilesFromIncomingDirUnlessAlreadyImporting()
eventually("automatic retry resumes when capacity returns") { passes(db) == 3 }
idle(db)
eventually("the state back on the main thread") { !db.incomingImportSpaceWarningShown }
db.full = true
db.initiateImportFilesFromIncomingDirUnlessAlreadyImporting()
eventually("a new capacity failure starts a new warning episode") { notices == 2 }
idle(db)
eventually("the browser refreshes on pause, recovery and next pause only") { refreshes == 3 }

// A viewer loading its series comes first.
loading = true
var before = passes(db)
db.initiateImportFilesFromIncomingDirUnlessAlreadyImporting()
spin(seconds: 0.2)
check(passes(db) == before, "viewer loading still postpones scheduling")
loading = false
Thread.detachNewThread { db.initiateImportFilesFromIncomingDirUnlessAlreadyImporting() }
eventually("a request from another thread") { passes(db) == before + 1 }
idle(db)
check(Probe.count("viewers asked off the main thread") == 0, "whether a viewer loads was asked away from the main thread")
before = passes(db)

// A pass waits for the lock of a rebuild or a synchronous import, and runs.
db.full = false
let lock = db.importFilesFromIncomingDirLock!
let locked = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), unlocked = DispatchSemaphore(value: 0)
let holder = Thread {
    lock.lock()
    locked.signal()
    release.wait()
    lock.unlock()
    unlocked.signal()
}
holder.start()
locked.wait()
db.initiateImportFilesFromIncomingDirUnlessAlreadyImporting()
eventually("the pass is reported while it waits for the lock") { ingest.isPassRunning(over: db) }
spin(seconds: 0.2)
check(passes(db) == before, "a pass went on with the import lock held")
db.initiateImportFilesFromIncomingDirUnlessAlreadyImporting()
release.signal()
unlocked.wait()
eventually("the pass runs once the lock is free, and the request that waited with it") { passes(db) == before + 2 }
idle(db)

// A warning that raises does not reach the scheduler.
db.full = true
throwNotification = true
let raising = passes(db)
db.initiateImportFilesFromIncomingDirUnlessAlreadyImporting()
eventually("a failed notification stops nothing") { passes(db) == raising + 1 }
idle(db)
spin(seconds: 0.1)
throwNotification = false
check(queueIsIntact(), "all scheduler paths preserve queue contents")

// The one warning of the main database, from a context that is not it.
let independent = DicomDatabase(name: "independent", incoming: folder)
independent.main = db
let previousNotices = notices
independent.updateStorageAvailabilityWarning()
db.updateStorageAvailabilityWarning()
spin(seconds: 0.1)
check(notices == previousNotices, "cleanup and independent contexts share one warning episode")
db.full = false
independent.updateStorageAvailabilityWarning()
spin(seconds: 0.1)
UserDefaults.standard.set(true, forKey: "hideListenerError")
db.full = true
independent.updateStorageAvailabilityWarning()
spin(seconds: 0.1)
check(notices == previousNotices && db.incomingImportSpaceWarningShown, "server mode suppresses notification but preserves status")
UserDefaults.standard.removeObject(forKey: "hideListenerError")
db.full = false
db.updateStorageAvailabilityWarning()
spin(seconds: 0.1)

// Requests during a pass are one more pass, from any thread, and belong to
// the main database. The scan asks from its worker, on a thread with no run
// loop: the `afterDelay` that used to ask there never fired.
db.files = true
let requested = Atomicish()
final class Atomicish: @unchecked Sendable {
    let lock = NSLock()
    var more = 3
    func take() -> Bool { lock.withLock { defer { more -= 1 }; return more > 0 } }
}
let counting = passes(db)
db.imports = { worker in
    check(!worker.isMainDatabase(), "the pass imports on a database of its own")
    check(!Thread.isMainThread, "the pass runs on the main thread")
    check(RunLoop.current.currentMode == nil, "the thread of a pass runs a run loop")
    if requested.take() {
        ProcessGraph.process.databaseIngest.requestImport(of: worker)
        ProcessGraph.process.databaseIngest.requestImport(of: worker)
    }
    return 7
}
db.initiateImportFilesFromIncomingDirUnlessAlreadyImporting()
eventually("each pass that found more led to one more") { passes(db) == counting + 4 }
idle(db)
check(passes(db) == counting + 4, "more passes than what was left to do")

// The count goes to the Dock, on the main thread, through the graph.
eventually("the Dock shows what the last pass imported") { DockProbe.badgeLabel == "7" }
db.files = false
db.imports = { _ in 0 }
ingest.requestImport()
eventually("the Dock clears when nothing was imported") { DockProbe.badgeLabel == nil }
idle(db)

// A database that is not the one the browser works with leaves the Dock alone.
let other = DicomDatabase(name: "other", incoming: folder)
other.files = true
other.imports = { _ in 5 }
ingest.requestImport(of: other)
eventually("a pass over another database") { passes(other) == 1 }
idle(other)
spin(seconds: 0.1)
check(DockProbe.badgeLabel == nil, "the Dock shows another database's count")

// A remote database imports nothing, whoever asks.
let remote = RemoteDatabase(name: "remote", incoming: folder)
ingest.requestImport(of: remote)
spin(seconds: 0.2)
check(passes(remote) == 0, "a remote database started a pass")

// The timer reaches every local database, and only those, and stops at zero.
DicomDatabase.registered = [db, remote]
UserDefaults.standard.set(1, forKey: "LISTENERCHECKINTERVAL")
let ticked = passes(db)
ingest.syncTimerWithPreferences()
eventually("the timer reached the local database twice", seconds: 8) { passes(db) >= ticked + 2 }
check(passes(remote) == 0, "the timer started a pass over a remote database")
UserDefaults.standard.set(0, forKey: "LISTENERCHECKINTERVAL")
ingest.syncTimerWithPreferences()
spin(seconds: 0.2)
idle(db)
let stopped = passes(db)
spin(seconds: 1.5)
check(passes(db) == stopped, "the timer went on with the interval at zero")

// Indexing now passes the preset's six options, on the caller's thread, and
// reads the preference then. What a cancelled pass left comes back.
let current = Thread.current.description
UserDefaults.standard.set(true, forKey: "onlyDICOM")
let indexed = ingest.indexReturningIDs(["a.dcm", "b.dcm"], preset: .upload, in: db)
check(indexed.objectIDs?.count == 1 && indexed.unindexed == ["left.dcm"], "the identifiers or what was left are not what the indexer gave")
check(db.indexed["post"] as? Bool == true && db.indexed["dicomOnly"] as? Bool == true && db.indexed["reread"] as? Bool == true
      && db.indexed["generated"] as? Bool == true && db.indexed["imported"] as? Bool == true && db.indexed["returned"] as? Bool == false,
      "the six options of the preset did not reach the indexer: \(db.indexed)")
check(db.indexed["thread"] as? String == current, "indexing now left the calling thread")
_ = ingest.indexReturningIDs(["a.dcm"], preset: .sourceCopy, in: db)
check(db.indexed["dicomOnly"] as? Bool == true, "the preference was not read")
UserDefaults.standard.set(false, forKey: "onlyDICOM")
_ = ingest.indexReturningIDs(["a.dcm"], preset: .sourceCopy, in: db)
check(db.indexed["dicomOnly"] as? Bool == false, "the preference was kept from an earlier read")
_ = ingest.indexReturningIDs(["a.dcm"], preset: .mediaScan, in: db)
check(db.indexed["post"] as? Bool == false && db.indexed["imported"] as? Bool == true, "the media preset did not reach the indexer")
check(ingest.index(["a.dcm", "b.dcm"], preset: .generated) == 1, "the port does not say how many images were added")
check(db.indexed["generated"] as? Bool == true, "the port did not pass the preset")

// Quitting cancels the pass under way, listed or not, and waits for it.
let inside = DispatchSemaphore(value: 0)
db.files = true
db.imports = { _ in
    guard let admission = IncomingImportGate.shared.admit(cancelling: Thread.current) else { return 0 }
    defer { IncomingImportGate.shared.leave(admission) }
    inside.signal()
    let end = Date(timeIntervalSinceNow: 30)
    while !Thread.current.isCancelled && Date() < end { Thread.sleep(forTimeInterval: 0.005) }
    check(Thread.current.isCancelled, "quitting did not cancel the pass")
    return 0
}
db.initiateImportFilesFromIncomingDirUnlessAlreadyImporting()
var entered = false
eventually("a pass inside the gate") {
    entered = entered || inside.wait(timeout: .now()) == .success
    return entered
}
ingest.stop()
let waited = Date()
check(IncomingImportGate.shared.waitUntilIdle(before: Date(timeIntervalSinceNow: 5)), "the cancelled pass was still inside after 5 s")
check(Date().timeIntervalSince(waited) < 1, "waiting for a cancelled pass took too long")
let refused = passes(db)
db.initiateImportFilesFromIncomingDirUnlessAlreadyImporting()
spin(seconds: 0.2)
check(passes(db) == refused, "a pass started once quitting had begun")
print("PASS: queued bytes, retries, warning episodes and browser transitions; viewer guard and quitting; a pass waits for the import lock; requests coalesce, also from a thread with no run loop; remote databases, the timer, the Dock and the gate")
'''

ingest_source=read('Horos/Sources/DatabaseIngest.swift')
if ingest_source is not None:
    # The warning is ImportFeedback's since it left DicomDatabase+ImportAlerts.swift.
    alerts=read('Horos/Sources/ImportFeedback.swift') or read('Horos/Sources/DicomDatabase+ImportAlerts.swift')
    instance=read('Horos/Sources/DicomDatabase+Instance.swift')
    standins=ACTOR_STANDINS
    if 'struct ImportFeedback' in alerts:
        # The type itself, pasted whole, with the database's log and its selector.
        feedback=alerts[alerts.index('struct ImportFeedback'):alerts.index('// The selectors of the category')]
        methods=('    let importFeedbackLog = ImportFeedbackLog()\n'
                 '    var incomingImportSpaceWarningShown: Bool { importFeedbackLog.storageWarningShown }\n'
                 +member(alerts,'    func updateStorageAvailabilityWarning() {').replace(
                     '    func updateStorageAvailabilityWarning() {','    @objc func updateStorageAvailabilityWarning() {'))
        standins=(standins.replace('    var incomingImportSpaceWarningShown = false\n','')
                  .replace('    @objc func outlineViewRefresh() {}','    @objc func outlineViewRefresh() { refreshes += 1 }')
                  +'\nenum HorosAlertPanel {\n    static func run(title: String?, message: String, defaultButton: String?, alternateButton: String?,'
                  ' otherButton: String?) -> Int { 0 }\n}\n\n'+feedback
                  +'\nstruct DicomFileIndexer {\n    let database: DicomDatabase\n'
                  '    init(database: DicomDatabase, processGraph: ProcessGraph) { self.database = database }\n'
                  '    func addFiles(atPaths paths: NSArray?, postNotifications: Bool, dicomOnly: Bool, rereadExistingItems: Bool, generatedByOsiriX: Bool,\n'
                  '                  importedFiles: Bool, returnArray: Bool, unindexedPaths: NSMutableArray?) -> NSArray? {\n'
                  '        database.addFiles(atPaths: paths, postNotifications: postNotifications, dicomOnly: dicomOnly, rereadExistingItems: rereadExistingItems,\n'
                  '                          generatedByOsiriX: generatedByOsiriX, importedFiles: importedFiles, returnArray: returnArray, unindexedPaths: unindexedPaths)\n'
                  '    }\n}\n')
    else:
        methods=(member(alerts,'    private final var mainDicomDatabase: DicomDatabase? {')
                 +member(alerts,'    func updateStorageAvailabilityWarning() {').replace(
                     '    func updateStorageAvailabilityWarning() {','    @objc func updateStorageAvailabilityWarning() {'))
    helpers=(objc_exception_guards.between('DicomDatabaseObjC')
             +member(instance,'    static func log(_ exception: NSException, stack: Bool, _ function: String) {'))
    with tempfile.TemporaryDirectory(prefix='horos-incoming-space-') as tmp:
        p=Path(tmp)
        (p/'Bridge.h').write_text('#import <Foundation/Foundation.h>\n#import "HorosObjCException.h"\nvoid _N2LogExceptionImpl(NSException* e, BOOL logStack, const char* pf);\n')
        (p/'adapter.swift').write_text(ingest_source.replace('NSApp.dockTile.badgeLabel','DockProbe.badgeLabel'))
        (p/'activity.swift').write_text(read('Horos/Sources/ActivityThread.swift'))
        (p/'gate.swift').write_text(read('Horos/Sources/IncomingImportGate.swift'))
        (p/'callbacks.swift').write_text(read('Horos/Sources/MainActorCallbacks.swift'))
        (p/'standins.swift').write_text('import IsiXContracts\nimport IsiXDatabase\nimport IsiXPreferences\n'+standins.replace('HELPERS',helpers).replace('ALERTS',methods))
        (p/'main.swift').write_text(ACTOR_DRIVER.replace('SWIFT_DEFAULTS',harness_defaults.SWIFT))
        (p/'log.m').write_text('#import <Foundation/Foundation.h>\nvoid _N2LogExceptionImpl(NSException* e, BOOL logStack, const char* pf) { NSLog(@"Caught fixture exception: %@",e); }\n')
        subprocess.run(['xcrun','clang','-c','-fobjc-arc','-I',str(root/'Horos/Sources'),str(root/'Horos/Sources/HorosObjCException.m'),'-o',str(p/'exception.o')],check=True,timeout=300)
        subprocess.run(['xcrun','clang','-c','-fobjc-arc',str(p/'log.m'),'-o',str(p/'log.o')],check=True,timeout=300)
        built=subprocess.run(['xcrun','swiftc','-swift-version','6','-module-name','Probe','-import-objc-header',str(p/'Bridge.h'),
                              '-I',str(root/'Horos/Sources'),'-module-cache-path',str(p/'cache'),
                              *isix_modules.module_flags('IsiXDatabase',p/'internal'),
                              str(p/'adapter.swift'),str(p/'activity.swift'),str(p/'gate.swift'),str(p/'callbacks.swift'),str(p/'standins.swift'),str(p/'main.swift'),
                              str(p/'exception.o'),str(p/'log.o'),'-o',str(p/'probe')],capture_output=True,text=True,timeout=300)
        if built.returncode!=0:
            print('FAIL: the adapter does not compile with its stand-ins\n'+built.stderr[-3000:])
            sys.exit(1)
        (p/'incoming').mkdir()
        ran=subprocess.run([str(p/'probe'),str(p/'incoming')],capture_output=True,text=True,timeout=120)
        print(ran.stdout[-1500:])
        if ran.returncode!=0:
            print(ran.stderr[-1500:])
            sys.exit(1)
    sys.exit(0)

incoming=read('Horos/Sources/IncomingAdmission.swift')
if incoming is not None:
    alerts=read('Horos/Sources/ImportFeedback.swift')
    instance=read('Horos/Sources/DicomDatabase+Instance.swift')
    methods=(member(alerts,'    private final var mainDicomDatabase: DicomDatabase? {')
             +member(alerts,'    func updateStorageAvailabilityWarning() {')
             +member(incoming,'    func initiateImportFilesFromIncomingDirUnlessAlreadyImporting() {'))
    helpers=(objc_exception_guards.between('DicomDatabaseObjC')
             +member(instance,'    static func log(_ exception: NSException, stack: Bool, _ function: String) {'))
    with tempfile.TemporaryDirectory(prefix='horos-incoming-space-') as tmp:
        p=Path(tmp)
        (p/'Bridge.h').write_text(SWIFT_BRIDGE)
        (p/'Probe.swift').write_text(SWIFT_PROBE.replace('HELPERS',helpers).replace('METHODS',methods))
        (p/'probe.m').write_text(SWIFT_STUBS+SWIFT_DRIVER+harness_defaults.OBJC)
        subprocess.run(['xcrun','swiftc','-parse-as-library','-module-name','Probe','-import-objc-header',str(p/'Bridge.h'),
                        '-I',str(root/'Horos/Sources'),'-c',str(p/'Probe.swift'),'-o',str(p/'swift.o')],check=True,timeout=300)
        subprocess.run(['xcrun','clang','-c','-fblocks','-I',str(p),'-I',str(root/'Horos/Sources'),str(p/'probe.m'),'-o',str(p/'probe.o')],check=True,timeout=300)
        subprocess.run(['xcrun','clang','-c','-fobjc-arc','-I',str(root/'Horos/Sources'),str(root/'Horos/Sources/HorosObjCException.m'),'-o',str(p/'exception.o')],check=True,timeout=300)
        subprocess.run(['xcrun','swiftc',str(p/'probe.o'),str(p/'swift.o'),str(p/'exception.o'),'-framework','Foundation','-o',str(p/'probe')],check=True,timeout=300)
        subprocess.run([str(p/'probe'),str(p/'incoming')],check=True,timeout=60)
    sys.exit(0)

src=read('Horos/Sources/DicomDatabase.mm')
a=src.index('- (void)updateStorageAvailabilityWarning {') if '- (void)updateStorageAvailabilityWarning {' in src else src.index('-(void)initiateImportFilesFromIncomingDirUnlessAlreadyImporting {')
b=src.index('+(void)importFilesFromIncomingDirTimerCallback:',a)
method=src[a:b]
harness=r'''
#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#define N2LogExceptionWithStackTrace(e) NSLog(@"Caught fixture exception: %@",e)
static BOOL loading, throwNotification;
static int notices, refreshes;
static NSString *lastNotice;
static void check(BOOL ok,NSString *message) { if(!ok) { NSLog(@"FAIL: %@",message);exit(1); } }
@interface ViewerController : NSObject
+ (BOOL)areLoadingViewers;
@end
@implementation ViewerController
+ (BOOL)areLoadingViewers {return loading;}
@end
@interface HorosIncomingImportGate : NSObject
+ (HorosIncomingImportGate *)shared;
- (BOOL)isStopped;
@end
@implementation HorosIncomingImportGate
+ (HorosIncomingImportGate *)shared {static id gate;if(!gate)gate=[self new];return gate;}
- (BOOL)isStopped {return NO;}
@end
@interface BrowserController : NSObject
@property(assign) id database;
+ (BrowserController *)currentBrowser;
@end
@implementation BrowserController
+ (BrowserController *)currentBrowser {static id browser;if(!browser)browser=[self new];return browser;}
- (void)performSelector:(SEL)sel withObject:(id)obj afterDelay:(NSTimeInterval)delay {refreshes++;}
@end
@interface AppController : NSObject
+ (id)sharedAppController;
- (void)notificationTitle:(NSString *)title description:(NSString *)description name:(NSString *)name;
@end
@implementation AppController
+ (id)sharedAppController {static id app;if(!app)app=[self new];return app;}
- (void)notificationTitle:(NSString *)title description:(NSString *)description name:(NSString *)name {
    notices++;lastNotice=[description copy];
    if(throwNotification)[NSException raise:@"FixtureNotificationFailure" format:@"Notification unavailable"];
}
@end
@interface DicomDatabase : NSObject { @public NSRecursiveLock *_importFilesFromIncomingDirLock; BOOL _incomingImportSpaceWarningShown; }
@property(copy) NSString *incomingDirPath;
@property BOOL full;
@property BOOL isMainDatabase;
@property(assign) DicomDatabase *mainDatabase;
- (void)updateStorageAvailabilityWarning;
@property int workerRequests;
- (BOOL)isFileSystemFreeSizeLimitReached;
- (void)initiateImportFilesFromIncomingDirUnlessAlreadyImporting;
@end
@implementation DicomDatabase
- (id)init {if((self=[super init]))_importFilesFromIncomingDirLock=[NSRecursiveLock new];return self;}
- (BOOL)isFileSystemFreeSizeLimitReached {return self.full;}
- (void)performSelectorInBackground:(SEL)selector withObject:(id)object {self.workerRequests++;}
METHOD
@end
int main(int argc,char **argv) { @autoreleasepool {
    DicomDatabase *db=[DicomDatabase new];db.isMainDatabase=YES;db.incomingDirPath=[NSString stringWithUTF8String:argv[1]];
    ((BrowserController *)[BrowserController currentBrowser]).database=db;
    NSFileManager *fm=NSFileManager.defaultManager;
    [fm createDirectoryAtPath:[db.incomingDirPath stringByAppendingPathComponent:@"nested"] withIntermediateDirectories:YES attributes:nil error:NULL];
    NSArray *names=@[@"received.dcm",@"upload.dcm.part",@"nested/received2.dcm"];
    NSData *original=[@"accepted bytes including a partially written transfer" dataUsingEncoding:NSUTF8StringEncoding];
    for(NSString *name in names)check([original writeToFile:[db.incomingDirPath stringByAppendingPathComponent:name] atomically:YES],@"fixture write");
    db.full=YES;
    [db initiateImportFilesFromIncomingDirUnlessAlreadyImporting];
    [db initiateImportFilesFromIncomingDirUnlessAlreadyImporting];
    for(NSString *name in names)check([[NSData dataWithContentsOfFile:[db.incomingDirPath stringByAppendingPathComponent:name]] isEqual:original],@"full volume preserves received, partial and nested files");
    check(db.workerRequests==2,@"worker retries while storage is full");
    check(notices==1 && [lastNotice containsString:@"preserved"] && [lastNotice containsString:@"retry"],@"one actionable warning per full-volume episode");
    db.full=NO;[db initiateImportFilesFromIncomingDirUnlessAlreadyImporting];
    check(db.workerRequests==3,@"automatic retry resumes when capacity returns");
    db.full=YES;[db initiateImportFilesFromIncomingDirUnlessAlreadyImporting];
    check(notices==2,@"new capacity failure starts a new warning episode");
    check(refreshes==3,@"browser refreshes on pause, recovery and next pause only");
    loading=YES;[db initiateImportFilesFromIncomingDirUnlessAlreadyImporting];
    check(db.workerRequests==4,@"viewer loading still postpones scheduling");loading=NO;
    dispatch_semaphore_t locked=dispatch_semaphore_create(0),release=dispatch_semaphore_create(0),done=dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT,0),^{[db->_importFilesFromIncomingDirLock lock];dispatch_semaphore_signal(locked);dispatch_semaphore_wait(release,DISPATCH_TIME_FOREVER);[db->_importFilesFromIncomingDirLock unlock];dispatch_semaphore_signal(done);});
    dispatch_semaphore_wait(locked,DISPATCH_TIME_FOREVER);
    [db initiateImportFilesFromIncomingDirUnlessAlreadyImporting];check(db.workerRequests==4,@"existing import lock postpones scheduling");
    dispatch_semaphore_signal(release);dispatch_semaphore_wait(done,DISPATCH_TIME_FOREVER);
    db.full=NO;[db initiateImportFilesFromIncomingDirUnlessAlreadyImporting];db.full=YES;throwNotification=YES;
    @try {[db initiateImportFilesFromIncomingDirUnlessAlreadyImporting];} @catch(NSException *e) {check(NO,@"warning failure must not escape the scheduler");}
    __block BOOL lockAvailable=NO;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT,0),^{lockAvailable=[db->_importFilesFromIncomingDirLock tryLock];if(lockAvailable)[db->_importFilesFromIncomingDirLock unlock];dispatch_semaphore_signal(done);});
    dispatch_semaphore_wait(done,DISPATCH_TIME_FOREVER);check(lockAvailable,@"notification failure releases import lock");
    for(NSString *name in names)check([[NSData dataWithContentsOfFile:[db.incomingDirPath stringByAppendingPathComponent:name]] isEqual:original],@"all scheduler paths preserve queue contents");
    throwNotification=NO;
    DicomDatabase *independent=[DicomDatabase new];independent.mainDatabase=db;
    int previousNotices=notices;
    [independent updateStorageAvailabilityWarning];[db updateStorageAvailabilityWarning];
    check(notices==previousNotices,@"cleanup and independent contexts share one warning episode");
    db.full=NO;[independent updateStorageAvailabilityWarning];
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"hideListenerError"];
    db.full=YES;[independent updateStorageAvailabilityWarning];
    check(notices==previousNotices && db->_incomingImportSpaceWarningShown,@"server mode suppresses notification but preserves status");
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"hideListenerError"];
    puts("PASS: queued bytes, retries, warning throttling, browser state transitions, viewer/lock guards and exception unlock");
} }
'''.replace('METHOD',method)
with tempfile.TemporaryDirectory(prefix='horos-incoming-space-') as tmp:
    p=Path(tmp);(p/'probe.m').write_text(harness + harness_defaults.OBJC)
    subprocess.run(['xcrun','clang','-fblocks','-framework','Foundation',str(p/'probe.m'),'-o',str(p/'probe')],check=True)
    subprocess.run([str(p/'probe'),str(p/'incoming')],check=True)
