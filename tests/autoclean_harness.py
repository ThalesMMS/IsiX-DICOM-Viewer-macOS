"""The stand-ins that compile the automatic cleanup outside the application.

tests/test-autoclean.py and tests/test-autoclean-equivalence.py run the
application's cleanup, its service and the Clean selectors of DicomDatabase, or
the DicomDatabase+Clean.swift of an earlier revision, on real SQLite stores,
with the real N2ManagedObjectContext (tests/n2_database_harness.py builds
N2ManagedDatabase into a library) and these stand-ins for the rest of the
application. Filesystem capacity is injected: `capacityOverride` answers it, or
`capacityMode`. A driver is Objective-C++ text put after SWIFT_IMPL, with a
`void harness_main(int argc, char **argv)`, ending in harness_defaults.OBJC.
"""
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tests'))
import n2_database_harness  # noqa: E402

SWIFT_HEADER = r'''
#import <Cocoa/Cocoa.h>
#import <CoreData/CoreData.h>
#import "HorosObjCException.h"
#import "HorosAlertPanel.h"
extern NSString *const _O2AddToDBAnywayNotification, *const _O2AddToDBAnywayCompleteNotification, *const OsirixAddToDBNotification, *const OsirixAddToDBCompleteNotification;
#ifdef __cplusplus
extern "C" {
#endif
void N2ManagedObjectContextPerformAndWait(NSManagedObjectContext *context, void (NS_NOESCAPE ^block)(void));
void harness_main(int argc, char **argv);
void harness_hold_scheduler(void);
void harness_release_scheduler(void);
void _N2LogExceptionImpl(NSException *e, BOOL logStack, const char *pf);
#ifdef __cplusplus
}
#endif
@interface AppController : NSObject
+ (AppController *)sharedAppController;
@property BOOL isSessionInactive;
@end
@interface PreferencesWindowController : NSObject
+ (PreferencesWindowController *)sharedPreferencesWindowController NS_SWIFT_NAME(sharedPreferencesWindowController());
- (void)showWindow:(id)sender;
- (void)setCurrentContextWithResourceName:(NSString *)name NS_SWIFT_NAME(setCurrentContext(withResourceName:));
@end
@interface NSThread (TestOperations)
@property CGFloat progress;
@property(retain) NSString *status;
- (void)enterOperation;
- (void)enterOperationIgnoringLowerLevels;
- (void)exitOperation;
@end
#import "N2ManagedDatabase.h"
@interface DicomStudy : NSManagedObject
@property(retain) NSNumber *lockedStudy;
@property(retain) NSString *comment, *comment2, *comment3, *comment4, *name, *studyName, *patientID, *patientUID;
@property(retain) NSDate *date, *dateAdded, *dateOpened;
@property(retain) NSSet *series;
@property(readonly) NSSet *albums;
@property(readonly) NSString *studyInstanceUID;
- (NSString *)type;
@end
@interface DicomSeries : NSManagedObject
@property(retain) NSSet *images;
@end
@interface DicomImage : NSManagedObject
- (NSString *)completePath;
- (void)setCompletePath:(NSString *)completePath;
- (NSNumber *)inDatabaseFolder;
- (void)setInDatabaseFolder:(NSNumber *)inDatabaseFolder;
@end
@interface DicomDatabase : NSObject { NSRecursiveLock *_cleanLock; BOOL _isLocal; }
@property(retain) N2ManagedObjectContext *managedObjectContext;
@property(retain) NSString *dataBaseDirPath;
@property(readonly) NSString *sqlFilePath;
@property BOOL isReadOnly;
+ (NSArray *)allDatabases;
- (BOOL)isLocal;
- (void)setIsLocal:(BOOL)isLocal;
- (BOOL)isMainDatabase;
- (id)mainDatabase;
- (id)independentDatabase;
- (id)privateQueueIndependentDatabase;
- (void)performBlockAndWait:(void (^)(void))block;
- (id)studyEntity;
- (id)logEntryEntity;
- (NSArray *)objectsForEntity:(id)entity;
- (NSArray *)objectsForEntity:(id)entity predicate:(NSPredicate *)predicate;
- (BOOL)tryLock;
- (void)lock;
- (void)unlock;
- (void)updateStorageAvailabilityWarning;
@end
@interface DicomDatabase (SwiftIvars)
@property(nonatomic, retain) NSRecursiveLock *cleanLock;
@end
'''
SWIFT_IMPL = r'''
#import "harness.h"
#import <objc/runtime.h>
#include <unistd.h>
#include <errno.h>
NSString *const _O2AddToDBAnywayNotification=@"refresh1", *const _O2AddToDBAnywayCompleteNotification=@"refresh2", *const OsirixAddToDBNotification=@"refresh3", *const OsirixAddToDBCompleteNotification=@"refresh4";
static BOOL rejectDeletion, rejectEligibility;
static int measurements, capacityMode;
static NSString *fixtureDirectory;
static NSDictionary *(^capacityOverride)(void);
static NSMutableArray *deletedStudies;
static NSThread *deletingThread;
static void check(BOOL ok, NSString *message) { if (!ok) { NSLog(@"FAIL: %@",message); exit(1); } }
void _N2LogExceptionImpl(NSException *e, BOOL logStack, const char *pf) { NSLog(@"Exception: %@", e); }
@interface NSFileManager (CapacityFixture)
- (NSDictionary *)fixtureAttributes:(NSString *)path error:(NSError **)error;
@end
@implementation NSFileManager (CapacityFixture)
- (NSDictionary *)fixtureAttributes:(NSString *)path error:(NSError **)error {
    if (![path hasPrefix:fixtureDirectory]) return [self fixtureAttributes:path error:error];
    measurements++;
    if (capacityOverride) return capacityOverride();
    if (capacityMode==1 && measurements>1) return nil;
    return @{NSFileSystemSize:@(1000ULL*1024*1024), NSFileSystemFreeSize:@(((capacityMode==2 && measurements>1) || (capacityMode==3 && measurements>2) ? 200ULL:0ULL)*1024*1024)};
}
@end
@implementation AppController
@synthesize isSessionInactive;
+ (AppController *)sharedAppController { static id app; if (!app) app=[self new]; return app; }
@end
@implementation PreferencesWindowController
+ (PreferencesWindowController *)sharedPreferencesWindowController { static id controller; if (!controller) controller=[self new]; return controller; }
- (void)showWindow:(id)sender {}
- (void)setCurrentContextWithResourceName:(NSString *)name {}
@end
@implementation HorosAlertPanel
+ (NSInteger)defaultResponse { return HorosAlertDefaultResponse; }
+ (NSInteger)alternateResponse { return HorosAlertAlternateResponse; }
+ (NSInteger)otherResponse { return HorosAlertOtherResponse; }
+ (NSInteger)runWithTitle:(NSString *)t message:(NSString *)m defaultButton:(NSString *)d alternateButton:(NSString *)a otherButton:(NSString *)o { return NSAlertDefaultReturn; }
+ (NSInteger)runInformationalWithTitle:(NSString *)t message:(NSString *)m defaultButton:(NSString *)d alternateButton:(NSString *)a otherButton:(NSString *)o { return NSAlertDefaultReturn; }
+ (NSInteger)runCriticalWithTitle:(NSString *)t message:(NSString *)m defaultButton:(NSString *)d alternateButton:(NSString *)a otherButton:(NSString *)o { return NSAlertDefaultReturn; }
@end
@implementation NSThread (TestOperations)
- (void)enterOperation {} - (void)enterOperationIgnoringLowerLevels {} - (void)exitOperation {}
- (CGFloat)progress { return 0; } - (void)setProgress:(CGFloat)p {}
- (NSString *)status { return nil; } - (void)setStatus:(NSString *)s {}
@end
@interface DicomStudy ()
@end
@implementation DicomStudy
@dynamic lockedStudy, comment2, comment3, comment4, name, studyName, patientID, patientUID, date, dateAdded, dateOpened, series;
- (NSString *)comment {
    if (rejectEligibility && [self.patientUID isEqual:@"patient0002"])
        [NSException raise:@"FixtureEligibilityFailure" format:@"Cannot evaluate study comments"];
    [self willAccessValueForKey:@"comment"];
    NSString *comment=[self primitiveValueForKey:@"comment"];
    [self didAccessValueForKey:@"comment"];
    return comment;
}
- (void)setComment:(NSString *)comment {
    [self willChangeValueForKey:@"comment"];
    [self setPrimitiveValue:comment forKey:@"comment"];
    [self didChangeValueForKey:@"comment"];
}
- (NSString *)type { return @"Study"; }
- (NSString *)studyInstanceUID { return self.patientUID; }
- (NSSet *)albums {
    if (!self.entity.relationshipsByName[@"albums"]) return [self.patientID isEqual:@"album"] ? [NSSet setWithObject:@1] : [NSSet set];
    [self willAccessValueForKey:@"albums"];
    NSSet *albums=[self primitiveValueForKey:@"albums"];
    [self didAccessValueForKey:@"albums"];
    return albums;
}
- (BOOL)validateForDelete:(NSError **)error {
    if (rejectDeletion) { if (error) *error=[NSError errorWithDomain:@"Fixture" code:1 userInfo:nil]; return NO; }
    deletingThread=[NSThread currentThread];
    [deletedStudies addObject:[self primitiveValueForKey:@"studyName"] ?: NSNull.null];
    return [super validateForDelete:error];
}
@end
@implementation DicomSeries
@dynamic images;
@end
@interface DicomImage ()
@property(retain) NSNumber *inDatabaseFolder;
@end
@implementation DicomImage
@dynamic inDatabaseFolder;
- (NSString *)completePath {
    [self willAccessValueForKey:@"completePath"];
    NSString *path=[self primitiveValueForKey:@"completePath"];
    [self didAccessValueForKey:@"completePath"];
    return path.isAbsolutePath ? path : [fixtureDirectory stringByAppendingPathComponent:path];
}
- (void)setCompletePath:(NSString *)completePath {
    [self willChangeValueForKey:@"completePath"];
    [self setPrimitiveValue:completePath forKey:@"completePath"];
    [self didChangeValueForKey:@"completePath"];
}
@end
@interface DicomDatabase (UnderTest)
- (void)cleanForFreeSpaceMB:(NSInteger)mb;
- (void)cleanOldStuff;
- (NSDictionary *)automaticCleanupPreview;
- (NSInteger)cleanupThresholdForAttributes:(NSDictionary *)attributes;
- (void)cleanForFreeSpace;
- (void)initiateCleanUnlessAlreadyCleaning;
@end
@implementation DicomDatabase
@synthesize managedObjectContext, dataBaseDirPath, isReadOnly;
- (id)init { if ((self=[super init])) { _cleanLock=[NSRecursiveLock new]; self.isLocal=YES; } return self; }
- (NSString *)sqlFilePath { return self.dataBaseDirPath; }
+ (NSArray *)allDatabases { return @[]; }
- (BOOL)isLocal { return _isLocal; }
- (void)setIsLocal:(BOOL)isLocal { _isLocal=isLocal; }
- (BOOL)isMainDatabase { return YES; }
- (id)mainDatabase { return self; }
- (id)independentDatabase { return self; }
- (id)privateQueueIndependentDatabase { return self; }
- (void)performBlockAndWait:(void (^)(void))block { N2ManagedObjectContextPerformAndWait(self.managedObjectContext, block); }
- (void)lock { [self.managedObjectContext lock]; }
- (BOOL)tryLock { return [self.managedObjectContext tryLock]; }
- (void)unlock { [self.managedObjectContext unlock]; }
- (id)logEntryEntity { return @"LogEntry"; }
- (NSArray *)objectsForEntity:(id)entity predicate:(NSPredicate *)predicate { return @[]; }
- (id)studyEntity { return @"Study"; }
- (NSArray *)objectsForEntity:(id)entity { return [self.managedObjectContext executeFetchRequest:[NSFetchRequest fetchRequestWithEntityName:entity] error:NULL]; }
- (void)updateStorageAvailabilityWarning {}
@end
@implementation DicomDatabase (SwiftIvars)
- (NSRecursiveLock *)cleanLock { return _cleanLock; }
- (void)setCleanLock:(NSRecursiveLock *)cleanLock { [_cleanLock autorelease]; _cleanLock=[cleanLock retain]; }
@end
// The overrides of RemoteDicomDatabase, which count what reaches them.
static int remoteSpaceCleans, remoteOldStuffCleans, remoteInitiations;
@interface RemoteStandIn : DicomDatabase
@end
@implementation RemoteStandIn
- (void)cleanForFreeSpaceMB:(NSInteger)mb { remoteSpaceCleans++; }
- (void)cleanOldStuff { remoteOldStuffCleans++; }
- (void)initiateCleanUnlessAlreadyCleaning { remoteInitiations++; }
@end
'''
# What the Swift of the cleanup asks of the application. The application's
# ProtectedMode and the main-thread post of Nitrogen are not in the harness:
# protected mode is off, and the post is synchronous.
SWIFT_MAIN = r'''import Foundation
enum ProtectedMode { static var isActive: Bool { false }; static func skip(_ what: String) {} }
extension NotificationCenter { func postNotificationOnMainThread(name: NSString, object: Any?, userInfo: NSDictionary?) { post(name: Notification.Name(name as String), object: object, userInfo: userInfo as? [AnyHashable: Any]) } }
final class ProcessGraph: Sendable {
    static let process = ProcessGraph()
    var preferences: UserDefaults { .standard }
    var isSessionInactive: Bool { false }
}
func onMainRunLoop(_ body: @escaping @MainActor @Sendable () -> Void) {
    let mainRunLoop = CFRunLoopGetMain()
    CFRunLoopPerformBlock(mainRunLoop, CFRunLoopMode.commonModes.rawValue) { MainActor.assumeIsolated(body) }
    CFRunLoopWakeUp(mainRunLoop)
}
enum ActivityThread {
    static func startUnlisted(name: String, _ body: @escaping @Sendable (_ listInActivity: @Sendable () -> Void) -> Void) {
        let thread = Thread { body {} }
        thread.name = name
        thread.start()
    }
}
'''

