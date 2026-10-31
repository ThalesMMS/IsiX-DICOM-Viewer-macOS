#!/usr/bin/env python3
"""Saved auto-query must wait until the first-use DICOM database is open.

Compile the production Objective-C startup/completion methods and Swift
QueryLogController. Let its real deferred AppKit fetch run while setup is
pending, using an in-memory LogEntry store and no network or user preferences.
The optional source paths allow the unpatched files to serve as negative controls.
"""
import argparse
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--browser-source', type=Path, default=root / 'Horos/Sources/BrowserController.m')
parser.add_argument('--log-source', type=Path, default=root / 'Horos/Sources/QueryLogController.swift')
args = parser.parse_args()
source = args.browser_source.read_bytes().decode('latin1')


def method(signature):
    start = source.index(signature)
    return source[start:source.index('\n}\n', start) + 3]


awake = source.index('-(void) awakeFromNib')
start = source.index('        [self refreshMatrix: self];', awake)
start = source.index('\n', start) + 1
startup = source[start:source.index('        [[self window] setAnimationBehavior:', start)]
completion = method('- (void)completeFirstUseDatabaseSetup')
restore = method('- (void)restoreAutoQueryAndRetrieve\n') if '- (void)restoreAutoQueryAndRetrieve\n' in source else ''

header = r'''
#import <Cocoa/Cocoa.h>
#import "HorosObjCException.h"
NS_ASSUME_NONNULL_BEGIN
@interface TestDatabase : NSObject
@property(retain) NSManagedObjectContext *managedObjectContext;
- (instancetype)initWithContext:(NSManagedObjectContext *)context;
@end
@interface BrowserController : NSObject
@property(retain, nullable) TestDatabase *database;
@property(retain, nullable) TestDatabase *chosenDatabase;
+ (nullable BrowserController *)currentBrowser;
+ (void)setCurrentForTest:(BrowserController *)browser;
- (void)startWindow;
- (void)completeFirstUseDatabaseSetup;
@end
void ConfigureDefaults(BOOL restart, BOOL saved, BOOL retrieving);
BOOL RetrievalPreference(void);
void SetPendingChoice(BOOL pending);
void ClearQuery(void);
NSUInteger QueryCreations(void);
NSArrayController * _Nullable CurrentQueryLog(void);
NS_ASSUME_NONNULL_END
'''

objc = r'''
#import "bridge.h"
static BOOL pendingChoice = YES;
static NSUInteger creations = 0;
static BrowserController *currentBrowser;
@interface HorosDatabaseFirstUse : NSObject
+ (BOOL)hasPendingChoice;
@end
@implementation HorosDatabaseFirstUse
+ (BOOL)hasPendingChoice { return pendingChoice; }
@end
@interface TestDefaults : NSObject
@property(retain) NSMutableDictionary *values;
+ (instancetype)standardUserDefaults;
- (BOOL)boolForKey:(NSString *)key;
- (id)objectForKey:(NSString *)key;
- (void)setBool:(BOOL)value forKey:(NSString *)key;
@end
@implementation TestDefaults
+ (instancetype)standardUserDefaults {
    static TestDefaults *defaults;
    if (!defaults) { defaults = [TestDefaults new]; defaults.values = [NSMutableDictionary dictionary]; }
    return defaults;
}
- (BOOL)boolForKey:(NSString *)key { return [self.values[key] boolValue]; }
- (id)objectForKey:(NSString *)key { return self.values[key]; }
- (void)setBool:(BOOL)value forKey:(NSString *)key { self.values[key] = @(value); }
@end
@interface AppController : NSObject
+ (id)sharedAppController;
- (void)notificationTitle:(NSString *)title description:(NSString *)description name:(NSString *)name;
@end
@implementation AppController
+ (id)sharedAppController { return nil; }
- (void)notificationTitle:(NSString *)title description:(NSString *)description name:(NSString *)name {}
@end
@interface WaitRendering : NSObject
- (instancetype)init:(NSString *)title;
- (void)showWindow:(id)sender;
- (void)close;
@end
@implementation WaitRendering
- (instancetype)init:(NSString *)title { return [super init]; }
- (void)showWindow:(id)sender {}
- (void)close {}
@end
@interface ICloudDriveDetector : NSObject
+ (void)performStartupICloudDriveTasks:(id)sender;
@end
@implementation ICloudDriveDetector
+ (void)performStartupICloudDriveTasks:(id)sender {}
@end
@interface O2HMigrationAssistant : NSObject
+ (void)performStartupO2HTasks:(id)sender;
@end
@implementation O2HMigrationAssistant
+ (void)performStartupO2HTasks:(id)sender {}
@end
@interface QueryController : NSObject
@property(retain) NSArrayController *logs;
+ (instancetype)currentAutoQueryController;
- (instancetype)initAutoQuery:(BOOL)automatic;
- (void)switchAutoRetrieving:(id)sender;
@end
static QueryController *currentQuery;
@implementation QueryController
+ (instancetype)currentAutoQueryController { return currentQuery; }
- (instancetype)initAutoQuery:(BOOL)automatic {
    if ((self = [super init])) {
        currentQuery = self;
        creations++;
        self.logs = [NSClassFromString(@"QueryLogController") new];
        self.logs.entityName = @"LogEntry";
        self.logs.automaticallyPreparesContent = YES;
        [self.logs awakeFromNib];
    }
    return self;
}
- (void)switchAutoRetrieving:(id)sender {}
@end
@implementation TestDatabase
- (instancetype)initWithContext:(NSManagedObjectContext *)context {
    if ((self = [super init])) self.managedObjectContext = context;
    return self;
}
@end
@interface BrowserController ()
- (void)restoreAutoQueryAndRetrieve;
- (void)awakeSources;
- (void)resetToLocalDatabase;
@end
@implementation BrowserController
+ (BrowserController *)currentBrowser { return currentBrowser; }
+ (void)setCurrentForTest:(BrowserController *)browser { currentBrowser = browser; }
- (void)awakeSources {}
- (void)resetToLocalDatabase { self.database = self.chosenDatabase; }
- (void)startWindow {
STARTUP
}
RESTORE
COMPLETION
@end
void ConfigureDefaults(BOOL restart, BOOL saved, BOOL retrieving) {
    TestDefaults *defaults = [TestDefaults standardUserDefaults];
    defaults.values = [@{@"restartAutoQueryAndRetrieve": @(restart), @"autoRetrieving": @(retrieving)} mutableCopy];
    if (saved) defaults.values[@"savedAutoDICOMQuerySettingsArray"] = @[@{}];
}
BOOL RetrievalPreference(void) { return [[TestDefaults standardUserDefaults] boolForKey:@"autoRetrieving"]; }
void SetPendingChoice(BOOL pending) { pendingChoice = pending; }
void ClearQuery(void) { currentQuery = nil; }
NSUInteger QueryCreations(void) { return creations; }
NSArrayController *CurrentQueryLog(void) { return currentQuery.logs; }
'''.replace('STARTUP', startup).replace('RESTORE', restore).replace('COMPLETION', completion)
# Substitute only the preferences dependency, keeping user settings untouched.
objc = objc.replace('NSUserDefaults', 'TestDefaults')

