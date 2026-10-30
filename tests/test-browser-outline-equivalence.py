#!/usr/bin/env python3
"""The browser's study list rows, selection, merging and deleting decide what
their Objective-C did.

The rest of the outline functions of BrowserController.m (the selection and a
patient's history, merging and unifying, deleting, the columns menu and the
outline's data source and delegate) moved to Swift, with their rules in the
IsiXDatabase module (StudyListRowRules.swift). This compiles the Objective-C
of those methods, cut out of BrowserController.m in the last revision that
has it (history_reference; the tree itself while it still has it), with
synthetic stand-ins for the app's classes, and the module with swiftc, and
gives both the same synthetic inputs:

* what each column shows for a study, a series, an image and a study of a
  node (-intOutlineView:objectValueForTableColumn:byItem:), with the report
  plugin, the report series, the note, the federated database and the age;
* what an edit writes in the selected rows (-setDatabaseValue:item:forKey:);
* how a cell is drawn (-outlineView:willDisplayCell:forTableColumn:item:):
  font, same-patient background, recency and report icons, grey "unknown";
* the tool tip of the recency icon, the rows that expand and their children;
* the header's menu of columns: its order, its checks, the preference it
  saves and the columns -refreshColumns shows and hides;
* a patient's history: when the selection asks for another one, the row of a
  study in it, new studies joining it, the refresh of the history and of a
  smart album's distant studies;
* the thumbnails of a selection: rebuilt or not, frames of a multi-frame
  series, made on the main thread or not;
* the series the others merge into, the former identity a unified study
  keeps, the edits of the files and the character set declared;
* deleting: locked studies, studies in albums, the files outside the database
  folder and their folders, which items -delItem: deletes and what it asks.

    python3 tests/test-browser-outline-equivalence.py [--reference REV]
"""
import argparse
import difflib
import plistlib
import random
import re
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import private_tmpdir  # noqa: F401,E402
import history_reference  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
BC = 'Horos/Sources/BrowserController.m'
MARK = '- (id)intOutlineView:(NSOutlineView *)outlineView objectValueForTableColumn:(NSTableColumn *)tableColumn byItem:(id)item'
RULES = ROOT / 'Modules/IsiXDatabase/Sources/StudyListRowRules.swift'

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
    print('skipped: needs the history that has the Objective-C outline functions of BrowserController.m')
    sys.exit(2)
if reference == 'tree':
    text = (ROOT / BC).read_bytes().decode('latin1')
else:
    shown = git('show', '%s:%s' % (reference, BC))
    if shown.returncode:
        sys.exit('FAIL: no %s at %s' % (BC, reference))
    text = shown.stdout.decode('latin1')
if MARK not in text:
    sys.exit('FAIL: %s has no Objective-C -intOutlineView:objectValueForTableColumn:byItem: in %s' % (reference, BC))
if not RULES.exists():
    sys.exit('FAIL: no StudyListRowRules.swift in IsiXDatabase')


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


def between(start_text, end_text, within=text):
    at = within.index(start_text)
    return within[at:within.index(end_text, at)]


def defaults(code):
    """The defaults the methods read and write come from and go to the case, not the user's domain."""
    code = re.sub(r'\[\[NSUserDefaults standardUserDefaults\] boolForKey: ?(@"\w+")\]', r'TestBool(\1)', code)
    code = re.sub(r'\[\[NSUserDefaults standardUserDefaults\] (?:stringForKey|objectForKey): ?(@"\w+")\]', r'TestObject(\1)', code)
    code = re.sub(r'\[\[NSUserDefaults standardUserDefaults\] integerForKey: ?(@"\w+")\]', r'TestInteger(\1)', code)
    code = re.sub(r'\[\[NSUserDefaults standardUserDefaults\] setBool: ?(.+?) forKey: ?(@"\w+")\]', r'TestSetBool(\1, \2)', code)
    code = re.sub(r'\[\[NSUserDefaults standardUserDefaults\] setObject: ?(.+?) forKey: ?(@"\w+")\]', r'TestSetObject(\1, \2)', code)
    return code


def managed(code):
    return re.sub(r'\bNSManagedObject\b', 'Mock', code)


value_method = defaults(managed(method(MARK)))
edit_block = between('        if( [key isEqualToString:@"stateText"])', '        [refreshTimer setFireDate:', method('- (void) setDatabaseValue:(id) object item:(id) item forKey:(NSString*) key'))
display = method('- (void)outlineView: (NSOutlineView *)outlineView willDisplayCell: (id)cell forTableColumn: (NSTableColumn *)tableColumn item: (id)item')
display = re.sub(r'DCMCalendarDate\s*\*now = .*?NSDate\s*\*today = [^;]*;', 'NSDate *today = TestToday();', display, flags=re.S)
display = display.replace('[[NSWorkspace sharedWorkspace] iconForContentType:([UTType typeWithFilenameExtension:@"download"] ?: UTTypeData)]',
                          '[TestImage imageNamed:@"download-icon"]')
display = defaults(managed(display.replace('NSImage', 'TestImage')))
if 'DCMCalendarDate' in display or 'UTType' in display:
    sys.exit('FAIL: -outlineView:willDisplayCell:forTableColumn:item: changed: cannot stand in for its calendar or icons')
tooltip = defaults(method('-(NSString*)outlineView:(NSOutlineView*)outlineView toolTipForCell:(NSCell*)cell rect:(NSRectPointer)rect tableColumn:(NSTableColumn*)tableColumn item:(id)item mouseLocation:(NSPoint)mouseLocation'))
expandable = method('- (BOOL)outlineView:(NSOutlineView *)outlineView isItemExpandable:(id)item')
children_count = method('- (NSInteger)outlineView:(NSOutlineView *)outlineView numberOfChildrenOfItem:(id)item')
columns_build = method('- (void)buildColumnsMenu')
columns_open = defaults(method('-(void)columnsMenuWillOpen'))
columns_action = defaults(method('- (void) columnsMenuAction: (id)sender'))
columns_refresh = defaults(method('- (void)refreshColumns'))
new_studies = method('- (void)_newStudiesRefreshComparativeStudies: (NSNotification *)aNotification')
refresh_history = managed(method('- (void) refreshComparativeStudies: (NSArray*) newStudies'))
refresh_needed = method('- (void) refreshComparativeStudiesIfNeeded:(id) timer')
refresh_needed = managed(defaults(between('- (void) refreshComparativeStudiesIfNeeded:(id) timer', '    if( comparativeStudyWaited)', refresh_needed)))
refresh_needed = re.sub(r'\[NSThread detachNewThreadSelector: @selector\((\w+:)\) toTarget:self withObject: ([^\]]+)\]', r'Rec(@"detach \1 %@", Plain(\2))', refresh_needed)
waited_condition = re.search(r'if\( (\[NSDate timeIntervalSinceReferenceDate\] - comparativeStudyWaitedTime < \d+)\)', method('- (void) refreshComparativeStudiesIfNeeded:(id) timer')).group(1)
selection = method('- (void)outlineViewSelectionDidChange:(NSNotification *)aNotification')
history_block = managed(between('            if( previousItem != item)', '            if( [item isDistant])\n                self.distantStudyMessage', selection))
history_block = re.sub(r'\[NSThread detachNewThreadSelector: @selector\((\w+:)\) toTarget:self withObject: ([^\]]+)\]', r'Rec(@"detach \1 %@", Plain(\2))', history_block)
refresh_block = managed(between('            BOOL refreshMatrix = YES;', '            if( refreshMatrix)', selection))
frames_condition = re.search(r'if \((\[\[item valueForKey:@"type"\] isEqualToString:@"Series"\] &&.*?> 1)\)\n', selection, re.S).group(1)
thread_block = between('                BOOL separateThread = YES;', '                @synchronized( previewPixThumbnails)', selection)
merge_series = method('- (void) mergeSeriesExecute:(NSArray*) seriesArray')
destination_block = managed(between('            NSManagedObject\t*destSeries = [seriesArray objectAtIndex: 0];', '            NSLog(@"MERGING SERIES', merge_series))
identity_functions = between('static void HorosFormerIdentity', '#endif\n\n#ifndef OSIRIX_LIGHT\n- (IBAction) unifyStudies')
unify = method('- (IBAction) unifyStudies:(id) sender')
unify_edits = re.search(r'NSArray\* tagAndValues = \[NSArray arrayWithObjects:.*?nil\];', unify, re.S).group(0)
merge_studies = method('- (IBAction) mergeStudies:(id) sender')
merge_edits = between('                                NSMutableArray* tagAndValues = [NSMutableArray array];',
                      '                                NSMutableArray *files = [NSMutableArray arrayWithArray: [[study paths] allObjects]];', merge_studies)
delete_objects = method('- (void) delObjects:(NSMutableArray*) objectsToDelete tree:(NSMutableSet*)treeObjs')
del_item = method('- (IBAction)delItem: (id)sender')
thumbnails_block = between('    if( sender == nil)', '    if( matrixThumbnails == NO && [databaseOutline selectedRow] == -1)', del_item)
question_block = between('    if( albumTable.selectedRow > 0 && matrixThumbnails == NO)', '    [context retain];', del_item)

