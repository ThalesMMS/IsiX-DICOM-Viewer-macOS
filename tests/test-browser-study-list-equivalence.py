#!/usr/bin/env python3
"""The browser's study list rules decide what their Objective-C did.

Building the study list, the files of the selection and the PACS On-Demand
searches moved from BrowserController.m to Swift, with their rules in the
IsiXDatabase module (StudyListRules.swift). This compiles the Objective-C of
those rules, cut out of BrowserController.m in the last revision that has it
(history_reference; the tree itself while it still has it), and the module
with swiftc, gives both the same synthetic inputs and compares what they
produce:

* -refreshEntireDBResult (shown or hidden, and the count);
* the predicate of the list (time interval, modality, search field, test);
* when the distant studies found join the list, and how they merge with the
  local studies (added, replacing a study with fewer images, retrieved), in
  the list and in a patient's history, with the image counts asked in the
  same order;
* the studies of other databases a search adds;
* the sort descriptors of the list, and a patient's other studies grouped
  after each study, within the related studies limit;
* the image each series of a study gives (-imagesArray:...), with the
  thumbnails asked in the same order, and what an empty study loses;
* the nodes of the comparative search, the names of the search types, the
  filters of the search field, of the time interval and of a smart album
  sent to the nodes, and the second patient-name query;
* the patient a history is still shown for;
* which lock files of dead processes -searchDeadProcesses ends.

    python3 tests/test-browser-study-list-equivalence.py [--reference REV]
"""
import argparse
import difflib
import os
import plistlib
import random
import re
import subprocess
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import private_tmpdir  # noqa: F401,E402
import history_reference  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
BC = 'Horos/Sources/BrowserController.m'
MARK = '- (NSString*) outlineViewRefresh\t\t// This function creates the \'root\' array for the outlineView'
RULES = ROOT / 'Modules/IsiXDatabase/Sources/StudyListRules.swift'

parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
parser.add_argument('--reference')
parser.add_argument('--dump', type=Path, help='write the records of both programs to this folder')
args = parser.parse_args()


def git(*command):
    return subprocess.run(['git', '-C', str(ROOT), *command], capture_output=True)


reference = args.reference
if reference is None:
    head = git('show', 'HEAD:' + BC)
    if (ROOT / BC).exists() and MARK in (ROOT / BC).read_bytes().decode('latin1'):
        reference = 'tree'
    elif head.returncode == 0 and MARK in head.stdout.decode('latin1'):
        reference = 'HEAD'
    else:
        reference = history_reference.before_text_removed(BC, MARK)
if reference is None:
    print('skipped: needs the history that has the Objective-C study list of BrowserController.m')
    sys.exit(2)
if reference == 'tree':
    text = (ROOT / BC).read_bytes().decode('latin1')
else:
    shown = git('show', '%s:%s' % (reference, BC))
    if shown.returncode:
        sys.exit('FAIL: no %s at %s' % (BC, reference))
    text = shown.stdout.decode('latin1')
if MARK not in text:
    sys.exit('FAIL: %s has no Objective-C -outlineViewRefresh in %s' % (reference, BC))
if not RULES.exists():
    sys.exit('FAIL: no StudyListRules.swift in IsiXDatabase')


def matching(source, start):
    depth, i = 0, start
    while i < len(source):
        c = source[i]
        if source.startswith('//', i):
            i = source.index('\n', i)
            continue
        if source.startswith('/*', i):
            i = source.index('*/', i) + 2
            continue
        if c in '"\'':
            j = i + 1
            while source[j] != c:
                j += 2 if source[j] == '\\' else 1
            i = j + 1
            continue
        if c == '{':
            depth += 1
        elif c == '}':
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    raise SystemExit('FAIL: unbalanced braces')


def method(signature, source=text):
    at = source.index(signature)
    return source[at:matching(source, source.index('{', at))]


def between(start_text, end_text, within):
    at = within.index(start_text)
    return within[at:within.index(end_text, at)]


def defaults(code):
    """The defaults the snippets read come from the case, not the user's domain."""
    code = re.sub(r'\[\[NSUserDefaults standardUserDefaults\] boolForKey: ?(@"\w+")\]', r'TestBool(\1)', code)
    code = re.sub(r'\[\[NSUserDefaults standardUserDefaults\] (?:objectForKey|arrayForKey): ?(@"\w+")\]', r'TestObject(\1)', code)
    return code


refresh = method(MARK)
entire = method('- (void) refreshEntireDBResult')
predicate_block = between('    // ********************\n    // TIME INTERVAL', '    //\t[_database lock];', refresh)
use_block = between('            BOOL useDistantArray = NO;', '            if( useDistantArray)', refresh)
merge_block = between('                NSMutableArray *localStudyInstanceUIDs', '                @synchronized (_albumNoOfStudiesCache)\n                {\n                    if( smartAlbumName', refresh)
federated_block = between('            if (self.filterPredicate && outlineViewArray)', '        }\n        @catch( NSException *ne)\n        {\n            outlineViewArray = [NSArray array];', refresh)
sort_block = between('    NSSortDescriptor * sortdate', '    if( filtered == YES && [[NSUserDefaults', refresh)
group_block = between('                outlineViewArray = [outlineViewArray sortedArrayUsingDescriptors: sortDescriptors];',
                      '            else\n            {\n                NSMutableArray\t*patientPredicateArray', refresh)
group_block = group_block[:group_block.rindex('}')]
images = method('- (NSArray*) imagesArray: (id) item preferredObject: (int) preferredObject onlyImages:(BOOL) onlyImages')
files = method('- (NSMutableArray*)filesForDatabaseOutlineSelection:(NSMutableArray*)correspondingManagedObjects treeObjects:(NSMutableSet*)treeManagedObjects onlyImages:(BOOL)onlyImages')
cleanup_block = between('                        int totImage = 0;', '                    }\n                }', files)
servers = method('+ (NSArray*) comparativeServers')
type_names = method('+ (NSString*) stringForSearchType:(int) curSearchType')
search_string = method('- (NSArray*) distantStudiesForSearchString: (NSString*) curSearchString type:(int) curSearchType')
interval = method('- (NSArray*) distantStudiesForIntervalFrom: (NSDate*) from to:(NSDate*) to')
smart_album = method('- (NSArray*) distantStudiesForSmartAlbum: (NSString*) albumName')
sub_search = method('- (NSArray*) subSearchForComparativeStudies: (id) studySelectedID inDatabase: (DicomDatabase*) idatabase')
history_block = between('                                // Merge local and distant studies\n                                NSMutableArray *studyToAutoretrieve',
                        '                                if( studyToAutoretrieve.count)', sub_search)
same_patient = re.search(r'\[self\.comparativePatientUID compare: studySelected\.patientUID options: ([^\]]+)\] == NSOrderedSame', sub_search).group(1)
dead = method('- (void) searchDeadProcesses')
autoretrieve_loop = method('for( NSDictionary *d in [[NSUserDefaults standardUserDefaults] objectForKey: @"smartAlbumStudiesDICOMNodes"])', refresh)

