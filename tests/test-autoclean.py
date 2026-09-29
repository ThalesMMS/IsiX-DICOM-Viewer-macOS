#!/usr/bin/env python3
"""Run the production date/space cleaners and transaction code against temporary SQLite stores.
Pass a git revision to demonstrate the old failures. Filesystem capacity is injected;
actual image files, Core Data deletion validation, saves and rollbacks are exercised.

DicomDatabase (Clean) is Swift since #722: the harness below then compiles
DicomDatabase+Clean.swift against the same stand-ins, and runs the same checks.
A revision given on the command line is read as the Objective-C of that time.
"""
from pathlib import Path
import subprocess, sys, tempfile
root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'tests'))
from sources import source_path  # noqa: E402
import harness_defaults  # the harness's preferences stay in its own process (#923)
revision = sys.argv[1] if len(sys.argv) > 1 else None
def source(path):
    return (subprocess.check_output(['git', 'show', f'{revision}:{path}']).decode()
            if revision else (root / path).read_text())
swift = revision is None and source_path('DicomDatabase+Clean').suffix == '.swift'
if not swift:
    clean = source('Horos/Sources/DicomDatabase+Clean.mm')
    clean = (clean[clean.index('// Both the preview') if '// Both the preview' in clean else clean.index('-(void)cleanOldStuff'):(clean.index('static BOOL _showingClean') if 'static BOOL _showingClean' in clean else clean.index('-(void)cleanForFreeSpace {'))] +
             clean[clean.index('-(void)cleanForFreeSpaceMB:'):clean.rindex('@end')])
context = source('Nitrogen/Sources/N2ManagedDatabase.mm')
context = context[context.index('- (void)performAfterSuccessfulSave:'):context.index('-(NSManagedObject*)existingObjectWithID:')]
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
    DicomDatabase *db=[DicomDatabase new];db.managedObjectContext=ctx;db.dataBaseDirPath=fixtureDirectory;
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
    capacityMode=[mode isEqual:@"space-failure"]?1:([mode isEqual:@"target"]?2:0);
    if ([mode hasSuffix:@"dirty"]) [[db objectsForEntity:@"Study"][0] setComment:@"unrelated pending edit"];
    db.isReadOnly=[mode isEqual:@"readonly"];
    db.isLocal=![mode isEqual:@"remote"];
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
            if ([mode hasSuffix:@"protected"] || [mode isEqual:@"readonly"] || [mode isEqual:@"remote"] ||
                [mode isEqual:@"date-disabled"] || [mode isEqual:@"date-recent"] ||
                [mode isEqual:@"date-group-recent"] || [mode isEqual:@"date-eligibility-failure"]) expectedPreview=0;
            check([preview[@"rows"] count]==expectedPreview,@"preview candidates match active production eligibility");
        }
        measurements=0; // The preview's capacity read must not consume the injected cleanup failure.
    }
    if (dateMode) [db cleanOldStuff]; else [db cleanForFreeSpaceMB:100];
    int deleted=([mode isEqual:@"batch"]?50:([mode isEqual:@"target"]||[mode isEqual:@"space-failure"]?1:0));
    if (dateMode) deleted=[mode isEqual:@"date-batch"]?50:([mode isEqual:@"date-success"]||[mode isEqual:@"date-keep-linked"]?count:0);
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
SWIFT_HEADER = r'''
#import <Cocoa/Cocoa.h>
#import <CoreData/CoreData.h>
#import "HorosObjCException.h"
#import "HorosAlertPanel.h"
extern NSString *const _O2AddToDBAnywayNotification, *const _O2AddToDBAnywayCompleteNotification, *const OsirixAddToDBNotification, *const OsirixAddToDBCompleteNotification;
#ifdef __cplusplus
extern "C" {
#endif
void harness_main(int argc, char **argv);
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
@interface N2ManagedObjectContext : NSManagedObjectContext {
    NSMutableArray *_afterSuccessfulSaveActions, *_nextSuccessfulSaveActions, *_discardedChangesActions;
    BOOL _defersSaves, _atomicChangesCancelled;
}
@property(readonly) BOOL defersSaves;
- (BOOL)performAtomicChanges:(BOOL (^)(NSError **))changes error:(NSError **)error;
@end
@interface DicomStudy : NSManagedObject
@property(retain) NSNumber *lockedStudy;
@property(retain) NSString *comment, *comment2, *comment3, *comment4, *studyName, *patientID, *patientUID;
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
@property(retain) NSNumber *inDatabaseFolder;
@end
@interface DicomDatabase : NSObject { NSRecursiveLock *_cleanLock; BOOL _isLocal; }
@property(retain) N2ManagedObjectContext *managedObjectContext;
@property(retain) NSString *dataBaseDirPath;
@property BOOL isReadOnly;
+ (NSArray *)allDatabases;
- (BOOL)isLocal;
- (void)setIsLocal:(BOOL)isLocal;
- (BOOL)isMainDatabase;
- (id)mainDatabase;
- (id)independentDatabase;
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
static void check(BOOL ok, NSString *message) { if (!ok) { NSLog(@"FAIL: %@",message); exit(1); } }
void _N2LogExceptionImpl(NSException *e, BOOL logStack, const char *pf) { NSLog(@"Exception: %@", e); }
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
+ (NSInteger)runWithTitle:(NSString *)t message:(NSString *)m defaultButton:(NSString *)d alternateButton:(NSString *)a otherButton:(NSString *)o { return NSAlertDefaultReturn; }
+ (NSInteger)runInformationalWithTitle:(NSString *)t message:(NSString *)m defaultButton:(NSString *)d alternateButton:(NSString *)a otherButton:(NSString *)o { return NSAlertDefaultReturn; }
+ (NSInteger)runCriticalWithTitle:(NSString *)t message:(NSString *)m defaultButton:(NSString *)d alternateButton:(NSString *)a otherButton:(NSString *)o { return NSAlertDefaultReturn; }
@end
@implementation NSThread (TestOperations)
- (void)enterOperation {} - (void)enterOperationIgnoringLowerLevels {} - (void)exitOperation {}
- (CGFloat)progress { return 0; } - (void)setProgress:(CGFloat)p {}
- (NSString *)status { return nil; } - (void)setStatus:(NSString *)s {}
@end
@implementation N2ManagedObjectContext
CONTEXT
@end
@interface DicomStudy ()
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
@implementation DicomSeries
@dynamic images;
@end
@interface DicomImage ()
@property(retain) NSString *completePath;
@end
@implementation DicomImage
@dynamic completePath, inDatabaseFolder;
@end
@interface DicomDatabase (UnderTest)
- (void)cleanForFreeSpaceMB:(NSInteger)mb;
- (void)cleanOldStuff;
- (NSDictionary *)automaticCleanupPreview;
- (NSInteger)cleanupThresholdForAttributes:(NSDictionary *)attributes;
- (void)cleanForFreeSpace;
@end
@implementation DicomDatabase
@synthesize managedObjectContext, dataBaseDirPath, isReadOnly;
- (id)init { if ((self=[super init])) { _cleanLock=[NSRecursiveLock new]; self.isLocal=YES; } return self; }
+ (NSArray *)allDatabases { return @[]; }
- (BOOL)isLocal { return _isLocal; }
- (void)setIsLocal:(BOOL)isLocal { _isLocal=isLocal; }
- (BOOL)isMainDatabase { return YES; }
- (id)mainDatabase { return self; }
- (id)independentDatabase { return self; }
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
'''
if swift:
    main = harness[harness.index('static NSAttributeDescription *attr('):].replace('int main(int argc, char **argv)', 'void harness_main(int argc, char **argv)', 1)
    assert 'void harness_main(' in main
    harness = SWIFT_IMPL.replace('CONTEXT', context) + main