OBJC = r'''
#import <Cocoa/Cocoa.h>
#undef NSLocalizedString
#define NSLocalizedString(key, comment) (key)
#define N2LogExceptionWithStackTrace(e) Rec(@"exception %@", [(e) name])
#define N2LogStackTrace(...) Rec(@"stack")
#define N2ManagedObjectContextPerformAndWait(context, ...) (__VA_ARGS__)()
#define HorosAlertDefaultResponse 1
#define HorosAlertAlternateResponse 0
#define HorosAlertOtherResponse -1
#define OsirixAddToDBNotificationImagesArray @"OsirixAddToDBNotificationImagesArray"
enum dbObjectSelection {oAny, oMiddle, oFirstForFirst};

static NSMutableArray *records;
static NSDictionary *testDefaults;
static void Rec(NSString *format, ...) {
    va_list list; va_start(list, format);
    [records addObject: [[[NSString alloc] initWithFormat: format arguments: list] autorelease]];
    va_end(list);
}
#define TestBool(key) [[testDefaults objectForKey: key] boolValue]
#define TestObject(key) [testDefaults objectForKey: key]
#define TestInteger(key) [[testDefaults objectForKey: key] integerValue]

static NSString *Plain(id object);
static void TestSetBool(BOOL value, NSString *key) { Rec(@"defaults %@ bool %d", key, (int) value); }
static void TestSetObject(id value, NSString *key) { Rec(@"defaults %@ %@", key, Plain(value)); }

static NSString *Plain(id object) {
    if (object == nil) return @"nil";
    if ([object isKindOfClass: [NSString class]]) return [NSString stringWithFormat: @"'%@'", object];
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
    if ([object isKindOfClass: [NSFont class]]) return [NSString stringWithFormat: @"font(%@ %.2f)", [object fontName], [object pointSize]];
    if ([object isKindOfClass: [NSNumber class]]) return [NSString stringWithFormat: @"n%@", object];
    if ([object respondsToSelector: @selector(ident)]) return [object performSelector: @selector(ident)];
    return [object description];
}

@interface NSException (Test)
- (NSString*) printStackTrace;
@end
@implementation NSException (Test)
- (NSString*) printStackTrace { Rec(@"stack trace"); return @""; }
@end

@@FONT@@

@interface TestImage : NSObject
@property(retain) NSString *ident;
+ (id) imageNamed: (NSString*) name;
@end
@implementation TestImage
+ (id) imageNamed: (NSString*) name { TestImage *image = [[self new] autorelease]; image.ident = [@"img:" stringByAppendingString: name]; return image; }
- (id) copyWithZone: (NSZone*) zone { return [self retain]; }
- (void) setSize: (NSSize) size {}
@end

static NSTimeInterval testToday;
static NSDate *TestToday(void) { return [NSDate dateWithTimeIntervalSinceReferenceDate: testToday]; }

@interface Mock : NSObject
@property(retain) NSString *ident;
@property(retain) NSMutableDictionary *values;
@property BOOL distant;
@property(retain) id context;
- (BOOL) isDistant;
- (id) managedObjectContext;
- (id) objectID;
- (NSString*) name;
- (NSString*) studyName;
- (NSString*) studyInstanceUID;
- (NSString*) patientUID;
- (NSString*) patientID;
- (NSDate*) date;
- (NSString*) note;
- (NSUInteger) numberOfImageSeries;
- (id) series;
- (id) primitiveValueForKey: (NSString*) key;
@end
@implementation Mock
- (id) valueForKey: (NSString*) key { id v = [self.values objectForKey: key]; return v == [NSNull null] ? nil : v; }
- (id) valueForKeyPath: (NSString*) keyPath {
    NSArray *keys = [keyPath componentsSeparatedByString: @"."];
    id value = [self valueForKey: [keys objectAtIndex: 0]];
    return keys.count > 1 ? [value valueForKeyPath: [[keys subarrayWithRange: NSMakeRange(1, keys.count - 1)] componentsJoinedByString: @"."]] : value;
}
- (void) setValue: (id) value forKey: (NSString*) key { Rec(@"set %@ %@ %@", self.ident, key, Plain(value)); }
- (BOOL) isDistant { return self.distant; }
- (id) managedObjectContext { return self.context; }
- (id) objectID { return [@"oid-" stringByAppendingString: self.ident]; }
- (NSString*) name { return [self valueForKey: @"name"]; }
- (NSString*) studyName { return [self valueForKey: @"studyName"]; }
- (NSString*) studyInstanceUID { return [self valueForKey: @"studyInstanceUID"]; }
- (NSString*) patientUID { return [self valueForKey: @"patientUID"]; }
- (NSString*) patientID { return [self valueForKey: @"patientID"]; }
- (NSDate*) date { return [self valueForKey: @"date"]; }
- (NSString*) note { return [self valueForKey: @"note"]; }
- (NSUInteger) numberOfImageSeries { return [[self valueForKey: @"nis"] unsignedIntegerValue]; }
- (id) series { return [self valueForKey: @"series"]; }
- (id) primitiveValueForKey: (NSString*) key { Rec(@"primitive %@ %@", self.ident, key); return [self valueForKey: key]; }
- (BOOL) isEqual: (id) other { return self == other; }
- (NSUInteger) hash { return (NSUInteger) self; }
@end
@interface DicomStudy : Mock
@end
@implementation DicomStudy
@end
@interface DicomSeries : Mock
@end
@implementation DicomSeries
@end
@interface DicomImage : Mock
@end
@implementation DicomImage
@end
@interface DicomAlbum : Mock
@end
@implementation DicomAlbum
@end
@interface DCMTKQueryNode : Mock
@property(retain) NSArray *kids, *queryGives;
@end
@implementation DCMTKQueryNode
- (NSArray*) children { return self.kids; }
- (void) purgeChildren { Rec(@"purge %@", self.ident); self.kids = nil; }
- (void) queryWithValues: (NSArray*) values { Rec(@"query %@", self.ident); self.kids = self.queryGives; }
- (void) setChildren: (NSArray*) c { Rec(@"setChildren %@ %lu", self.ident, (unsigned long) c.count); self.kids = [[c mutableCopy] autorelease]; }
@end
@interface DCMTKStudyQueryNode : DCMTKQueryNode
@end
@implementation DCMTKStudyQueryNode
@end
@interface DCMTKSeriesQueryNode : DCMTKQueryNode
@end
@implementation DCMTKSeriesQueryNode
@end
@interface HorosSurgicalProcedureOutlineRow : NSObject
@end
@implementation HorosSurgicalProcedureOutlineRow
- (NSString*) ident { return @"surgical"; }
- (BOOL) isDistant { return NO; }
- (id) valueForKey: (NSString*) key { return nil; }
@end

static NSDictionary *databasesByContext;
@interface DicomDatabase : NSObject
@property(retain) NSString *baseDirPath, *name, *ident;
@property BOOL local;
@end
static NSDictionary *contextObjects;
@implementation DicomDatabase
+ (DicomDatabase*) databaseForContext: (id) context { return context ? [databasesByContext objectForKey: context] : nil; }
- (id) managedObjectContext { return nil; }
- (id) objectWithID: (id) objectID { Rec(@"objectWithID %@", objectID); return [contextObjects objectForKey: objectID]; }
- (BOOL) isLocal { return self.local; }
- (BOOL) save: (NSError**) error { Rec(@"save %@", self.ident); return YES; }
@end
@interface RemoteDicomDatabase : DicomDatabase
@end
@implementation RemoteDicomDatabase
- (void) object: (id) object setValue: (id) value forKey: (NSString*) key { Rec(@"remote %@ %@ %@", Plain(object), key, Plain(value)); }
@end

@interface HorosFederatedSearch : NSObject
@end
@implementation HorosFederatedSearch
+ (BOOL) pathsEqual: (NSString*) a other: (NSString*) b { return a && b && [[a lowercaseString] isEqualToString: [b lowercaseString]]; }
+ (NSString*) displayName: (NSString*) name origin: (NSString*) origin currentOrigin: (NSString*) current { return [NSString stringWithFormat: @"%@ <%@ / %@>", name, origin, current]; }
+ (NSString*) displayOriginWithName: (NSString*) name path: (NSString*) path { return [NSString stringWithFormat: @"%@@%@", name, path]; }
@end

@interface PluginFilter : NSObject
+ (id) filter;
- (id) reportDateForStudy: (id) study;
@end
@implementation PluginFilter
+ (id) filter { return [[self new] autorelease]; }
- (id) reportDateForStudy: (id) study { Rec(@"plugin date %@", Plain(study)); return [study valueForKey: @"pluginDate"]; }
@end
@interface FakeBundle : NSObject
@end
@implementation FakeBundle
- (Class) principalClass { return [PluginFilter class]; }
@end
static NSDictionary *reportPlugins;
@interface PluginManager : NSObject
@end
@implementation PluginManager
+ (NSDictionary*) reportPlugins { return reportPlugins; }
+ (void) startProtectForCrashWithFilter: (id) filter { Rec(@"protect"); }
+ (void) endProtectForCrash { Rec(@"unprotect"); }
@end
@interface DCMAbstractSyntaxUID : NSObject
@end
@implementation DCMAbstractSyntaxUID
+ (BOOL) isStructuredReport: (NSString*) uid { return [uid hasPrefix: @"1.2.840.10008.5.1.4.1.1.88"]; }
@end
@interface HorosStudyNote : NSObject
@end
@implementation HorosStudyNote
+ (NSString*) singleLineTextOfNote: (NSString*) note { return note ? [[note componentsSeparatedByString: @"\n"] componentsJoinedByString: @" "] : nil; }
@end

@interface Cell : NSObject
@property(retain) NSString *ident;
@property BOOL colored;
@end
@implementation Cell
- (void) setHighlighted: (BOOL) flag { Rec(@"cell highlighted %d", (int) flag); }
- (void) setFont: (id) font { Rec(@"cell font %@", Plain(font)); }
- (void) setImage: (id) image { Rec(@"cell image %@", Plain(image)); }
- (void) setTransparent: (BOOL) flag { Rec(@"cell transparent %d", (int) flag); }
- (void) setDrawsBackground: (BOOL) flag { Rec(@"cell background %d", (int) flag); }
- (void) setBackgroundColor: (NSColor*) color { Rec(@"cell backgroundColor %@", [color description]); }
- (void) setLineBreakMode: (NSLineBreakMode) mode { Rec(@"cell lineBreak %d", (int) mode); }
- (void) setTextColor: (NSColor*) color { Rec(@"cell textColor %@", [color description]); }
- (BOOL) respondsToSelector: (SEL) selector {
    if (selector == @selector(setTextColor:)) return self.colored;
    return [super respondsToSelector: selector];
}
@end
@interface ImageAndTextCell : Cell
@end
@implementation ImageAndTextCell
- (void) setLastImage: (id) image { Rec(@"cell lastImage %@", Plain(image)); }
@end

@interface Window : NSObject
@property(assign) id firstResponder;
@end
@implementation Window
@end

@interface HeaderView : NSObject
@end
@implementation HeaderView
- (void) setMenu: (NSMenu*) menu { Rec(@"header menu %ld", (long) menu.numberOfItems); }
@end

@interface Outline : NSObject
@property(retain) NSArray *tableColumns, *rows;
@property(retain) NSMutableSet *visible;
@property(retain) NSIndexSet *selectedRowIndexes;
@property NSInteger selectedColumn, selectedRow, tag;
@property(retain) NSMenu *menu;
@end
@implementation Outline
- (BOOL) isColumnWithIdentifierVisible: (id) identifier { return [self.visible containsObject: identifier]; }
- (void) setColumnWithIdentifier: (id) identifier visible: (BOOL) visible { Rec(@"column %@ visible %d", identifier, (int) visible); }
- (NSInteger) columnWithIdentifier: (id) identifier {
    NSUInteger i = 0;
    for (NSTableColumn *c in self.tableColumns) { if ([[c identifier] isEqual: identifier]) return i; i++; }
    return -1;
}
- (void) selectColumnIndexes: (NSIndexSet*) indexes byExtendingSelection: (BOOL) extend { Rec(@"select column %lu", (unsigned long) indexes.firstIndex); }
- (void) scrollColumnToVisible: (NSInteger) column { Rec(@"scroll column %ld", (long) column); }
- (id) headerView { return [[HeaderView new] autorelease]; }
- (id) itemAtRow: (NSInteger) row { return row >= 0 && row < (NSInteger) self.rows.count ? [self.rows objectAtIndex: row] : nil; }
- (void) reloadData { Rec(@"reload %ld", (long) self.tag); }
- (void) selectRowIndexes: (NSIndexSet*) indexes byExtendingSelection: (BOOL) extend { Rec(@"select row %lu in %ld", (unsigned long) indexes.firstIndex, (long) self.tag); self.selectedRow = indexes.firstIndex; }
- (void) scrollRowToVisible: (NSInteger) row { Rec(@"scroll row %ld in %ld", (long) row, (long) self.tag); }
- (id) tableColumnWithIdentifier: (NSString*) identifier { Rec(@"column %@", identifier); return self; }
- (id) headerCell { return self; }
- (void) setStringValue: (NSString*) value { Rec(@"header %@", value); }
@end

@interface Viewer : NSObject
@end
@implementation Viewer
- (void) comparativeRefresh: (NSString*) uid { Rec(@"viewer refresh %@", Plain(uid)); }
@end
static NSArray *displayedViewers;
@interface ViewerController : NSObject
@end
@implementation ViewerController
+ (NSArray*) getDisplayed2DViewers { return displayedViewers; }
@end

static NSArray *alertAnswers;
static NSUInteger alertIndex;
static NSInteger Alert(NSString *kind, NSString *title, NSString *message, NSString *a, NSString *b, NSString *c) {
    NSInteger answer = alertIndex < alertAnswers.count ? [[alertAnswers objectAtIndex: alertIndex] integerValue] : 1;
    alertIndex++;
    Rec(@"alert %@ '%@' '%@' %@ %@ %@ -> %ld", kind, title, message, Plain(a), Plain(b), Plain(c), (long) answer);
    return answer;
}
#define HorosRunAlertPanel(title, format, a, b, c, ...) Alert(@"plain", title, [NSString stringWithFormat: format, ##__VA_ARGS__], a, b, c)
#define HorosRunInformationalAlertPanel(title, format, a, b, c, ...) Alert(@"info", title, [NSString stringWithFormat: format, ##__VA_ARGS__], a, b, c)
#define HorosRunCriticalAlertPanel(title, format, a, b, c, ...) Alert(@"critical", title, [NSString stringWithFormat: format, ##__VA_ARGS__], a, b, c)

@interface WaitRendering : NSObject
@end
@implementation WaitRendering
- (id) init: (NSString*) message { self = [super init]; Rec(@"wait '%@'", message); return self; }
- (void) showWindow: (id) sender { Rec(@"wait show"); }
- (id) window { return self; }
- (void) orderOut: (id) sender { Rec(@"wait hide"); }
- (void) makeKeyAndOrderFront: (id) sender { Rec(@"wait front"); }
- (void) close { Rec(@"wait close"); }
@end
@interface QueryController : NSObject
@end
@implementation QueryController
+ (id) currentQueryController { return nil; }
+ (id) currentAutoQueryController { return nil; }
@end

@interface DCMAttributeTag : NSObject
@property(retain) NSString *ident;
+ (id) tagWithTagString: (NSString*) tag;
@end
@implementation DCMAttributeTag
+ (id) tagWithTagString: (NSString*) tag { DCMAttributeTag *t = [[self new] autorelease]; t.ident = [@"tag" stringByAppendingString: tag]; return t; }
@end
static NSDictionary *fileAttributes;
@interface DCMObject : NSObject
@property(retain) NSDictionary *attributes;
+ (instancetype) objectWithContentsOfFile: (NSString*) path;
@end
@interface HorosDCMTKObject : NSObject
@end
@implementation DCMObject
- (id) attributeValueWithName: (NSString*) name { return [self.attributes objectForKey: name]; }
// The model's reading forwards to the reader, as +[DCMObject objectWithContentsOfFile:] does.
+ (instancetype) objectWithContentsOfFile: (NSString*) path { return [HorosDCMTKObject objectWithContentsOfFile: path]; }
@end
@implementation HorosDCMTKObject
+ (id) objectWithContentsOfFile: (NSString*) path {
    if ([fileAttributes objectForKey: path] == nil) return nil;
    DCMObject *o = [[DCMObject new] autorelease]; o.attributes = [fileAttributes objectForKey: path]; return o;
}
@end
static NSDictionary *charsets;
@interface XMLController : NSObject
@end
@implementation XMLController
+ (NSString*) characterSetToDeclareForValues: (NSArray*) values inDicomFile: (NSString*) path refused: (BOOL*) refused {
    NSString *c = [charsets objectForKey: path];
    Rec(@"charset %@ %@", path, Plain(values));
    if ([c isEqualToString: @"refused"]) { *refused = YES; return nil; }
    return [c isEqualToString: @"none"] ? nil : c;
}
+ (BOOL) modifyDicom: (NSArray*) edits dicomFiles: (NSArray*) files { Rec(@"modify %@ %@", Plain(edits), Plain(files)); return YES; }
@end
@interface TestStudy : Mock
@property(retain) NSSet *pathSet;
@end
@implementation TestStudy
- (NSSet*) paths { return self.pathSet; }
@end
@interface TestFileManager : NSObject
@end
@implementation TestFileManager
- (BOOL) removeItemAtPath: (NSString*) path error: (NSError**) error { Rec(@"remove %@", [path lastPathComponent]); return YES; }
@end

@@IDENTITY@@

@interface BrowserController : NSObject
{
@public
    DicomDatabase *_database;
    Outline *databaseOutline, *comparativeTable, *albumTable;
    id previousItem;
    NSArray *originalOutlineViewArray, *outlineViewArray, *databaseSelectionArray;
    NSSet *originalOutlineViewStudies;
    NSMenu *columnsMenu;
    id refreshTimer;
    BOOL DatabaseIsEdited;
    Window *testWindow;
    NSTimeInterval lastRefreshComparativeStudies, lastRefreshSmartAlbumDistantStudies;
    long previousNoOfFiles;
    NSArray *albumArrayValue;
    BOOL dontSelectStudyFromComparativeStudies;
    id oMatrix;
}
@property(retain) NSArray *comparativeStudies;
@property(retain) NSString *comparativePatientUID;
@end

@implementation BrowserController

- (DicomDatabase*) database { return _database; }
- (id) window { return testWindow; }
- (float) fontSize: (NSString*) type { return [type isEqualToString: @"dbFont"] ? 12.5 : 10.0; }
- (NSArray*) databaseSelection { return databaseSelectionArray; }
- (NSArray*) albumArray { return albumArrayValue; }
- (NSArray*) childrenArray: (id) item { Rec(@"childrenArray %@", Plain(item)); return [item valueForKey: @"kids"]; }
- (void) computeTimeInterval { Rec(@"computeTimeInterval"); }
- (void) checkIfLocalStudyHasMoreOrSameNumberOfImagesOfADistantStudy: (id) studies { Rec(@"check"); }
- (void) refreshMatrix: (id) sender { Rec(@"refreshMatrix"); }
- (void) proceedDeleteObjects: (NSArray*) objects tree: (NSSet*) tree { Rec(@"proceed %@ tree %@", Plain([objects valueForKey: @"id"]), tree ? @"set" : @"nil"); }
- (BOOL) isThumbnailMenuItem: (id) sender { return testThumbnailItem; }

@@VALUE@@

- (void) editKey: (NSString*) key value: (id) object
{
@@EDIT@@
}

@@DISPLAY@@

@@TOOLTIP@@

@@EXPANDABLE@@

@@CHILDREN@@

@@COLUMNS_BUILD@@

@@COLUMNS_OPEN@@

@@COLUMNS_ACTION@@

@@COLUMNS_REFRESH@@

@@NEW_STUDIES@@

@@REFRESH_HISTORY@@

@@REFRESH_NEEDED@@
}

- (void) historyFor: (id) item
{
@@HISTORY@@
}

- (BOOL) refreshFor: (id) item
{
@@REFRESH@@
    return refreshMatrix;
}

- (BOOL) waitedFor: (NSTimeInterval) comparativeStudyWaitedTime
{
    return @@WAITED@@;
}

- (BOOL) framesFor: (id) item
{
    return @@FRAMES@@;
}

- (BOOL) threadFor: (NSArray*) files imageLevel: (BOOL) imageLevel
{
@@THREAD@@
    return separateThread;
}

- (id) destinationOf: (NSArray*) seriesArray
{
@@DESTINATION@@
    return destSeries;
}

- (NSArray*) unifyEdits: (DicomStudy*) destStudy original: (DCMObject*) dcmObject former: (NSArray*) former
{
    NSString *originalPatientName = [dcmObject attributeValueWithName:@"PatientsName"];
    NSString *originalBirthDate = [dcmObject attributeValueWithName:@"PatientsBirthDate"];
    NSString *existingOtherPatientNames = [former objectAtIndex: 0], *existingOtherPatientIDs = [former objectAtIndex: 1];
    @@UNIFY_EDITS@@
    return tagAndValues;
}

- (NSArray*) mergeEdits: (DicomStudy*) destStudy study: (DicomStudy*) study original: (DCMObject*) dcmObject former: (NSArray*) former
{
    NSMutableArray *params = [NSMutableArray array];
    NSString *originalPatientName = [dcmObject attributeValueWithName:@"PatientsName"];
    NSString *originalBirthDate = [dcmObject attributeValueWithName:@"PatientsBirthDate"];
    NSString *originalStudyID = [dcmObject attributeValueWithName:@"StudyID"];
    NSString *originalStudyInstanceUID = [dcmObject attributeValueWithName:@"StudyInstanceUID"];
    NSString *originalStudyDescription = [dcmObject attributeValueWithName:@"StudyDescription"];
    NSString *existingOtherPatientNames = [former objectAtIndex: 0], *existingOtherPatientIDs = [former objectAtIndex: 1];
@@MERGE_EDITS@@
    return tagAndValues;
}

@@DELETE@@

- (void) thumbnailsFor: (id) sender firstResponder: (id) responder thumbnailItem: (BOOL) thumbnailItem
{
    BOOL matrixThumbnails = YES;
    testWindow.firstResponder = responder;
    testThumbnailItem = thumbnailItem;
@@THUMBNAILS@@
    Rec(@"thumbnails %d", (int) matrixThumbnails);
}

- (void) questionFor: (BOOL) matrixThumbnails level: (NSString*) level
{
    NSInteger result = 0;
    NSArray *albumArray = self.albumArray;
@@QUESTION@@
    Rec(@"result %ld", (long) result);
}

@end
'''

# The pieces the harness compiles as they were, with stand-ins for what the
# app supplies; NSFileManager stays real for the deletion of files outside
# the database folder.
replacements = {
    '@@FONT@@': re.search(r'#define DISTANTSTUDYFONT .*', text).group(0),
    '@@IDENTITY@@': identity_functions.replace('[NSFileManager defaultManager]', '[[TestFileManager new] autorelease]'),
    '@@VALUE@@': value_method,
    '@@EDIT@@': edit_block,
    '@@DISPLAY@@': display,
    '@@TOOLTIP@@': tooltip,
    '@@EXPANDABLE@@': expandable,
    '@@CHILDREN@@': children_count,
    '@@COLUMNS_BUILD@@': columns_build,
    '@@COLUMNS_OPEN@@': columns_open,
    '@@COLUMNS_ACTION@@': columns_action,
    '@@COLUMNS_REFRESH@@': columns_refresh,
    '@@NEW_STUDIES@@': new_studies,
    '@@REFRESH_HISTORY@@': refresh_history,
    '@@REFRESH_NEEDED@@': refresh_needed,
    '@@HISTORY@@': history_block,
    '@@REFRESH@@': refresh_block.replace('[[item valueForKey:@"noFiles"] intValue]', '[[item valueForKey:@"noFiles"] intValue]'),
    '@@FRAMES@@': frames_condition,
    '@@WAITED@@': waited_condition,
    '@@THREAD@@': thread_block,
    '@@DESTINATION@@': destination_block,
    '@@UNIFY_EDITS@@': unify_edits,
    '@@MERGE_EDITS@@': merge_edits,
    '@@DELETE@@': delete_objects,
    '@@THUMBNAILS@@': thumbnails_block,
    '@@QUESTION@@': question_block,
}
OBJC = OBJC.replace('@interface BrowserController : NSObject', 'static BOOL testThumbnailItem;\n@interface BrowserController : NSObject')
for key, value in replacements.items():
    if OBJC.count(key) != 1:
        sys.exit('FAIL: the harness has %d %s' % (OBJC.count(key), key))
    OBJC = OBJC.replace(key, value)