OBJC = r'''
#import <Foundation/Foundation.h>
#import <CoreData/CoreData.h>
#include <limits.h>
#include <signal.h>
#define N2LogException(e) Rec(@"exception")
#define N2LogExceptionWithStackTrace(e) Rec(@"exception")
#undef NSLocalizedString
#define NSLocalizedString(key, comment) (key)
#define N2LocalizedSingularPluralCount(c, s, p) [NSString stringWithFormat: @"%d", (int)(c)]
#define DCMTKStudyQueryNode Node
#define DCMTKQueryNode Node
#define kill(pid, sig) Rec(@"kill %d %d", (int)(pid), (int)(sig))
#define unlink(path) Rec(@"unlink %s", strrchr((path), '/') + 1)
enum dbObjectSelection {oAny, oMiddle, oFirstForFirst};
enum { between = 5, after = 12 };

static NSMutableArray *records;
static NSDictionary *testDefaults;
static void Rec(NSString *format, ...) {
    va_list list; va_start(list, format);
    [records addObject: [[[NSString alloc] initWithFormat: format arguments: list] autorelease]];
    va_end(list);
}
#define TestBool(key) [[testDefaults objectForKey: key] boolValue]
#define TestObject(key) [testDefaults objectForKey: key]
static NSString *Name(id object) {
    if (object == nil) return @"nil";
    if ([object respondsToSelector: @selector(ident)]) return [object performSelector: @selector(ident)];
    return [object description];
}
static NSString *Names(NSArray *array) {
    if (array == nil) return @"nil";
    NSMutableArray *names = [NSMutableArray array];
    for (id object in array) [names addObject: Name(object)];
    return [names componentsJoinedByString: @","];
}
static NSString *Plain(id object) {
    if (object == nil) return @"nil";
    if ([object isKindOfClass: [NSDictionary class]]) {
        NSMutableArray *parts = [NSMutableArray array];
        for (id key in [[object allKeys] sortedArrayUsingSelector: @selector(compare:)])
            [parts addObject: [NSString stringWithFormat: @"%@=%@", key, Plain([object objectForKey: key])]];
        return [NSString stringWithFormat: @"{%@}", [parts componentsJoinedByString: @";"]];
    }
    if ([object isKindOfClass: [NSArray class]]) {
        NSMutableArray *parts = [NSMutableArray array];
        for (id item in object) [parts addObject: Plain(item)];
        return [NSString stringWithFormat: @"[%@]", [parts componentsJoinedByString: @","]];
    }
    if ([object isKindOfClass: [NSDate class]]) return [NSString stringWithFormat: @"date(%.3f)", [object timeIntervalSinceReferenceDate]];
    return [object description];
}

@interface NSUserDefaults (Test)
+ (NSDateFormatter*) dateTimeFormatter;
@end
@implementation NSUserDefaults (Test)
+ (NSDateFormatter*) dateTimeFormatter { NSDateFormatter *f = [[NSDateFormatter new] autorelease]; f.dateFormat = @"yyyy-MM-dd HH:mm:ss"; return f; }
@end

@interface Node : NSObject
@property(retain) NSString *ident, *studyInstanceUID, *patientID, *patientUID, *name, *uid;
@property(retain) NSNumber *filesValue, *rawFilesValue;
@property(retain) NSDate *date;
@end
@implementation Node
- (NSNumber*) noFiles { Rec(@"files %@", self.ident); return self.filesValue; }
- (NSNumber*) rawNoFiles { Rec(@"raw %@", self.ident); return self.rawFilesValue; }
@end

static Node *MakeNode(NSDictionary *d) {
    Node *n = [[Node new] autorelease];
    n.ident = [d objectForKey: @"id"];
    n.studyInstanceUID = [d objectForKey: @"uid"];
    n.uid = [d objectForKey: @"uid"];
    n.patientID = [d objectForKey: @"patientID"];
    n.patientUID = [d objectForKey: @"patientUID"];
    n.name = [d objectForKey: @"name"];
    n.filesValue = [d objectForKey: @"files"];
    n.rawFilesValue = [d objectForKey: @"raw"];
    n.date = [d objectForKey: @"date"] ? [NSDate dateWithTimeIntervalSinceReferenceDate: [[d objectForKey: @"date"] doubleValue]] : nil;
    return n;
}
static NSArray *MakeNodes(NSArray *list) {
    if (list == nil) return nil;
    NSMutableArray *nodes = [NSMutableArray array];
    for (NSDictionary *d in list) [nodes addObject: MakeNode(d)];
    return nodes;
}

@interface Button : NSObject
@property(retain) NSString *title;
@property BOOL hidden;
@end
@implementation Button
@end
@interface Popup : NSObject
@property NSInteger indexOfSelectedItem;
@end
@implementation Popup
@end
@interface Outline : NSObject
@property(retain) NSArray *sortDescriptors;
@end
@implementation Outline
@end

@interface DicomDatabase : NSObject
@property(retain) NSString *baseDirPath;
@property(retain) NSArray *pool;
@property BOOL isReadOnly, isLocal;
+ (DicomDatabase*) databaseForContext: (id) context;
@end
@implementation DicomDatabase
+ (DicomDatabase*) databaseForContext: (id) context { return nil; }
- (id) studyEntity { return @"Study"; }
- (NSArray*) objectsForEntity: (id) entity predicate: (NSPredicate*) predicate {
    return [self.pool filteredArrayUsingPredicate: predicate];
}
@end

static NSArray *federatedResult;
@interface HorosFederatedSearch : NSObject
@end
@implementation HorosFederatedSearch
+ (NSString*) identityKeyWithPatientUID: (NSString*) patientUID studyUID: (NSString*) studyUID originPath: (NSString*) path { return patientUID; }
@end

static NSInteger relatedLimit;
@interface HorosAssociationContract : NSObject
@end
@implementation HorosAssociationContract
+ (NSInteger) relatedStudiesLimitIn: (id) defaults { return relatedLimit; }
@end

static NSArray *candidateServers;
@interface HorosRISRequestServers : NSObject
@end
@implementation HorosRISRequestServers
+ (NSArray*) candidates { return candidateServers; }
@end

static NSArray *queryAnswers;
static NSUInteger queryIndex;
@interface QueryController : NSObject
@end
@implementation QueryController
+ (NSArray*) queryStudiesForFilters: (NSDictionary*) filters servers: (NSArray*) servers showErrors: (BOOL) showErrors {
    Rec(@"query %@ servers %lu", Plain(filters), (unsigned long)servers.count);
    NSArray *answer = queryIndex < queryAnswers.count ? [queryAnswers objectAtIndex: queryIndex] : nil;
    queryIndex++;
    if ([answer isKindOfClass: [NSString class]]) return nil;
    return MakeNodes(answer);
}
@end

static const char *processFolder;
static const char *HorosDICOMProcessFolder(void) { return processFolder; }

@interface Item : NSObject
@property(retain) NSString *ident, *type;
@property(retain) NSArray *children;
@property(retain) NSSet *images;
@property BOOL hasThumbnail;
@end
@implementation Item
- (id) primitiveValueForKey: (NSString*) key {
    Rec(@"thumbnail %@", self.ident);
    return self.hasThumbnail ? @"yes" : nil;
}
@end

@interface DicomSeries : NSObject
@property(retain) NSString *name, *ident;
@property(retain) NSNumber *id;
@property(retain) NSArray *imageList;
@end
@implementation DicomSeries
@end
@interface Context : NSObject
@end
@implementation Context
- (void) deleteObject: (id) object { Rec(@"delete %@", Name(object)); }
@end

@interface BrowserController : NSObject
{
    int distantEntireDBResultCount, localEntireDBResultCount;
    NSArray *outlineViewArray;
    Button *searchInEntireDBResult;
    NSDate *timeIntervalStart, *timeIntervalEnd;
    Popup *modalityFilterMenu;
    NSPredicate *testPredicate;
    NSArray *smartAlbumDistantArray;
    int searchType;
    NSString *_searchString;
    NSMutableArray *comparativeRetrieveQueue;
    NSRecursiveLock *searchForComparativeStudiesLock;
    Outline *databaseOutline;
    DicomDatabase *_database;
    BOOL autoretrievingPACSOnDemandSmartAlbum;
}
@property(retain) NSString *modalityFilter, *filterPredicateDescription, *smartAlbumDistantName, *distantSearchString;
@property(retain) NSPredicate *filterPredicate;
@property(retain) NSDate *distantTimeIntervalStart, *distantTimeIntervalEnd;
@property int distantSearchType;
@property(readonly) DicomDatabase *database;
@end

@implementation BrowserController

- (DicomDatabase*) database { return _database; }

+ (NSArray*) federatedStudiesMatchingPredicate: (NSPredicate*) predicate excludingDatabasePath: (NSString*) path applyingUser: (id) user {
    return federatedResult;
}

- (void) rememberOriginalOutlineViewArray: (NSArray*) array { Rec(@"original %@", Names(array)); }

@@ENTIRE@@

- (NSDictionary*) predicateCase: (NSDictionary*) c
{
    timeIntervalStart = [c objectForKey: @"start"]; timeIntervalEnd = [c objectForKey: @"end"];
    modalityFilterMenu = [[Popup new] autorelease];
    modalityFilterMenu.indexOfSelectedItem = [[c objectForKey: @"menu"] integerValue];
    self.modalityFilter = [c objectForKey: @"modality"];
    self.filterPredicate = [c objectForKey: @"filter"] ? [NSPredicate predicateWithFormat: [c objectForKey: @"filter"]] : nil;
    self.filterPredicateDescription = @" / search";
    testPredicate = [c objectForKey: @"test"] ? [NSPredicate predicateWithFormat: [c objectForKey: @"test"]] : nil;
    NSPredicate *predicate = nil, *subPredicate = nil;
    NSString *description = @"";
    BOOL filtered = NO;
@@PREDICATE@@
    return @{@"predicate": [predicate predicateFormat], @"filtered": @(filtered)};
}

- (BOOL) useDistant: (NSDictionary*) c
{
    NSString *smartAlbumName = [c objectForKey: @"album"];
    smartAlbumDistantArray = [[c objectForKey: @"hasDistant"] boolValue] ? @[] : nil;
    self.smartAlbumDistantName = [c objectForKey: @"distantAlbum"];
    timeIntervalStart = [c objectForKey: @"start"]; timeIntervalEnd = [c objectForKey: @"end"];
    self.distantTimeIntervalStart = [c objectForKey: @"distantStart"]; self.distantTimeIntervalEnd = [c objectForKey: @"distantEnd"];
    self.filterPredicate = [[c objectForKey: @"hasFilter"] boolValue] ? [NSPredicate predicateWithValue: YES] : nil;
    searchType = [[c objectForKey: @"type"] intValue]; self.distantSearchType = [[c objectForKey: @"distantType"] intValue];
    _searchString = [c objectForKey: @"search"]; self.distantSearchString = [c objectForKey: @"distantSearch"];
@@USE@@
    return useDistantArray;
}

- (void) mergeList: (NSDictionary*) c
{
    outlineViewArray = MakeNodes([c objectForKey: @"local"]);
    NSArray *filteredAlbumDistantStudies = MakeNodes([c objectForKey: @"distant"]);
    NSMutableArray *queue = [NSMutableArray array];
    for (NSString *uid in [c objectForKey: @"queue"]) [queue addObject: @{@"studyInstanceUID": uid}];
    comparativeRetrieveQueue = queue;
    BOOL autoretrieve = [[c objectForKey: @"autoretrieve"] boolValue];
    NSMutableArray *distantStudies = [NSMutableArray array];
    NSMutableArray *studyToAutoretrieve = [NSMutableArray array];
@@MERGE@@
    Rec(@"list %@ added %@ retrieved %@", Names(outlineViewArray), Names(distantStudies), Names(studyToAutoretrieve));
}

- (void) mergeHistory: (NSDictionary*) c
{
    NSMutableArray *mergedStudies = [NSMutableArray arrayWithArray: MakeNodes([c objectForKey: @"local"])];
    NSArray *distantStudies = MakeNodes([c objectForKey: @"distant"]);
    NSMutableArray *queue = [NSMutableArray array];
    for (NSString *uid in [c objectForKey: @"queue"]) [queue addObject: @{@"studyInstanceUID": uid}];
    comparativeRetrieveQueue = queue;
@@HISTORY@@
    Rec(@"history %@ retrieved %@", Names(mergedStudies), Names(studyToAutoretrieve));
}

- (void) federate: (NSDictionary*) c
{
    _database = [[DicomDatabase new] autorelease];
    _database.baseDirPath = @"/base";
    outlineViewArray = MakeNodes([c objectForKey: @"local"]);
    federatedResult = MakeNodes([c objectForKey: @"federated"]);
    self.filterPredicate = [NSPredicate predicateWithValue: YES];
@@FEDERATED@@
    Rec(@"federated %@", Names(outlineViewArray));
}

- (void) sortCase: (NSDictionary*) c
{
    databaseOutline = [[Outline new] autorelease];
    NSMutableArray *current = nil;
    if ([c objectForKey: @"keys"]) {
        current = [NSMutableArray array];
        for (NSString *key in [c objectForKey: @"keys"])
            [current addObject: [NSSortDescriptor sortDescriptorWithKey: [key isEqualToString: @"<nil>"] ? nil : key ascending: [key hasPrefix: @"n"]]];
    }
    databaseOutline.sortDescriptors = current;
@@SORT@@
    NSMutableArray *parts = [NSMutableArray array];
    for (NSSortDescriptor *s in sortDescriptors)
        [parts addObject: [NSString stringWithFormat: @"%@/%d/%@", s.key, s.ascending, s.selector ? NSStringFromSelector(s.selector) : @"-"]];
    Rec(@"sort %@", [parts componentsJoinedByString: @","]);
}

- (void) groupCase: (NSDictionary*) c
{
    _database = [[DicomDatabase new] autorelease];
    _database.pool = MakeNodes([c objectForKey: @"pool"]);
    outlineViewArray = MakeNodes([c objectForKey: @"list"]);
    relatedLimit = [[c objectForKey: @"limit"] integerValue];
    NSArray *sortDescriptors = [NSArray arrayWithObject: [NSSortDescriptor sortDescriptorWithKey: @"name" ascending: YES]];
    @try {
@@GROUP@@
    } @catch (NSException *e) { Rec(@"raised"); }
    Rec(@"grouped %@", Names(outlineViewArray));
}

- (NSArray*) childrenArray: (id) item onlyImages: (BOOL) onlyImages
{
    Rec(@"children %@", Name(item));
    return [item children];
}

@@IMAGES@@

- (void) cleanup: (NSDictionary*) c
{
    BOOL onlyImages = [[c objectForKey: @"onlyImages"] boolValue];
    NSMutableArray *correspondingManagedObjects = [NSMutableArray array];
    Context *context = [[Context new] autorelease];
    id curObj = @"study";
    NSMutableArray *seriesArray = [NSMutableArray array];
    for (NSDictionary *d in [c objectForKey: @"series"]) {
        DicomSeries *s = [[DicomSeries new] autorelease];
        s.name = [d objectForKey: @"name"]; s.id = [d objectForKey: @"seriesID"]; s.ident = [d objectForKey: @"id"];
        s.imageList = [d objectForKey: @"images"];
        [seriesArray addObject: s];
    }
@@CLEANUP@@
    Rec(@"cleanup images %lu", (unsigned long)correspondingManagedObjects.count);
}

- (NSArray*) imagesArray: (DicomSeries*) series onlyImages: (BOOL) onlyImages { return series.imageList; }

@@SERVERS@@

@@TYPES@@

@@SEARCHSTRING@@

@@INTERVAL@@

@@SMARTALBUM@@

- (void) setUpSearch: (NSDictionary*) c
{
    modalityFilterMenu = [[Popup new] autorelease];
    modalityFilterMenu.indexOfSelectedItem = [[c objectForKey: @"menu"] integerValue];
    self.modalityFilter = [c objectForKey: @"modality"];
    _database = [[DicomDatabase new] autorelease];
    _database.isLocal = YES;
    queryAnswers = [c objectForKey: @"answers"];
    queryIndex = 0;
}

@@DEAD@@

- (BOOL) albumRetrieves: (NSString*) smartAlbumName
{
    BOOL autoretrieve = NO;
    @@AUTORETRIEVE@@
    return autoretrieve;
}

@end

int main(int argc, char **argv)
{
    @autoreleasepool {
        records = [NSMutableArray new];
        NSDictionary *cases = [NSPropertyListSerialization propertyListWithData: [NSData dataWithContentsOfFile: [NSString stringWithUTF8String: argv[1]]] options: 0 format: nil error: nil];
        BrowserController *b = [BrowserController new];
        NSMutableArray *out = [NSMutableArray array];
        void (^flush)(void) = ^{ for (NSString *r in records) printf("%s\n", r.UTF8String); [records removeAllObjects]; };

        for (NSArray *c in [cases objectForKey: @"entire"]) {
            [b setValue: [c objectAtIndex: 0] forKey: @"distantEntireDBResultCount"];
            [b setValue: [c objectAtIndex: 1] forKey: @"localEntireDBResultCount"];
            NSMutableArray *list = [NSMutableArray array];
            for (int i = 0; i < [[c objectAtIndex: 2] intValue]; i++) [list addObject: @(i)];
            [b setValue: list forKey: @"outlineViewArray"];
            Button *button = [[Button new] autorelease];
            [b setValue: button forKey: @"searchInEntireDBResult"];
            [b refreshEntireDBResult];
            Rec(@"entire %@ %@ %@: %@", [c objectAtIndex: 0], [c objectAtIndex: 1], [c objectAtIndex: 2], button.hidden ? @"hidden" : button.title);
            flush();
        }
        for (NSDictionary *c in [cases objectForKey: @"predicate"]) {
            NSDictionary *r = [b predicateCase: c];
            Rec(@"predicate %@ filtered %@", [r objectForKey: @"predicate"], [r objectForKey: @"filtered"]);
            flush();
        }
        for (NSDictionary *c in [cases objectForKey: @"use"]) {
            Rec(@"use %d", [b useDistant: c]);
            flush();
        }
        for (NSDictionary *c in [cases objectForKey: @"merge"]) {
            testDefaults = [c objectForKey: @"defaults"];
            [b mergeList: c];
            flush();
        }
        for (NSDictionary *c in [cases objectForKey: @"history"]) {
            testDefaults = [c objectForKey: @"defaults"];
            [b mergeHistory: c];
            flush();
        }
        for (NSDictionary *c in [cases objectForKey: @"federated"]) {
            [b federate: c];
            flush();
        }
        for (NSDictionary *c in [cases objectForKey: @"sort"]) {
            [b sortCase: c];
            flush();
        }
        for (NSDictionary *c in [cases objectForKey: @"group"]) {
            [b groupCase: c];
            flush();
        }
        for (NSDictionary *c in [cases objectForKey: @"images"]) {
            Item *study = [[Item new] autorelease];
            study.ident = @"study"; study.type = [c objectForKey: @"type"];
            NSMutableArray *children = [NSMutableArray array];
            for (NSDictionary *d in [c objectForKey: @"series"]) {
                Item *series = [[Item new] autorelease];
                series.ident = [d objectForKey: @"id"]; series.type = @"Series";
                series.hasThumbnail = [[d objectForKey: @"thumbnail"] boolValue];
                series.children = [d objectForKey: @"images"];
                series.images = [NSSet setWithArray: [[d objectForKey: @"images"] subarrayWithRange: NSMakeRange(0, MIN(1, [[d objectForKey: @"images"] count]))]];
                [children addObject: series];
            }
            study.children = children;
            NSArray *result = [b imagesArray: study preferredObject: [[c objectForKey: @"preferred"] intValue] onlyImages: YES];
            Rec(@"images %@", Names(result));
            flush();
        }
        for (NSDictionary *c in [cases objectForKey: @"cleanup"]) {
            [b cleanup: c];
            flush();
        }
        for (NSDictionary *c in [cases objectForKey: @"servers"]) {
            testDefaults = @{@"comparativeSearchDICOMNodes": [c objectForKey: @"chosen"]};
            candidateServers = [c objectForKey: @"candidates"];
            NSArray *found = [BrowserController comparativeServers];
            NSMutableArray *names = [NSMutableArray array];
            for (NSDictionary *s in found) [names addObject: [s objectForKey: @"Name"]];
            Rec(@"servers %@", [names componentsJoinedByString: @","]);
            flush();
        }
        for (NSNumber *type in [cases objectForKey: @"types"]) {
            Rec(@"type %@: %@", type, [BrowserController stringForSearchType: type.intValue]);
            flush();
        }
        testDefaults = @{};
        candidateServers = @[];
        for (NSDictionary *c in [cases objectForKey: @"search"]) {
            [b setUpSearch: c];
            NSArray *result = [b distantStudiesForSearchString: [c objectForKey: @"string"] type: [[c objectForKey: @"type"] intValue]];
            Rec(@"search result %@", Names(result));
            flush();
        }
        for (NSDictionary *c in [cases objectForKey: @"interval"]) {
            [b setUpSearch: c];
            NSArray *result = [b distantStudiesForIntervalFrom: [c objectForKey: @"from"] to: [c objectForKey: @"to"]];
            Rec(@"interval result %@", Names(result));
            flush();
        }
        for (NSDictionary *c in [cases objectForKey: @"album"]) {
            [b setUpSearch: c];
            testDefaults = @{@"searchForComparativeStudiesOnDICOMNodes": @YES, @"searchForSmartAlbumStudiesOnDICOMNodes": @YES,
                             @"smartAlbumStudiesDICOMNodes": [c objectForKey: @"entries"]};
            NSString *album = [c objectForKey: @"name"];
            NSArray *result = [b distantStudiesForSmartAlbum: [album isEqualToString: @"<nil>"] ? nil : album];
            Rec(@"album result %@", Names(result));
            Rec(@"album autoretrieve %@", [b albumRetrieves: album] ? @"yes" : @"no");
            flush();
        }
        for (NSArray *pair in [cases objectForKey: @"patients"]) {
            NSString *shown = [pair objectAtIndex: 0], *patient = [pair objectAtIndex: 1];
            BOOL same = [shown compare: patient options: @@SAMEPATIENT@@] == NSOrderedSame;
            Rec(@"patient %@ %@: %d", shown, patient, same);
            flush();
        }
        for (NSDictionary *c in [cases objectForKey: @"dead"]) {
            processFolder = [[c objectForKey: @"folder"] UTF8String];
            [b searchDeadProcesses];
            flush();
        }
    }
    return 0;
}
'''
pieces = {'ENTIRE': entire, 'PREDICATE': predicate_block, 'USE': use_block, 'MERGE': defaults(merge_block),
          'HISTORY': '    NSMutableArray *studyToAutoretrieve = [NSMutableArray array];\n' + defaults(history_block.split('\n', 2)[2]),
          'FEDERATED': federated_block, 'SORT': sort_block, 'GROUP': defaults(group_block), 'IMAGES': images,
          'CLEANUP': cleanup_block, 'SERVERS': defaults(servers), 'TYPES': type_names, 'SEARCHSTRING': search_string,
          'INTERVAL': interval, 'SMARTALBUM': defaults(smart_album), 'SAMEPATIENT': same_patient, 'DEAD': dead,
          'AUTORETRIEVE': defaults(autoretrieve_loop)}