swift = r'''
import Cocoa
func require(_ condition: Bool, _ reason: String) {
    if !condition { print("FAIL: \(reason)"); exit(1) }
}
func drainEvents(_ scenario: String) {
    do {
        try HorosObjCException.perform {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.08))
        }
    } catch {
        let exception = (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException
        print("FAIL: \(scenario): \(exception?.reason ?? error.localizedDescription)")
        exit(1)
    }
}
_ = NSApplication.shared
let model = NSManagedObjectModel()
let entry = NSEntityDescription()
entry.name = "LogEntry"
entry.managedObjectClassName = "NSManagedObject"
let time = NSAttributeDescription()
time.name = "startTime"
time.attributeType = .dateAttributeType
entry.properties = [time]
model.entities = [entry]
let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
try coordinator.addPersistentStore(ofType: NSInMemoryStoreType, configurationName: nil, at: nil)
let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
context.persistentStoreCoordinator = coordinator
NSEntityDescription.insertNewObject(forEntityName: "LogEntry", into: context).setValue(Date(), forKey: "startTime")
try context.save()
let database = TestDatabase(context: context)
let browser = BrowserController()
BrowserController.setCurrentForTest(browser)
browser.chosenDatabase = database
ConfigureDefaults(true, true, true)
SetPendingChoice(true)
browser.startWindow()
drainEvents("location choice still pending")
require(QueryCreations() == 0, "auto-query started before choosing a database")
require(RetrievalPreference(), "pending setup changed the retrieval preference")
SetPendingChoice(false)
browser.completeFirstUseDatabaseSetup()
drainEvents("database chosen")
require(QueryCreations() == 1, "saved auto-query did not resume after setup")
require(CurrentQueryLog()?.managedObjectContext === context, "query log uses the wrong context")
require((CurrentQueryLog()?.arrangedObjects as? NSArray)?.count == 1, "query log did not fetch the real store")
browser.completeFirstUseDatabaseSetup()
require(QueryCreations() == 1, "setup resumed auto-query twice")
ClearQuery()
browser.startWindow()
drainEvents("existing installation")
require(QueryCreations() == 2, "ordinary startup no longer restores auto-query")
ClearQuery()
browser.database = nil
browser.startWindow()
drainEvents("database failed to open")
require(QueryCreations() == 2, "auto-query started without a database")
let earlyLog = QueryLogController()
earlyLog.entityName = "LogEntry"
earlyLog.automaticallyPreparesContent = true
earlyLog.awakeFromNib()
drainEvents("log loaded before database")
require(!earlyLog.automaticallyPreparesContent, "early log still schedules a fetch")
browser.database = database
ConfigureDefaults(false, true, true)
browser.startWindow()
require(!RetrievalPreference(), "disabled restore still enables retrieval")
ConfigureDefaults(true, false, true)
browser.startWindow()
require(!RetrievalPreference(), "missing saved settings still enable retrieval")
print("PASS: auto-query waits for first-use completion, resumes once with a usable log, and preserves ordinary startup")
'''

with tempfile.TemporaryDirectory(prefix='isix-first-use-auto-query-') as directory:
    folder = Path(directory)
    (folder / 'bridge.h').write_text(header)
    (folder / 'browser.m').write_text(objc)
    (folder / 'main.swift').write_text(swift)
    includes = ['-I', str(root / 'Horos/Sources'), '-I', str(folder)]
    for name, path in [('browser', folder / 'browser.m'), ('exception', root / 'Horos/Sources/HorosObjCException.m')]:
        subprocess.run(['xcrun', 'clang', '-c', '-fno-objc-arc', *includes, str(path), '-o', str(folder / f'{name}.o')],
                       check=True, timeout=120)
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-import-objc-header', str(folder / 'bridge.h'),
                    '-Xcc', '-I' + str(root / 'Horos/Sources'), str(args.log_source),
                    str(root / 'Horos/Sources/MainActorCallbacks.swift'), str(folder / 'main.swift'),
                    str(folder / 'browser.o'), str(folder / 'exception.o'), '-o', str(folder / 'test')],
                   check=True, timeout=300)
    subprocess.run([str(folder / 'test')], check=True, timeout=60)