OBJC += r'''
static NSString *testRoot;
static NSTimeInterval testNow;

static id MakeRow(id spec);
static NSArray *MakeRows(NSArray *list) {
    if (list == nil) return nil;
    NSMutableArray *rows = [NSMutableArray array];
    for (id spec in list) [rows addObject: MakeRow(spec)];
    return rows;
}
static id MakeRow(id spec) {
    if (spec == nil) return nil;
    if (![spec isKindOfClass: [NSDictionary class]]) return spec;
    NSDictionary *d = spec;
    NSString *kind = [d objectForKey: @"cls"];
    if ([kind isEqualToString: @"surgical"]) return [[HorosSurgicalProcedureOutlineRow new] autorelease];
    if ([kind isEqualToString: @"file"]) {
        NSMutableDictionary *image = [NSMutableDictionary dictionaryWithDictionary: [d objectForKey: @"values"]];
        [image setObject: [testRoot stringByAppendingPathComponent: [d objectForKey: @"file"]] forKey: @"completePath"];
        return image;
    }
    NSDictionary *classes = @{@"study": [DicomStudy class], @"series": [DicomSeries class], @"image": [DicomImage class], @"node": [DCMTKStudyQueryNode class],
                              @"seriesNode": [DCMTKSeriesQueryNode class], @"album": [DicomAlbum class], @"mock": [Mock class], @"testStudy": [TestStudy class]};
    Mock *m = [[[classes objectForKey: kind] new] autorelease];
    m.ident = [d objectForKey: @"id"];
    m.distant = [[d objectForKey: @"distant"] boolValue];
    m.context = [d objectForKey: @"context"];
    NSMutableDictionary *values = [NSMutableDictionary dictionaryWithDictionary: [d objectForKey: @"values"] ?: @{}];
    if ([d objectForKey: @"dateAgo"]) [values setObject: [NSDate dateWithTimeIntervalSinceReferenceDate: testNow - [[d objectForKey: @"dateAgo"] doubleValue]] forKey: @"date"];
    if ([d objectForKey: @"dateAddedAgo"]) [values setObject: [NSDate dateWithTimeIntervalSinceReferenceDate: testNow - [[d objectForKey: @"dateAddedAgo"] doubleValue]] forKey: @"dateAdded"];
    if ([d objectForKey: @"dateToday0"]) [values setObject: [NSDate dateWithTimeIntervalSinceReferenceDate: floor(testNow / 86400) * 86400 + [[d objectForKey: @"dateToday0"] doubleValue]] forKey: @"date"];
    if ([d objectForKey: @"reportSeries"]) [values setObject: MakeRows([d objectForKey: @"reportSeries"]) forKey: @"series"];
    if ([d objectForKey: @"seriesSet"]) [values setObject: [NSSet setWithArray: MakeRows([d objectForKey: @"seriesSet"])] forKey: @"series"];
    if ([d objectForKey: @"seriesRow"]) [values setObject: MakeRow([d objectForKey: @"seriesRow"]) forKey: @"series"];
    if ([d objectForKey: @"imagesSet"]) [values setObject: [NSSet setWithArray: MakeRows([d objectForKey: @"imagesSet"])] forKey: @"images"];
    if ([d objectForKey: @"imagesList"]) [values setObject: MakeRows([d objectForKey: @"imagesList"]) forKey: @"images"];
    if ([d objectForKey: @"imageSeriesCount"]) {
        NSMutableArray *series = [NSMutableArray array];
        for (int i = 0; i < [[d objectForKey: @"imageSeriesCount"] intValue]; i++) [series addObject: @"s"];
        [values setObject: series forKey: @"imageSeries"];
    }
    if ([d objectForKey: @"kids"]) [values setObject: MakeRows([d objectForKey: @"kids"]) forKey: @"kids"];
    m.values = values;
    if ([m isKindOfClass: [DCMTKQueryNode class]]) {
        ((DCMTKQueryNode*) m).kids = [[MakeRows([d objectForKey: @"nodeKids"]) mutableCopy] autorelease];
        ((DCMTKQueryNode*) m).queryGives = MakeRows([d objectForKey: @"queryGives"]);
    }
    if ([m isKindOfClass: [TestStudy class]]) ((TestStudy*) m).pathSet = [NSSet setWithArray: [d objectForKey: @"paths"]];
    return m;
}

static NSArray *Tree(NSString *folder) {
    NSMutableArray *names = [NSMutableArray array];
    NSDirectoryEnumerator *e = [[NSFileManager defaultManager] enumeratorAtPath: folder];
    for (NSString *name in e) [names addObject: name];
    return [names sortedArrayUsingSelector: @selector(compare:)];
}

static void Flush(void) {
    for (NSString *line in records) printf("%s\n", [line UTF8String]);
    [records removeAllObjects];
}

int main(int argc, char **argv) {
    @autoreleasepool {
        records = [NSMutableArray array];
        NSDictionary *cases = [NSPropertyListSerialization propertyListWithData: [NSData dataWithContentsOfFile: @(argv[1])] options: 0 format: NULL error: NULL];
        testRoot = @(argv[2]);
        testNow = [NSDate timeIntervalSinceReferenceDate];
        NSMutableDictionary *databases = [NSMutableDictionary dictionary];
        for (NSString *key in [cases objectForKey: @"databases"]) {
            NSDictionary *d = [[cases objectForKey: @"databases"] objectForKey: key];
            DicomDatabase *db = [[d objectForKey: @"remote"] boolValue] ? [[RemoteDicomDatabase new] autorelease] : [[DicomDatabase new] autorelease];
            db.ident = key; db.baseDirPath = [d objectForKey: @"base"]; db.name = [d objectForKey: @"name"]; db.local = [[d objectForKey: @"local"] boolValue];
            [databases setObject: db forKey: key];
        }
        databasesByContext = databases;
        reportPlugins = @{@"plug": [[FakeBundle new] autorelease]};
        BrowserController *b = [[BrowserController new] autorelease];
        b->testWindow = [[Window new] autorelease];
        b->oMatrix = [[NSObject new] autorelease];
        int n;

        n = 0;
        for (NSDictionary *c in [cases objectForKey: @"value"]) {
            testDefaults = [c objectForKey: @"defaults"];
            b->_database = [databases objectForKey: [c objectForKey: @"database"]];
            id item = MakeRow([c objectForKey: @"row"]);
            for (NSString *identifier in [cases objectForKey: @"identifiers"]) {
                NSTableColumn *column = [[[NSTableColumn alloc] initWithIdentifier: identifier] autorelease];
                id value = [b intOutlineView: nil objectValueForTableColumn: column byItem: item];
                Rec(@"value %d %@ %@", n, identifier, Plain(value));
            }
            n++;
            Flush();
        }

        n = 0;
        for (NSDictionary *c in [cases objectForKey: @"edit"]) {
            b->databaseSelectionArray = MakeRows([c objectForKey: @"selection"]);
            Rec(@"edit %d %@", n++, [c objectForKey: @"key"]);
            [b editKey: [c objectForKey: @"key"] value: [c objectForKey: @"value"]];
            Flush();
        }

        n = 0;
        for (NSDictionary *c in [cases objectForKey: @"display"]) {
            testDefaults = [c objectForKey: @"defaults"];
            b->_database = [databases objectForKey: [c objectForKey: @"database"]];
            Mock *item = MakeRow([c objectForKey: @"row"]);
            id previous = [c objectForKey: @"previous"];
            b->previousItem = [previous isEqual: @"same"] ? item : MakeRow(previous);
            b->originalOutlineViewArray = [c objectForKey: @"listed"] ? @[] : nil;
            b->originalOutlineViewStudies = [[c objectForKey: @"listed"] boolValue] ? [NSSet setWithObject: item] : [NSSet set];
            testToday = testNow - [[c objectForKey: @"todayAgo"] doubleValue];
            Outline *outline = [[Outline new] autorelease];
            b->testWindow.firstResponder = [[c objectForKey: @"focused"] boolValue] ? outline : nil;
            Cell *cell = [[c objectForKey: @"imageCell"] boolValue] ? [[ImageAndTextCell new] autorelease] : [[Cell new] autorelease];
            cell.colored = [[c objectForKey: @"colored"] boolValue];
            NSTableColumn *column = [[[NSTableColumn alloc] initWithIdentifier: [c objectForKey: @"identifier"]] autorelease];
            Rec(@"display %d %@", n++, [c objectForKey: @"identifier"]);
            [b outlineView: (id) outline willDisplayCell: cell forTableColumn: column item: item];
            Flush();
        }
        b->previousItem = nil;

        n = 0;
        for (NSDictionary *c in [cases objectForKey: @"tooltip"]) {
            id item = MakeRow([c objectForKey: @"row"]);
            NSArray *r = [c objectForKey: @"rect"], *p = [c objectForKey: @"mouse"];
            NSRect rect = NSMakeRect([[r objectAtIndex: 0] doubleValue], [[r objectAtIndex: 1] doubleValue], [[r objectAtIndex: 2] doubleValue], [[r objectAtIndex: 3] doubleValue]);
            NSTableColumn *column = [[[NSTableColumn alloc] initWithIdentifier: [c objectForKey: @"identifier"]] autorelease];
            NSString *tip = [b outlineView: nil toolTipForCell: nil rect: &rect tableColumn: column item: item
                             mouseLocation: NSMakePoint([[p objectAtIndex: 0] doubleValue], [[p objectAtIndex: 1] doubleValue])];
            Rec(@"tooltip %d %@", n++, Plain(tip));
            Flush();
        }

        n = 0;
        for (NSDictionary *c in [cases objectForKey: @"tree"]) {
            b->_database = [[c objectForKey: @"noDatabase"] boolValue] ? nil : [databases objectForKey: @"local"];
            NSMutableArray *list = [NSMutableArray array];
            for (int i = 0; i < [[c objectForKey: @"listCount"] intValue]; i++) [list addObject: @"row"];
            b->outlineViewArray = list;
            id item = MakeRow([c objectForKey: @"row"]);
            BOOL expandable = [b outlineView: nil isItemExpandable: item];
            NSInteger count = [b outlineView: nil numberOfChildrenOfItem: item];
            Rec(@"tree %d %d %ld", n++, (int) expandable, (long) count);
            Flush();
        }
        b->outlineViewArray = nil;

        n = 0;
        for (NSDictionary *c in [cases objectForKey: @"columns"]) {
            testDefaults = [c objectForKey: @"defaults"];
            Outline *outline = [[Outline new] autorelease];
            NSMutableArray *columns = [NSMutableArray array];
            for (NSDictionary *spec in [c objectForKey: @"columns"]) {
                NSTableColumn *column = [[[NSTableColumn alloc] initWithIdentifier: [spec objectForKey: @"id"]] autorelease];
                [[column headerCell] setStringValue: [spec objectForKey: @"title"]];
                [column setHidden: [[spec objectForKey: @"hidden"] boolValue]];
                [columns addObject: column];
            }
            outline.tableColumns = columns;
            outline.visible = [NSMutableSet setWithArray: [c objectForKey: @"visible"]];
            outline.selectedColumn = [[c objectForKey: @"selectedColumn"] integerValue];
            b->databaseOutline = outline;
            Rec(@"columns %d", n++);
            [b buildColumnsMenu];
            for (NSMenuItem *item in [b->columnsMenu itemArray]) Rec(@"item '%@' %@", item.title, Plain(item.representedObject));
            [b columnsMenuWillOpen];
            for (NSMenuItem *item in [b->columnsMenu itemArray]) Rec(@"state '%@' %ld", item.title, (long) item.state);
            if ([c objectForKey: @"action"]) {
                NSMenuItem *item = [[b->columnsMenu itemArray] objectAtIndex: [[c objectForKey: @"action"] integerValue]];
                if ([c objectForKey: @"actionState"]) item.state = [[c objectForKey: @"actionState"] integerValue];
                [b columnsMenuAction: item];
                Rec(@"after '%@' %ld", item.title, (long) item.state);
            }
            Rec(@"refresh");
            [b refreshColumns];
            Flush();
        }
        b->databaseOutline = nil;

        n = 0;
        for (NSDictionary *c in [cases objectForKey: @"newStudies"]) {
            b->_database = [databases objectForKey: @"local"];
            b.comparativePatientUID = [c objectForKey: @"shown"];
            b.comparativeStudies = MakeRows([c objectForKey: @"history"]);
            Outline *table = [[Outline new] autorelease]; table.tag = 2; table.selectedRow = [[c objectForKey: @"selectedRow"] integerValue];
            b->comparativeTable = table;
            NSNotification *note = [NSNotification notificationWithName: @"new" object: nil
                                    userInfo: @{OsirixAddToDBNotificationImagesArray: MakeRows([c objectForKey: @"newStudies"])}];
            Rec(@"newStudies %d", n++);
            [b _newStudiesRefreshComparativeStudies: note];
            Rec(@"history %@", Plain(b.comparativeStudies));
            Flush();
        }

        n = 0;
        for (NSDictionary *c in [cases objectForKey: @"refreshHistory"]) {
            b->_database = [databases objectForKey: @"local"];
            Outline *outline = [[Outline new] autorelease];
            outline.rows = MakeRows([c objectForKey: @"rows"]);
            outline.selectedRowIndexes = [c objectForKey: @"selected"] ? [NSIndexSet indexSetWithIndex: [[c objectForKey: @"selected"] integerValue]] : [NSIndexSet indexSet];
            b->databaseOutline = outline;
            Outline *table = [[Outline new] autorelease]; table.tag = 2;
            b->comparativeTable = table;
            NSMutableDictionary *objects = [NSMutableDictionary dictionary];
            for (id spec in [c objectForKey: @"inContext"]) { Mock *m = MakeRow(spec); [objects setObject: m forKey: [@"oid-" stringByAppendingString: m.ident]]; }
            contextObjects = objects;
            b.comparativePatientUID = [c objectForKey: @"shown"];
            displayedViewers = [[c objectForKey: @"viewers"] boolValue] ? @[[[Viewer new] autorelease]] : @[];
            Rec(@"refreshHistory %d", n++);
            [b refreshComparativeStudies: MakeRows([c objectForKey: @"newStudies"])];
            Rec(@"history %@", Plain(b.comparativeStudies));
            Flush();
        }

        n = 0;
        for (NSDictionary *c in [cases objectForKey: @"refreshNeeded"]) {
            testDefaults = [c objectForKey: @"defaults"];
            b->lastRefreshComparativeStudies = [NSDate timeIntervalSinceReferenceDate] - [[c objectForKey: @"lastAgo"] doubleValue];
            b->lastRefreshSmartAlbumDistantStudies = [NSDate timeIntervalSinceReferenceDate] - [[c objectForKey: @"lastSmartAgo"] doubleValue];
            Outline *outline = [[Outline new] autorelease];
            outline.rows = MakeRows([c objectForKey: @"rows"]);
            outline.selectedRowIndexes = [c objectForKey: @"selected"] ? [NSIndexSet indexSetWithIndex: [[c objectForKey: @"selected"] integerValue]] : [NSIndexSet indexSet];
            b->databaseOutline = outline;
            Outline *albums = [[Outline new] autorelease]; albums.selectedRow = [[c objectForKey: @"albumRow"] integerValue];
            b->albumTable = albums;
            b->albumArrayValue = MakeRows([c objectForKey: @"albums"]);
            Rec(@"refreshNeeded %d", n++);
            [b refreshComparativeStudiesIfNeeded: [[c objectForKey: @"timer"] boolValue] ? @"timer" : nil];
            Rec(@"reset %d", (int) (b->lastRefreshComparativeStudies == 0));
            Flush();
        }

        n = 0;
        for (NSDictionary *c in [cases objectForKey: @"history"]) {
            b.comparativePatientUID = [c objectForKey: @"shown"];
            b.comparativeStudies = [[c objectForKey: @"noHistory"] boolValue] ? nil : MakeRows([c objectForKey: @"history"]);
            Outline *table = [[Outline new] autorelease]; table.tag = 2;
            b->comparativeTable = table;
            id item = MakeRow([c objectForKey: @"item"]);
            id previous = [c objectForKey: @"previous"];
            b->previousItem = [([previous isEqual: @"same"] ? item : MakeRow(previous)) retain];
            Rec(@"selectionHistory %d", n++);
            [b historyFor: item];
            Rec(@"shown %@ history %@ previous %@", Plain(b.comparativePatientUID), Plain(b.comparativeStudies), Plain(b->previousItem));
            Flush();
        }

        n = 0;
        for (NSDictionary *c in [cases objectForKey: @"refresh"]) {
            id item = MakeRow([c objectForKey: @"item"]);
            id previous = [c objectForKey: @"previous"];
            b->previousItem = [previous isEqual: @"same"] ? item : MakeRow(previous);
            b->previousNoOfFiles = [[c objectForKey: @"previousFiles"] longValue];
            b->DatabaseIsEdited = YES;
            BOOL refresh = [b refreshFor: item];
            Rec(@"refresh %d %d edited %d files %ld", n++, (int) refresh, (int) b->DatabaseIsEdited, b->previousNoOfFiles);
            Flush();
        }
        b->previousItem = nil;

        n = 0;
        for (NSDictionary *c in [cases objectForKey: @"waited"]) {
            Rec(@"waited %d %d", n++, (int) [b waitedFor: [NSDate timeIntervalSinceReferenceDate] - [[c objectForKey: @"ago"] doubleValue]]);
            Flush();
        }

        n = 0;
        for (NSDictionary *c in [cases objectForKey: @"frames"]) {
            Rec(@"frames %d %d", n++, (int) [b framesFor: MakeRow([c objectForKey: @"item"])]);
            Flush();
        }

        n = 0;
        for (NSDictionary *c in [cases objectForKey: @"thread"]) {
            BOOL separate = [b threadFor: MakeRows([c objectForKey: @"files"]) imageLevel: [[c objectForKey: @"imageLevel"] boolValue]];
            Rec(@"thread %d %d", n++, (int) separate);
            Flush();
        }

        n = 0;
        for (NSDictionary *c in [cases objectForKey: @"destination"]) {
            id destination = [b destinationOf: MakeRows([c objectForKey: @"series"])];
            Rec(@"destination %d %@", n++, Plain(destination));
            Flush();
        }

        n = 0;
        for (NSDictionary *c in [cases objectForKey: @"identity"]) {
            fileAttributes = [c objectForKey: @"files"];
            NSString *names = nil, *ids = nil;
            @try { HorosFormerIdentity(MakeRow([c objectForKey: @"study"]), &names, &ids); } @catch (NSException *e) { Rec(@"raised %@", e.name); }
            Rec(@"identity %d %@ %@", n++, Plain(names), Plain(ids));
            Flush();
        }

        n = 0;
        for (NSDictionary *c in [cases objectForKey: @"write"]) {
            charsets = [c objectForKey: @"charsets"];
            alertAnswers = [c objectForKey: @"answers"]; alertIndex = 0;
            NSMutableArray *edits = [NSMutableArray array];
            for (NSArray *e in [c objectForKey: @"edits"]) [edits addObject: @[[DCMAttributeTag tagWithTagString: [e objectAtIndex: 0]], [e objectAtIndex: 1]]];
            BOOL ok = HorosWriteIdentityEdits([c objectForKey: @"files"], edits, [c objectForKey: @"title"]);
            Rec(@"write %d %d", n++, (int) ok);
            Flush();
        }

        n = 0;
        for (NSDictionary *c in [cases objectForKey: @"unify"]) {
            DCMObject *dcm = [[DCMObject new] autorelease]; dcm.attributes = [c objectForKey: @"dcm"];
            NSArray *former = [c objectForKey: @"former"];
            Rec(@"unify %d %@", n, Plain([b unifyEdits: MakeRow([c objectForKey: @"dest"]) original: dcm former: former]));
            Rec(@"merge %d %@", n++, Plain([b mergeEdits: MakeRow([c objectForKey: @"dest"]) study: MakeRow([c objectForKey: @"study"]) original: dcm former: former]));
            Flush();
        }

        n = 0;
        for (NSDictionary *c in [cases objectForKey: @"delete"]) {
            NSString *folder = [testRoot stringByAppendingPathComponent: [NSString stringWithFormat: @"delete%d", n]];
            for (NSString *file in [c objectForKey: @"files"]) {
                NSString *path = [testRoot stringByAppendingPathComponent: file];
                [[NSFileManager defaultManager] createDirectoryAtPath: [path stringByDeletingLastPathComponent] withIntermediateDirectories: YES attributes: nil error: NULL];
                [@"x" writeToFile: path atomically: NO encoding: NSUTF8StringEncoding error: NULL];
            }
            Outline *albums = [[Outline new] autorelease]; albums.selectedRow = [[c objectForKey: @"albumRow"] integerValue];
            b->albumTable = albums;
            alertAnswers = [c objectForKey: @"answers"]; alertIndex = 0;
            NSMutableArray *objects = [NSMutableArray arrayWithArray: MakeRows([c objectForKey: @"images"])];
            Rec(@"delete %d", n++);
            [b delObjects: objects tree: [[c objectForKey: @"tree"] boolValue] ? [NSMutableSet set] : nil];
            Rec(@"left %@", Plain(Tree(folder)));
            Flush();
        }

        n = 0;
        for (NSDictionary *c in [cases objectForKey: @"thumbnails"]) {
            Outline *outline = [[Outline new] autorelease], *table = [[Outline new] autorelease];
            b->databaseOutline = outline; b->comparativeTable = table;
            NSString *kind = [c objectForKey: @"sender"];
            id sender = nil;
            NSMenu *menu = [[NSMenu new] autorelease];
            if ([kind isEqualToString: @"item"] || [kind isEqualToString: @"outlineItem"]) sender = [menu addItemWithTitle: @"x" action: nil keyEquivalent: @""];
            if ([kind isEqualToString: @"looseItem"]) sender = [[[NSMenuItem alloc] initWithTitle: @"x" action: nil keyEquivalent: @""] autorelease];
            if ([kind isEqualToString: @"outlineItem"]) outline.menu = menu;
            if ([kind isEqualToString: @"other"]) sender = @"button";
            NSString *r = [c objectForKey: @"responder"];
            id responder = [r isEqualToString: @"matrix"] ? b->oMatrix : [r isEqualToString: @"outline"] ? outline : [r isEqualToString: @"comparative"] ? table : nil;
            Rec(@"thumbnails %d", n++);
            [b thumbnailsFor: sender firstResponder: responder thumbnailItem: [[c objectForKey: @"thumbnailItem"] boolValue]];
            Flush();
        }

        n = 0;
        for (NSDictionary *c in [cases objectForKey: @"question"]) {
            Outline *albums = [[Outline new] autorelease]; albums.selectedRow = [[c objectForKey: @"albumRow"] integerValue];
            b->albumTable = albums;
            b->albumArrayValue = MakeRows([c objectForKey: @"albums"]);
            alertAnswers = @[[c objectForKey: @"answer"]]; alertIndex = 0;
            Rec(@"question %d", n++);
            [b questionFor: [[c objectForKey: @"thumbnails"] boolValue] level: [c objectForKey: @"level"]];
            Flush();
        }
    }
    return 0;
}
'''