OBJC = re.sub(r'@@(\w+)@@', lambda m: pieces[m.group(1)], OBJC)

SWIFT = r'''
import Foundation

var records: [String] = []
func rec(_ line: String) { records.append(line) }
func flush() { for r in records { print(r) }; records.removeAll() }

func str(_ value: Any?) -> String? { value as? String }
func int(_ value: Any?) -> Int32 { (value as? NSNumber)?.int32Value ?? 0 }
func date(_ value: Any?) -> Date? { value as? Date }
func names(_ list: [String]?) -> String { list.map { $0.joined(separator: ",") } ?? "nil" }
func plain(_ object: Any?) -> String {
    guard let object else { return "nil" }
    if let d = object as? NSDictionary {
        let keys = (d.allKeys as! [String]).sorted { ($0 as NSString).compare($1) == .orderedAscending }
        return "{" + keys.map { "\($0)=\(plain(d.object(forKey: $0)))" }.joined(separator: ";") + "}"
    }
    if let a = object as? [Any] { return "[" + a.map(plain).joined(separator: ",") + "]" }
    if let d = object as? Date { return String(format: "date(%.3f)", d.timeIntervalSinceReferenceDate) }
    return (object as AnyObject).description
}

struct Node {
    var id: String, uid: String?, patientID: String?, name: String?, files: NSNumber?, raw: NSNumber?, date: Double?
    init(_ d: [String: Any]) {
        id = d["id"] as! String; uid = d["uid"] as? String; patientID = d["patientID"] as? String; name = d["name"] as? String
        files = d["files"] as? NSNumber; raw = d["raw"] as? NSNumber; date = (d["date"] as? NSNumber)?.doubleValue
    }
    var filesValue: Int32 { rec("files \(id)"); return files?.int32Value ?? 0 }
    var rawValue: Int32 { rec("raw \(id)"); return raw?.int32Value ?? 0 }
}
func nodes(_ value: Any?) -> [Node]? { (value as? [[String: Any]])?.map(Node.init) }

let cases = try! PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])), format: nil) as! [String: Any]

for case let c as [NSNumber] in cases["entire"] as! [Any] {
    let shown = EntireDatabaseResult.shownCount(distant: c[0].int32Value, local: c[1].int32Value, displayed: c[2].intValue)
    rec("entire \(c[0]) \(c[1]) \(c[2]): " + (shown.map { "\($0)" } ?? "hidden"))
    flush()
}
for case let c as [String: Any] in cases["predicate"] as! [Any] {
    let menu = (c["menu"] as? NSNumber)?.intValue ?? 0
    let modality = str(c["modality"])
    let chosen = menu > 0 && ((modality as NSString?)?.length ?? 0) > 0 ? modality : nil
    let made = StudyListPredicate.make(start: date(c["start"]), end: date(c["end"]), modality: chosen,
                                       filter: str(c["filter"]).map { NSPredicate(format: $0) }, test: str(c["test"]).map { NSPredicate(format: $0) })
    rec("predicate \(made.predicate.predicateFormat) filtered \(made.filtered ? 1 : 0)")
    flush()
}
for case let c as [String: Any] in cases["use"] as! [Any] {
    let apply = DistantStudiesInList.apply(hasDistantStudies: (c["hasDistant"] as? Bool) ?? false, smartAlbum: str(c["album"]), distantAlbum: str(c["distantAlbum"]),
                                           start: date(c["start"]), end: date(c["end"]), distantStart: date(c["distantStart"]), distantEnd: date(c["distantEnd"]),
                                           hasFilter: (c["hasFilter"] as? Bool) ?? false, searchType: int(c["type"]), distantSearchType: int(c["distantType"]),
                                           searchString: str(c["search"]), distantSearchString: str(c["distantSearch"]))
    rec("use \(apply ? 1 : 0)")
    flush()
}
func flag(_ c: [String: Any], _ key: String) -> Bool { ((c["defaults"] as? [String: Any])?[key] as? Bool) ?? false }
for case let c as [String: Any] in cases["merge"] as! [Any] {
    let local = nodes(c["local"]) ?? [], distant = nodes(c["distant"]) ?? []
    let queue = (c["queue"] as? [String]) ?? []
    let merge = DistantStudyMerge.list(localUIDs: local.map(\.uid), distantUIDs: distant.map(\.uid), preferMoreImages: flag(c, "preferStudyWithMoreImages"),
                                       autoretrieve: (c["autoretrieve"] as? Bool) ?? false, retrievePartial: flag(c, "automaticallyRetrievePartialStudies"),
                                       inRetrieveQueue: { d in distant[d].uid.map { u in queue.contains { ($0 as NSString).isEqual(to: u) } } ?? false },
                                       localRawFiles: { local[$0].rawValue }, distantRawFiles: { distant[$0].rawValue }, distantFiles: { distant[$0].filesValue })
    var list = local.map(\.id)
    for r in merge.replaced { list[r.row] = distant[r.distant].id }
    rec("list \(names(c["local"] == nil ? nil : list)) added \(names(merge.added.map { distant[$0].id })) retrieved \(names(merge.retrieved.map { distant[$0].id }))")
    flush()
}
for case let c as [String: Any] in cases["history"] as! [Any] {
    let local = nodes(c["local"]) ?? [], distant = nodes(c["distant"]) ?? []
    let queue = (c["queue"] as? [String]) ?? []
    let merge = DistantStudyMerge.history(localUIDs: local.map(\.uid), distantUIDs: distant.map(\.uid), preferMoreImages: flag(c, "preferStudyWithMoreImages"),
                                          retrievePartial: flag(c, "automaticallyRetrievePartialStudies"),
                                          inRetrieveQueue: { d in distant[d].uid.map { u in queue.contains { ($0 as NSString).isEqual(to: u) } } ?? false },
                                          localRawFiles: { local[$0].rawValue }, distantRawFiles: { distant[$0].rawValue }, distantFiles: { distant[$0].filesValue })
    let members = merge.members.map { m -> String in
        switch m { case .local(let i): return local[i].id; case .distant(let d): return distant[d].id }
    }
    rec("history \(names(members)) retrieved \(names(merge.retrieved.map { distant[$0].id }))")
    flush()
}
for case let c as [String: Any] in cases["federated"] as! [Any] {
    let local = nodes(c["local"]) ?? [], federated = nodes(c["federated"]) ?? []
    let added = DistantStudyMerge.federated(localKeys: (c["local"] as! [[String: Any]]).map { $0["patientUID"] as? String },
                                            federatedKeys: (c["federated"] as! [[String: Any]]).map { $0["patientUID"] as? String })
    rec("federated \(names(local.map(\.id) + added.map { federated[$0].id }))")
    flush()
}
for case let c as [String: Any] in cases["sort"] as! [Any] {
    let current = (c["keys"] as? [String])?.map { NSSortDescriptor(key: $0 == "<nil>" ? nil : $0, ascending: $0.hasPrefix("n")) }
    let sorted = StudyListOrder.descriptors(current)
    rec("sort " + sorted.map { "\($0.key ?? "(null)")/\($0.ascending ? 1 : 0)/\($0.selector.map { NSStringFromSelector($0) } ?? "-")" }.joined(separator: ","))
    flush()
}
for case let c as [String: Any] in cases["group"] as! [Any] {
    let pool = nodes(c["pool"]) ?? []
    let list = (nodes(c["list"]) ?? []).enumerated().sorted { a, b in
        let order = ((a.element.name ?? "") as NSString).compare(b.element.name ?? "")
        return order == .orderedAscending || (order == .orderedSame && a.offset < b.offset)
    }.map(\.element)
    rec("original \(names(list.map(\.id)))")
    var related: [Int: [Node]] = [:]
    let rows = StudyListOrder.groupedByPatient(uids: list.map(\.uid), limit: (c["limit"] as? NSNumber)?.intValue ?? 0) { i in
        let study = list[i]
        let found = pool.filter { p in
            let samePatient = (p.patientID == nil && study.patientID == nil) || (p.patientID != nil && study.patientID != nil && (p.patientID! as NSString).isEqual(to: study.patientID!))
            let sameUID = (p.uid == nil && study.uid == nil) || (p.uid != nil && study.uid != nil && (p.uid! as NSString).isEqual(to: study.uid!))
            return samePatient && !sameUID
        }.enumerated().sorted { a, b in
            (a.element.date ?? 0) > (b.element.date ?? 0) || ((a.element.date ?? 0) == (b.element.date ?? 0) && a.offset < b.offset)
        }.map(\.element)
        related[i] = found
        return found.map(\.uid)
    }
    rec("grouped " + rows.map { row -> String in
        switch row { case .study(let i): return list[i].id; case .related(let i, let j): return related[i]![j].id }
    }.joined(separator: ","))
    flush()
}
for case let c as [String: Any] in cases["images"] as! [Any] {
    let series = c["series"] as! [[String: Any]]
    var result: [String]? = nil
    rec("children study")
    if (c["type"] as? String) == "Series" {
        result = series.map { $0["id"] as! String }
    } else if (c["type"] as? String) == "Study" {
        result = []
        var walk = SelectionImages.Walk(preferred: int(c["preferred"]))
        for s in series {
            let id = s["id"] as! String, images = s["images"] as! [String]
            let which = walk.next(hasThumbnail: { rec("thumbnail \(id)"); return (s["thumbnail"] as? Bool) ?? false })
            switch which {
            case SelectionImages.any:
                if let first = images.first { result!.append(first) }
            case SelectionImages.middle:
                rec("children \(id)")
                if let m = SelectionImages.middleIndex(count: images.count) { result!.append(images[m]) }
            case SelectionImages.firstForFirst:
                rec("children \(id)")
                if !images.isEmpty { result!.append(images[0]) }
            default: break
            }
        }
    }
    rec("images \(names(result))")
    flush()
}
for case let c as [String: Any] in cases["cleanup"] as! [Any] {
    let series = c["series"] as! [[String: Any]]
    var total: Int32 = 0
    var marker: String? = nil
    for s in series {
        total = total &+ Int32((s["images"] as! [Any]).count)
        if SelectionImages.isNoAutodeletionSeries(name: s["name"] as? String, id: int(s["seriesID"])) { marker = s["id"] as? String }
    }
    let cleanup = SelectionImages.studyCleanup(imageCount: Int(total), hasNoAutodeletionSeries: marker != nil, onlyImages: (c["onlyImages"] as? Bool) ?? false)
    if cleanup.deleteSeries { rec("delete \(marker!)") }
    if cleanup.deleteStudy { rec("delete study") }
    rec("cleanup images \(series.reduce(0) { $0 + ($1["images"] as! [Any]).count })")
    flush()
}
for case let c as [String: Any] in cases["servers"] as! [Any] {
    let candidates = (c["candidates"] as! [Any]).compactMap { $0 as? NSDictionary }
    let found = DistantSearch.comparativeServers(chosen: (c["chosen"] as! [Any]).compactMap { $0 as? NSDictionary }, candidates: candidates)
    rec("servers " + found.servers.map { candidates[$0]["Name"] as! String }.joined(separator: ","))
    flush()
}
for case let type as NSNumber in cases["types"] as! [Any] {
    rec("type \(type): \(DistantSearch.searchTypeName(type.int32Value) ?? "")")
    flush()
}
var queryIndex = 0
var answers: [Any] = []
func query(_ filters: NSDictionary) -> [Node]? {
    rec("query \(plain(filters)) servers 0")
    defer { queryIndex += 1 }
    guard queryIndex < answers.count else { return nil }
    return nodes(answers[queryIndex])
}
func chosenModality(_ c: [String: Any]) -> String? {
    let menu = (c["menu"] as? NSNumber)?.intValue ?? 0
    let modality = str(c["modality"])
    return menu > 0 && ((modality as NSString?)?.length ?? 0) > 0 ? modality : nil
}
for case let c as [String: Any] in cases["search"] as! [Any] {
    answers = (c["answers"] as? [Any]) ?? []; queryIndex = 0
    let type = int(c["type"])
    var result: [Node]?
    if type == DistantSearch.seriesDescriptionType {
        result = []
    } else {
        let search = DistantSearch.searchFilters(c["string"] as! String, type: type, modality: chosenModality(c))
        result = query(search.filters)
        if let name = DistantSearch.alternatePatientName(search.name, type: type) {
            search.filters["PatientsName"] = name
            let more = query(search.filters) ?? []
            if let found = result {
                result = found + DistantStudyMerge.missing(from: found.map(\.uid), in: more.map(\.uid)).map { more[$0] }
            }
        }
    }
    rec("search result \(names(result?.map(\.id)))")
    flush()
}
for case let c as [String: Any] in cases["interval"] as! [Any] {
    answers = (c["answers"] as? [Any]) ?? []; queryIndex = 0
    var result: [Node]?
    if let filters = DistantSearch.intervalFilters(from: date(c["from"]), to: date(c["to"]), modality: chosenModality(c)) {
        result = query(filters)
    } else {
        rec("exception")
    }
    rec("interval result \(names(result?.map(\.id)))")
    flush()
}
for case let c as [String: Any] in cases["album"] as! [Any] {
    answers = (c["answers"] as? [Any]) ?? []; queryIndex = 0
    let entries = (c["entries"] as! [Any]).compactMap { $0 as? NSDictionary }
    let album = (c["name"] as! String) == "<nil>" ? nil : c["name"] as? String
    var result: [Node]?
    if let filters = DistantSearch.smartAlbumFilters(entries, album: album) {
        result = query(filters)
    }
    rec("album result \(names(result?.map(\.id)))")
    rec("album autoretrieve \(DistantSearch.albumRetrievesAutomatically(entries, album: c["name"] as? String) ? "yes" : "no")")
    flush()
}
for case let pair as [String] in cases["patients"] as! [Any] {
    rec("patient \(pair[0]) \(pair[1]): \(DistantSearch.samePatient(pair[0], pair[1]) ? 1 : 0)")
    flush()
}
for case let c as [String: Any] in cases["dead"] as! [Any] {
    let folder = c["folder"] as! String
    var kills: [String] = []
    for name in (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [] {
        guard ProcessLocks.pid(forFileName: name) != nil else { continue }
        let created = (try? FileManager.default.attributesOfItem(atPath: (folder as NSString).appendingPathComponent(name)))?[.creationDate] as? Date
        let sinceNow = created?.timeIntervalSinceNow ?? 0
        if ProcessLocks.isStale(sinceNow: sinceNow) {
            let pid = ProcessLocks.pid(forFileName: name) ?? 0
            if pid != 0 {
                kills.append("kill \(pid) 15")
                kills.append("unlink lock_process-\(pid)")
            }
        }
    }
    for k in kills { rec(k) }
    flush()
}
'''


