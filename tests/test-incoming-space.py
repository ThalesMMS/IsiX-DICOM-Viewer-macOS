#!/usr/bin/env python3
"""Compile the real incoming scheduler; verify preservation, retry and warning episodes.
The worker is a scheduling probe. Full DICOM import is validated separately in the app.
An optional git revision reproduces the previous destructive scheduler.

DicomDatabase is Swift: -initiateImportFilesFromIncomingDirUnlessAlreadyImporting
(DicomDatabase+IncomingImport.swift) and -updateStorageAvailabilityWarning
(DicomDatabase+ImportAlerts.swift) are compiled as they are, in an
@implementation of a DicomDatabase declared as the probe needs it, with the
@try of DicomDatabaseObjC.attempt (HorosObjCException.m). A revision from
before the move has DicomDatabase.mm, whose Objective-C methods are compiled
instead.
"""
from pathlib import Path
import subprocess,sys,tempfile
import harness_defaults  # the harness's preferences stay in its own process
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

incoming=read('Horos/Sources/DicomDatabase+IncomingImport.swift')
if incoming is not None:
    alerts=read('Horos/Sources/DicomDatabase+ImportAlerts.swift')
    instance=read('Horos/Sources/DicomDatabase+Instance.swift')
    methods=(member(alerts,'    private final var mainDicomDatabase: DicomDatabase? {')
             +member(alerts,'    func updateStorageAvailabilityWarning() {')
             +member(incoming,'    func initiateImportFilesFromIncomingDirUnlessAlreadyImporting() {'))
    helpers=(member(instance,'    static func attempt(_ body: () -> Void) -> NSException? {')
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