# The same cases through the module, with the app's glue of the Swift methods
# (BrowserController+OutlineDataSource.swift, +OutlineSelection.swift,
# +Merge.swift, +Deletion.swift) around the same stand-ins.
SWIFT = r'''
import AppKit
import Foundation

var records: [String] = []
func rec(_ line: String) { records.append(line) }
func flush() {
    for line in records { print(line) }
    records.removeAll()
}
var testDefaults: NSDictionary = [:]
func testObject(_ key: String) -> Any? { testDefaults.object(forKey: key) }
func testBool(_ key: String) -> Bool {
    if let n = testObject(key) as? NSNumber { return n.boolValue }
    if let s = testObject(key) as? NSString { return s.boolValue }
    return false
}
func testInteger(_ key: String) -> Int {
    if let n = testObject(key) as? NSNumber { return n.intValue }
    if let s = testObject(key) as? NSString { return s.integerValue }
    return 0
}
func intValue(_ value: Any?) -> Int32 { RowValues.int(value) }
func boolValue(_ value: Any?) -> Bool {
    if let n = value as? NSNumber { return n.boolValue }
    if let s = value as? NSString { return s.boolValue }
    return false
}
func literallyEqual(_ a: String?, _ b: String?) -> Bool {
    guard let a, let b else { return false }
    return (a as NSString).isEqual(to: b)
}
func described(_ value: Any?) -> String {
    guard let value else { return "(null)" }
    return (value as AnyObject).description ?? "(null)"
}

@objc protocol Identified { var ident: String { get } }

func plain(_ object: Any?) -> String {
    guard let object else { return "nil" }
    if let s = object as? NSString { return "'\(s)'" }
    if let d = object as? NSDictionary {
        let keys = (d.allKeys as NSArray).sortedArray(using: #selector(NSString.compare(_:)))
        return "{" + keys.map { "\($0)=\(plain(d.object(forKey: $0)))" }.joined(separator: ";") + "}"
    }
    if let a = object as? NSArray { return "[" + a.map { plain($0) }.joined(separator: ",") + "]" }
    if let date = object as? NSDate { return String(format: "date(%.3f)", date.timeIntervalSinceReferenceDate) }
    if let font = object as? NSFont { return String(format: "font(%@ %.2f)", font.fontName, font.pointSize) }
    if let n = object as? NSNumber { return "n\(n)" }
    if let i = object as? Identified { return i.ident }
    return (object as AnyObject).description ?? "nil"
}

final class TestImage: NSObject, Identified {
    let ident: String
    init(_ name: String) { ident = "img:" + name }
}

var testNow: TimeInterval = 0
var testToday: TimeInterval = 0
var testRoot = ""

class Mock: NSObject, Identified {
    var ident = ""
    var values: [String: Any] = [:]
    var distant = false
    var context: Any?
    override func value(forKey key: String) -> Any? { values[key] }
    override func value(forKeyPath keyPath: String) -> Any? {
        let keys = keyPath.components(separatedBy: ".")
        let value = self.value(forKey: keys[0])
        return keys.count > 1 ? (value as AnyObject?)?.value(forKeyPath: keys.dropFirst().joined(separator: ".")) : value
    }
    override func setValue(_ value: Any?, forKey key: String) { rec("set \(ident) \(key) \(plain(value))") }
    @objc func isDistant() -> Bool { distant }
    var objectID: String { "oid-" + ident }
    var series: Any? { values["series"] }
    func primitiveValue(_ key: String) -> Any? {
        rec("primitive \(ident) \(key)")
        return values[key]
    }
    override func isEqual(_ object: Any?) -> Bool { self === (object as AnyObject?) }
    override var hash: Int { ObjectIdentifier(self).hashValue }
}
final class DicomStudy: Mock {}
final class DicomSeries: Mock {}
final class DicomImage: Mock {}
final class DicomAlbum: Mock {}
class QueryNode: Mock {
    var kids: NSMutableArray?
    var queryGives: NSArray?
    func children() -> NSArray? { kids }
    func purgeChildren() { rec("purge \(ident)"); kids = nil }
    func query() { rec("query \(ident)"); kids = queryGives.map { NSMutableArray(array: $0 as [AnyObject]) } }
    func setChildren(_ c: NSArray) { rec("setChildren \(ident) \(c.count)"); kids = c.mutableCopy() as? NSMutableArray }
}
final class StudyNode: QueryNode {}
final class SeriesNode: QueryNode {}
final class TestStudy: Mock { var pathSet = NSSet() }
final class SurgicalRow: NSObject, Identified {
    var ident: String { "surgical" }
    @objc func isDistant() -> Bool { false }
    override func value(forKey key: String) -> Any? { nil }
}

final class Database: NSObject, Identified {
    var ident = ""
    var baseDirPath: String?
    var name: String?
    var local = false
    var remote = false
}
var databasesByContext: [String: Database] = [:]
var contextObjects: [String: Any] = [:]

func makeRow(_ spec: Any?) -> Any? {
    guard let spec else { return nil }
    guard let d = spec as? NSDictionary else { return spec }
    let kind = d.object(forKey: "cls") as? String
    if kind == "surgical" { return SurgicalRow() }
    if kind == "file" {
        let image = NSMutableDictionary(dictionary: d.object(forKey: "values") as? NSDictionary ?? [:])
        image.setObject((testRoot as NSString).appendingPathComponent(d.object(forKey: "file") as! String), forKey: "completePath" as NSString)
        return image
    }
    let m: Mock
    switch kind {
    case "study": m = DicomStudy()
    case "series": m = DicomSeries()
    case "image": m = DicomImage()
    case "node": m = StudyNode()
    case "seriesNode": m = SeriesNode()
    case "album": m = DicomAlbum()
    case "testStudy": m = TestStudy()
    default: m = Mock()
    }
    m.ident = d.object(forKey: "id") as? String ?? ""
    m.distant = boolValue(d.object(forKey: "distant"))
    m.context = d.object(forKey: "context")
    var values: [String: Any] = [:]
    for (key, value) in (d.object(forKey: "values") as? NSDictionary ?? [:]) { values[key as! String] = value }
    if let ago = d.object(forKey: "dateAgo") as? NSNumber { values["date"] = NSDate(timeIntervalSinceReferenceDate: testNow - ago.doubleValue) }
    if let ago = d.object(forKey: "dateAddedAgo") as? NSNumber { values["dateAdded"] = NSDate(timeIntervalSinceReferenceDate: testNow - ago.doubleValue) }
    if let offset = d.object(forKey: "dateToday0") as? NSNumber { values["date"] = NSDate(timeIntervalSinceReferenceDate: (testNow / 86400).rounded(.down) * 86400 + offset.doubleValue) }
    if let list = d.object(forKey: "reportSeries") as? NSArray { values["series"] = makeRows(list) }
    if let list = d.object(forKey: "seriesSet") as? NSArray { values["series"] = NSSet(array: makeRows(list) as! [Any]) }
    if let row = d.object(forKey: "seriesRow") { values["series"] = makeRow(row) }
    if let list = d.object(forKey: "imagesSet") as? NSArray { values["images"] = NSSet(array: makeRows(list) as! [Any]) }
    if let list = d.object(forKey: "imagesList") as? NSArray { values["images"] = makeRows(list) }
    if let count = d.object(forKey: "imageSeriesCount") as? NSNumber { values["imageSeries"] = NSArray(array: Array(repeating: "s", count: count.intValue)) }
    if let list = d.object(forKey: "kids") as? NSArray { values["kids"] = makeRows(list) }
    m.values = values
    if let node = m as? QueryNode {
        node.kids = (makeRows(d.object(forKey: "nodeKids") as? NSArray) as NSArray?).map { NSMutableArray(array: $0 as [AnyObject]) }
        node.queryGives = makeRows(d.object(forKey: "queryGives") as? NSArray)
    }
    if let study = m as? TestStudy { study.pathSet = NSSet(array: d.object(forKey: "paths") as? [Any] ?? []) }
    return m
}
func makeRows(_ list: NSArray?) -> NSArray? {
    guard let list else { return nil }
    return NSArray(array: list.map { makeRow($0) as Any })
}

// Stand-ins of the app's classes, as the Objective-C harness has them.
func pathsEqual(_ a: String?, _ b: String?) -> Bool {
    guard let a, let b else { return false }
    return (a.lowercased() as NSString).isEqual(to: b.lowercased())
}
func federatedName(_ name: Any?, origin: String, current: String?) -> String {
    "\(described(name)) <\(origin) / \(described(current))>"
}
func displayOrigin(_ name: String?, _ path: String?) -> String { "\(described(name))@\(described(path))" }
func isStructuredReport(_ uid: Any?) -> Bool { (uid as? String)?.hasPrefix("1.2.840.10008.5.1.4.1.1.88") ?? false }
func singleLine(_ note: Any?) -> Any? {
    guard let note = note as? String else { return nil }
    return note.components(separatedBy: "\n").joined(separator: " ")
}
func alert(_ kind: String, _ title: String, _ message: String, _ a: String?, _ b: String?, _ c: String?) -> Int {
    let answer = alertIndex < alertAnswers.count ? (alertAnswers[alertIndex] as! NSNumber).intValue : 1
    alertIndex += 1
    rec("alert \(kind) '\(title)' '\(message)' \(plain(a)) \(plain(b)) \(plain(c)) -> \(answer)")
    return answer
}
var alertAnswers: NSArray = []
var alertIndex = 0
let HorosAlertDefaultResponse = 1, HorosAlertAlternateResponse = 0, HorosAlertOtherResponse = -1

func rowValue(_ item: Any?, _ key: String) -> Any? { (item as? NSObject)?.value(forKey: key) }
func isRowType(_ item: Any?, _ type: String) -> Bool { (rowValue(item, "type") as? NSString)?.isEqual(to: type) ?? false }
func isDistantRow(_ item: Any?) -> Bool { (item as? Mock)?.isDistant() ?? (item as? SurgicalRow)?.isDistant() ?? false }
func objcElements(_ collection: Any?) -> [Any] {
    switch collection {
    case let set as NSSet: return Array(set)
    case let array as NSArray: return Array(array)
    default: return []
    }
}

// MARK: - The data source and the cells (BrowserController+OutlineDataSource.swift)

var database: Database?

func reportPluginDate(of item: Any?) -> Any? {
    guard let name = testObject("REPORTSPLUGIN") as? String, name == "plug" else { return nil }
    rec("protect")
    rec("plugin date \(plain(item))")
    let date = rowValue(item, "pluginDate")
    rec("unprotect")
    return date
}

func studyListName(_ name: Any?, of item: Any?) -> Any? {
    if let object = item as? Mock, let database,
       let origin = (object.context as? String).flatMap({ databasesByContext[$0] }),
       origin !== database,
       !literallyEqual(origin.baseDirPath, database.baseDirPath),
       !pathsEqual(origin.baseDirPath, database.baseDirPath) {
        return federatedName(name, origin: displayOrigin(origin.name, origin.baseDirPath), current: database.name)
    }
    return name
}

func latestReportImageDate(of item: Any?) -> Any? {
    var latest: Date?
    for case let oneSeries as NSObject in objcElements(rowValue(item, "series")) {
        guard StudyListCell.isReportSeries(id: oneSeries.value(forKey: "id"), name: oneSeries.value(forKey: "name"), isStructuredReport: {
            isStructuredReport(oneSeries.value(forKey: "seriesSOPClassUID"))
        }) else { continue }
        for case let image as NSObject in objcElements(oneSeries.value(forKey: "images")) {
            let date = image.value(forKey: "date") as? Date
            if StudyListCell.isLater(date, than: latest) { latest = date }
        }
    }
    return latest
}

func objectValue(_ item: Any?, _ identifier: String) -> Any? {
    let row = StudyListCell.Row(
        value: { rowValue(item, $0) },
        isDistant: { isDistantRow(item) },
        isStudyObject: { item is DicomStudy },
        reportPluginDate: { reportPluginDate(of: item) },
        latestReportDate: { latestReportImageDate(of: item) },
        note: { singleLine((item as? DicomStudy)?.value(forKey: "note")) },
        displayName: { name in studyListName(name, of: item) },
        numberOfImageSeries: { Int(truncatingIfNeeded: ((item as? DicomStudy)?.value(forKey: "nis") as? NSNumber)?.uintValue ?? 0) },
        localized: { $0 })
    return StudyListCell.objectValue(identifier: identifier, reportsMode: intValue(testObject("REPORTSMODE")),
                                     hidePatientName: { testBool("HIDEPATIENTNAME") }, ageDisplay: { testInteger("yearOldDatabaseDisplay") }, row: row)
}

func edit(_ key: String, _ object: Any?, _ selection: NSArray?) {
    for managedObject in selection ?? [] {
        switch StudyListEdit.write(key: key, value: object, rowType: { rowValue(managedObject, "type") }) {
        case .skip: break
        case .value: (managedObject as? NSObject)?.setValue(object, forKey: key)
        case .locked(let locked): (managedObject as? NSObject)?.setValue(NSNumber(value: locked), forKey: "lockedStudy")
        }
    }
}

class Cell: NSObject {
    var colored = false
    func setHighlighted(_ flag: Bool) { rec("cell highlighted \(flag ? 1 : 0)") }
    func setFont(_ font: NSFont?) { rec("cell font \(plain(font))") }
    func setImage(_ image: Any?) { rec("cell image \(plain(image))") }
    func setTransparent(_ flag: Bool) { rec("cell transparent \(flag ? 1 : 0)") }
    func setDrawsBackground(_ flag: Bool) { rec("cell background \(flag ? 1 : 0)") }
    func setBackgroundColor(_ color: NSColor) { rec("cell backgroundColor \(color.description)") }
    func setLineBreakMode(_ mode: NSLineBreakMode) { rec("cell lineBreak \(mode.rawValue)") }
    func setTextColor(_ color: NSColor) { rec("cell textColor \(color.description)") }
}
final class ImageAndTextCell: Cell {
    func setLastImage(_ image: Any?) { rec("cell lastImage \(plain(image))") }
}

var previousItem: Any?
var hasOriginal = false
var originalStudies = NSSet()
var focused = false
func fontSize(_ type: String) -> CGFloat { type == "dbFont" ? 12.5 : 10.0 }
let reportIcons = (local: TestImage("Report.icns"), web: TestImage("download-icon"))

func display(_ cell: Cell, _ identifier: String?, _ item: Any?) {
    cell.setHighlighted(false)
    if let imageCell = cell as? ImageAndTextCell {
        imageCell.setImage(nil)
        imageCell.setLastImage(nil)
    }
    func isColumn(_ name: String) -> Bool { literallyEqual(identifier, name) }

    if isRowType(item, "Study") {
        if isColumn("lockedStudy") { cell.setTransparent(false) }
        let size = fontSize("dbFont")
        switch StudyListRowStyle.font(isStudy: true, isDistant: { isDistantRow(item) }, listed: {
            hasOriginal ? originalStudies.contains(item as Any) : nil
        }) {
        case .distant: cell.setFont(NSFont(name: "Helvetica-BoldOblique", size: size))
        case .bold: cell.setFont(NSFont.boldSystemFont(ofSize: size))
        case .regular: cell.setFont(NSFont.systemFont(ofSize: size))
        case .series: break
        }

        if isColumn("name") {
            let previous = previousItem
            let background = StudyListRowStyle.samePatientBackground(
                enabled: testBool("displaySamePatientWithColorBackground") && focused,
                selectionIsStudy: { isRowType(previous, "Study") },
                isSelection: (previous as AnyObject?) === (item as AnyObject?),
                patientUID: { rowValue(item, "patientUID") },
                selectedPatientUID: { rowValue(previous, "patientUID") })
            cell.setDrawsBackground(background)
            if background { cell.setBackgroundColor(NSColor.unemphasizedSelectedContentBackgroundColor) }

            let date = rowValue(item, "date") as? Date
            let recency = StudyListRowStyle.recency(dateSinceNow: date?.timeIntervalSinceNow, date: date?.timeIntervalSinceReferenceDate,
                                                    todayStart: { testToday },
                                                    added: {
                                                        let added = rowValue(item, "dateAdded")
                                                        return (added != nil, (added as? Date)?.timeIntervalSinceNow)
                                                    })
            switch recency {
            case .tenMinutes: cell.setImage(TestImage("Realised1.tif"))
            case .hour: cell.setImage(TestImage("Realised2.tif"))
            case .fourHours: cell.setImage(TestImage("Realised3.tif"))
            case .today: cell.setImage(TestImage("Realised4.tif"))
            case .received: cell.setImage(TestImage("Receiving.tif"))
            case nil: break
            }
        }

        if isColumn("reportURL") {
            switch StudyListRowStyle.reportIcon(url: rowValue(item, "reportURL"), databaseIsLocal: database?.local ?? false) {
            case .web: cell.setImage(reportIcons.web)
            case .file: cell.setImage(reportIcons.local)
            case nil: break
            }
        }
    } else {
        if isColumn("lockedStudy") { cell.setTransparent(true) }
        cell.setFont(NSFont.boldSystemFont(ofSize: fontSize("dbSeriesFont")))
    }
    cell.setLineBreakMode(.byTruncatingMiddle)

    if cell.colored {
        let type = rowValue(item, "type")
        let gray = StudyListCell.showsUnknown(type: type, identifier: identifier ?? "", value: {
            rowValue(item, StudyListCell.valueKey(type: type, identifier: identifier ?? ""))
        })
        cell.setTextColor(gray ? NSColor.disabledControlTextColor : NSColor.controlTextColor)
    }
}

func toolTip(_ item: Any?, _ identifier: String?, _ frame: NSRect, _ mouseLocation: NSPoint) -> String? {
    if isDistantRow(item) { return "Double-Click to retrieve" }
    guard literallyEqual(identifier, "name") else { return nil }
    let imageFrame = NSRect(x: frame.origin.x, y: frame.origin.y, width: frame.size.height, height: frame.size.height)
    guard NSPointInRect(mouseLocation, imageFrame) else { return nil }
    let now = Date().timeIntervalSinceReferenceDate
    let acquired = (rowValue(item, "date") as? Date)?.timeIntervalSinceReferenceDate
    let added = (rowValue(item, "dateAdded") as? Date)?.timeIntervalSinceReferenceDate
    switch StudyListRowStyle.toolTip(now: now, acquired: acquired, added: added) {
    case .tenMinutes: return "Acquired within the last 10 minutes"
    case .hour: return "Acquired within the last hour"
    case .fourHours: return "Acquired within the last 4 hours"
    case .today: return "Acquired today"
    case .addedMinute: return "Added within the last 60 seconds"
    case nil: return nil
    }
}

func isExpandable(_ item: Any?) -> Bool {
    StudyListTree.isExpandable(surgicalRow: item is SurgicalRow, isDistant: { isDistantRow(item) },
                               isStudyNode: { item is StudyNode }, type: { rowValue(item, "type") })
}

func numberOfChildren(_ item: Any?, listCount: Int) -> Int {
    if database == nil { return 0 }
    guard let item else { return Int(Int32(truncatingIfNeeded: listCount)) }
    if item is SurgicalRow { return 0 }
    if isDistantRow(item) {
        if let node = item as? StudyNode {
            let children = node.children()
            if StudyListTree.nodeChildrenAreStale(count: children?.count ?? 0, lastIsQueryNode: { children?.lastObject is QueryNode }) {
                node.purgeChildren()
            }
            if node.children() == nil {
                node.query()
                if node.children() == nil { node.setChildren(NSMutableArray()) }
            }
        }
        return (item as? QueryNode)?.children()?.count ?? 0
    }
    return StudyListTree.childCount(type: rowValue(item, "type"), noFiles: { rowValue(item, "noFiles") },
                                    imageSeries: { rowValue(item, "imageSeries") })
}

final class Outline: NSObject {
    var tableColumns: [NSTableColumn] = []
    var visible = NSMutableSet()
    var selectedColumn = 0
    var selectedRow = 0
    var tag = 0
    var rows: NSArray?
    var selectedRowIndexes = IndexSet()
    var menu: NSMenu?
    func isColumnWithIdentifierVisible(_ identifier: Any?) -> Bool { visible.contains(identifier as Any) }
    func setColumnWithIdentifier(_ identifier: Any?, visible flag: Bool) { rec("column \(described(identifier)) visible \(flag ? 1 : 0)") }
    func column(withIdentifier identifier: String) -> Int {
        for (i, c) in tableColumns.enumerated() where c.identifier.rawValue == identifier { return i }
        return -1
    }
    func selectColumnIndexes(_ indexes: IndexSet) { rec("select column \(indexes.first ?? NSNotFound)") }
    func scrollColumnToVisible(_ column: Int) { rec("scroll column \(column)") }
    func item(atRow row: Int) -> Any? { row >= 0 && row < (rows?.count ?? 0) ? rows?.object(at: row) : nil }
    func reloadData() { rec("reload \(tag)") }
    func selectRow(_ row: Int) { rec("select row \(row) in \(tag)"); selectedRow = row }
    func scrollRowToVisible(_ row: Int) { rec("scroll row \(row) in \(tag)") }
    func setHeader(_ title: String) { rec("column Cell"); rec("header \(title)") }
}

var columnsMenu: NSMenu?
var databaseOutline: Outline?

func buildColumnsMenu() {
    let menu = NSMenu(title: "")
    columnsMenu = menu
    let columns = databaseOutline?.tableColumns ?? []
    for index in StudyListColumns.menuOrder(titles: columns.map { $0.headerCell.stringValue }) {
        let column = columns[index]
        let item = menu.addItem(withTitle: column.headerCell.stringValue, action: nil, keyEquivalent: "")
        item.representedObject = column.identifier.rawValue
    }
    if databaseOutline != nil { rec("header menu \(menu.numberOfItems)") }
}

func columnsMenuWillOpen() {
    let columns = databaseOutline?.tableColumns ?? []
    let identifiers: [Any?] = columns.map { $0.identifier.rawValue }
    for item in columnsMenu?.items ?? [] {
        let checked = StudyListColumns.isChecked(identifier: item.representedObject, hidePatientName: testBool("HIDEPATIENTNAME"),
                                                 identifiers: identifiers, hidden: { columns[$0].isHidden })
        item.state = checked ? .on : .off
    }
}

func columnsMenuAction(_ sender: NSMenuItem) {
    sender.state = sender.state.rawValue == 0 ? .on : .off
    if literallyEqual(sender.representedObject as? String, "name") {
        rec("defaults HIDEPATIENTNAME bool \(sender.state.rawValue == 0 ? 1 : 0)")
    } else {
        let items = columnsMenu?.items ?? []
        let saved = StudyListColumns.saved(titles: items.map(\.title), states: items.map { $0.state.rawValue })
        rec("defaults COLUMNSDATABASE \(plain(saved))")
        refreshColumns()
    }
}

func refreshColumns() {
    let columnsDatabase = testObject("COLUMNSDATABASE") as? NSDictionary
    let enumerator = columnsDatabase?.keyEnumerator()
    while let key = enumerator?.nextObject() as? String {
        guard let outline = databaseOutline else { continue }
        let titles = ((outline.tableColumns as NSArray).value(forKey: "headerCell") as? NSArray)?.value(forKey: "title") as? NSArray
        let index = titles?.index(of: key) ?? NSNotFound
        if index == NSNotFound { continue }
        let identifier = outline.tableColumns[index].identifier
        let change = StudyListColumns.change(visible: outline.isColumnWithIdentifierVisible(identifier.rawValue),
                                             saved: columnsDatabase?.value(forKey: key),
                                             isSelectedColumn: { outline.column(withIdentifier: identifier.rawValue) == outline.selectedColumn })
        if let change {
            if change.selectFirstColumn { outline.selectColumnIndexes(IndexSet(integer: 0)) }
            outline.setColumnWithIdentifier(identifier.rawValue, visible: change.visible)
            if change.scrollToColumn { outline.scrollColumnToVisible(outline.column(withIdentifier: identifier.rawValue)) }
        }
    }
    buildColumnsMenu()
}

// MARK: - The selection and the history (BrowserController+OutlineSelection.swift)

var comparativeStudies: NSArray?
var comparativePatientUID: String?
var comparativeTable = Outline()
var displayedViewers = 0
var lastRefreshComparativeStudies: TimeInterval = 0
var lastRefreshSmartAlbumDistantStudies: TimeInterval = 0
var albumTable = Outline()
var albumArray: NSArray?
var previousNoOfFiles = 0
var databaseIsEdited = false

func comparativeStudyUIDs() -> [Any?]? {
    guard let studies = comparativeStudies else { return nil }
    return ((studies.value(forKey: "studyInstanceUID") as? NSArray) as? [Any])?.map { $0 is NSNull ? nil : $0 }
}
func studyOfRow(_ item: Any?) -> Any? { isRowType(item, "Study") ? item : rowValue(item, "study") }
func comparativeSearchObject(_ study: Any?) -> Any? {
    if let study = study as? DicomStudy { return study.objectID }
    return study
}
func selectedOutlineItem() -> Any? {
    guard let outline = databaseOutline else { return nil }
    return outline.item(atRow: outline.selectedRowIndexes.first ?? NSNotFound)
}

func newStudies(_ newStudies: NSArray?) {
    if database == nil { return }
    let table = comparativeTable
    for newStudy in newStudies ?? [] {
        guard ComparativeHistory.isShownPatient(shown: comparativePatientUID, patientUID: rowValue(newStudy, "patientUID")) else { continue }
        let current = comparativeStudies ?? NSArray()
        let copy = NSMutableArray(array: current as [AnyObject])
        var selectedStudy: Any?
        if table.selectedRow >= 0 { selectedStudy = copy.object(at: table.selectedRow) }
        let history = ComparativeHistory.newStudy(rowValue(newStudy, "studyInstanceUID"),
                                                  uids: (0..<current.count).map { rowValue(current.object(at: $0), "studyInstanceUID") },
                                                  isQueryNode: { current.object(at: $0) is StudyNode })
        for index in history.replaced {
            let position = copy.index(of: current.object(at: index))
            if position != NSNotFound { copy.replaceObject(at: position, with: newStudy) }
        }
        if !history.found {
            copy.add(newStudy)
            copy.sort(using: [NSSortDescriptor(key: "date", ascending: false)])
        }
        comparativeStudies = copy
        table.reloadData()
        if let selectedStudy {
            let uids = ((copy.value(forKey: "studyInstanceUID") as? NSArray) as? [Any])?.map { $0 is NSNull ? nil : $0 }
            if let index = ComparativeHistory.row(of: rowValue(selectedStudy, "studyInstanceUID"), in: uids ?? []) {
                table.selectRow(index)
            }
        }
    }
}

func refreshHistory(_ newStudies: NSArray?) {
    if database == nil { return }
    let item = selectedOutlineItem()
    let studySelected = studyOfRow(item)
    let table = comparativeTable
    if item != nil {
        let mainContextStudies = NSMutableArray()
        for study in newStudies ?? [] {
            if let study = study as? DicomStudy {
                rec("objectWithID \(study.objectID)")
                if let object = contextObjects[study.objectID] { mainContextStudies.add(object) }
            } else {
                mainContextStudies.add(study)
            }
        }
        comparativeStudies = mainContextStudies
        table.reloadData()
        if let name = rowValue(studySelected, "name") as? String { table.setHeader(name) }
        let index = ComparativeHistory.row(of: rowValue(studySelected, "studyInstanceUID"), in: comparativeStudyUIDs())
        table.selectRow(index ?? 0)
        for _ in 0..<displayedViewers { rec("viewer refresh \(plain(comparativePatientUID))") }
        table.scrollRowToVisible(table.selectedRow)
    } else {
        comparativeStudies = nil
        table.reloadData()
    }
}

func refreshNeeded(_ timer: Any?) {
    if timer == nil { lastRefreshComparativeStudies = 0 }
    if ComparativeHistory.refreshDue(now: Date.timeIntervalSinceReferenceDate, last: lastRefreshComparativeStudies) {
        let studySelected = studyOfRow(selectedOutlineItem())
        if let object = comparativeSearchObject(studySelected) {
            rec("detach searchForComparativeStudies: \(plain(object))")
        }
        rec("computeTimeInterval")
    }
    if testBool("searchForSmartAlbumStudiesOnDICOMNodes"), albumTable.selectedRow > 0 {
        if (albumArray?.count ?? 0) > albumTable.selectedRow, let album = albumArray?.object(at: albumTable.selectedRow) as? DicomAlbum {
            if boolValue(album.value(forKey: "smartAlbum")) {
                if ComparativeHistory.refreshDue(now: Date.timeIntervalSinceReferenceDate, last: lastRefreshSmartAlbumDistantStudies) {
                    rec("detach searchForSmartAlbumDistantStudies: \(plain(album.value(forKey: "name")))")
                }
            }
        }
    }
}

func selectionHistory(_ item: Any) {
    let table = comparativeTable
    if (previousItem as AnyObject?) !== (item as AnyObject) {
        previousItem = item
        let studySelected = studyOfRow(item)
        if ComparativeHistory.patientChanged(selected: rowValue(studySelected, "patientUID"), shown: comparativePatientUID) {
            comparativePatientUID = rowValue(studySelected, "patientUID") as? String
            comparativeStudies = nil
            table.reloadData()
            table.setHeader("History")
            rec("detach searchForComparativeStudies: \(plain(comparativeSearchObject(studySelected)))")
        } else if let index = ComparativeHistory.row(of: rowValue(studySelected, "studyInstanceUID"), in: comparativeStudyUIDs()) {
            table.selectRow(index)
            table.scrollRowToVisible(table.selectedRow)
        }
    }
}

func isSameRow(_ item: Any?, _ previous: Any?) -> Bool {
    if (item as AnyObject?) === (previous as AnyObject?) { return true }
    guard let previous = previous as? Mock, let item = item as? Mock else { return false }
    return (previous.objectID as NSString).isEqual(item.objectID)
}

func refreshMatrixFor(_ item: Any) -> Bool {
    let sameRow = isSameRow(item, previousItem)
    let nowFiles = Int(intValue(rowValue(item, "noFiles")))
    if !sameRow { databaseIsEdited = false }
    let refresh = OutlineSelection.matrixNeedsRefresh(sameItem: sameRow, files: nowFiles, previousFiles: previousNoOfFiles)
    previousNoOfFiles = nowFiles
    return refresh
}

func frames(_ item: Any?) -> Bool {
    OutlineSelection.showsFrames(type: rowValue(item, "type"), imageCount: { (rowValue(item, "images") as? NSSet)?.count ?? 0 },
                                 frames: { rowValue((rowValue(item, "images") as? NSSet)?.allObjects.first, "numberOfFrames") })
}

func separateThread(_ files: NSArray?, imageLevel: Bool) -> Bool {
    OutlineSelection.iconsOnSeparateThread(imageLevel: imageLevel, missingThumbnails: {
        var thumbnailsToGenerate = 0
        for image in files ?? [] {
            if ((image as? Mock)?.series as? Mock)?.primitiveValue("thumbnail") == nil { thumbnailsToGenerate += 1 }
        }
        return thumbnailsToGenerate
    })
}

// MARK: - Merging (BrowserController+Merge.swift)

func destination(_ seriesArray: NSArray) -> Any? {
    guard seriesArray.count > 0 else { return nil }
    let candidates: [Any?] = seriesArray.map { item in
        isRowType(item, "Series") ? item : (rowValue(item, "series") as? NSSet)?.anyObject()
    }
    var destSeries: Any? = seriesArray[0]
    if let index = StudyMerge.destinationSeries(count: candidates.count, isSeries: { isRowType(candidates[$0], "Series") },
                                                imageExtension: { rowValue((rowValue(candidates[$0], "images") as? NSSet)?.anyObject(), "extension") }) {
        destSeries = candidates[index]
    }
    if !isRowType(destSeries, "Series") { destSeries = rowValue(destSeries, "Series") }
    return destSeries
}

final class Tag: NSObject, Identified {
    let ident: String
    init(_ tag: String) { ident = "tag" + tag }
}
func arrayUpToNil(_ objects: Any?...) -> NSArray {
    let array = NSMutableArray()
    for object in objects {
        guard let object else { break }
        array.add(object)
    }
    return array
}
func identityEdits(_ tags: [String], _ values: [Any?]) -> [Any] {
    StudyMerge.edits(tags: tags, values: values).map { arrayUpToNil(Tag($0.tag), $0.value) }
}

var fileAttributes: NSDictionary = [:]
func dicomObject(atPath path: String?) -> NSDictionary? {
    guard let path else { return nil }
    return fileAttributes.object(forKey: path) as? NSDictionary
}
func firstPath(of study: Any?) -> String? {
    guard let study = study as? TestStudy else { return nil }
    return study.pathSet.allObjects.first as? String
}
func formerIdentity(of study: Any?) -> (names: String, ids: String) {
    let own = dicomObject(atPath: firstPath(of: study))
    return StudyMerge.formerIdentity(otherNames: own?.object(forKey: "OtherPatientNames"), otherIDs: own?.object(forKey: "OtherPatientIDs"),
                                     name: rowValue(study, "name"), patientID: rowValue(study, "patientID"))
}

var charsets: NSDictionary = [:]
func writeIdentityEdits(_ files: NSArray, _ tagAndValues: [Any], _ title: String) -> Bool {
    let values = NSMutableArray()
    for case let edit as NSArray in tagAndValues where edit.count > 1 { values.add(edit.object(at: 1)) }
    let plainFiles = NSMutableArray(), declaring = NSMutableArray()
    var refusedFiles = 0
    for file in files {
        rec("charset \(described(file)) \(plain(values))")
        let c = charsets.object(forKey: file) as? String
        var refused = false
        var charset: String?
        if c == "refused" { refused = true } else if c != "none" { charset = c }
        if refused { refusedFiles += 1 }
        (charset != nil ? declaring : plainFiles).add(file)
    }
    if refusedFiles > 0 && alert("critical", title, String(format: "%d files declare a character set that cannot hold the new patient identity. Their other fields will change; the ones they cannot hold will keep their former values.", Int32(truncatingIfNeeded: refusedFiles)), "Continue", "Cancel", nil) != HorosAlertDefaultResponse {
        return false
    }
    if plainFiles.count > 0 { rec("modify \(plain(tagAndValues as NSArray)) \(plain(plainFiles))") }
    if declaring.count > 0 {
        let characterSet = arrayUpToNil(Tag(StudyMerge.characterSetTag), StudyMerge.unicodeCharacterSet)
        rec("modify \(plain(([characterSet] + tagAndValues) as NSArray)) \(plain(declaring))")
    }
    for case let file as String in files { rec("remove \(((file + ".bak") as NSString).lastPathComponent)") }
    return true
}

func unifyEdits(_ dest: Any?, _ dcm: NSDictionary, _ former: NSArray) -> NSArray {
    identityEdits(StudyMerge.patientTags, [rowValue(dest, "patientID"), dcm.object(forKey: "PatientsName"), dcm.object(forKey: "PatientsBirthDate"),
                                           former.object(at: 1), former.object(at: 0)]) as NSArray
}

func mergeEdits(_ dest: Any?, _ study: Any?, _ dcm: NSDictionary, _ former: NSArray) -> NSArray {
    var tagAndValues: [Any] = []
    if StudyMerge.changesPatient(destinationID: rowValue(dest, "patientID"), destinationName: rowValue(dest, "name"),
                                 studyID: rowValue(study, "patientID"), studyName: rowValue(study, "name")) {
        tagAndValues += identityEdits(StudyMerge.patientTags, [rowValue(dest, "patientID"), dcm.object(forKey: "PatientsName"),
                                                               dcm.object(forKey: "PatientsBirthDate"), former.object(at: 1), former.object(at: 0)])
    }
    tagAndValues += identityEdits(StudyMerge.studyTags, [dcm.object(forKey: "StudyID"), dcm.object(forKey: "StudyInstanceUID"), dcm.object(forKey: "StudyDescription")])
    return tagAndValues as NSArray
}

// MARK: - Deleting (BrowserController+Deletion.swift)

func objcFiltered(_ array: NSArray, _ predicate: NSPredicate) -> NSArray {
    let copy = array.mutableCopy() as! NSMutableArray
    copy.filter(using: predicate)
    return copy.copy() as! NSArray
}

func delObjects(_ objectsToDelete: NSMutableArray?, tree treeObjs: NSMutableSet?) {
    let lockedImages = objectsToDelete.map { objcFiltered($0, NSPredicate(format: "series.study.lockedStudy == YES")) }
    switch StudyDeletion.locked(lockedImages?.count ?? 0, of: objectsToDelete?.count ?? 0) {
    case .all:
        _ = alert("plain", "Locked Studies", "These images are stored in locked studies. First, unlock these studies to delete them.", nil, nil, nil)
    case .some, .none:
        var cancelled = false
        if let lockedImages, lockedImages.count > 0 {
            objectsToDelete?.removeObjects(in: lockedImages as? [Any] ?? [])
            _ = alert("info", "Locked Studies", "Some images are stored in locked studies. Only unlocked images will be deleted.", "OK", nil, nil)
        }
        if albumTable.selectedRow == 0 {
            let albumedImages = objectsToDelete.map { objcFiltered($0, NSPredicate(format: "series.study.albums.@count > 0")) }
            if let albumedImages, albumedImages.count > 0 {
                let result = alert("info", "Images in Albums", "Some or all of these images are stored in albums. Do you really want to delete these images, stored in albums?\r\rDelete all images or only those not stored in an album?", "All", "Cancel", "Only if not stored in an album")
                if result == HorosAlertOtherResponse { objectsToDelete?.removeObjects(in: albumedImages as? [Any] ?? []) }
                if result == HorosAlertAlternateResponse { cancelled = true }
            }
        }
        if !cancelled {
            rec("wait 'Deleting...'")
            rec("wait show")
            let nonLocalImagesPath = objectsToDelete.flatMap { objcFiltered($0, NSPredicate(format: "inDatabaseFolder == NO")).value(forKey: "completePath") as? NSArray }
            let result: Int
            if (nonLocalImagesPath?.count ?? 0) > 0 {
                rec("wait hide")
                result = alert("info", "Delete/Remove images", "Some of the selected images are not stored in the Database folder. Do you want to only remove the links of these images from the database or also delete the original files?", "Remove the links", "Cancel", "Delete the files")
                rec("wait front")
            } else {
                result = HorosAlertDefaultResponse
            }
            if result != HorosAlertAlternateResponse {
                if result == HorosAlertDefaultResponse || result == HorosAlertOtherResponse {
                    rec("proceed \(plain(objectsToDelete?.value(forKey: "id"))) tree \(treeObjs != nil ? "set" : "nil")")
                }
                if result == HorosAlertOtherResponse {
                    for case let path as String in nonLocalImagesPath ?? [] {
                        try? FileManager.default.removeItem(atPath: path)
                        if let companion = StudyDeletion.companionFile(of: path) { try? FileManager.default.removeItem(atPath: companion) }
                        let currentDirectory = (path as NSString).deletingLastPathComponent + "/"
                        let dirContent = try? FileManager.default.contentsOfDirectory(atPath: currentDirectory)
                        if StudyDeletion.removesFolder(contents: dirContent) { try? FileManager.default.removeItem(atPath: currentDirectory) }
                    }
                }
            }
            rec("wait close")
        }
    }
    rec("refreshMatrix")
}

func tree(_ folder: String) -> NSArray {
    var names: [String] = []
    if let e = FileManager.default.enumerator(atPath: folder) { for case let name as String in e { names.append(name) } }
    return (names as NSArray).sortedArray(using: #selector(NSString.compare(_:))) as NSArray
}

// MARK: - The driver

@main
struct Driver {
    static func main() {
        let cases = try! PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])), format: nil) as! NSDictionary
        testRoot = CommandLine.arguments[2]
        testNow = Date.timeIntervalSinceReferenceDate
        var databases: [String: Database] = [:]
        for (key, value) in cases.object(forKey: "databases") as! NSDictionary {
            let d = value as! NSDictionary
            let db = Database()
            db.ident = key as! String
            db.baseDirPath = d.object(forKey: "base") as? String
            db.name = d.object(forKey: "name") as? String
            db.local = boolValue(d.object(forKey: "local"))
            db.remote = boolValue(d.object(forKey: "remote"))
            databases[db.ident] = db
        }
        databasesByContext = databases
        func list(_ key: String) -> [NSDictionary] { cases.object(forKey: key) as? [NSDictionary] ?? [] }
        var n = 0

        for c in list("value") {
            testDefaults = c.object(forKey: "defaults") as? NSDictionary ?? [:]
            database = (c.object(forKey: "database") as? String).flatMap { databases[$0] }
            let item = makeRow(c.object(forKey: "row"))
            for case let identifier as String in cases.object(forKey: "identifiers") as! NSArray {
                rec("value \(n) \(identifier) \(plain(objectValue(item, identifier)))")
            }
            n += 1
            flush()
        }

        n = 0
        for c in list("edit") {
            let key = c.object(forKey: "key") as! String
            rec("edit \(n) \(key)")
            n += 1
            edit(key, c.object(forKey: "value"), makeRows(c.object(forKey: "selection") as? NSArray))
            flush()
        }

        n = 0
        for c in list("display") {
            testDefaults = c.object(forKey: "defaults") as? NSDictionary ?? [:]
            database = (c.object(forKey: "database") as? String).flatMap { databases[$0] }
            let item = makeRow(c.object(forKey: "row"))
            let previous = c.object(forKey: "previous")
            previousItem = (previous as? String) == "same" ? item : makeRow(previous)
            hasOriginal = c.object(forKey: "listed") != nil
            originalStudies = boolValue(c.object(forKey: "listed")) ? NSSet(object: item as Any) : NSSet()
            testToday = testNow - ((c.object(forKey: "todayAgo") as? NSNumber)?.doubleValue ?? 0)
            focused = boolValue(c.object(forKey: "focused"))
            let cell = boolValue(c.object(forKey: "imageCell")) ? ImageAndTextCell() : Cell()
            cell.colored = boolValue(c.object(forKey: "colored"))
            let identifier = c.object(forKey: "identifier") as? String
            rec("display \(n) \(identifier ?? "")")
            n += 1
            display(cell, identifier, item)
            flush()
        }
        previousItem = nil

        n = 0
        for c in list("tooltip") {
            let item = makeRow(c.object(forKey: "row"))
            let r = (c.object(forKey: "rect") as! [NSNumber]).map(\.doubleValue), p = (c.object(forKey: "mouse") as! [NSNumber]).map(\.doubleValue)
            let tip = toolTip(item, c.object(forKey: "identifier") as? String, NSRect(x: r[0], y: r[1], width: r[2], height: r[3]), NSPoint(x: p[0], y: p[1]))
            rec("tooltip \(n) \(plain(tip))")
            n += 1
            flush()
        }

        n = 0
        for c in list("tree") {
            database = boolValue(c.object(forKey: "noDatabase")) ? nil : databases["local"]
            let item = makeRow(c.object(forKey: "row"))
            let expandable = isExpandable(item)
            let count = numberOfChildren(item, listCount: (c.object(forKey: "listCount") as? NSNumber)?.intValue ?? 0)
            rec("tree \(n) \(expandable ? 1 : 0) \(count)")
            n += 1
            flush()
        }

        n = 0
        for c in list("columns") {
            testDefaults = c.object(forKey: "defaults") as? NSDictionary ?? [:]
            let outline = Outline()
            for case let spec as NSDictionary in c.object(forKey: "columns") as! NSArray {
                let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(spec.object(forKey: "id") as! String))
                column.headerCell.stringValue = spec.object(forKey: "title") as! String
                column.isHidden = boolValue(spec.object(forKey: "hidden"))
                outline.tableColumns.append(column)
            }
            outline.visible = NSMutableSet(array: c.object(forKey: "visible") as? [Any] ?? [])
            outline.selectedColumn = (c.object(forKey: "selectedColumn") as? NSNumber)?.intValue ?? 0
            databaseOutline = outline
            rec("columns \(n)")
            n += 1
            buildColumnsMenu()
            for item in columnsMenu?.items ?? [] { rec("item '\(item.title)' \(plain(item.representedObject))") }
            columnsMenuWillOpen()
            for item in columnsMenu?.items ?? [] { rec("state '\(item.title)' \(item.state.rawValue)") }
            if let action = c.object(forKey: "action") as? NSNumber, let item = columnsMenu?.items[action.intValue] {
                if let state = c.object(forKey: "actionState") as? NSNumber { item.state = NSControl.StateValue(rawValue: state.intValue) }
                columnsMenuAction(item)
                rec("after '\(item.title)' \(item.state.rawValue)")
            }
            rec("refresh")
            refreshColumns()
            flush()
        }
        databaseOutline = nil

        n = 0
        for c in list("newStudies") {
            database = databases["local"]
            comparativePatientUID = c.object(forKey: "shown") as? String
            comparativeStudies = makeRows(c.object(forKey: "history") as? NSArray)
            comparativeTable = Outline()
            comparativeTable.tag = 2
            comparativeTable.selectedRow = (c.object(forKey: "selectedRow") as? NSNumber)?.intValue ?? 0
            rec("newStudies \(n)")
            n += 1
            newStudies(makeRows(c.object(forKey: "newStudies") as? NSArray))
            rec("history \(plain(comparativeStudies))")
            flush()
        }

        n = 0
        for c in list("refreshHistory") {
            database = databases["local"]
            let outline = Outline()
            outline.rows = makeRows(c.object(forKey: "rows") as? NSArray)
            outline.selectedRowIndexes = (c.object(forKey: "selected") as? NSNumber).map { IndexSet(integer: $0.intValue) } ?? IndexSet()
            databaseOutline = outline
            comparativeTable = Outline()
            comparativeTable.tag = 2
            contextObjects = [:]
            for spec in c.object(forKey: "inContext") as? NSArray ?? [] {
                let m = makeRow(spec) as! Mock
                contextObjects[m.objectID] = m
            }
            comparativePatientUID = c.object(forKey: "shown") as? String
            displayedViewers = boolValue(c.object(forKey: "viewers")) ? 1 : 0
            rec("refreshHistory \(n)")
            n += 1
            refreshHistory(makeRows(c.object(forKey: "newStudies") as? NSArray))
            rec("history \(plain(comparativeStudies))")
            flush()
        }

        n = 0
        for c in list("refreshNeeded") {
            testDefaults = c.object(forKey: "defaults") as? NSDictionary ?? [:]
            lastRefreshComparativeStudies = Date.timeIntervalSinceReferenceDate - ((c.object(forKey: "lastAgo") as? NSNumber)?.doubleValue ?? 0)
            lastRefreshSmartAlbumDistantStudies = Date.timeIntervalSinceReferenceDate - ((c.object(forKey: "lastSmartAgo") as? NSNumber)?.doubleValue ?? 0)
            let outline = Outline()
            outline.rows = makeRows(c.object(forKey: "rows") as? NSArray)
            outline.selectedRowIndexes = (c.object(forKey: "selected") as? NSNumber).map { IndexSet(integer: $0.intValue) } ?? IndexSet()
            databaseOutline = outline
            albumTable = Outline()
            albumTable.selectedRow = (c.object(forKey: "albumRow") as? NSNumber)?.intValue ?? 0
            albumArray = makeRows(c.object(forKey: "albums") as? NSArray)
            rec("refreshNeeded \(n)")
            n += 1
            refreshNeeded(boolValue(c.object(forKey: "timer")) ? "timer" : nil)
            rec("reset \(lastRefreshComparativeStudies == 0 ? 1 : 0)")
            flush()
        }

        n = 0
        for c in list("history") {
            comparativePatientUID = c.object(forKey: "shown") as? String
            comparativeStudies = boolValue(c.object(forKey: "noHistory")) ? nil : makeRows(c.object(forKey: "history") as? NSArray)
            comparativeTable = Outline()
            comparativeTable.tag = 2
            let item = makeRow(c.object(forKey: "item"))!
            let previous = c.object(forKey: "previous")
            previousItem = (previous as? String) == "same" ? item : makeRow(previous)
            rec("selectionHistory \(n)")
            n += 1
            selectionHistory(item)
            rec("shown \(plain(comparativePatientUID)) history \(plain(comparativeStudies)) previous \(plain(previousItem))")
            flush()
        }

        n = 0
        for c in list("refresh") {
            let item = makeRow(c.object(forKey: "item"))!
            let previous = c.object(forKey: "previous")
            previousItem = (previous as? String) == "same" ? item : makeRow(previous)
            previousNoOfFiles = (c.object(forKey: "previousFiles") as? NSNumber)?.intValue ?? 0
            databaseIsEdited = true
            let refresh = refreshMatrixFor(item)
            rec("refresh \(n) \(refresh ? 1 : 0) edited \(databaseIsEdited ? 1 : 0) files \(previousNoOfFiles)")
            n += 1
            flush()
        }
        previousItem = nil

        n = 0
        for c in list("waited") {
            let since = Date.timeIntervalSinceReferenceDate - ((c.object(forKey: "ago") as? NSNumber)?.doubleValue ?? 0)
            rec("waited \(n) \(ComparativeHistory.stillWaiting(now: Date.timeIntervalSinceReferenceDate, since: since) ? 1 : 0)")
            n += 1
            flush()
        }

        n = 0
        for c in list("frames") {
            rec("frames \(n) \(frames(makeRow(c.object(forKey: "item"))) ? 1 : 0)")
            n += 1
            flush()
        }

        n = 0
        for c in list("thread") {
            let separate = separateThread(makeRows(c.object(forKey: "files") as? NSArray), imageLevel: boolValue(c.object(forKey: "imageLevel")))
            rec("thread \(n) \(separate ? 1 : 0)")
            n += 1
            flush()
        }

        n = 0
        for c in list("destination") {
            rec("destination \(n) \(plain(destination(makeRows(c.object(forKey: "series") as? NSArray) ?? [])))")
            n += 1
            flush()
        }

        n = 0
        for c in list("identity") {
            fileAttributes = c.object(forKey: "files") as? NSDictionary ?? [:]
            let former = formerIdentity(of: makeRow(c.object(forKey: "study")))
            rec("identity \(n) \(plain(former.names)) \(plain(former.ids))")
            n += 1
            flush()
        }

        n = 0
        for c in list("write") {
            charsets = c.object(forKey: "charsets") as? NSDictionary ?? [:]
            alertAnswers = c.object(forKey: "answers") as? NSArray ?? []
            alertIndex = 0
            var edits: [Any] = []
            for case let e as NSArray in c.object(forKey: "edits") as? NSArray ?? [] { edits.append([Tag(e.object(at: 0) as! String), e.object(at: 1)] as NSArray) }
            let ok = writeIdentityEdits(c.object(forKey: "files") as? NSArray ?? [], edits, c.object(forKey: "title") as! String)
            rec("write \(n) \(ok ? 1 : 0)")
            n += 1
            flush()
        }

        n = 0
        for c in list("unify") {
            let dcm = c.object(forKey: "dcm") as? NSDictionary ?? [:]
            let former = c.object(forKey: "former") as! NSArray
            rec("unify \(n) \(plain(unifyEdits(makeRow(c.object(forKey: "dest")), dcm, former)))")
            rec("merge \(n) \(plain(mergeEdits(makeRow(c.object(forKey: "dest")), makeRow(c.object(forKey: "study")), dcm, former)))")
            n += 1
            flush()
        }

        n = 0
        for c in list("delete") {
            let folder = (testRoot as NSString).appendingPathComponent("delete\(n)")
            for case let file as String in c.object(forKey: "files") as? NSArray ?? [] {
                let path = (testRoot as NSString).appendingPathComponent(file)
                try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                try? "x".write(toFile: path, atomically: false, encoding: .utf8)
            }
            albumTable = Outline()
            albumTable.selectedRow = (c.object(forKey: "albumRow") as? NSNumber)?.intValue ?? 0
            alertAnswers = c.object(forKey: "answers") as? NSArray ?? []
            alertIndex = 0
            let objects = NSMutableArray(array: (makeRows(c.object(forKey: "images") as? NSArray) ?? []) as [AnyObject])
            rec("delete \(n)")
            n += 1
            delObjects(objects, tree: boolValue(c.object(forKey: "tree")) ? NSMutableSet() : nil)
            rec("left \(plain(tree(folder)))")
            flush()
        }

        n = 0
        for c in list("thumbnails") {
            let outline = Outline(), table = Outline()
            let kind = c.object(forKey: "sender") as? String
            var sender: Any?
            let menu = NSMenu()
            if kind == "item" || kind == "outlineItem" { sender = menu.addItem(withTitle: "x", action: nil, keyEquivalent: "") }
            if kind == "looseItem" { sender = NSMenuItem(title: "x", action: nil, keyEquivalent: "") }
            if kind == "outlineItem" { outline.menu = menu }
            if kind == "other" { sender = "button" }
            let matrix = NSObject()
            let r = c.object(forKey: "responder") as? String
            let responder: AnyObject? = r == "matrix" ? matrix : r == "outline" ? outline : r == "comparative" ? table : nil
            rec("thumbnails \(n)")
            n += 1
            let thumbnails = StudyDeletion.deletesThumbnails(hasSender: sender != nil, listAsked: {
                (sender is NSMenuItem && (sender as? NSMenuItem)?.menu === outline.menu) || responder === outline || responder === table
            })
            rec("thumbnails \(thumbnails ? 1 : 0)")
            flush()
        }

        n = 0
        for c in list("question") {
            albumTable = Outline()
            let albumRow = (c.object(forKey: "albumRow") as? NSNumber)?.intValue ?? 0
            albumArray = makeRows(c.object(forKey: "albums") as? NSArray)
            alertAnswers = [c.object(forKey: "answer") as Any] as NSArray
            alertIndex = 0
            rec("question \(n)")
            n += 1
            let level = c.object(forKey: "level") as! String
            let result: Int
            switch StudyDeletion.question(albumRow: albumRow, thumbnails: boolValue(c.object(forKey: "thumbnails")),
                                          smartAlbum: { boolValue(rowValue(albumArray?.object(at: albumRow), "smartAlbum")) }) {
            case .deleteOrRemove:
                result = alert("info", "Delete/Remove images", String(format: "Do you want to only remove the selected images from the current album or delete them from the database? (%@)", level), "Delete", "Cancel", "Remove from current album")
            case .delete:
                result = alert("info", "Delete images", String(format: "Are you sure you want to delete the selected images? (%@)", level), "OK", "Cancel", nil)
            }
            rec("result \(result)")
            flush()
        }
    }
}
'''