def build_cases(folder):
    rng = random.Random(20261027)
    entire = [[d, l, n] for d, l, n in [(0, 0, 0), (5, 0, 3), (0, 5, 5), (2, 9, 4), (-1, 0, 3), (0, -3, 7), (7, 7, 7), (2147483647, 1, 2)]]
    for _ in range(40):
        entire.append([rng.choice([0, 1, 3, 10, 50, -2]), rng.choice([0, 2, 9, 40, -1]), rng.choice([0, 1, 5, 20])])

    t0, t1 = 800000000.5, 800086400.25
    predicate = []
    for start in [None, t0]:
        for end in [None, t1]:
            for menu, modality in [(0, None), (0, 'CT'), (2, 'MR'), (1, ''), (3, None)]:
                for filt in [None, 'name CONTAINS[cd] "smith"']:
                    for test in [None, 'modality == "US"']:
                        c = {'menu': menu}
                        if start is not None:
                            c['start'] = dt(start)
                        if end is not None:
                            c['end'] = dt(end)
                        if modality is not None:
                            c['modality'] = modality
                        if filt:
                            c['filter'] = filt
                        if test:
                            c['test'] = test
                        predicate.append(c)

    use = []
    strings = [None, 'abc', 'Ab', 'é', 'é']
    for _ in range(160):
        c = {'hasDistant': rng.random() < 0.6, 'hasFilter': rng.random() < 0.5,
             'type': rng.choice([0, 1, 5]), 'distantType': rng.choice([0, 1, 5])}
        for key, values in [('album', ['A', 'B', None]), ('distantAlbum', ['A', 'B', None]), ('search', strings), ('distantSearch', strings)]:
            v = rng.choice(values)
            if v is not None:
                c[key] = v
        for key in ['start', 'end', 'distantStart', 'distantEnd']:
            v = rng.choice([None, t0, t1])
            if v is not None:
                c[key] = dt(v)
        use.append(c)

    def study(ident, uid, files=None, raw=None, **more):
        d = {'id': ident}
        if uid is not None:
            d['uid'] = uid
        if files is not None:
            d['files'] = files
        if raw is not None:
            d['raw'] = raw
        d.update(more)
        return d

    merge, history = [], []
    uids = ['1.2', '1.3', '1.4', '1.5', None, 'é', 'é']
    for n in range(80):
        local = [study('L%d' % i, rng.choice(uids), rng.randint(0, 9), rng.randint(0, 9)) for i in range(rng.randint(0, 5))]
        distant = [study('D%d' % i, rng.choice(uids), rng.randint(0, 12), rng.randint(0, 12)) for i in range(rng.randint(0, 5))]
        queue = [u for u in rng.sample([u for u in uids if u], rng.randint(0, 2))]
        flags = {'preferStudyWithMoreImages': rng.random() < 0.7, 'automaticallyRetrievePartialStudies': rng.random() < 0.4}
        c = {'local': local, 'distant': distant, 'queue': queue, 'defaults': flags, 'autoretrieve': rng.random() < 0.3}
        if n % 17 == 5:
            del c['local']
        merge.append(c)
        history.append({'local': local, 'distant': distant, 'queue': queue, 'defaults': flags})

    federated = []
    keys = ['p1', 'p2', 'p3', None, 'é', 'é']
    for _ in range(30):
        federated.append({'local': [study('L%d' % i, None, patientUID=k) if k else study('L%d' % i, None) for i, k in enumerate(rng.choices(keys, k=rng.randint(0, 4)))],
                          'federated': [study('F%d' % i, None, patientUID=k) if k else study('F%d' % i, None) for i, k in enumerate(rng.choices(keys, k=rng.randint(0, 4)))]})

    sort = [{}, {'keys': []}, {'keys': ['name']}, {'keys': ['name', 'date']}, {'keys': ['date']}, {'keys': ['nmodality', 'name']},
            {'keys': ['<nil>']}, {'keys': ['noFiles', 'name']}]

    group = []
    for n in range(40):
        pool = []
        for i in range(rng.randint(2, 9)):
            pool.append(study('P%d' % i, rng.choice(['u%d' % i, 'u%d' % i, 'u%d' % i, None, 'u0']), patientID=rng.choice(['A', 'B', 'C', None]),
                              name=rng.choice(['ann', 'bob', 'cid', 'dan']), date=float(rng.randint(0, 1000))))
        listed = rng.sample(pool, rng.randint(1, len(pool)))
        group.append({'pool': pool, 'list': listed, 'limit': rng.choice([0, 0, 1, 2, -1])})

    images = []
    for n in range(60):
        series = []
        for i in range(rng.randint(0, 5)):
            series.append({'id': 'S%d' % i, 'thumbnail': rng.random() < 0.6, 'images': ['S%d.%d' % (i, j) for j in range(rng.choice([0, 1, 2, 3, 6, 7]))]})
        images.append({'type': rng.choice(['Study', 'Study', 'Series', 'Image']), 'preferred': rng.choice([0, 1, 2]), 'series': series})

    cleanup = []
    for n in range(40):
        series = []
        for i in range(rng.randint(0, 4)):
            series.append({'id': 'S%d' % i, 'name': rng.choice(['OsiriX No Autodeletion', 'CT', 'OsiriX No Autodeletion ', 'osirix no autodeletion']),
                           'seriesID': rng.choice([5005, 5005, 1, 0]), 'images': ['x'] * rng.choice([0, 0, 1, 3])})
        cleanup.append({'series': series, 'onlyImages': rng.random() < 0.5})

    def node(name, description, address):
        d = {'Name': name}
        if description is not None:
            d['Description'] = description
        if address is not None:
            d['Address'] = address
        return d

    candidates = [node('pacs', 'PACS', '10.0.0.1'), node('web', 'Web', 'https://w'), node('pacs2', 'PACS', '10.0.0.2'),
                  node('dup', 'PACS', '10.0.0.1'), node('accent', 'é', 'h')]
    servers = []
    for chosen in [[], [{'server': {'Description': 'PACS', 'Address': '10.0.0.1'}}], [{'server': {'Description': 'Web', 'Address': 'https://w'}},
                   {'server': {'Description': 'PACS', 'Address': '10.0.0.2'}}], [{'server': {'Description': 'PACS'}}],
                   [{'server': {'Description': 'PACS'}}, {'server': {'Address': '10.0.0.1'}}], [{'server': {'Description': 'é', 'Address': 'h'}}],
                   [{'server': {'Description': 'é', 'Address': 'h'}}], [{'other': 1}]]:
        servers.append({'chosen': chosen, 'candidates': candidates})

    types = list(range(-1, 14))

    found = [study('Q1', '1.1'), study('Q2', '1.2')]
    more = [study('Q2b', '1.2'), study('Q3', '1.3'), study('Q3c', '1.3')]
    search = []
    for string in ['smith', 'smith john', 'smith, john', 'van der berg', 'a,b', 'CT', '', ' lead', 'trail ', 'é é']:
        for type in [0, 1, 2, 3, 4, 5, 6, 7, 8, 11]:
            for menu, modality in [(0, None), (2, 'MR')]:
                c = {'string': string, 'type': type, 'menu': menu, 'answers': rng.choice([[found, more], [found], ['nil', more], [found, 'nil'], []])}
                if modality:
                    c['modality'] = modality
                search.append(c)

    interval = []
    for start in [None, t0]:
        for end in [None, t1]:
            for menu, modality in [(0, None), (1, 'US')]:
                c = {'menu': menu, 'answers': [found]}
                if start is not None:
                    c['from'] = dt(start)
                if end is not None:
                    c['to'] = dt(end)
                if modality:
                    c['modality'] = modality
                interval.append(c)

    entries = [{'name': 'CT today', 'activated': True, 'modality': 'CT', 'autoretrieve': True},
               {'name': 'MR', 'activated': False}, {'name': 'MR', 'activated': 'YES', 'date': 3},
               {'name': 'é', 'activated': 1}, {'name': 'none'}]
    album = [{'name': name, 'entries': entries, 'answers': [found]} for name in ['CT today', 'MR', 'none', 'é', 'é', 'x', '<nil>']]

    patients = [['ABC', 'abc'], ['Éva', 'eva'], ['ＡＢ', 'AB'], ['a', 'b'], ['1.2', '1.2 '], ['é', 'é'], ['ß', 'SS']]

    dead = []
    now = time.time()
    for n, files in enumerate([[('lock_process-123', 7200), ('lock_process-456', 100), ('other', 9000)],
                               [('lock_process-', 7200), ('lock_process-x', 7200), ('lock_process- 77', 7200), ('lock_process-12abc', 4000)],
                               [('lock_process-99999999999', 7200), ('lock_process--5', 3700), ('lock_process-8', 3500)], []]):
        sub = folder / ('procs%d' % n)
        sub.mkdir()
        for name, age in files:
            path = sub / name
            path.write_text('')
            stamp = now - age
            os.utime(path, (stamp, stamp))
        dead.append({'folder': str(sub)})

    return {'entire': entire, 'predicate': predicate, 'use': use, 'merge': merge, 'history': history, 'federated': federated,
            'sort': sort, 'group': group, 'images': images, 'cleanup': cleanup, 'servers': servers, 'types': types,
            'search': search, 'interval': interval, 'album': album, 'patients': patients, 'dead': dead}