# Keeps the scheduler's actor busy, so that a test can see what does not wait for it.
HOLD_SCHEDULER = r'''
import IsiXDatabase
extension CleanupScheduler { func hold(entered: DispatchSemaphore, until released: DispatchSemaphore) { entered.signal(); released.wait() } }
nonisolated(unsafe) let schedulerReleased = DispatchSemaphore(value: 0)
@_cdecl("harness_hold_scheduler") func holdScheduler() {
    let entered = DispatchSemaphore(value: 0)
    let scheduler = DatabaseCleanupService.scheduler
    nonisolated(unsafe) let enteredBox = entered
    Task.detached { await scheduler.hold(entered: enteredBox, until: schedulerReleased) }
    entered.wait()
}
@_cdecl("harness_release_scheduler") func releaseScheduler() { schedulerReleased.signal() }
'''

CURRENT_SOURCES = (ROOT / 'Horos/Sources/DicomDatabase+Clean.swift', ROOT / 'Horos/Sources/DatabaseCleanupService.swift')


def library(folder):
    """The N2ManagedDatabase library in `folder`/n2, built once per test."""
    return n2_database_harness.library(Path(folder) / 'n2')


def compile_objc(folder, driver, library_folder):
    """The stand-ins and `driver` as an object file in `folder`, with the header Swift imports."""
    folder = Path(folder)
    folder.mkdir(parents=True, exist_ok=True)
    (folder / 'harness.h').write_text(SWIFT_HEADER)
    (folder / 'test.mm').write_text(SWIFT_IMPL + driver)
    subprocess.run(['xcrun', 'clang++', '-DNDEBUG', '-fblocks', '-fobjc-exceptions', '-Wno-deprecated-declarations', '-iquote', str(folder),
                    '-I', str(library_folder), '-c', str(folder / 'test.mm'), '-o', str(folder / 'test.o')], check=True)


def compile_swift(folder, sources, library_folder, archives, modules=None, main=SWIFT_MAIN):
    """The executable `folder`/test: `sources` and the stand-ins, with the
    object file of compile_objc. `modules` is the folder of the internal modules
    they import, that of the library unless a test built its own."""
    folder = Path(folder)
    (folder / 'main.swift').write_text(main + 'harness_main(CommandLine.argc, CommandLine.unsafeArgv)\nexit(0)\n')
    subprocess.run(['xcrun', 'swiftc', '-module-name', 'Horos', '-import-objc-header', str(folder / 'harness.h'),
                    '-Xcc', '-iquote', '-Xcc', str(folder), '-Xcc', '-I', '-Xcc', str(library_folder),
                    '-I', str(modules or Path(library_folder) / 'modules'),
                    *map(str, sources), str(folder / 'main.swift'), str(folder / 'test.o'), *archives,
                    '-lc++', '-framework', 'Cocoa', '-framework', 'CoreData', '-o', str(folder / 'test')], check=True)
    return folder / 'test'