IDENTIFIERS = ['reportURL', 'stateText', 'lockedStudy', 'note', 'modality', 'name', 'dateOfBirth', 'referringPhysician',
               'performingPhysician', 'institutionName', 'patientID', 'yearOld', 'accessionNumber', 'noSeries', 'studyName',
               'comment', 'date', 'noFiles', 'seriesDescription']


def dt(seconds):
    import datetime
    return datetime.datetime(2001, 1, 1) + datetime.timedelta(seconds=seconds)


def build_cases(rng):
    sr = '1.2.840.10008.5.1.4.1.1.88.33'

    def report_series(n):
        series = []
        for i in range(n):
            series.append({'cls': 'series', 'id': 'R%d' % i,
                           'values': {'id': rng.choice([5003, 5003, 5002, '5003']), 'name': rng.choice(['OsiriX Report SR', 'OsiriX Report SR', 'Report', 'osirix report sr']),
                                      'seriesSOPClassUID': rng.choice([sr, sr, '1.2.840.10008.5.1.4.1.1.2'])},
                           'imagesList': [{'cls': 'image', 'id': 'I%d.%d' % (i, j), 'values': ({'date': dt(rng.choice([1000, 5000, 9000, 9000]))} if rng.random() < 0.8 else {})}
                                          for j in range(rng.randint(0, 3))]})
        return series

    def row(n):
        cls = rng.choice(['study', 'study', 'study', 'series', 'series', 'image', 'node', 'mock'])
        values = {}
        for key, choices in [('type', ['Study', 'Series', 'Image', None, 'study']),
                             ('name', ['Smith^John', '', None, 'Ã‰va']), ('studyName', ['CT head', '', None]),
                             ('seriesDescription', ['Axial', '', None]), ('modality', ['CT', '', None, 'MR\\CT']),
                             ('stateText', [0, 1, 3, '2', '0', None]), ('lockedStudy', [0, 1, None]),
                             ('yearOld', ['45 y', '3 m', None, '45 y']), ('yearOldAcquisition', ['46 y', '45 y', None, '2 m']),
                             ('reportURL', ['/r.pages', 'http://x', None]), ('comment', ['c', '', None]),
                             ('noFiles', [0, 3, '7', None]), ('patientID', ['P1', None]), ('accessionNumber', ['A1', None]),
                             ('dateOfBirth', [dt(100), None]), ('pluginDate', [dt(77), None]), ('note', ['line1\nline2', None]),
                             ('nis', [0, 2, 5])]:
            value = rng.choice(choices)
            if value is not None:
                values[key] = value
        if cls == 'study' and values.get('type') is None:
            values['type'] = 'Study'
        spec = {'cls': cls, 'id': 'row%d' % n, 'values': values, 'distant': cls == 'node' or rng.random() < 0.1}
        if cls == 'node':
            spec['values']['type'] = rng.choice(['Study', 'Series'])
        if rng.random() < 0.4:
            spec['reportSeries'] = report_series(rng.randint(0, 3))
        if rng.random() < 0.5:
            spec['imageSeriesCount'] = rng.randint(0, 4)
        if rng.random() < 0.5:
            spec['context'] = rng.choice(['local', 'other', 'sameLower', 'missing'])
        return spec

    databases = {'local': {'base': '/Data/Horos Data', 'name': 'Local', 'local': True},
                 'other': {'base': '/Other/Horos Data', 'name': 'Other', 'local': True},
                 'sameLower': {'base': '/data/horos data', 'name': 'Lower', 'local': True},
                 'remote': {'base': '/Remote', 'name': 'Remote', 'local': False, 'remote': True}}

    value = []
    for n in range(160):
        defaults = {}
        if rng.random() < 0.5:
            defaults['REPORTSMODE'] = rng.choice(['3', 3, '0', 1])
        if rng.random() < 0.5:
            defaults['REPORTSPLUGIN'] = rng.choice(['plug', 'none'])
        if rng.random() < 0.4:
            defaults['HIDEPATIENTNAME'] = rng.choice([True, False])
        if rng.random() < 0.7:
            defaults['yearOldDatabaseDisplay'] = rng.choice([0, 1, 2, 3, -1])
        c = {'row': row(n), 'defaults': defaults}
        if rng.random() < 0.9:
            c['database'] = rng.choice(['local', 'local', 'other', 'remote'])
        value.append(c)

    edit = []
    for key in ['stateText', 'lockedStudy', 'comment', 'comment2']:
        for v in [0, 1, 2, -1, 256, '3', '-2', 'x', None]:
            selection = [{'cls': rng.choice(['study', 'series']), 'id': 'sel%d' % i, 'values': {'type': rng.choice(['Study', 'Series', 'study'])}}
                         for i in range(rng.randint(0, 3))]
            c = {'key': key, 'selection': selection}
            if v is not None:
                c['value'] = v
            edit.append(c)

    display = []
    for n in range(400):
        spec = row(1000 + n)
        if n % 2 == 0:
            spec['cls'] = 'study'
            spec['values']['type'] = 'Study'
        r = rng.random() * (0.5 if n % 4 == 0 else 1)
        if r < 0.25:
            spec['dateAgo'] = rng.choice([-30000, 0, 100, 500, 570, 630, 700, 2000, 3570, 3630, 4000, 10000, 14370, 14430, 20000, 80000, 86370, 86430, 90000, 300000])
        elif r < 0.35:
            spec['dateToday0'] = rng.choice([-3600, 3600, 30000, 82000])
        if rng.random() < 0.4:
            spec['dateAddedAgo'] = rng.choice([10, 30, 100, 1000])
        spec['values']['patientUID'] = rng.choice(['ABC', 'abc', 'A', '', 'Ã‰VA', 'eva', 'a'])
        c = {'row': spec, 'identifier': 'name' if n % 4 == 0 else rng.choice(['name', 'name', 'reportURL', 'lockedStudy', 'studyName', 'modality', 'comment', 'yearOld']),
             'database': rng.choice(['local', 'remote']), 'imageCell': rng.random() < 0.6, 'colored': rng.random() < 0.8,
             'focused': rng.random() < 0.6, 'todayAgo': rng.choice([100, 20000, 50000, 90000]),
             'defaults': {'displaySamePatientWithColorBackground': rng.random() < 0.7}}
        p = rng.random()
        if p < 0.2:
            c['previous'] = 'same'
        elif p < 0.8:
            c['previous'] = {'cls': 'study', 'id': 'prev%d' % n, 'values': {'type': rng.choice(['Study', 'Study', 'Series']), 'patientUID': rng.choice(['abc', 'ABC', 'eva', 'Ã‰va', 'zz', 'a', ''])}}
        if rng.random() < 0.6:
            c['listed'] = rng.random() < 0.5
        display.append(c)

    for n, (uid, other) in enumerate([('A', 'a'), ('AB', 'ab'), ('', ''), ('ab', None), ('Ã‰va', 'eva'), ('ab', 'ab ')]):
        previous = {'cls': 'study', 'id': 'pp%d' % n, 'values': {'type': 'Study', 'patientUID': other}}
        display.append({'row': {'cls': 'study', 'id': 'pu%d' % n, 'values': {'type': 'Study', 'patientUID': uid}}, 'identifier': 'name',
                         'database': 'local', 'imageCell': True, 'colored': True, 'focused': True, 'todayAgo': 100,
                         'defaults': {'displaySamePatientWithColorBackground': True}, 'previous': previous})

    tooltip = []
    for n in range(160):
        spec = {'cls': rng.choice(['study', 'study', 'node']), 'id': 't%d' % n, 'values': {}, 'distant': rng.random() < 0.15}
        r = rng.random()
        if r < 0.5:
            spec['dateAgo'] = rng.choice([-500, 100, 500, 700, 2000, 4000, 13000, 15000, 100000, 400000])
        elif r < 0.8:
            spec['dateToday0'] = rng.choice([-7200, -100, 100, 7200])
        if rng.random() < 0.5:
            spec['dateAddedAgo'] = rng.choice([5, 30, 90, 1000])
        tooltip.append({'row': spec, 'identifier': rng.choice(['name', 'name', 'name', 'comment']),
                        'rect': [10, 20, 100, 16], 'mouse': rng.choice([[12, 25], [12, 25], [30, 25], [9, 25], [25.9, 35.9], [26, 30]])})

    tree = []
    for n in range(60):
        kind = rng.choice(['study', 'series', 'image', 'node', 'seriesNode', 'surgical', 'root', 'mock'])
        c = {'listCount': rng.choice([0, 3, 70000])}
        if rng.random() < 0.1:
            c['noDatabase'] = True
        if kind != 'root':
            spec = {'cls': kind, 'id': 'tree%d' % n, 'values': {}}
            if kind in ('node', 'seriesNode'):
                spec['distant'] = True
                k = rng.random()
                if k < 0.3:
                    spec['nodeKids'] = [{'cls': rng.choice(['seriesNode', 'node']), 'id': 'k%d' % i, 'distant': True} for i in range(rng.randint(1, 3))]
                elif k < 0.5:
                    spec['nodeKids'] = [{'cls': 'mock', 'id': 'k%d' % i} for i in range(rng.randint(1, 2))]
                elif k < 0.6:
                    spec['nodeKids'] = []
                if rng.random() < 0.5:
                    spec['queryGives'] = [{'cls': 'seriesNode', 'id': 'q%d' % i, 'distant': True} for i in range(rng.randint(0, 2))]
            else:
                spec['values']['type'] = rng.choice(['Study', 'Series', 'Image', 'Other', None]) if kind == 'mock' else {'study': 'Study', 'series': 'Series', 'image': 'Image', 'surgical': None}[kind]
                if spec['values']['type'] is None:
                    del spec['values']['type']
                spec['values']['noFiles'] = rng.choice([0, 4, '9', 3000000000])
                spec['imageSeriesCount'] = rng.choice([0, 2])
            c['row'] = spec
        tree.append(c)

    titles = ['Patient name', 'Date', 'Modality', 'Comment', '', 'date', 'Ã‰tat', 'Date', 'Accession']
    ids = ['name', 'date', 'modality', 'comment', 'empty', 'date2', 'state', 'dup', 'accessionNumber']
    columns = []
    for n in range(30):
        chosen = rng.sample(range(len(ids)), rng.randint(2, len(ids)))
        cols = [{'id': ids[i], 'title': titles[i], 'hidden': rng.random() < 0.3} for i in chosen]
        visible = [ids[i] for i in chosen if rng.random() < 0.6]
        saved = {}
        for i in chosen:
            if rng.random() < 0.6:
                saved[titles[i]] = rng.choice([0, 1, 1, 2, -1, '1', '0', 256])
        if rng.random() < 0.3:
            saved['Missing title'] = 1
        c = {'columns': cols, 'visible': visible, 'selectedColumn': rng.randint(-1, len(cols)), 'defaults': {}}
        if rng.random() < 0.8:
            c['defaults']['COLUMNSDATABASE'] = saved
        if rng.random() < 0.5:
            c['defaults']['HIDEPATIENTNAME'] = rng.random() < 0.5
        if rng.random() < 0.7:
            c['action'] = rng.randrange(len(cols))
            if rng.random() < 0.3:
                c['actionState'] = rng.choice([-1, 0, 1])
        columns.append(c)

    def study(ident, uid, patient='abc', date=None, cls='study'):
        values = {'type': 'Study', 'studyInstanceUID': uid, 'patientUID': patient, 'name': 'Name ' + ident}
        if uid is None:
            del values['studyInstanceUID']
        if patient is None:
            del values['patientUID']
        if date is not None:
            values['date'] = dt(date)
        return {'cls': cls, 'id': ident, 'values': values, 'distant': cls == 'node'}

    new_studies = []
    for n in range(40):
        history = [study('H%d' % i, rng.choice(['1.1', '1.2', '1.3', None]), date=rng.choice([100, 200, 300, None]), cls=rng.choice(['study', 'node']))
                   for i in range(rng.randint(0, 4))]
        newcomers = [study('N%d' % i, rng.choice(['1.1', '1.2', '1.9', None]), patient=rng.choice(['abc', 'ABC', 'Ã¡bc', 'zzz', None]),
                     date=rng.choice([150, 250, None])) for i in range(rng.randint(0, 3))]
        new_studies.append({'shown': rng.choice(['abc', 'ABC', None]), 'history': history, 'newStudies': newcomers,
                            'selectedRow': rng.randrange(len(history)) if history and rng.random() < 0.7 else -1})

    refresh_history = []
    for n in range(30):
        rows = [study('O%d' % i, rng.choice(['1.1', '1.2', None])) for i in range(3)]
        rows.append({'cls': 'series', 'id': 'OS', 'values': {'type': 'Series', 'study': None}})
        rows[-1]['values'].pop('study')
        newcomers = [study('C%d' % i, rng.choice(['1.1', '1.2', '1.5']), cls=rng.choice(['study', 'node'])) for i in range(rng.randint(0, 3))]
        in_context = [study(s['id'], s['values'].get('studyInstanceUID')) for s in newcomers if s['cls'] == 'study' and rng.random() < 0.7]
        for s in in_context:
            s['id'] = s['id']
        c = {'rows': rows, 'newStudies': newcomers, 'inContext': in_context, 'shown': 'abc', 'viewers': rng.random() < 0.5}
        if rng.random() < 0.85:
            c['selected'] = rng.randrange(len(rows))
        refresh_history.append(c)

    refresh_needed = []
    for n in range(30):
        rows = [study('Q%d' % i, '1.%d' % i, cls=rng.choice(['study', 'node'])) for i in range(2)]
        albums = [{'cls': 'album', 'id': 'A%d' % i, 'values': {'name': 'Album %d' % i, 'smartAlbum': rng.choice([True, False, 'YES', 0])}} for i in range(3)]
        c = {'rows': rows, 'albums': albums, 'albumRow': rng.choice([-1, 0, 1, 2, 5]), 'timer': rng.random() < 0.7,
             'lastAgo': rng.choice([10, 170, 190, 1000]), 'lastSmartAgo': rng.choice([10, 1000]),
             'defaults': {'searchForSmartAlbumStudiesOnDICOMNodes': rng.random() < 0.6}}
        if rng.random() < 0.8:
            c['selected'] = rng.randrange(len(rows))
        refresh_needed.append(c)

    history = []
    for n in range(40):
        item = study('S%d' % n, rng.choice(['1.1', '1.2', None]), patient=rng.choice(['abc', 'ABC', 'Ã¡bc', None, 'x']), cls=rng.choice(['study', 'study', 'node']))
        if rng.random() < 0.3:
            item = {'cls': 'series', 'id': 'SS%d' % n, 'values': {'type': 'Series'}, 'seriesRow': None}
            item.pop('seriesRow')
            item['values']['study'] = None
            item['values'].pop('study')
        c = {'item': item, 'shown': rng.choice(['abc', None, 'x']),
             'history': [study('HH%d' % i, rng.choice(['1.1', '1.2', None])) for i in range(rng.randint(0, 3))]}
        if rng.random() < 0.2:
            c['noHistory'] = True
        p = rng.random()
        if p < 0.3:
            c['previous'] = 'same'
        elif p < 0.7:
            c['previous'] = study('P%d' % n, '1.1')
        history.append(c)

    refresh = []
    for n in range(30):
        item = {'cls': rng.choice(['study', 'series', 'node']), 'id': 'F%d' % (n % 5), 'values': {'noFiles': rng.choice([0, 3, '3', None])}}
        if item['values']['noFiles'] is None:
            del item['values']['noFiles']
        c = {'item': item, 'previousFiles': rng.choice([0, 3])}
        p = rng.random()
        if p < 0.3:
            c['previous'] = 'same'
        elif p < 0.6:
            c['previous'] = {'cls': rng.choice(['study', 'node']), 'id': item['id'] if rng.random() < 0.6 else 'other', 'values': {}}
        refresh.append(c)

    frames = []
    for n in range(20):
        images = [{'cls': 'image', 'id': 'fi%d' % i, 'values': {'numberOfFrames': rng.choice([1, 2, '5', 0])}} for i in range(rng.choice([0, 1, 1, 2]))]
        frames.append({'item': {'cls': 'series', 'id': 'fr%d' % n, 'values': {'type': rng.choice(['Series', 'Study'])}, 'imagesSet': images}})

    thread = []
    for n in range(20):
        files = [{'cls': 'image', 'id': 'ti%d' % i, 'seriesRow': {'cls': 'series', 'id': 'ts%d' % i, 'values': ({'thumbnail': 'data'} if rng.random() < 0.5 else {})}}
                 for i in range(rng.randint(0, 8))]
        thread.append({'files': files, 'imageLevel': rng.random() < 0.3})
    for missing in range(3, 8):
        for level in [False, True]:
            files = [{'cls': 'image', 'id': 'tm%d' % i, 'seriesRow': {'cls': 'series', 'id': 'tms%d' % i, 'values': ({} if i < missing else {'thumbnail': 'data'})}}
                     for i in range(missing + 2)]
            thread.append({'files': files, 'imageLevel': level})

    destination = []
    for n in range(30):
        series = []
        for i in range(rng.randint(1, 4)):
            images = [{'cls': 'image', 'id': 'di%d' % i, 'values': {'extension': rng.choice(['dcm', 'DCM', 'jpg'])}}]
            if rng.random() < 0.3:
                series.append({'cls': 'study', 'id': 'ds%d' % i, 'values': {'type': 'Study'},
                               'seriesSet': [{'cls': 'series', 'id': 'dss%d' % i, 'values': {'type': 'Series'}, 'imagesSet': images}]})
            else:
                series.append({'cls': 'series', 'id': 'd%d' % i, 'values': {'type': 'Series'}, 'imagesSet': images})
        destination.append({'series': series})

    identity = []
    for n in range(20):
        files = {'/f/%d.dcm' % n: {k: v for k, v in [('OtherPatientNames', rng.choice(['Old^Name', '', None])),
                                                      ('OtherPatientIDs', rng.choice(['OLD1', None]))] if v is not None}}
        st = {'cls': 'testStudy', 'id': 'is%d' % n, 'values': {}, 'paths': ['/f/%d.dcm' % n] if rng.random() < 0.8 else ['/missing.dcm']}
        if rng.random() < 0.8:
            st['values']['name'] = 'Doe^Jane'
        if rng.random() < 0.8:
            st['values']['patientID'] = 'ID%d' % n
        identity.append({'study': st, 'files': files})

    write = []
    for n in range(20):
        files = ['/w/%d/%d.dcm' % (n, i) for i in range(rng.randint(1, 3))]
        write.append({'files': files, 'charsets': {f: rng.choice(['none', 'none', 'ISO_IR 192', 'refused']) for f in files},
                      'edits': [['(0010,0020)', 'NEW'], ['(0010,0010)', 'Name']] + ([['(0010,1001)', '']] if rng.random() < 0.5 else []),
                      'answers': [rng.choice([1, 0])], 'title': 'Unify Patient Identity'})

    unify = []
    for n in range(20):
        dcm = {k: v for k, v in [('PatientsName', rng.choice(['Dest^Name', None])), ('PatientsBirthDate', rng.choice(['19700101', None])),
                                  ('StudyID', rng.choice(['7', None])), ('StudyInstanceUID', rng.choice(['1.2.3', None])),
                                  ('StudyDescription', rng.choice(['CT', None]))] if v is not None}
        dest = {'cls': 'study', 'id': 'ud%d' % n, 'values': {k: v for k, v in [('patientID', rng.choice(['P1', None])), ('name', rng.choice(['A', None]))] if v is not None}}
        st = {'cls': 'study', 'id': 'us%d' % n, 'values': {k: v for k, v in [('patientID', rng.choice(['P1', 'P2', None])), ('name', rng.choice(['A', 'B', None]))] if v is not None}}
        unify.append({'dest': dest, 'study': st, 'dcm': dcm, 'former': [rng.choice(['Old - A', 'A']), rng.choice(['X - P1', 'P1'])]})

    delete = []
    for n in range(24):
        files, images = [], []
        for i in range(rng.randint(0, 5)):
            local = rng.random() < 0.5
            name = rng.choice(['a.dcm', 'b.hdr', 'c.dcm'])
            rel = 'delete%d/dir%d/%s' % (n, i % 2, name)
            if not local:
                files.append(rel)
                if name.endswith('.hdr') and rng.random() < 0.7:
                    files.append(rel[:-4] + '.img')
            images.append({'cls': 'file', 'file': rel, 'values': {'id': 'img%d' % i, 'inDatabaseFolder': local,
                                                                     'series': {'study': {'lockedStudy': rng.random() < 0.25, 'albums': ['al'] * rng.choice([0, 0, 1])}}}})
        if rng.random() < 0.4:
            files.append('delete%d/dir0/.DS_Store' % n)
        if rng.random() < 0.3:
            files.append('delete%d/dir1/keep.txt' % n)
        delete.append({'files': files, 'images': images, 'albumRow': rng.choice([0, 0, 2]),
                       'answers': [rng.choice([1, 0, -1]) for _ in range(4)], 'tree': rng.random() < 0.5})

    thumbnails = []
    for sender in ['none', 'item', 'outlineItem', 'looseItem', 'other']:
        for responder in ['none', 'matrix', 'outline', 'comparative']:
            for item in [False, True]:
                thumbnails.append({'sender': sender, 'responder': responder, 'thumbnailItem': item})

    question = []
    for album_row in [-1, 0, 1, 2]:
        for thumbs in [False, True]:
            for smart in [True, False, 'YES', 0]:
                question.append({'albumRow': album_row, 'thumbnails': thumbs, 'level': rng.choice(['Selected Lines', 'Selected Thumbnails']),
                                 'albums': [{'cls': 'album', 'id': 'q%d' % i, 'values': {'smartAlbum': smart}} for i in range(3)], 'answer': rng.choice([1, 0, -1])})

    return {'databases': databases, 'identifiers': IDENTIFIERS, 'value': value, 'edit': edit, 'display': display, 'tooltip': tooltip,
            'tree': tree, 'columns': columns, 'newStudies': new_studies, 'refreshHistory': refresh_history, 'refreshNeeded': refresh_needed,
            'history': history, 'refresh': refresh, 'frames': frames, 'thread': thread, 'destination': destination, 'identity': identity,
            'write': write, 'unify': unify, 'waited': [{'ago': ago} for ago in [0, 5, 9.5, 10.5, 15, 100, -3]], 'delete': delete, 'thumbnails': thumbnails, 'question': question}


