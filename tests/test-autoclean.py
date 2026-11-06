#!/usr/bin/env python3
"""Run the production date/space cleaners and transaction code against temporary SQLite stores.
Pass a git revision to demonstrate the old failures. Filesystem capacity is injected;
actual image files, Core Data deletion validation, saves and rollbacks are exercised.

The cleanup is Swift: DicomDatabase+Clean.swift, its selectors, and
DatabaseCleanupService.swift are compiled against the stand-ins of
tests/autoclean_harness.py, and run the same checks, with the real
N2ManagedObjectContext. A revision given on the command line is read as the
Objective-C of that time, N2ManagedDatabase.mm included.

Two scenarios only the Swift has:
- remote-overrides: the forwarders of a database that overrides what
  RemoteDicomDatabase overrides reach those overrides, and nothing is deleted;
- space-synchronous: -cleanForFreeSpace deletes on the calling thread, reads the
  free space again after the deletion, and returns while the actor of the
  scheduler is held busy, as it must for an import that holds the writer gate.
"""
from pathlib import Path
import subprocess, sys, tempfile
root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'tests'))
from sources import source_path  # noqa: E402
import autoclean_harness  # noqa: E402
import harness_defaults  # the harness's preferences stay in its own process
revision = sys.argv[1] if len(sys.argv) > 1 else None
# Deleting a series asks VRController for the file of its scissors state on the
# thread of the context, and Swift stops a main-actor method called from there.
if revision is None and 'public nonisolated static func getUniqueFilenameScissorState(' not in (root / 'Horos/Sources/VRController+State.swift').read_text():
    raise SystemExit('FAILED: the state file of a series is not reachable from the thread that deletes it')
# The modal loop of a warning serves neither the main queue nor the main actor
# when it runs inside one of their blocks, so the warnings come from the run loop.
if revision is None:
    service = (root / 'Horos/Sources/DatabaseCleanupService.swift').read_text()
    for warning in ('showLimitSoonReachedWarning', 'showNoStudiesToDeleteWarning'):
        if f'onMainRunLoop {{ Self.{warning}(processGraph) }}' not in service:
            raise SystemExit(f'FAILED: {warning} does not come from the main run loop')
def source(path):
    return (subprocess.check_output(['git', 'show', f'{revision}:{path}']).decode()
            if revision else (root / path).read_text())
swift = revision is None and source_path('DicomDatabase+Clean').suffix == '.swift'
if not swift:
    clean = source('Horos/Sources/DicomDatabase+Clean.mm')
    clean = (clean[clean.index('// Both the preview') if '// Both the preview' in clean else clean.index('-(void)cleanOldStuff'):(clean.index('static BOOL _showingClean') if 'static BOOL _showingClean' in clean else clean.index('-(void)cleanForFreeSpace {'))] +
             clean[clean.index('-(void)cleanForFreeSpaceMB:'):clean.rindex('@end')])
context = ''
if not swift:
    # The context of that revision, with the queue helper its methods call.
    context = source('Nitrogen/Sources/N2ManagedDatabase.mm')
    context = (context[context.index('void N2ManagedObjectContextPerformAndWait'):context.index('@implementation N2ManagedObjectContext')] +
               context[context.index('- (void)performAfterSuccessfulSave:'):context.index('-(NSManagedObject*)existingObjectWithID:')])