def dt(seconds):
    import datetime
    return datetime.datetime(2001, 1, 1) + datetime.timedelta(seconds=seconds)


failures = []
with tempfile.TemporaryDirectory(prefix='horos-study-list-') as tmp:
    tmp = Path(tmp)
    (tmp / 'cases.plist').write_bytes(plistlib.dumps(build_cases(tmp), fmt=plistlib.FMT_BINARY))
    (tmp / 'reference.m').write_text(OBJC)
    built = subprocess.run(['xcrun', 'clang', '-fno-objc-arc', '-fblocks', '-Wno-format', '-Wno-objc-method-access',
                            '-Wno-incompatible-pointer-types', '-Wno-objc-root-class',
                            '-framework', 'Foundation', '-framework', 'CoreData', str(tmp / 'reference.m'), '-o', str(tmp / 'reference')],
                           capture_output=True, text=True, timeout=300)
    if built.returncode:
        sys.exit('FAIL: the Objective-C reference does not compile:\n' + built.stderr[-3000:])
    (tmp / 'main.swift').write_text(SWIFT)
    built = subprocess.run(['xcrun', 'swiftc', '-o', str(tmp / 'current'), str(RULES), str(tmp / 'main.swift')],
                           capture_output=True, text=True, timeout=300)
    if built.returncode:
        sys.exit('FAIL: the module does not compile:\n' + built.stderr[-3000:])
    objc = subprocess.run([str(tmp / 'reference'), str(tmp / 'cases.plist')], capture_output=True, text=True, timeout=60)
    swift = subprocess.run([str(tmp / 'current'), str(tmp / 'cases.plist')], capture_output=True, text=True, timeout=60)
    if objc.returncode or swift.returncode:
        sys.exit('FAIL: a driver failed:\n' + objc.stderr[-1500:] + swift.stderr[-1500:])
    a, b = objc.stdout.splitlines(), swift.stdout.splitlines()
    if args.dump:
        args.dump.mkdir(parents=True, exist_ok=True)
        (args.dump / 'reference.txt').write_text(objc.stdout)
        (args.dump / 'current.txt').write_text(swift.stdout)
    if a != b:
        diff = list(difflib.unified_diff(a, b, 'Objective-C', 'IsiXDatabase', lineterm='', n=0))
        failures.append('records differ:\n' + '\n'.join(diff[:80]))

if failures:
    for failure in failures:
        print('FAIL:', failure)
    sys.exit(1)
kinds = {}
for line in a:
    key = line.split()[0]
    kinds[key] = kinds.get(key, 0) + 1
print('ok: the study list rules of %s and IsiXDatabase agree on %d records (%s)'
      % (reference, sum(kinds.values()), ', '.join('%s %d' % kv for kv in sorted(kinds.items()))))