def without_none(value):
    """A key whose value is None is absent: a binary plist would hold NSNull."""
    if isinstance(value, dict):
        return {k: without_none(v) for k, v in value.items() if v is not None}
    if isinstance(value, list):
        return [without_none(v) for v in value if v is not None]
    return value


failures = []
with tempfile.TemporaryDirectory(prefix='horos-outline-') as tmp:
    tmp = Path(tmp)
    (tmp / 'cases.plist').write_bytes(plistlib.dumps(without_none(build_cases(random.Random(20261027))), fmt=plistlib.FMT_BINARY))
    (tmp / 'reference.m').write_text(OBJC)
    built = subprocess.run(['xcrun', 'clang', '-fno-objc-arc', '-fblocks', '-w', '-framework', 'Cocoa',
                            str(tmp / 'reference.m'), '-o', str(tmp / 'reference')], capture_output=True, text=True, timeout=300)
    if built.returncode:
        sys.exit('FAIL: the Objective-C reference does not compile:\n' + built.stderr[-3000:])
    (tmp / 'main.swift').write_text(SWIFT)
    built = subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-o', str(tmp / 'current'), str(RULES), str(tmp / 'main.swift')],
                           capture_output=True, text=True, timeout=300)
    if built.returncode:
        sys.exit('FAIL: the module does not compile:\n' + built.stderr[-3000:])
    (tmp / 'objc-root').mkdir()
    (tmp / 'swift-root').mkdir()
    # Bytes, not text: the messages of the alerts hold carriage returns,
    # which universal newlines would make lines of their own.
    objc = subprocess.run([str(tmp / 'reference'), str(tmp / 'cases.plist'), str(tmp / 'objc-root')], capture_output=True, timeout=60)
    swift = subprocess.run([str(tmp / 'current'), str(tmp / 'cases.plist'), str(tmp / 'swift-root')], capture_output=True, timeout=60)
    if objc.returncode or swift.returncode:
        sys.exit('FAIL: a driver failed:\n' + objc.stderr[-1500:].decode('utf-8', 'replace') + swift.stderr[-1500:].decode('utf-8', 'replace'))
    a, b = objc.stdout.decode('utf-8').split('\n'), swift.stdout.decode('utf-8').split('\n')
    if args.dump:
        args.dump.mkdir(parents=True, exist_ok=True)
        (args.dump / 'reference.txt').write_bytes(objc.stdout)
        (args.dump / 'current.txt').write_bytes(swift.stdout)
    if a != b:
        diff = list(difflib.unified_diff(a, b, 'Objective-C', 'IsiXDatabase', lineterm='', n=1))
        failures.append('records differ:\n' + '\n'.join(diff[:100]))

if failures:
    for failure in failures:
        print('FAIL:', failure)
    sys.exit(1)
kinds = {}
for line in a:
    if not line:
        continue
    key = line.split(' ')[0]
    kinds[key] = kinds.get(key, 0) + 1
print('ok: the study list rows of %s and IsiXDatabase agree on %d records (%s)'
      % (reference, sum(kinds.values()), ', '.join('%s %d' % kv for kv in sorted(kinds.items()))))