harness = r'''
#import <Cocoa/Cocoa.h>
#import <CoreData/CoreData.h>
#import <objc/runtime.h>
#include <unistd.h>
#include <errno.h>
#define MAXSTUDYDELETE 50
#define N2LogExceptionWithStackTrace(e) NSLog(@"Exception: %@", e)
static NSString *_O2AddToDBAnywayNotification=@"refresh1", *_O2AddToDBAnywayCompleteNotification=@"refresh2", *OsirixAddToDBNotification=@"refresh3", *OsirixAddToDBCompleteNotification=@"refresh4";
static BOOL _cleanForFreeSpaceLimitSoonReachedDisplayed;
static BOOL rejectDeletion, rejectEligibility;
static int measurements, capacityMode;
static NSString *fixtureDirectory;
static void check(BOOL ok, NSString *message) { if (!ok) { NSLog(@"FAIL: %@",message); exit(1); } }
@interface NSFileManager (CapacityFixture)
- (NSDictionary *)fixtureAttributes:(NSString *)path error:(NSError **)error;
@end
@implementation NSFileManager (CapacityFixture)
- (NSDictionary *)fixtureAttributes:(NSString *)path error:(NSError **)error {
    if (![path isEqual:fixtureDirectory]) return [self fixtureAttributes:path error:error];
    measurements++;
    if (capacityMode==1 && measurements>1) return nil;
    return @{NSFileSystemSize:@(1000ULL*1024*1024), NSFileSystemFreeSize:@((capacityMode==2 && measurements>1 ? 200ULL:0ULL)*1024*1024)};
}
@end
@interface AppController : NSObject
+ (id)sharedAppController;
- (BOOL)isSessionInactive;
@end
@implementation AppController
+ (id)sharedAppController { static id app; if (!app) app=[self new]; return app; }
- (BOOL)isSessionInactive { return NO; }
@end
@interface NSThread (TestOperations)
@property double progress;
- (void)enterOperation;
- (void)exitOperation;
@end
@implementation NSThread (TestOperations)
- (void)enterOperation {} - (void)exitOperation {} - (double)progress { return 0; } - (void)setProgress:(double)p {}
@end
@interface N2ManagedObjectContext : NSManagedObjectContext {
    NSMutableArray *_afterSuccessfulSaveActions, *_nextSuccessfulSaveActions, *_discardedChangesActions;
    BOOL _defersSaves, _atomicChangesCancelled;
}
@property(readonly) BOOL defersSaves;
- (BOOL)performAtomicChanges:(BOOL (^)(NSError **))changes error:(NSError **)error;
@end
@implementation N2ManagedObjectContext
CONTEXT
@end
@interface DicomStudy : NSManagedObject
@property(retain) NSNumber *lockedStudy;
@property(retain) NSString *comment, *comment2, *comment3, *comment4, *studyName, *patientID, *patientUID;
@property(retain) NSDate *date, *dateAdded, *dateOpened;
@property(retain) NSSet *series;
- (NSSet *)albums;
- (NSString *)type;
- (NSString *)studyInstanceUID;
@end
@implementation DicomStudy
@dynamic lockedStudy, comment, comment2, comment3, comment4, studyName, patientID, patientUID, date, dateAdded, dateOpened, series;
- (id)valueForKey:(NSString *)key {
    if (rejectEligibility && [key isEqual:@"comment"] && [self.patientUID isEqual:@"patient0002"])
        [NSException raise:@"FixtureEligibilityFailure" format:@"Cannot evaluate study comments"];
    return [super valueForKey:key];
}
- (NSString *)type { return @"Study"; }
- (NSString *)studyInstanceUID { return self.patientUID; }
- (NSSet *)albums { return [self.patientID isEqual:@"album"] ? [NSSet setWithObject:@1] : [NSSet set]; }
- (BOOL)validateForDelete:(NSError **)error {
    if (rejectDeletion) { if (error) *error=[NSError errorWithDomain:@"Fixture" code:1 userInfo:nil]; return NO; }
    return [super validateForDelete:error];
}
@end
@interface DicomSeries : NSManagedObject
@property(retain) NSSet *images;
@end
@implementation DicomSeries
@dynamic images;
@end
@interface DicomImage : NSManagedObject
@property(retain) NSString *completePath;
@property(retain) NSNumber *inDatabaseFolder;
@end
@implementation DicomImage
@dynamic completePath, inDatabaseFolder;
@end
@interface DicomDatabase : NSObject { NSRecursiveLock *_cleanLock; }
@property(retain) N2ManagedObjectContext *managedObjectContext;
@property(retain) NSString *dataBaseDirPath;
@property BOOL isReadOnly, isLocal;
- (id)studyEntity;
- (NSArray *)objectsForEntity:(id)entity;
- (BOOL)save:(NSError **)error;
- (void)cleanForFreeSpaceMB:(NSInteger)mb;
- (void)cleanOldStuff;
- (NSDictionary *)automaticCleanupPreview;
- (NSInteger)cleanupThresholdForAttributes:(NSDictionary *)attributes;
- (void)cleanForFreeSpace;
- (BOOL)tryLock;
- (void)lock;
- (void)unlock;
- (id)logEntryEntity;
- (NSArray *)objectsForEntity:(id)entity predicate:(NSPredicate *)predicate;
- (void)save;
@end
@implementation DicomDatabase
- (id)init { if ((self=[super init])) { _cleanLock=[NSRecursiveLock new]; self.isLocal=YES; } return self; }
- (void)cleanForFreeSpace {} // Space path is exercised separately.
- (void)lock { [self.managedObjectContext lock]; }
- (BOOL)tryLock { return [self.managedObjectContext tryLock]; }
- (void)unlock { [self.managedObjectContext unlock]; }
- (id)logEntryEntity { return @"LogEntry"; }
- (NSArray *)objectsForEntity:(id)entity predicate:(NSPredicate *)predicate { return @[]; }
- (void)save { [self save:NULL]; }
- (id)studyEntity { return @"Study"; }
- (NSArray *)objectsForEntity:(id)entity { return [self.managedObjectContext executeFetchRequest:[NSFetchRequest fetchRequestWithEntityName:entity] error:NULL]; }
- (BOOL)save:(NSError **)error { return [self.managedObjectContext save:error]; }
- (void)_cleanForFreeSpaceLimitSoonReachedWarning {}
- (void)_cleanDisplayWarningAboutTryingToDeleteRecentlyAddedStudy {}
CLEAN
@end
static NSAttributeDescription *attr(NSString *name, NSAttributeType type) {
    NSAttributeDescription *a=[NSAttributeDescription new];a.name=name;a.attributeType=type;a.optional=YES;return a;
}
static NSRelationshipDescription *rel(NSString *name, NSEntityDescription *dest) {
    NSRelationshipDescription *r=[NSRelationshipDescription new];r.name=name;r.destinationEntity=dest;r.minCount=0;r.maxCount=0;r.optional=YES;r.deleteRule=NSCascadeDeleteRule;return r;
}
int main(int argc, char **argv) { @autoreleasepool {
    NSString *mode=[NSString stringWithUTF8String:argv[1]];
    BOOL dateMode=[mode hasPrefix:@"date-"];
    fixtureDirectory=[NSString stringWithUTF8String:argv[2]];
    method_exchangeImplementations(class_getInstanceMethod(NSFileManager.class,@selector(attributesOfFileSystemForPath:error:)),class_getInstanceMethod(NSFileManager.class,@selector(fixtureAttributes:error:)));
    NSManagedObjectModel *model=[NSManagedObjectModel new];
    NSEntityDescription *study=[NSEntityDescription new], *series=[NSEntityDescription new], *image=[NSEntityDescription new];
    study.name=@"Study";study.managedObjectClassName=@"DicomStudy";
    series.name=@"Series";series.managedObjectClassName=@"DicomSeries";
    image.name=@"Image";image.managedObjectClassName=@"DicomImage";
    NSMutableArray *props=[NSMutableArray array];
    for (NSString *key in @[@"comment",@"comment2",@"comment3",@"comment4",@"name",@"studyName",@"patientID",@"patientUID"]) [props addObject:attr(key,NSStringAttributeType)];
    for (NSString *key in @[@"date",@"dateAdded",@"dateOpened"]) [props addObject:attr(key,NSDateAttributeType)];
    [props addObject:attr(@"lockedStudy",NSBooleanAttributeType)];[props addObject:rel(@"series",series)];study.properties=props;
    series.properties=@[rel(@"images",image)];image.properties=@[attr(@"completePath",NSStringAttributeType),attr(@"inDatabaseFolder",NSBooleanAttributeType)];model.entities=@[study,series,image];
    NSPersistentStoreCoordinator *psc=[[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:model];
    check([psc addPersistentStoreWithType:NSSQLiteStoreType configuration:nil URL:[NSURL fileURLWithPath:[fixtureDirectory stringByAppendingPathComponent:@"index.sqlite"]] options:nil error:NULL]!=nil,@"create SQLite");
    N2ManagedObjectContext *ctx=[[N2ManagedObjectContext alloc] initWithConcurrencyType:NSConfinementConcurrencyType];ctx.persistentStoreCoordinator=psc;
    DicomDatabase *db=[mode isEqual:@"remote-overrides"]?[NSClassFromString(@"RemoteStandIn") new]:[DicomDatabase new];db.managedObjectContext=ctx;db.dataBaseDirPath=fixtureDirectory;
    int count=[mode hasSuffix:@"batch"]?55:3;
    NSMutableArray *paths=[NSMutableArray array];
    for(int i=0;i<count;i++) {
        DicomStudy *s=[NSEntityDescription insertNewObjectForEntityForName:@"Study" inManagedObjectContext:ctx];
        s.date=s.dateAdded=[NSDate dateWithTimeIntervalSinceNow:-86400*(i+1)];s.lockedStudy=@NO;
        s.patientUID=[NSString stringWithFormat:@"patient%04d",i];
        if (dateMode) s.date=s.dateAdded=[NSDate dateWithTimeIntervalSinceNow:-86400*(i+20)];
        if ([mode isEqual:@"date-recent"]) s.dateAdded=[NSDate date];
        if ([mode isEqual:@"date-group-recent"]) { s.patientUID=@"same-patient"; if(i==2)s.date=[NSDate date]; }
        if ([mode isEqual:@"date-batch"]) s.patientUID=@"same-patient";
        DicomSeries *se=[NSEntityDescription insertNewObjectForEntityForName:@"Series" inManagedObjectContext:ctx];
        DicomImage *im=[NSEntityDescription insertNewObjectForEntityForName:@"Image" inManagedObjectContext:ctx];
        im.inDatabaseFolder=@NO;
        im.completePath=[fixtureDirectory stringByAppendingPathComponent:[NSString stringWithFormat:@"image%d.dcm",i]];
        check([[@"original pixels" dataUsingEncoding:NSUTF8StringEncoding] writeToFile:im.completePath atomically:YES],@"create original");[paths addObject:im.completePath];
        se.images=[NSSet setWithObject:im];s.series=[NSSet setWithObject:se];
        if ([mode hasSuffix:@"protected"]) { if(i==0)s.lockedStudy=@YES; if(i==1)s.patientID=@"album"; if(i==2)s.comment=@"keep"; }
    }
    check([ctx save:NULL],@"initial durable index");
    [NSUserDefaults.standardUserDefaults setBool:YES forKey:@"dontDeleteStudiesWithComments"];
    rejectDeletion=[mode hasSuffix:@"save-failure"];
    NSUserDefaults *defaults=NSUserDefaults.standardUserDefaults;
    [defaults setInteger:30 forKey:@"LOGCLEANINGDAYS"];
    [defaults setInteger:2 forKey:@"AUTOCLEANINGDATEPRODUCEDDAYS"];
    [defaults setInteger:2 forKey:@"AUTOCLEANINGDATEOPENEDDAYS"];
    [defaults setBool:dateMode && ![mode isEqual:@"date-disabled"] forKey:@"AUTOCLEANINGDATE"];
    [defaults setBool:YES forKey:@"AUTOCLEANINGDATEPRODUCED"];
    [defaults setBool:NO forKey:@"AUTOCLEANINGDATEOPENED"];
    [defaults setBool:![mode isEqual:@"date-keep-linked"] forKey:@"AUTOCLEANINGDELETEORIGINAL"];
    [defaults setBool:NO forKey:@"AUTOCLEANINGCOMMENTS"];
    [defaults setBool:!dateMode forKey:@"AUTOCLEANINGSPACE"];
    [defaults setObject:@"100" forKey:@"AUTOCLEANINGSPACESIZE"];
    rejectEligibility=[mode isEqual:@"date-eligibility-failure"];
    capacityMode=[mode isEqual:@"space-failure"]?1:([mode isEqual:@"target"]?2:([mode isEqual:@"space-synchronous"]?3:0));
    if ([mode hasSuffix:@"dirty"]) [[db objectsForEntity:@"Study"][0] setComment:@"unrelated pending edit"];
    db.isReadOnly=[mode isEqual:@"readonly"];
    db.isLocal=![mode isEqual:@"remote"] && ![mode isEqual:@"remote-overrides"];
    __block int notifications=0;
    id token=[NSNotificationCenter.defaultCenter addObserverForName:_O2AddToDBAnywayNotification object:db queue:nil usingBlock:^(NSNotification *n){notifications++;}];
    if ([db respondsToSelector:@selector(cleanupThresholdForAttributes:)]) {
        NSDictionary *capacity=@{NSFileSystemSize:@(1000ULL*1048576)};
        [defaults setObject:@"-10" forKey:@"AUTOCLEANINGSPACESIZE"];
        check([db cleanupThresholdForAttributes:capacity]==100,@"percentage threshold uses volume capacity");
        for (NSString *value in @[@"0",@"1e309",@"1e30"]) {
            [defaults setObject:value forKey:@"AUTOCLEANINGSPACESIZE"];
            check([db cleanupThresholdForAttributes:capacity]==0,@"invalid threshold cannot trigger cleanup");
        }
        [defaults setObject:@"100" forKey:@"AUTOCLEANINGSPACESIZE"];
    }
    if ([db respondsToSelector:@selector(automaticCleanupPreview)]) {
        BOOL dirtyBefore=ctx.hasChanges;
        NSDictionary *preview=[db automaticCleanupPreview];
        check(ctx.hasChanges==dirtyBefore,@"preview does not mutate context");
        for (NSString *path in paths)
            check([[NSData dataWithContentsOfFile:path] isEqual:[@"original pixels" dataUsingEncoding:NSUTF8StringEncoding]],@"preview preserves all originals");
        if (![mode hasSuffix:@"dirty"]) {
            int expectedPreview = [mode hasSuffix:@"batch"] ? 50 : 3;
            if ([mode isEqual:@"space-limit-soon"]) capacityMode=0; // the preview still sees no free space
            if ([mode hasSuffix:@"protected"] || [mode isEqual:@"readonly"] || [mode isEqual:@"remote"] || [mode isEqual:@"remote-overrides"] ||
                [mode isEqual:@"date-disabled"] || [mode isEqual:@"date-recent"] ||
                [mode isEqual:@"date-group-recent"] || [mode isEqual:@"date-eligibility-failure"]) expectedPreview=0;
            check([preview[@"rows"] count]==expectedPreview,@"preview candidates match active production eligibility");
        }
        measurements=0; // The preview's capacity read must not consume the injected cleanup failure.
    }
    if ([mode isEqual:@"remote-overrides"]) {
        REMOTE_CHECKS
    } else if ([mode isEqual:@"space-synchronous"]) {
        SYNCHRONOUS_CHECKS
    } else if ([mode isEqual:@"space-limit-soon"]) {
        LIMIT_CHECKS
    } else if ([mode isEqual:@"date-initiated"]) {
        INITIATED_CHECKS
    } else if (dateMode) [db cleanOldStuff]; else [db cleanForFreeSpaceMB:100];
    int deleted=([mode isEqual:@"batch"]?50:([mode isEqual:@"target"]||[mode isEqual:@"space-failure"]||[mode isEqual:@"space-synchronous"]?1:0));
    if (dateMode) deleted=[mode isEqual:@"date-batch"]?50:([mode isEqual:@"date-success"]||[mode isEqual:@"date-initiated"]||[mode isEqual:@"date-keep-linked"]?count:0);
    NSManagedObjectContext *reader=[[NSManagedObjectContext alloc] initWithConcurrencyType:NSConfinementConcurrencyType];reader.persistentStoreCoordinator=psc;
    check([reader countForFetchRequest:[NSFetchRequest fetchRequestWithEntityName:@"Study"] error:NULL]==count-deleted,@"durable study count");
    int remaining=0;for(NSString *p in paths) if([NSFileManager.defaultManager fileExistsAtPath:p]) { remaining++; check([[NSData dataWithContentsOfFile:p] isEqual:[@"original pixels" dataUsingEncoding:NSUTF8StringEncoding]],@"preserved bytes unchanged"); }
    check(remaining==([mode isEqual:@"date-keep-linked"]?count:count-deleted),@"original bytes preserved or removed only after commit");
    check(notifications==(deleted>0?1:0),@"refresh after even one deletion");
    check(ctx.hasChanges==[mode hasSuffix:@"dirty"],@"rollback cleanup preserves unrelated pending work");
    [NSNotificationCenter.defaultCenter removeObserver:token];
    NSLog(@"PASS %@: %d committed deletions, %d original files preserved",mode,deleted,remaining);
} }
'''
# The Swift category is compiled against the same stand-ins, declared in a header
# Swift imports. The checks and the fixture (main, below) are the same text.
REMOTE_CHECKS = r'''
        [db cleanForFreeSpace];
        check(remoteSpaceCleans==1,@"-cleanForFreeSpace reaches the override of -cleanForFreeSpaceMB:");
        [db cleanOldStuff];
        check(remoteOldStuffCleans==1,@"-cleanOldStuff reaches its override");
        [db initiateCleanUnlessAlreadyCleaning];
        check(remoteInitiations==1,@"-initiateCleanUnlessAlreadyCleaning reaches its override");
        [db cleanForFreeSpaceMB:100];
        check(remoteSpaceCleans==2,@"-cleanForFreeSpaceMB: reaches its override");
'''
SYNCHRONOUS_CHECKS = r'''
        [defaults setObject:@"100" forKey:@"AUTOCLEANINGSPACESIZE"];
        measurements=0;
        deletedStudies=[NSMutableArray array];
        harness_hold_scheduler();
        [db cleanForFreeSpace];
        check(deletedStudies.count==1,@"the study is deleted before -cleanForFreeSpace returns, with the scheduler busy");
        check(deletingThread==[NSThread currentThread],@"the study is deleted on the calling thread");
        check(measurements==3,@"the free space is read again after the deletion");
        harness_release_scheduler();
'''
LIMIT_CHECKS = r'''
        capacityOverride=^NSDictionary *{ return @{NSFileSystemSize:@(1000ULL*1024*1024), NSFileSystemFreeSize:@(110ULL*1024*1024)}; };
        harness_hold_scheduler();
        [db cleanForFreeSpace];
        harness_release_scheduler();
'''
INITIATED_CHECKS = r'''
        [db initiateCleanUnlessAlreadyCleaning];
        NSManagedObjectContext *watcher=[[NSManagedObjectContext alloc] initWithConcurrencyType:NSConfinementConcurrencyType];watcher.persistentStoreCoordinator=psc;
        for (int wait=0; wait<1000 && [watcher countForFetchRequest:[NSFetchRequest fetchRequestWithEntityName:@"Study"] error:NULL]>0; wait++) usleep(10000);
        usleep(100000);
'''
if swift:
    main = harness[harness.index('static NSAttributeDescription *attr('):].replace('int main(int argc, char **argv)', 'void harness_main(int argc, char **argv)', 1)
    assert 'void harness_main(' in main
    # The real context is made for no database.
    main = main.replace('[[N2ManagedObjectContext alloc] initWithConcurrencyType:', '[[N2ManagedObjectContext alloc] initWithDatabase:nil concurrencyType:', 1)
    main = main.replace('REMOTE_CHECKS', REMOTE_CHECKS).replace('SYNCHRONOUS_CHECKS', SYNCHRONOUS_CHECKS).replace('LIMIT_CHECKS', LIMIT_CHECKS).replace('INITIATED_CHECKS', INITIATED_CHECKS)