else:
    harness = harness.replace('CONTEXT', context).replace('CLEAN\n', clean+'\n')
with tempfile.TemporaryDirectory(prefix='horos-autoclean-') as tmp:
    path=Path(tmp); (path/'test.mm').write_text(harness + harness_defaults.OBJC)
    if swift:
        for name in ('HorosObjCException.h', 'HorosObjCException.m', 'HorosAlertPanel.h'):
            (path/name).write_bytes((root/'Horos/Sources'/name).read_bytes())
        (path/'harness.h').write_text(SWIFT_HEADER)
        (path/'main.swift').write_text('import Foundation\nharness_main(CommandLine.argc, CommandLine.unsafeArgv)\nexit(0)\n')
        subprocess.run(['xcrun','clang++','-DNDEBUG','-fblocks','-fobjc-exceptions','-Wno-deprecated-declarations','-iquote',str(path),'-c',str(path/'test.mm'),'-o',str(path/'test.o')],check=True)
        subprocess.run(['xcrun','clang','-x','objective-c','-fobjc-exceptions','-iquote',str(path),'-c',str(path/'HorosObjCException.m'),'-o',str(path/'exception.o')],check=True)
        subprocess.run(['xcrun','swiftc','-module-name','Horos','-import-objc-header',str(path/'harness.h'),'-Xcc','-iquote','-Xcc',str(path),
                        str(source_path('DicomDatabase+Clean')),str(path/'main.swift'),str(path/'test.o'),str(path/'exception.o'),
                        '-lc++','-framework','Cocoa','-framework','CoreData','-o',str(path/'test')],check=True)
    else:
        subprocess.run(['xcrun','clang++','-DNDEBUG','-fblocks','-fobjc-exceptions','-Wno-deprecated-declarations','-framework','Cocoa','-framework','CoreData',str(path/'test.mm'),'-o',str(path/'test')],check=True)
    failures=[]
    for mode in ['save-failure','space-failure','target','batch','protected','dirty','readonly','remote','date-save-failure','date-success','date-disabled','date-protected','date-dirty','date-recent','date-group-recent','date-keep-linked','date-batch','date-eligibility-failure']:
        folder=path/mode;folder.mkdir()
        result=subprocess.run([str(path/'test'),mode,str(folder)],capture_output=True,text=True)
        print(mode, result.returncode, '\n'.join(result.stderr.splitlines()[-3:]))
        if result.returncode: failures.append(mode)
    if failures: raise SystemExit('FAILED: '+', '.join(failures))