else:
    harness = harness.replace('CONTEXT', context).replace('CLEAN\n', clean+'\n')
    harness = harness.replace('REMOTE_CHECKS', '').replace('SYNCHRONOUS_CHECKS', '').replace('LIMIT_CHECKS', '').replace('INITIATED_CHECKS', '')
with tempfile.TemporaryDirectory(prefix='horos-autoclean-') as tmp:
    path=Path(tmp)
    if swift:
        library, archives = autoclean_harness.library(path)
        autoclean_harness.compile_objc(path, main + harness_defaults.OBJC, library)
        autoclean_harness.compile_swift(path, autoclean_harness.CURRENT_SOURCES, library, archives,
                                        main=autoclean_harness.SWIFT_MAIN + autoclean_harness.HOLD_SCHEDULER)
    else:
        (path/'test.mm').write_text(harness + harness_defaults.OBJC)
        subprocess.run(['xcrun','clang++','-DNDEBUG','-fblocks','-fobjc-exceptions','-Wno-deprecated-declarations','-framework','Cocoa','-framework','CoreData',str(path/'test.mm'),'-o',str(path/'test')],check=True)
    failures=[]
    for mode in ['save-failure','space-failure','target','batch','protected','dirty','readonly','remote','date-save-failure','date-success','date-disabled','date-protected','date-dirty','date-recent','date-group-recent','date-keep-linked','date-batch','date-eligibility-failure'] + (['remote-overrides','space-synchronous','space-limit-soon','date-initiated'] if swift else []):
        folder=path/mode;folder.mkdir()
        result=subprocess.run([str(path/'test'),mode,str(folder)],capture_output=True,text=True,timeout=60)
        print(mode, result.returncode, '\n'.join(result.stderr.splitlines()[-3:]))
        if result.returncode: failures.append(mode)
    if failures: raise SystemExit('FAILED: '+', '.join(failures))
