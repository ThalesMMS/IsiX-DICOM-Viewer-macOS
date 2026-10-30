#!/usr/bin/env python3
"""The browser's window, menus, keys, thumbnails' preview and Bonjour decide
what their Objective-C did.

The rest of BrowserController.m outside the class itself (the thumbnails'
preview, the GUI functions, Bonjour) moved to Swift, with their rules in the
IsiXDatabase module (BrowserWindowRules.swift). This compiles the Objective-C
of those methods, cut out of BrowserController.m in the last revision that
has it (history_reference; the tree itself while it still has it), against
stand-ins for the app's classes, and the Swift as it stands in the app's
files (the same functions, cut out of BrowserController+Menus.swift,
+Interface.swift, +Thumbnails.swift, +Bonjour.swift and +Window.swift) with
the module, against stand-ins with the same members. Both read the same
synthetic cases and write records:

* -validateMenuItem: for the browser's commands: enabled, title, check mark,
  and the dearer questions it asks (images with ROIs or key images, the
  thumbnails' menu, the files of the selection, a report on disk);
* the list's and the albums' contextual menus, item by item;
* Lock and Unlock Studies;
* the keys of the list: delete, open, play, type to select a patient;
* the modifier keys, from Carbon's;
* the animation slider for the selected row;
* the frame a 2D viewer lends the preview, refused or copied;
* the list's saved sort, the search menu's series description, the window's
  split views on close, the default database.

    python3 tests/test-browser-window-equivalence.py [--reference REV]
"""
import argparse
import difflib
import json
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
MARK = '- (BOOL) validateMenuItem: (NSMenuItem*) menuItem'
SOURCES = ROOT / 'Horos/Sources'
RULES = ROOT / 'Modules/IsiXDatabase/Sources/BrowserWindowRules.swift'

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
    print('skipped: needs the history that has the Objective-C window functions of BrowserController.m')
    sys.exit(2)
if reference == 'tree':
    text = (ROOT / BC).read_bytes().decode('latin1')
else:
    shown = git('show', '%s:%s' % (reference, BC))
    if shown.returncode:
        sys.exit('FAIL: no %s at %s' % (BC, reference))
    text = shown.stdout.decode('latin1')
if MARK not in text:
    sys.exit('FAIL: %s has no Objective-C -validateMenuItem: in %s' % (reference, BC))
if not RULES.exists():
    sys.exit('FAIL: no BrowserWindowRules.swift in IsiXDatabase')


def matching(source, start):
    """The index after the brace that closes the one at `start`."""
    depth, i = 0, start
    while i < len(source):
        c = source[i]
        if source.startswith('//', i):
            i = source.index('\n', i)
            continue
        if source.startswith('/*', i):
            i = source.index('*/', i) + 2
            continue
        if c == '"':
            j = i + 1
            while source[j] != c:
                j += 2 if source[j] == '\\' else 1
            i = j + 1
            continue
        if c == "'" and source[i + 2:i + 3] == "'":
            i += 3
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


def swift(name):
    return (SOURCES / name).read_text()


def swift_function(source, signature):
    """A function of a Swift file, from its attributes to its closing brace."""
    at = source.index(signature)
    line = source.rindex('\n', 0, at) + 1
    while True:
        previous = source.rindex('\n', 0, line - 1) + 1
        if source[previous:line].strip().startswith('@'):
            line = previous
        else:
            break
    return source[line:matching(source, source.index('{', at))]


def objc_common(code):
    code = code.replace('[NSUserDefaults standardUserDefaults]', 'testDefaults')
    code = code.replace('NSBeep()', 'Rec(@"beep")')
    return code


# --- the Objective-C ---------------------------------------------------------
validate = objc_common(method(MARK))
validate = validate.replace('[[NSFileManager defaultManager] fileExistsAtPath:report]', 'TestFileExists(report)')
validate = validate.replace('[HorosReportImageInsertion kindOfReportPath:report] != HorosReportImageKindUnsupported', 'TestReportKind(report) != 0')
validate = validate.replace('[[[NSApp mainWindow] windowController] isKindOfClass:[ViewerController class]]', 'TestMainIsViewer()')
menus = objc_common(method('-(void)menuWillOpen:(NSMenu*)menu'))
menus = menus.replace('[[AppController sharedAppController] workspaceMenu]', 'TestWorkspaceMenu()')
menus = menus.replace('[HorosContextMenuPruning hideUnavailableItemsIn: menu groups: groups defaultTarget: self]', 'TestPrune(menu, groups)')
key_down = objc_common(method('- (void)keyDown:(NSEvent *)event'))
key_down = key_down.replace('[HorosOutlineSelectionRestore selectItem: [result objectAtIndex: 0] inOutline: databaseOutline extending: NO]',
                            'TestSelect([result objectAtIndex: 0])')
key_down = key_down.replace('NSLog(@"%@", pressedKeys);', '')
lock = method('- (IBAction) lockStudies: (id) sender')
unlock = method('- (IBAction) unlockStudies: (id) sender')
slider = method('- (void) initAnimationSlider')
reuse = method('- (DCMPix*) getDCMPixFromViewerIfAvailable: (NSString*) pathToFind frameNumber: (int) frameNumber expectedFrame: (HorosPreviewFrame*) expectedFrame')
reuse = re.sub(r'NSLog\( @"Preview: not reusing a loaded frame: %@", (.*?)\);\n', r'Rec(@"refused %@", \1);\n', reuse)
reset = objc_common(method('- (void)resetToDefaultDatabaseIfNecessary\n{'))
modifiers = method('+ (unsigned int)_currentModifierFlags').replace('GetCurrentKeyModifiers()', 'testCarbonModifiers')
awake = method('-(void) awakeFromNib')
sort_block = objc_common(between('            if( [[NSUserDefaults standardUserDefaults] objectForKey: @"databaseSortDescriptor"])',
                                 '            [self loadSortDescriptors:nil];', awake))
search_block = between('        NSMenu *searchMenu = [[[searchField cell] searchMenuTemplate] copy];', '        [self setSearchType:', awake)
close = method('- (void) browserPrepareForClose')
close_block = objc_common(between('    {\n        NSView* left = [[splitDrawer subviews] objectAtIndex:0];', '    [[NSUserDefaults standardUserDefaults] setObject:[databaseOutline columnState]', close))
for name, code in (('validate', validate), ('menus', menus), ('keys', key_down), ('reuse', reuse), ('reset', reset)):
    if 'NSUserDefaults' in code or 'NSFileManager' in code or 'NSApp ' in code:
        sys.exit('FAIL: the Objective-C %s changed: cannot stand in for what it reads' % name)

OBJC = r'''
#import <Cocoa/Cocoa.h>
#undef NSLocalizedString
#define NSLocalizedString(key, comment) (key)
#define N2LogExceptionWithStackTrace(e) Rec(@"exception %@", [(e) name])
#define cmdKey 0x0100
#define shiftKey 0x0200
#define optionKey 0x0800
#define controlKey 0x1000

static NSMutableArray *records;
static NSDictionary *testCase;
static UInt32 testCarbonModifiers;
static void Rec(NSString *format, ...) {
    va_list list; va_start(list, format);
    [records addObject: [[[NSString alloc] initWithFormat: format arguments: list] autorelease]];
    va_end(list);
}
static id Plain(id value) { return value == nil || value == [NSNull null] ? nil : value; }
static id CaseValue(NSString *key) { return Plain([testCase objectForKey: key]); }
static NSString *Text(id value) {
    if (value == nil) return @"nil";
    if ([value isKindOfClass: [NSDictionary class]]) {
        NSMutableArray *pairs = [NSMutableArray array];
        for (id key in [[value allKeys] sortedArrayUsingSelector: @selector(compare:)]) [pairs addObject: [NSString stringWithFormat: @"%@=%@", key, Text([value objectForKey: key])]];
        return [NSString stringWithFormat: @"{%@}", [pairs componentsJoinedByString: @","]];
    }
    return [value description];
}

@interface TestDefaults : NSObject { @public NSMutableDictionary *values; }
@end
@implementation TestDefaults
- (id)objectForKey:(NSString*)key { return Plain([values objectForKey: key]); }
- (NSString*)stringForKey:(NSString*)key { id v = [self objectForKey: key]; return [v isKindOfClass: [NSNumber class]] ? [v stringValue] : v; }
- (NSArray*)arrayForKey:(NSString*)key { id v = [self objectForKey: key]; return [v isKindOfClass: [NSArray class]] ? v : nil; }
- (BOOL)boolForKey:(NSString*)key { return [[self objectForKey: key] boolValue]; }
- (NSInteger)integerForKey:(NSString*)key { return [[self objectForKey: key] integerValue]; }
- (void)setBool:(BOOL)value forKey:(NSString*)key { Rec(@"set %@ %d", key, value); }
- (void)setObject:(id)value forKey:(NSString*)key { Rec(@"set %@ %@", key, Text(value)); }
@end
static TestDefaults *testDefaults;

static BOOL TestFileExists(NSString *path) { Rec(@"exists %@", path); return [(CaseValue(@"reportExists") ?: @NO) boolValue]; }
static int TestReportKind(NSString *path) { Rec(@"kind %@", path); return [(CaseValue(@"reportKind") ?: @0) intValue]; }
static BOOL TestMainIsViewer(void) { return [(CaseValue(@"mainIsViewer") ?: @NO) boolValue]; }
static NSMenu *TestWorkspaceMenu(void) {
    if (![(CaseValue(@"workspace") ?: @NO) boolValue]) return nil;
    NSMenu *menu = [[[NSMenu alloc] initWithTitle: @"workspace"] autorelease];
    [menu addItemWithTitle: @"State 1" action: @selector(loadState:) keyEquivalent: @""];
    return menu;
}
static void TestPrune(NSMenu *menu, NSArray *groups) { Rec(@"prune %d groups", (int) groups.count); }
static void TestSelect(id item) { Rec(@"select %@", [item valueForKey: @"name"]); }

@interface Row : NSObject { @public NSDictionary *values; }
@end
NSArray *Rows(NSArray *list);
@implementation Row
- (id)valueForKey:(NSString*)key {
    id v = Plain([values objectForKey: key]);
    if ([key isEqualToString: @"study"] && [v isKindOfClass: [NSDictionary class]]) { Row *r = [[[Row alloc] init] autorelease]; r->values = [v retain]; return r; }
    if ([key isEqualToString: @"images"] && [v isKindOfClass: [NSArray class]]) return [NSSet setWithArray: Rows(v)];
    return v;
}
- (void)setValue:(id)value forKey:(NSString*)key { Rec(@"write %@ %@ %@", Plain([values objectForKey: @"name"]), key, Text(value)); }
- (BOOL)isDistant { return [(Plain([values objectForKey: @"distant"]) ?: @NO) boolValue]; }
@end

NSArray *Rows(NSArray *list) {
    NSMutableArray *rows = [NSMutableArray array];
    for (NSDictionary *d in list) { Row *r = [[[Row alloc] init] autorelease]; r->values = [d retain]; [rows addObject: r]; }
    return rows;
}

@interface TestOutline : NSObject { @public NSArray *rows; NSIndexSet *selection; NSMenu *menu; NSArray *sortDescriptors; NSArray *visible; NSInteger selected; }
@end
@implementation TestOutline
- (NSIndexSet*)selectedRowIndexes { return selection; }
- (id)itemAtRow:(NSInteger)row { return row >= 0 && row < (NSInteger) rows.count ? [rows objectAtIndex: row] : nil; }
- (NSMenu*)menu { return menu; }
- (NSInteger)selectedRow { return selected; }
- (void)scrollRowToVisible:(NSInteger)row { Rec(@"scroll %d", (int) row); }
- (BOOL)isColumnWithIdentifierVisible:(id)identifier { return [visible containsObject: identifier ?: @"(none)"]; }
- (NSTableColumn*)tableColumnWithIdentifier:(NSString*)identifier {
    NSTableColumn *column = [[[NSTableColumn alloc] initWithIdentifier: identifier ?: @""] autorelease];
    if ([identifier isEqualToString: @"name"] || [identifier isEqualToString: @"date"])
        [column setSortDescriptorPrototype: [NSSortDescriptor sortDescriptorWithKey: identifier ascending: YES selector: [identifier isEqualToString: @"name"] ? @selector(caseInsensitiveCompare:) : @selector(compare:)]];
    return column;
}
- (void)setSortDescriptors:(NSArray*)list { for (NSSortDescriptor *d in list) Rec(@"sort %@ %d %@", d.key, d.ascending, NSStringFromSelector(d.selector)); }
- (NSArray*)sortDescriptors { return sortDescriptors; }
@end

@interface TestMatrix : NSObject { @public NSArray *cells; NSInteger selected; NSUInteger selectedCount; }
@end
@implementation TestMatrix
- (NSArray*)selectedCells { NSMutableArray *a = [NSMutableArray array]; for (NSUInteger i = 0; i < selectedCount; i++) [a addObject: @(i)]; return a; }
- (id)selectedCell { return selected >= 0 && selected < (NSInteger) cells.count ? [cells objectAtIndex: selected] : nil; }
- (BOOL)selectCellWithTag:(NSInteger)tag { Rec(@"select cell %d", (int) tag); selected = -1; for (NSUInteger i = 0; i < cells.count; i++) if ([[cells objectAtIndex: i] tag] == tag) selected = i; return YES; }
@end

@interface TestDatabase : NSObject { @public BOOL local, readOnly; NSString *base; }
@end
@implementation TestDatabase
- (BOOL)isLocal { return local; }
- (BOOL)isReadOnly { return readOnly; }
- (NSString*)baseDirPath { return base; }
@end

@interface DicomDatabase : NSObject
@end
@implementation DicomDatabase
+ (NSString*)baseDirPathForMode:(int)mode path:(NSString*)path { Rec(@"base %d %@", mode, Text(path)); return Plain(CaseValue(@"defaultPath")); }
@end

@interface TestWindow : NSObject { @public id firstResponder; }
@end
@implementation TestWindow
- (id)firstResponder { return firstResponder; }
@end

@interface NSMutableArray (Duplicated)
- (void)removeDuplicatedStringsInSyncWithThisArray:(NSMutableArray*)other;
@end
@implementation NSMutableArray (Duplicated)
- (void)removeDuplicatedStringsInSyncWithThisArray:(NSMutableArray*)other { Rec(@"dedupe %d", (int) other.count); }
@end

@interface HorosFileRevision : NSObject { @public NSString *path; }
@end
@implementation HorosFileRevision
- (id)initWithPath:(NSString*)p { self = [super init]; path = [p retain]; return self; }
+ (NSString*)refusalForReusingFileWithLoaded:(id)loaded current:(HorosFileRevision*)current { return [NSString stringWithFormat: @"changed %@ %@", loaded, current->path]; }
@end

@interface HorosPreviewFrame : NSObject { @public NSString *description_; }
@end
@implementation HorosPreviewFrame
- (id)initWithPath:(NSString*)path sopInstanceUID:(NSString*)sop seriesInstanceUID:(NSString*)series sopClassUID:(NSString*)cls modality:(NSString*)modality
       frameNumber:(NSInteger)frame frameCount:(NSInteger)count rows:(NSInteger)rows columns:(NSInteger)columns seriesID:(NSInteger)seriesID {
    self = [super init];
    description_ = [[NSString stringWithFormat: @"%@|%@|%@|%@|%@|%d|%d|%d|%d|%d", path, sop, series, cls, modality, (int) frame, (int) count, (int) rows, (int) columns, (int) seriesID] retain];
    return self;
}
@end

@interface HorosPreviewIdentity : NSObject
@end
@implementation HorosPreviewIdentity
+ (NSString*)refusalForReusing:(HorosPreviewFrame*)loaded asRequested:(HorosPreviewFrame*)requested {
    Rec(@"identity %@ / %@", loaded->description_, requested->description_);
    return [loaded->description_ isEqualToString: requested->description_] ? nil : @"another frame";
}
@end

@interface DCMPix : NSObject <NSCopying> { @public NSDictionary *values; float *fImage; BOOL ownsImage; NSString *name; }
@property(readonly) NSRecursiveLock *checking;
@property long pwidth, pheight;
@end
@implementation DCMPix
@synthesize pwidth, pheight;
- (NSRecursiveLock*)checking { return nil; }
- (void)CheckLoad { Rec(@"load %@", name); }
- (BOOL)isLoaded { return [[values objectForKey: @"loaded"] boolValue]; }
- (BOOL)loadedFileMatchesDisk { return [[values objectForKey: @"matches"] boolValue]; }
- (id)loadedFileRevision { return @"rev"; }
- (float*)fImage { return fImage; }
- (void)setfImage:(float*)image { fImage = image; Rec(@"pixels %@ %g %g", name, image[0], image[pheight * pwidth - 1]); }
- (void)freefImageWhenDone:(BOOL)b { Rec(@"owns %@ %d", name, b); }
- (id)copyWithZone:(NSZone*)zone { DCMPix *c = [[DCMPix alloc] init]; c->values = [values retain]; c->name = [[name stringByAppendingString: @" copy"] retain]; c.pwidth = pwidth; c.pheight = pheight; return c; }
@end

@interface ViewerController : NSObject { @public NSArray *files; NSArray *pixes; BOOL closing; }
@end
static NSMutableArray *testViewers;
@implementation ViewerController
+ (NSArray*)get2DViewers { return testViewers; }
- (BOOL)windowWillClose { return closing; }
- (NSArray*)fileList { return files; }
- (NSArray*)pixList { return pixes; }
- (NSData*)volumeData { return nil; }
@end

@interface DicomStudy : Row
@end
@implementation DicomStudy
@end

@interface DicomImage : Row
@end
@implementation DicomImage
- (NSString*)completePath { return [self valueForKey: @"completePath"]; }
- (NSString*)sopInstanceUID { return [self valueForKey: @"sopInstanceUID"]; }
- (NSNumber*)frameID { return [self valueForKey: @"frameID"]; }
- (NSNumber*)numberOfFrames { return [self valueForKey: @"numberOfFrames"]; }
- (NSNumber*)height { return [self valueForKey: @"height"]; }
- (NSNumber*)width { return [self valueForKey: @"width"]; }
- (id)valueForKeyPath:(NSString*)path { return [path hasPrefix: @"series."] ? Plain([[values objectForKey: @"series"] objectForKey: [path substringFromIndex: 7]]) : [super valueForKeyPath: path]; }
@end

@interface TestResponder : NSResponder
@end
@implementation TestResponder
- (void)keyDown:(NSEvent*)event { Rec(@"super keyDown %@", event.characters); }
@end

static BOOL withReset = NO;

@interface BrowserController : TestResponder {
@public
    TestOutline *databaseOutline; TestDatabase *_database; NSMenu *imageTileMenu; TestMatrix *oMatrix; id comparativeTable;
    id albumTable; NSMenu *columnsMenu; NSButton *animationCheck; NSSlider *animationSlider; NSArray *matrixViewArray;
    NSMutableString *pressedKeys; NSArray *outlineViewArray; id _sourcesTableView, _activityTableView; TestWindow *window;
    NSSearchField *searchField; NSSplitView *splitDrawer, *splitComparative;
}
@property(readonly) TestDatabase *database;
@end

static BOOL gHorizontalHistory = NO;

@implementation BrowserController
- (TestDatabase*)database { return _database; }
- (TestWindow*)window { return window; }
- (NSArray*)ROIImages:(id)sender { Rec(@"roi images"); return [@[@1, @2, @3] subarrayWithRange: NSMakeRange(0, [(CaseValue(@"roi") ?: @0) intValue])]; }
- (NSArray*)ROIsAndKeyImages:(id)sender { Rec(@"rois and keys"); return [@[@1, @2, @3] subarrayWithRange: NSMakeRange(0, [(CaseValue(@"roisKeys") ?: @0) intValue])]; }
- (NSArray*)KeyImages:(id)sender { Rec(@"key images"); return [@[@1, @2, @3] subarrayWithRange: NSMakeRange(0, [(CaseValue(@"keys") ?: @0) intValue])]; }
- (BOOL)isThumbnailMenuItem:(id)sender { Rec(@"thumbnail item"); return [(CaseValue(@"thumbItem") ?: @NO) boolValue]; }
- (NSMutableArray*)filesForDatabaseMatrixSelection:(NSMutableArray*)objects onlyImages:(BOOL)only {
    Rec(@"files matrix %d", only); [objects addObjectsFromArray: Rows(CaseValue(@"linked") ?: @[])]; return [NSMutableArray arrayWithObject: @"/f"]; }
- (NSMutableArray*)filesForDatabaseOutlineSelection:(NSMutableArray*)objects onlyImages:(BOOL)only {
    Rec(@"files outline %d", only); [objects addObjectsFromArray: Rows(CaseValue(@"linked") ?: @[])]; return [NSMutableArray arrayWithObject: @"/f"]; }
- (void)refreshDatabase:(id)sender { Rec(@"refresh database"); }
- (void)columnsMenuWillOpen { Rec(@"columns menu"); }
- (void)delItem:(id)sender { Rec(@"delete %@", sender == nil ? @"nil" : NSStringFromClass([sender class])); }
- (void)viewerDICOM:(id)sender { Rec(@"open %@", sender == nil ? @"nil" : NSStringFromClass([sender class])); }
- (NSArray*)imagesArray:(id)item { Rec(@"images of %@", Text([item valueForKey: @"name"])); id v = [item valueForKey: @"thumbImages"]; return v ? Rows(v) : nil; }
- (void)previewSliderAction:(id)sender { Rec(@"preview slider reset %d", withReset); }
- (NSString*)outlineViewRefresh { Rec(@"outline refresh"); return nil; }
- (void)refreshMatrix:(id)sender { Rec(@"refresh matrix"); }
- (void)resetToLocalDatabase { Rec(@"reset to local"); }
- (void)albumTableDoublePressed:(id)s {} - (void)addAlbum:(id)s {} - (void)addSmartAlbum:(id)s {} - (void)removeAlbum:(id)s {}
- (void)saveAlbums:(id)s {} - (void)addAlbums:(id)s {} - (void)defaultAlbums:(id)s {} - (void)setSearchType:(id)s {}
- (void)attachExistingReport:(id)s {} - (void)insertSelectedImagesIntoReport:(id)s {}

@@VALIDATE@@
@@MENUS@@
@@KEYDOWN@@
@@LOCK@@
@@UNLOCK@@
@@SLIDER@@
@@REUSE@@
@@RESET@@
@@MODIFIERS@@

- (void)sortCase { @@SORT@@ }
- (void)searchMenuCase { @@SEARCH@@ }
- (void)closeCase { @@CLOSE@@ }
@end
''' + r'''
#include "driver.h"
'''

parts = {'VALIDATE': validate, 'MENUS': menus, 'KEYDOWN': key_down, 'LOCK': lock, 'UNLOCK': unlock, 'SLIDER': slider,
         'REUSE': reuse, 'RESET': reset, 'MODIFIERS': modifiers, 'SORT': sort_block, 'SEARCH': search_block, 'CLOSE': close_block}
OBJC = re.sub(r'@@(\w+)@@', lambda m: parts[m.group(1)], OBJC)

# The Objective-C driver: the cases, the stand-ins they build, the records.
DRIVER = r'''
@interface TestTable : NSObject { @public NSMenu *menu; NSInteger clickedRow; }
@end
@implementation TestTable
- (NSMenu*)menu { return menu; }
- (NSInteger)clickedRow { return clickedRow; }
@end

static void Tree(NSMenu *menu, NSString *indent, id owner) {
    for (NSMenuItem *item in menu.itemArray) {
        if (item.isSeparatorItem) { Rec(@"%@---", indent); continue; }
        Rec(@"%@%@ | %@ | %@ | %d | %@", indent, item.title, item.action ? NSStringFromSelector(item.action) : @"-",
            item.target == nil ? @"nil" : item.target == owner ? @"self" : @"other", item.isEnabled, Text(item.representedObject));
        if (item.submenu) Tree(item.submenu, [indent stringByAppendingString: @"  "], owner);
    }
}

static NSIndexSet *Indexes(NSArray *list) {
    NSMutableIndexSet *set = [NSMutableIndexSet indexSet];
    for (NSNumber *n in list) [set addIndex: n.unsignedIntegerValue];
    return set;
}

static TestDatabase *Database(id d) {
    if (Plain(d) == nil) return nil;
    TestDatabase *db = [[[TestDatabase alloc] init] autorelease];
    db->local = [[d objectForKey: @"local"] boolValue]; db->readOnly = [[d objectForKey: @"readOnly"] boolValue]; db->base = [Plain([d objectForKey: @"base"]) retain];
    return db;
}

static BrowserController *Browser(NSDictionary *c) {
    BrowserController *b = [[[BrowserController alloc] init] autorelease];
    testCase = c;
    testDefaults->values = [[NSMutableDictionary dictionaryWithDictionary: [c objectForKey: @"defaults"] ?: @{}] retain];
    b->databaseOutline = [[TestOutline alloc] init];
    b->databaseOutline->rows = [Rows([c objectForKey: @"rows"] ?: @[]) retain];
    b->databaseOutline->selection = [Indexes([c objectForKey: @"selected"] ?: @[]) retain];
    b->databaseOutline->selected = [([c objectForKey: @"selectedRow"] ?: @-1) integerValue];
    b->databaseOutline->visible = [([c objectForKey: @"visible"] ?: @[]) retain];
    b->_database = [Database([c objectForKey: @"db"]) retain];
    b->oMatrix = [[TestMatrix alloc] init];
    b->oMatrix->selectedCount = [([c objectForKey: @"matrixCount"] ?: @0) unsignedIntegerValue];
    b->comparativeTable = [[NSObject alloc] init];
    b->window = [[TestWindow alloc] init];
    TestTable *albums = [[TestTable alloc] init]; albums->clickedRow = [([c objectForKey: @"clickedRow"] ?: @0) integerValue];
    b->albumTable = albums;
    b->_sourcesTableView = [[NSObject alloc] init];
    b->_activityTableView = [[NSObject alloc] init];
    b->animationCheck = [[NSButton alloc] init];
    b->animationCheck.state = [([c objectForKey: @"check"] ?: @0) integerValue];
    b->pressedKeys = [[NSMutableString alloc] init];
    b->outlineViewArray = [Rows([c objectForKey: @"list"] ?: @[]) retain];
    NSString *responder = [c objectForKey: @"responder"] ?: @"none";
    if ([responder isEqual: @"matrix"]) b->window->firstResponder = b->oMatrix;
    else if ([responder isEqual: @"list"]) b->window->firstResponder = b->databaseOutline;
    else if ([responder isEqual: @"history"]) b->window->firstResponder = b->comparativeTable;
    else if ([responder isEqual: @"album"]) b->window->firstResponder = b->albumTable;
    else if ([responder isEqual: @"sources"]) b->window->firstResponder = b->_sourcesTableView;
    else if ([responder isEqual: @"activity"]) b->window->firstResponder = b->_activityTableView;
    else if ([responder isEqual: @"other"]) b->window->firstResponder = [[NSObject alloc] init];
    return b;
}

static void Flush(NSString *label) {
    for (NSString *r in records) printf("%s %s\n", label.UTF8String, r.UTF8String);
    [records removeAllObjects];
}

int main(int argc, const char **argv) { @autoreleasepool {
    [NSApplication sharedApplication];
    records = [NSMutableArray array];
    testDefaults = [[TestDefaults alloc] init];
    NSDictionary *cases = [NSJSONSerialization JSONObjectWithData: [NSData dataWithContentsOfFile: @(argv[1])] options: 0 error: nil];
    int i = 0;

    for (NSDictionary *c in cases[@"validate"]) {
        BrowserController *b = Browser(c);
        if ([c[@"tileMenu"] boolValue]) b->imageTileMenu = [[NSMenu alloc] initWithTitle: @"tile"];
        if ([c[@"listMenu"] boolValue]) b->databaseOutline->menu = [[NSMenu alloc] initWithTitle: @"list"];
        NSMenuItem *item = [[[NSMenuItem alloc] initWithTitle: @"T" action: NSSelectorFromString(c[@"action"]) keyEquivalent: @""] autorelease];
        item.tag = [c[@"tag"] integerValue];
        NSString *menu = c[@"menu"];
        if ([menu isEqual: @"tile"] && b->imageTileMenu) [b->imageTileMenu addItem: item];
        else if ([menu isEqual: @"list"] && b->databaseOutline->menu) [b->databaseOutline->menu addItem: item];
        else if ([menu isEqual: @"other"]) [[[[NSMenu alloc] initWithTitle: @"o"] autorelease] addItem: item];
        BOOL r = [b validateMenuItem: item];
        Rec(@"-> %d %@ %d", r, item.title, (int) item.state);
        Flush([NSString stringWithFormat: @"validate %d", i++]);
    }
    i = 0;
    for (NSDictionary *c in cases[@"menus"]) {
        BrowserController *b = Browser(c);
        NSMenu *menu = [[[NSMenu alloc] initWithTitle: @"m"] autorelease];
        [menu addItemWithTitle: @"stale" action: nil keyEquivalent: @""];
        NSString *kind = c[@"kind"];
        if ([kind isEqual: @"albums"]) ((TestTable*) b->albumTable)->menu = menu;
        else if ([kind isEqual: @"columns"]) b->columnsMenu = menu;
        [b menuWillOpen: menu];
        Tree(menu, @"", b);
        Flush([NSString stringWithFormat: @"menus %d", i++]);
    }
    i = 0;
    for (NSDictionary *c in cases[@"lock"]) {
        BrowserController *b = Browser(c);
        if ([c[@"lock"] boolValue]) [b lockStudies: nil]; else [b unlockStudies: nil];
        Flush([NSString stringWithFormat: @"lock %d", i++]);
    }
    i = 0;
    for (NSDictionary *c in cases[@"keys"]) {
        BrowserController *b = Browser(c);
        for (NSString *k in c[@"keys"]) {
            NSEvent *e = [NSEvent keyEventWithType: NSEventTypeKeyDown location: NSZeroPoint modifierFlags: 0 timestamp: 0 windowNumber: 0 context: nil
                                        characters: k charactersIgnoringModifiers: k isARepeat: NO keyCode: 0];
            [b keyDown: e];
            Rec(@"check %d keys %@", (int) b->animationCheck.state, b->pressedKeys);
        }
        Flush([NSString stringWithFormat: @"keys %d", i++]);
    }
    i = 0;
    for (NSNumber *n in cases[@"modifiers"]) {
        testCarbonModifiers = n.unsignedIntValue;
        Rec(@"%u", [BrowserController _currentModifierFlags]);
        Flush([NSString stringWithFormat: @"modifiers %d", i++]);
    }
    i = 0;
    for (NSDictionary *c in cases[@"slider"]) {
        BrowserController *b = Browser(c);
        NSMutableArray *cells = [NSMutableArray array];
        for (NSNumber *t in c[@"cells"]) { NSButtonCell *cell = [[[NSButtonCell alloc] init] autorelease]; cell.tag = t.integerValue; [cells addObject: cell]; }
        b->oMatrix->cells = [cells retain];
        b->oMatrix->selected = [c[@"selectedCell"] integerValue];
        b->matrixViewArray = [Rows(c[@"thumbnails"] ?: @[]) retain];
        b->animationSlider = [[NSSlider alloc] init];
        b->animationSlider.maxValue = 99; b->animationSlider.numberOfTickMarks = 7; b->animationSlider.intValue = 5;
        b->animationSlider.enabled = [c[@"enabled"] boolValue];
        [b initAnimationSlider];
        Rec(@"slider %d %g %d %d", b->animationSlider.isEnabled, b->animationSlider.maxValue, (int) b->animationSlider.numberOfTickMarks, b->animationSlider.intValue);
        Flush([NSString stringWithFormat: @"slider %d", i++]);
    }
    i = 0;
    for (NSDictionary *c in cases[@"reuse"]) {
        BrowserController *b = Browser(c);
        testViewers = [NSMutableArray array];
        for (NSDictionary *v in c[@"viewers"]) {
            ViewerController *viewer = [[ViewerController alloc] init];
            viewer->closing = [v[@"closing"] boolValue];
            NSMutableArray *files = [NSMutableArray array], *pixes = [NSMutableArray array];
            for (NSDictionary *f in v[@"files"]) { DicomImage *image = [[[DicomImage alloc] init] autorelease]; image->values = [f retain]; [files addObject: image]; }
            int n = 0;
            for (NSDictionary *p in v[@"pixes"]) {
                DCMPix *pix = [[[DCMPix alloc] init] autorelease]; pix->values = [p retain]; pix->name = [[NSString stringWithFormat: @"pix%d", n++] retain];
                pix.pwidth = [p[@"w"] intValue]; pix.pheight = [p[@"h"] intValue];
                pix->fImage = malloc(sizeof(float) * MAX(1, pix.pwidth * pix.pheight));
                for (long k = 0; k < pix.pwidth * pix.pheight; k++) pix->fImage[k] = k + n * 100;
                [pixes addObject: pix];
            }
            viewer->files = [files retain]; viewer->pixes = [pixes retain];
            [testViewers addObject: viewer];
        }
        NSDictionary *e = Plain(c[@"expected"]);
        HorosPreviewFrame *expected = e ? [[[HorosPreviewFrame alloc] initWithPath: e[@"completePath"] sopInstanceUID: e[@"sopInstanceUID"]
            seriesInstanceUID: e[@"series"][@"seriesDICOMUID"] sopClassUID: e[@"series"][@"seriesSOPClassUID"] modality: e[@"series"][@"modality"]
            frameNumber: [e[@"frameID"] intValue] frameCount: [e[@"numberOfFrames"] intValue] rows: [e[@"height"] intValue] columns: [e[@"width"] intValue]
            seriesID: [e[@"series"][@"id"] intValue]] autorelease] : nil;
        DCMPix *pix = [b getDCMPixFromViewerIfAvailable: Plain(c[@"path"]) frameNumber: [c[@"frame"] intValue] expectedFrame: expected];
        Rec(@"-> %@", pix ? pix->name : @"nil");
        Flush([NSString stringWithFormat: @"reuse %d", i++]);
    }
    i = 0;
    for (NSDictionary *c in cases[@"reset"]) {
        BrowserController *b = Browser(c);
        [b resetToDefaultDatabaseIfNecessary];
        Flush([NSString stringWithFormat: @"reset %d", i++]);
    }
    i = 0;
    for (NSDictionary *c in cases[@"sort"]) {
        BrowserController *b = Browser(c);
        [b sortCase];
        Flush([NSString stringWithFormat: @"sort %d", i++]);
    }
    i = 0;
    for (NSDictionary *c in cases[@"search"]) {
        BrowserController *b = Browser(c);
        b->searchField = [[NSSearchField alloc] init];
        NSMenu *template = nil;
        if (Plain(c[@"template"])) {
            template = [[[NSMenu alloc] initWithTitle: @"search"] autorelease];
            for (NSArray *pair in c[@"template"]) { NSMenuItem *item = [template addItemWithTitle: pair[0] action: nil keyEquivalent: @""]; item.tag = [pair[1] integerValue]; }
        }
        [[b->searchField cell] setSearchMenuTemplate: template];
        [b searchMenuCase];
        NSMenu *after = [[b->searchField cell] searchMenuTemplate];
        if (after == nil) Rec(@"no template");
        for (NSMenuItem *item in after.itemArray) Rec(@"%@ %d %@ %@", item.title, (int) item.tag, item.action ? NSStringFromSelector(item.action) : @"-", item.target == b ? @"self" : @"nil");
        Flush([NSString stringWithFormat: @"search %d", i++]);
    }
    i = 0;
    for (NSDictionary *c in cases[@"close"]) {
        BrowserController *b = Browser(c);
        gHorizontalHistory = [c[@"horizontal"] boolValue];
        NSSplitView *(^split)(id) = ^NSSplitView*(id hidden) {
            if (!Plain(hidden)) return (NSSplitView*) nil;
            NSSplitView *s = [[NSSplitView alloc] initWithFrame: NSMakeRect(0, 0, 300, 200)];
            for (NSNumber *h in hidden) { NSView *v = [[[NSView alloc] initWithFrame: NSMakeRect(0, 0, 100, 100)] autorelease]; v.hidden = h.boolValue; [s addSubview: v]; }
            return s;
        };
        b->splitDrawer = split(c[@"drawer"]);
        b->splitComparative = split(c[@"comparative"]);
        NSMutableArray *sorts = [NSMutableArray array];
        for (NSArray *pair in c[@"sorts"] ?: @[]) [sorts addObject: [NSSortDescriptor sortDescriptorWithKey: Plain(pair[0]) ascending: [pair[1] boolValue]]];
        b->databaseOutline->sortDescriptors = [sorts retain];
        @try { [b closeCase]; } @catch (NSException *e) { Rec(@"raised %@", e.name); }
        Flush([NSString stringWithFormat: @"close %d", i++]);
    }
    return 0;
} }
'''

# --- the Swift, as the app has it ---------------------------------------------
menus_swift = swift('BrowserController+Menus.swift')
interface_swift = swift('BrowserController+Interface.swift')
thumbnails_swift = swift('BrowserController+Thumbnails.swift')
bonjour_swift = swift('BrowserController+Bonjour.swift')
window_swift = swift('BrowserController+Window.swift')
outline_swift = swift('BrowserController+OutlineDataSource.swift')


def swift_common(code):
    code = code.replace('UserDefaults.standard', 'testDefaults')
    code = code.replace('NSSound.beep()', 'rec("beep")')
    return code


state = between('/// What the browser\'s menu validation asks, read from the window when asked.', 'extension BrowserController {', menus_swift)
glue = '\n'.join([
    swift_function(menus_swift, 'private func boolValue('),
    swift_function(menus_swift, 'private func rows('),
    state,
    swift_function(outline_swift, 'func isDistantRow('),
    swift_function(thumbnails_swift, 'private func intValue('),
    swift_function(thumbnails_swift, 'private func previewFrame('),
])
members = '\n'.join([
    swift_function(menus_swift, 'func menuWillOpen('),
    swift_function(menus_swift, 'func validateMenuItem('),
    swift_function(menus_swift, 'func unlockStudies('),
    swift_function(menus_swift, 'func lockStudies('),
    swift_function(interface_swift, 'static func _currentModifierFlags('),
    swift_function(interface_swift, 'override func keyDown('),
    swift_function(thumbnails_swift, 'func initAnimationSlider('),
    swift_function(thumbnails_swift, 'private func animate('),
    swift_function(thumbnails_swift, 'private func disableAnimation('),
    swift_function(thumbnails_swift, 'private func resetPreviewToSlider('),
    swift_function(thumbnails_swift, 'nonisolated func getDCMPix(fromViewerIfAvailable pathToFind: String!, frameNumber: Int32, expectedFrame'),
    swift_function(bonjour_swift, 'func resetToDefaultDatabaseIfNecessary('),
    swift_function(window_swift, 'private func isSubviewHidden('),
    '    func sortCase() {\n        let defaults = testDefaults\n        let outline = horos_databaseOutline\n'
    + between('        switch ListSort.restored(', '        loadSortDescriptors(nil)', window_swift) + '    }',
    '    func searchMenuCase() {\n' + between('        let searchCell = horos_searchField?.cell', '        setSearchType(searchCell', window_swift) + '    }',
    '    func closeCase() {\n        let defaults = testDefaults\n'
    + between('        defaults.set(isSubviewHidden(horos_splitDrawer', '        defaults.set(outline?.columnState()', window_swift) + '    }',
])
members = swift_common(members)
members = members.replace('NSApp.mainWindow?.windowController is ViewerController', 'testMainIsViewer()')
members = members.replace('FileManager.default.fileExists(atPath: report)', 'testFileExists(report)')
members = members.replace('ReportImageInsertion.kind(ofReportPath: report) != .unsupported', 'testReportKind(report) != 0')
members = members.replace('AppController.shared()?.workspaceMenu()', 'testWorkspaceMenu()')
members = members.replace('ContextMenuPruning.hideUnavailableItems(in: menu, groups: groups as? [NSMenu] ?? [], defaultTarget: self)', 'testPrune(menu, groups)')
members = members.replace('if let outline = horos_databaseOutline { OutlineSelectionRestore.select(first, in: outline, extending: false) }', 'testSelect(first)')
members = re.sub(r'NSLog\("Preview: not reusing a loaded frame: %@", (.*?)\)\n', r'rec("refused " + (\1))\n', members)
members = members.replace('NSLog("%@", pressedKeys)', '')
glue = swift_common(glue)
glue = glue.replace('NSApp.mainWindow?.windowController is ViewerController', 'testMainIsViewer()')
for name, code in (('glue', glue), ('members', members)):
    for forbidden in ('UserDefaults.standard', 'FileManager.default.fileExists', 'NSApp.', 'AppController', 'ContextMenuPruning', 'NSLog('):
        if forbidden in code:
            sys.exit('FAIL: the Swift %s changed: cannot stand in for %s' % (name, forbidden))

SWIFT = r'''
import AppKit
import Foundation

nonisolated(unsafe) var records: [String] = []
nonisolated(unsafe) var testCase: NSDictionary = [:]
nonisolated(unsafe) var testCarbonModifiers: UInt32 = 0
func rec(_ text: String) { records.append(text) }
func plain(_ value: Any?) -> Any? { value is NSNull ? nil : value }
func caseValue(_ key: String) -> Any? { plain(testCase.object(forKey: key)) }
func text(_ value: Any?) -> String {
    guard let value = plain(value) else { return "nil" }
    if let dictionary = value as? NSDictionary {
        let keys = (dictionary.allKeys as NSArray).sortedArray(using: #selector(NSString.compare(_:)))
        return "{" + keys.map { "\($0)=\(text(dictionary.object(forKey: $0)))" }.joined(separator: ",") + "}"
    }
    return (value as AnyObject).description
}
func GetCurrentKeyModifiers() -> UInt32 { testCarbonModifiers }

final class TestDefaults: NSObject {
    var values = NSMutableDictionary()
    func object(forKey key: String) -> Any? { plain(values.object(forKey: key)) }
    func string(forKey key: String) -> String? { let v = object(forKey: key); return (v as? NSNumber)?.stringValue ?? v as? String }
    func array(forKey key: String) -> [Any]? { object(forKey: key) as? [Any] }
    func bool(forKey key: String) -> Bool { (object(forKey: key) as AnyObject?)?.boolValue ?? false }
    func integer(forKey key: String) -> Int { (object(forKey: key) as AnyObject?)?.integerValue ?? 0 }
    func set(_ value: Bool, forKey key: String) { rec("set \(key) \(value ? 1 : 0)") }
    func set(_ value: Any?, forKey key: String) { rec("set \(key) \(text(value))") }
}
nonisolated(unsafe) let testDefaults = TestDefaults()

func testFileExists(_ path: String) -> Bool { rec("exists \(path)"); return (caseValue("reportExists") as? Bool) ?? false }
func testReportKind(_ path: String) -> Int { rec("kind \(path)"); return (caseValue("reportKind") as? Int) ?? 0 }
func testMainIsViewer() -> Bool { (caseValue("mainIsViewer") as? Bool) ?? false }
@MainActor func testWorkspaceMenu() -> NSMenu? {
    guard (caseValue("workspace") as? Bool) ?? false else { return nil }
    let menu = NSMenu(title: "workspace")
    menu.addItem(withTitle: "State 1", action: NSSelectorFromString("loadState:"), keyEquivalent: "")
    return menu
}
func testPrune(_ menu: NSMenu, _ groups: NSMutableArray) { rec("prune \(groups.count) groups") }
func testSelect(_ item: Any) { rec("select \(objcText((item as AnyObject).value(forKey: "name")))") }

enum BrowserObjC {
    static func attempt(_ body: () -> Void) -> NSException? { body(); return nil }
    static func log(_ exception: NSException, stack: Bool = false, _ function: String) { rec("exception \(exception.name.rawValue)") }
    static func synchronized<T>(_ object: AnyObject?, _ body: () -> T) -> T { body() }
}

class Row: NSObject {
    var values: NSDictionary = [:]
    convenience init(_ values: NSDictionary) { self.init(); self.values = values }
    override func value(forKey key: String) -> Any? {
        let v = plain(values.object(forKey: key))
        if key == "study", let d = v as? NSDictionary { return Row(d) }
        if key == "images", let list = v as? [NSDictionary] { return NSSet(array: rows(list)) }
        return v
    }
    override func setValue(_ value: Any?, forKey key: String) { rec("write \(objcText(values.object(forKey: "name"))) \(key) \(text(value))") }
    @objc func isDistant() -> Bool { (plain(values.object(forKey: "distant")) as? Bool) ?? false }
}
func rows(_ list: [NSDictionary]) -> [Row] { list.map { Row($0) } }

final class DicomImage: Row {
    override func value(forKeyPath keyPath: String) -> Any? {
        if keyPath.hasPrefix("series.") { return plain((values.object(forKey: "series") as? NSDictionary)?.object(forKey: String(keyPath.dropFirst(7)))) }
        return super.value(forKeyPath: keyPath)
    }
}

final class TestOutline: NSObject {
    var rowObjects: [Row] = []
    var selectedRowIndexes = IndexSet()
    var menu: NSMenu?
    var selectedRow = -1
    var visible: [String] = []
    var storedSorts: [NSSortDescriptor] = []
    var sortDescriptors: [NSSortDescriptor] {
        get { storedSorts }
        set { for d in newValue { rec("sort \(d.key ?? "(null)") \(d.ascending ? 1 : 0) \(d.selector.map(NSStringFromSelector) ?? "(null)")") } }
    }
    func item(atRow row: Int) -> Any? { row >= 0 && row < rowObjects.count ? rowObjects[row] : nil }
    func scrollRowToVisible(_ row: Int) { rec("scroll \(row)") }
    func isColumnWithIdentifierVisible(_ identifier: Any?) -> Bool { visible.contains((identifier as? String) ?? "(none)") }
    func tableColumn(withIdentifier identifier: NSUserInterfaceItemIdentifier) -> NSTableColumn? {
        let column = NSTableColumn(identifier: identifier)
        if identifier.rawValue == "name" || identifier.rawValue == "date" {
            column.sortDescriptorPrototype = NSSortDescriptor(key: identifier.rawValue, ascending: true,
                                                              selector: identifier.rawValue == "name" ? #selector(NSString.caseInsensitiveCompare(_:)) : #selector(NSNumber.compare(_:)))
        }
        return column
    }
}

final class TestMatrix: NSObject {
    var cells: [NSButtonCell] = []
    var selected = -1
    var count = 0
    var selectedCells: [Any] { Array(repeating: 0, count: count) }
    // A method, as NSControl's is in Swift.
    func selectedCell() -> NSCell? { selected >= 0 && selected < cells.count ? cells[selected] : nil }
    @discardableResult func selectCell(withTag tag: Int) -> Bool {
        rec("select cell \(tag)"); selected = cells.firstIndex { $0.tag == tag } ?? -1; return true
    }
}

final class TestDatabase: NSObject {
    var local = false, readOnly = false
    var baseDirPath: String?
    func isLocal() -> Bool { local }
    var isReadOnly: Bool { readOnly }
}

enum DicomDatabase {
    static func baseDirPath(forMode mode: Int32, path: String?) -> String? {
        rec("base \(mode) \(path ?? "nil")"); return caseValue("defaultPath") as? String
    }
}

final class TestWindow: NSObject { var firstResponder: AnyObject? }
final class TestTable: NSObject { var menu: NSMenu?; var clickedRow = 0 }

extension NSMutableArray {
    func removeDuplicatedStrings(inSyncWithThisArray other: NSMutableArray?) { rec("dedupe \(other?.count ?? 0)") }
}

final class FileRevision {
    let path: String
    init(path: String) { self.path = path }
    static func refusalForReusingFile(loaded: FileRevision?, current: FileRevision?) -> String? { "changed rev \(current?.path ?? "")" }
}

final class PreviewFrame: NSObject {
    let description_: String
    init(path: String, sopInstanceUID: String, seriesInstanceUID: String, sopClassUID: String, modality: String,
         frameNumber: Int, frameCount: Int, rows: Int, columns: Int, seriesID: Int) {
        description_ = "\(path)|\(sopInstanceUID)|\(seriesInstanceUID)|\(sopClassUID)|\(modality)|\(frameNumber)|\(frameCount)|\(rows)|\(columns)|\(seriesID)"
        super.init()
    }
}
enum PreviewIdentity {
    static func refusalForReusing(_ loaded: PreviewFrame, asRequested requested: PreviewFrame) -> String? {
        rec("identity \(loaded.description_) / \(requested.description_)")
        return loaded.description_ == requested.description_ ? nil : "another frame"
    }
}

final class DCMPix: NSObject, NSCopying {
    var values: NSDictionary = [:]
    var name = ""
    var pwidth = 0, pheight = 0
    var storage: UnsafeMutablePointer<Float>?
    var fImage: UnsafeMutablePointer<Float>? {
        get { storage }
        set { storage = newValue; if let image = newValue { rec(String(format: "pixels %@ %g %g", name, Double(image[0]), Double(image[pheight * pwidth - 1]))) } }
    }
    var checking: NSRecursiveLock? { nil }
    func checkLoad() { rec("load \(name)") }
    func isLoaded() -> Bool { (values.object(forKey: "loaded") as? Bool) ?? false }
    func loadedFileMatchesDisk() -> Bool { (values.object(forKey: "matches") as? Bool) ?? false }
    func loadedFileRevision() -> Any? { "rev" }
    func freefImage(whenDone b: Bool) { rec("owns \(name) \(b ? 1 : 0)") }
    func copy(with zone: NSZone? = nil) -> Any {
        let c = DCMPix(); c.values = values; c.name = name + " copy"; c.pwidth = pwidth; c.pheight = pheight; return c
    }
}

nonisolated(unsafe) var testViewers: [ViewerController] = []
final class ViewerController: NSObject {
    var files: [Any] = []
    var pixes: [Any] = []
    var closing = false
    static func get2DViewers() -> [Any]! { testViewers }
    func windowWillClose() -> Bool { closing }
    func fileList() -> [Any]! { files }
    func pixList() -> [Any]! { pixes }
    func volumeData() -> Data? { nil }
}

class TestResponder: NSResponder {
    override func keyDown(with event: NSEvent) { rec("super keyDown \(event.characters ?? "")") }
}

@MainActor final class BrowserController: TestResponder {
    nonisolated(unsafe) static var horos_withReset = false
    nonisolated(unsafe) static var horizontal = false
    static func horizontalHistory() -> Bool { horizontal }

    var horos_databaseOutline: TestOutline?
    var horos_databaseIvar: TestDatabase?
    var database: TestDatabase? { horos_databaseIvar }
    var horos_imageTileMenu: NSMenu?
    var horos_oMatrix: TestMatrix?
    var horos_comparativeTable: AnyObject?
    var horos_albumTable: TestTable?
    var horos_columnsMenu: NSMenu?
    var horos_animationCheck: NSButton?
    var horos_animationSlider: NSSlider?
    var horos_matrixViewArray: [Any]?
    var horos_pressedKeys: NSMutableString?
    var horos_outlineViewList: Any?
    var horos_sourcesTableView: AnyObject?
    var horos_activityTableView: AnyObject?
    var horos_searchField: NSSearchField?
    var horos_splitDrawer: NSSplitView?
    var horos_splitComparative: NSSplitView?
    var window: TestWindow?

    func roiImages(_ sender: Any!) -> [Any]! { rec("roi images"); return Array(repeating: 1, count: (caseValue("roi") as? Int) ?? 0) }
    func roisAndKeyImages(_ sender: Any!) -> [Any]! { rec("rois and keys"); return Array(repeating: 1, count: (caseValue("roisKeys") as? Int) ?? 0) }
    func keyImages(_ sender: Any!) -> [Any]! { rec("key images"); return Array(repeating: 1, count: (caseValue("keys") as? Int) ?? 0) }
    func isThumbnailMenuItem(_ sender: Any?) -> Bool { rec("thumbnail item"); return (caseValue("thumbItem") as? Bool) ?? false }
    func files(forDatabaseMatrixSelection objects: NSMutableArray!, onlyImages: Bool) -> NSMutableArray! {
        rec("files matrix \(onlyImages ? 1 : 0)"); objects.addObjects(from: rows((caseValue("linked") as? [NSDictionary]) ?? [])); return ["/f"]
    }
    func files(forDatabaseOutlineSelection objects: NSMutableArray!, onlyImages: Bool) -> NSMutableArray! {
        rec("files outline \(onlyImages ? 1 : 0)"); objects.addObjects(from: rows((caseValue("linked") as? [NSDictionary]) ?? [])); return ["/f"]
    }
    func refreshDatabase(_ sender: Any!) { rec("refresh database") }
    func columnsMenuWillOpen() { rec("columns menu") }
    func delItem(_ sender: Any!) { rec("delete \(sender.map { String(describing: type(of: $0)) } ?? "nil")") }
    func viewerDICOM(_ sender: Any!) { rec("open \(sender.map { String(describing: type(of: $0)) } ?? "nil")") }
    func imagesArray(_ item: Any!) -> [Any]! {
        rec("images of \(text((item as AnyObject?)?.value(forKey: "name")))")
        return ((item as AnyObject?)?.value(forKey: "thumbImages") as? [NSDictionary]).map(rows)
    }
    func previewSliderAction(_ sender: Any!) { rec("preview slider reset \(BrowserController.horos_withReset ? 1 : 0)") }
    @discardableResult func outlineViewRefresh() -> String! { rec("outline refresh"); return nil }
    func refreshMatrix(_ sender: Any!) { rec("refresh matrix") }
    func resetToLocalDatabase() { rec("reset to local") }
    @objc func albumTableDoublePressed(_ s: Any!) {}
    @objc func addAlbum(_ s: Any!) {}
    @objc func addSmartAlbum(_ s: Any!) {}
    @objc func saveAlbums(_ s: Any!) {}
    @objc func addAlbums(_ s: Any!) {}
    @objc func defaultAlbums(_ s: Any!) {}
    @objc func setSearchType(_ s: Any!) {}
    @objc func attachExistingReport(_ s: Any!) {}
    @objc func insertSelectedImagesIntoReport(_ s: Any!) {}

@@MEMBERS@@
}

@@GLUE@@
''' + r'''
@@DRIVER@@
'''

# The Swift driver: the same cases, stand-ins and records as the Objective-C one.
SWIFT_DRIVER = r'''
func objcText(_ value: Any?) -> String { plain(value).map { "\($0)" } ?? "(null)" }
func list(_ c: NSDictionary, _ key: String) -> [NSDictionary] { (plain(c.object(forKey: key)) as? [NSDictionary]) ?? [] }
func number(_ c: NSDictionary, _ key: String, _ otherwise: Int = 0) -> Int { (plain(c.object(forKey: key)) as? NSNumber)?.intValue ?? otherwise }
func flag(_ value: Any?) -> Bool { (plain(value) as? NSNumber)?.boolValue ?? false }

@MainActor func tree(_ menu: NSMenu, _ indent: String, _ owner: AnyObject) {
    for item in menu.items {
        if item.isSeparatorItem { rec(indent + "---"); continue }
        let target = item.target == nil ? "nil" : item.target === owner ? "self" : "other"
        rec("\(indent)\(item.title) | \(item.action.map(NSStringFromSelector) ?? "-") | \(target) | \(item.isEnabled ? 1 : 0) | \(text(item.representedObject))")
        if let submenu = item.submenu { tree(submenu, indent + "  ", owner) }
    }
}

func indexes(_ value: Any?) -> IndexSet {
    var set = IndexSet()
    for n in (plain(value) as? [NSNumber]) ?? [] { set.insert(n.intValue) }
    return set
}

func database(_ value: Any?) -> TestDatabase? {
    guard let d = plain(value) as? NSDictionary else { return nil }
    let db = TestDatabase()
    db.local = flag(d.object(forKey: "local")); db.readOnly = flag(d.object(forKey: "readOnly")); db.baseDirPath = plain(d.object(forKey: "base")) as? String
    return db
}

@MainActor func browser(_ c: NSDictionary) -> BrowserController {
    let b = BrowserController()
    testCase = c
    testDefaults.values = NSMutableDictionary(dictionary: (plain(c.object(forKey: "defaults")) as? NSDictionary) ?? [:])
    let outline = TestOutline()
    outline.rowObjects = rows(list(c, "rows"))
    outline.selectedRowIndexes = indexes(c.object(forKey: "selected"))
    outline.selectedRow = number(c, "selectedRow", -1)
    outline.visible = (plain(c.object(forKey: "visible")) as? [String]) ?? []
    b.horos_databaseOutline = outline
    b.horos_databaseIvar = database(c.object(forKey: "db"))
    let matrix = TestMatrix()
    matrix.count = number(c, "matrixCount")
    b.horos_oMatrix = matrix
    b.horos_comparativeTable = NSObject()
    let window = TestWindow()
    b.window = window
    let albums = TestTable(); albums.clickedRow = number(c, "clickedRow")
    b.horos_albumTable = albums
    b.horos_sourcesTableView = NSObject()
    b.horos_activityTableView = NSObject()
    let check = NSButton()
    check.state = NSControl.StateValue(rawValue: number(c, "check"))
    b.horos_animationCheck = check
    b.horos_pressedKeys = NSMutableString()
    b.horos_outlineViewList = rows(list(c, "list"))
    switch (plain(c.object(forKey: "responder")) as? String) ?? "none" {
    case "matrix": window.firstResponder = matrix
    case "list": window.firstResponder = outline
    case "history": window.firstResponder = b.horos_comparativeTable
    case "album": window.firstResponder = albums
    case "sources": window.firstResponder = b.horos_sourcesTableView
    case "activity": window.firstResponder = b.horos_activityTableView
    case "other": window.firstResponder = NSObject()
    default: break
    }
    return b
}

func flush(_ label: String) {
    for r in records { print("\(label) \(r)") }
    records.removeAll()
}

@main struct Main {
    @MainActor static func main() {
        _ = NSApplication.shared
        let data = try! Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let cases = try! JSONSerialization.jsonObject(with: data) as! NSDictionary
        func section(_ name: String) -> [NSDictionary] { (cases.object(forKey: name) as? [NSDictionary]) ?? [] }

        for (i, c) in section("validate").enumerated() {
            let b = browser(c)
            if flag(c.object(forKey: "tileMenu")) { b.horos_imageTileMenu = NSMenu(title: "tile") }
            if flag(c.object(forKey: "listMenu")) { b.horos_databaseOutline?.menu = NSMenu(title: "list") }
            let item = NSMenuItem(title: "T", action: NSSelectorFromString(c.object(forKey: "action") as! String), keyEquivalent: "")
            item.tag = number(c, "tag")
            let other = NSMenu(title: "o")
            switch c.object(forKey: "menu") as? String {
            case "tile" where b.horos_imageTileMenu != nil: b.horos_imageTileMenu?.addItem(item)
            case "list" where b.horos_databaseOutline?.menu != nil: b.horos_databaseOutline?.menu?.addItem(item)
            case "other": other.addItem(item)
            default: break
            }
            let r = b.validateMenuItem(item)
            rec("-> \(r ? 1 : 0) \(item.title) \(item.state.rawValue)")
            withExtendedLifetime(other) {}
            flush("validate \(i)")
        }
        for (i, c) in section("menus").enumerated() {
            let b = browser(c)
            let menu = NSMenu(title: "m")
            menu.addItem(withTitle: "stale", action: nil, keyEquivalent: "")
            switch c.object(forKey: "kind") as? String {
            case "albums": b.horos_albumTable?.menu = menu
            case "columns": b.horos_columnsMenu = menu
            default: break
            }
            b.menuWillOpen(menu)
            tree(menu, "", b)
            flush("menus \(i)")
        }
        for (i, c) in section("lock").enumerated() {
            let b = browser(c)
            if flag(c.object(forKey: "lock")) { b.lockStudies(nil) } else { b.unlockStudies(nil) }
            flush("lock \(i)")
        }
        for (i, c) in section("keys").enumerated() {
            let b = browser(c)
            for k in (c.object(forKey: "keys") as? [String]) ?? [] {
                let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                         characters: k, charactersIgnoringModifiers: k, isARepeat: false, keyCode: 0)!
                b.keyDown(with: e)
                rec("check \(b.horos_animationCheck!.state.rawValue) keys \(b.horos_pressedKeys!)")
            }
            flush("keys \(i)")
        }
        for (i, n) in ((cases.object(forKey: "modifiers") as? [NSNumber]) ?? []).enumerated() {
            testCarbonModifiers = n.uint32Value
            rec("\(BrowserController._currentModifierFlags())")
            flush("modifiers \(i)")
        }
        for (i, c) in section("slider").enumerated() {
            let b = browser(c)
            b.horos_oMatrix?.cells = ((c.object(forKey: "cells") as? [NSNumber]) ?? []).map { let cell = NSButtonCell(); cell.tag = $0.intValue; return cell }
            b.horos_oMatrix?.selected = number(c, "selectedCell")
            b.horos_matrixViewArray = rows(list(c, "thumbnails"))
            let slider = NSSlider()
            slider.maxValue = 99; slider.numberOfTickMarks = 7; slider.intValue = 5
            slider.isEnabled = flag(c.object(forKey: "enabled"))
            b.horos_animationSlider = slider
            b.initAnimationSlider()
            rec(String(format: "slider %d %g %d %d", slider.isEnabled ? 1 : 0, slider.maxValue, Int32(slider.numberOfTickMarks), slider.intValue))
            flush("slider \(i)")
        }
        for (i, c) in section("reuse").enumerated() {
            let b = browser(c)
            testViewers = []
            for v in list(c, "viewers") {
                let viewer = ViewerController()
                viewer.closing = flag(v.object(forKey: "closing"))
                viewer.files = list(v, "files").map { DicomImage($0) }
                var n = 0
                viewer.pixes = list(v, "pixes").map { p in
                    let pix = DCMPix(); pix.values = p; pix.name = "pix\(n)"; n += 1
                    pix.pwidth = number(p, "w"); pix.pheight = number(p, "h")
                    let count = max(1, pix.pwidth * pix.pheight)
                    let image = UnsafeMutablePointer<Float>.allocate(capacity: count)
                    for k in 0..<pix.pwidth * pix.pheight { image[k] = Float(k + n * 100) }
                    pix.storage = image
                    return pix
                }
                testViewers.append(viewer)
            }
            var expected: PreviewFrame?
            if let e = plain(c.object(forKey: "expected")) as? NSDictionary {
                let series = e.object(forKey: "series") as! NSDictionary
                expected = PreviewFrame(path: e.object(forKey: "completePath") as! String, sopInstanceUID: e.object(forKey: "sopInstanceUID") as! String,
                                        seriesInstanceUID: series.object(forKey: "seriesDICOMUID") as! String, sopClassUID: series.object(forKey: "seriesSOPClassUID") as! String,
                                        modality: series.object(forKey: "modality") as! String, frameNumber: number(e, "frameID"), frameCount: number(e, "numberOfFrames"),
                                        rows: number(e, "height"), columns: number(e, "width"), seriesID: number(series, "id"))
            }
            let pix = b.getDCMPix(fromViewerIfAvailable: plain(c.object(forKey: "path")) as? String, frameNumber: Int32(number(c, "frame")), expectedFrame: expected)
            rec("-> \(pix?.name ?? "nil")")
            flush("reuse \(i)")
        }
        for (i, c) in section("reset").enumerated() {
            let b = browser(c)
            b.resetToDefaultDatabaseIfNecessary()
            flush("reset \(i)")
        }
        for (i, c) in section("sort").enumerated() {
            let b = browser(c)
            b.sortCase()
            flush("sort \(i)")
        }
        for (i, c) in section("search").enumerated() {
            let b = browser(c)
            let field = NSSearchField()
            b.horos_searchField = field
            var template: NSMenu?
            if let pairs = plain(c.object(forKey: "template")) as? [[Any]] {
                template = NSMenu(title: "search")
                for pair in pairs { template?.addItem(withTitle: pair[0] as! String, action: nil, keyEquivalent: "").tag = (pair[1] as! NSNumber).intValue }
            }
            (field.cell as? NSSearchFieldCell)?.searchMenuTemplate = template
            b.searchMenuCase()
            let after = (field.cell as? NSSearchFieldCell)?.searchMenuTemplate
            if after == nil { rec("no template") }
            for item in after?.items ?? [] {
                rec("\(item.title) \(item.tag) \(item.action.map(NSStringFromSelector) ?? "-") \(item.target === b ? "self" : "nil")")
            }
            flush("search \(i)")
        }
        for (i, c) in section("close").enumerated() {
            let b = browser(c)
            BrowserController.horizontal = flag(c.object(forKey: "horizontal"))
            func split(_ hidden: Any?) -> NSSplitView? {
                guard let hidden = plain(hidden) as? [NSNumber] else { return nil }
                let s = NSSplitView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
                for h in hidden { let v = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100)); v.isHidden = h.boolValue; s.addSubview(v) }
                return s
            }
            b.horos_splitDrawer = split(c.object(forKey: "drawer"))
            b.horos_splitComparative = split(c.object(forKey: "comparative"))
            b.horos_databaseOutline?.storedSorts = ((c.object(forKey: "sorts") as? [[Any]]) ?? []).map {
                NSSortDescriptor(key: plain($0[0]) as? String, ascending: flag($0[1]))
            }
            b.closeCase()
            flush("close \(i)")
        }
    }
}
'''


# --- the cases -----------------------------------------------------------------
ACTIONS = sorted(set(re.findall(r'@selector\(\s*(\w+:?)\s*\)', validate))) + ['openSomethingElse:', 'viewerDICOMInt:']
NAMES = ['Alice', 'alfred', 'Bob', 'bea', 'Carl', 'Zoe', 'Ana']


def row(rng, i):
    r = {'name': rng.choice(NAMES) + str(i), 'type': rng.choice(['Study', 'Series', 'Image', 'Other', None])}
    if rng.random() < .7:
        r['lockedStudy'] = rng.choice([True, False, 1, 0, 'YES', 'NO', None])
    if rng.random() < .3:
        r['distant'] = rng.choice([True, False])
    if rng.random() < .3:
        r['reportURL'] = rng.choice(['/r/x.pages', '', None])
    if rng.random() < .6:
        study = {'name': 'S%d' % i, 'type': 'Study', 'lockedStudy': rng.choice([True, False, None])}
        if rng.random() < .6:
            study['reportURL'] = rng.choice(['/r/a.pages', '', '/r/b.odt'])
        r['study'] = study
    return r


def browser_case(rng):
    rows = [row(rng, i) for i in range(rng.randint(0, 5))]
    # Now and then a row past the end, which the outline answers with nil.
    count = len(rows) + (1 if rng.random() < .15 else 0)
    c = {'rows': rows, 'selected': sorted(rng.sample(range(count), rng.randint(min(1, count), min(3, count)))),
         'selectedRow': rng.randint(-1, len(rows)),
         'db': rng.choice([None, {'local': True, 'readOnly': False, 'base': '/db'}, {'local': True, 'readOnly': True, 'base': '/db'},
                           {'local': False, 'readOnly': False, 'base': '/remote'}, {'local': False, 'readOnly': True}]),
         'defaults': {'COMMENTSAUTOFILL': rng.choice([True, False, None]), 'ANNOTATIONS': rng.choice([0, 1, 2, 3, None])},
         'responder': rng.choice(['none', 'matrix', 'list', 'history', 'album', 'sources', 'activity', 'other']),
         'matrixCount': rng.randint(0, 3), 'clickedRow': rng.randint(-1, 2), 'check': rng.choice([0, 1])}
    return c


def build_cases(rng):
    validate_cases = []
    for action in ACTIONS:
        for _ in range(24):
            c = browser_case(rng)
            c.update({'action': action, 'tag': rng.choice([0, 1, 2, 3]), 'tileMenu': rng.random() < .5, 'listMenu': rng.random() < .5,
                      'menu': rng.choice(['tile', 'list', 'other', 'none']), 'roi': rng.randint(0, 3), 'roisKeys': rng.randint(0, 3),
                      'keys': rng.randint(0, 3), 'thumbItem': rng.random() < .5, 'mainIsViewer': rng.random() < .5,
                      'reportExists': rng.random() < .6, 'reportKind': rng.choice([0, 1, 2]),
                      'linked': [{'name': 'f%d' % k, 'inDatabaseFolder': rng.choice([True, False, None, 'YES'])} for k in range(rng.randint(0, 2))]})
            validate_cases.append(c)

    menus = []
    for kind in ['albums', 'list', 'columns']:
        for _ in range(16):
            c = browser_case(rng)
            rules = [{'name': 'Rule %d' % k, 'activated': rng.choice([True, False]),
                      **({'description': rng.choice(['to PACS', ''])} if rng.random() < .7 else {})} for k in range(rng.randint(0, 3))]
            c['defaults']['AUTOROUTINGDICTIONARY'] = rng.choice([rules, rules, None])
            c.update({'kind': kind, 'workspace': rng.random() < .5})
            menus.append(c)

    lock = []
    for _ in range(40):
        c = browser_case(rng)
        c['lock'] = rng.random() < .5
        lock.append(c)

    keys = []
    for _ in range(40):
        c = browser_case(rng)
        c['list'] = [{'name': rng.choice(NAMES) + str(k)} for k in range(rng.randint(0, 5))]
        c['keys'] = [rng.choice(['a', 'A', 'b', 'Z', 'al', '\x7f', '\x08', '\r', '\n', '\x03', ' ', '', '', 'é', '', '1'])
                     for _ in range(rng.randint(1, 4))]
        keys.append(c)

    modifiers = [0, 0x100, 0x200, 0x400, 0x800, 0x1000, 0x1b00, 0x1f00, 0xffff] + [rng.randint(0, 0xffff) for _ in range(8)]

    def frames():
        return rng.choice([{'numberOfFrames': n} for n in (0, 1, 2, 5)] + [{'numberOfFrames': '3'}, {}])

    slider = []
    for _ in range(160):
        c = browser_case(rng)
        selected = rng.randint(-1, 2)
        rows = [{'name': 'r%d' % k, 'type': rng.choice(['Series', 'Study', 'Image']),
                 'images': [frames() for _ in range(rng.randint(0, 3))]} for k in range(3)]
        thumbnails = []
        for k in range(rng.randint(0, 3)):
            t = {'name': 't%d' % k}
            if rng.random() < .8:
                t['thumbImages'] = [frames() for _ in range(rng.randint(0, 3))]
            thumbnails.append(t)
        cells = [rng.randint(0, 3) for _ in range(rng.choice([0, 1, 2, 3, 3]))]
        c.update({'rows': rows, 'selectedRow': selected, 'cells': cells,
                  'selectedCell': rng.randint(0, len(cells) - 1) if cells and rng.random() < .85 else -1,
                  'thumbnails': thumbnails, 'enabled': rng.random() < .5})
        slider.append(c)

    reuse = []
    for _ in range(160):
        c = browser_case(rng)
        viewers = []
        all_files = []
        for _ in range(rng.randint(0, 2)):
            files, pixes = [], []
            for _ in range(rng.randint(0, 3)):
                f = {'completePath': rng.choice(['/a', '/b', '/c']), 'frameID': rng.randint(0, 2), 'sopInstanceUID': rng.choice(['1.1', '1.2']),
                     'numberOfFrames': rng.choice([1, 3]), 'height': rng.choice([2, 3]), 'width': rng.choice([2, 4]),
                     'series': {'seriesDICOMUID': rng.choice(['9.1', '9.2']), 'seriesSOPClassUID': '1.2.840', 'modality': rng.choice(['CT', 'MR']), 'id': rng.randint(1, 2)}}
                files.append(f)
                all_files.append(f)
                pixes.append({'loaded': rng.random() < .8, 'matches': rng.random() < .8, 'w': rng.randint(1, 3), 'h': rng.randint(1, 3)})
            viewers.append({'closing': rng.random() < .2, 'files': files, 'pixes': pixes})
        # Mostly a frame some viewer holds, as the preview asks for it.
        target = rng.choice(all_files) if all_files and rng.random() < .85 else None
        path = target['completePath'] if target and rng.random() < .85 else rng.choice(['/a', '/b', '/c', None])
        frame = target['frameID'] if target and rng.random() < .85 else rng.randint(0, 2)
        expected = None
        if target and rng.random() < .7:
            expected = json.loads(json.dumps(target))
            if rng.random() < .25:
                expected['series']['modality'] = 'PT'
        c.update({'viewers': viewers, 'path': path, 'frame': frame, 'expected': expected})
        reuse.append(c)

    reset = []
    for _ in range(24):
        c = browser_case(rng)
        c['defaults'].update({'DEFAULT_DATABASELOCATION': rng.choice([0, 1, '1', None]), 'DEFAULT_DATABASELOCATIONURL': rng.choice(['/db', '/other', None])})
        c['defaultPath'] = rng.choice(['/db', '/remote', None])
        reset.append(c)

    sort = []
    for _ in range(30):
        c = browser_case(rng)
        saved = rng.choice([None, {'key': 'date', 'order': True}, {'key': 'name', 'order': False}, {'key': 'modality', 'order': 1},
                            {'key': 'date'}, {'order': False}, {'key': 'gone', 'order': True}])
        c['defaults']['databaseSortDescriptor'] = saved
        c['visible'] = rng.sample(['name', 'date', 'modality', '(none)'], rng.randint(0, 4))
        sort.append(c)

    search = []
    for _ in range(20):
        c = browser_case(rng)
        template = None
        if rng.random() < .85:
            template = [[t, tag] for t, tag in rng.sample([['Name', 0], ['ID', 1], ['Accession', 3], ['Description', 4],
                                                            ['Series Description', 11], ['Comments', 5]], rng.randint(0, 5))]
        c['template'] = template
        search.append(c)

    close = []
    for _ in range(24):
        c = browser_case(rng)
        c.update({'horizontal': rng.random() < .5, 'drawer': rng.choice([None, [rng.random() < .5, rng.random() < .5]]),
                  'comparative': rng.choice([None, [rng.random() < .5, rng.random() < .5]]),
                  'sorts': rng.choice([[], [['date', True]], [['name', False], ['date', True]], [[None, True]]])})
        close.append(c)

    return {'validate': validate_cases, 'menus': menus, 'lock': lock, 'keys': keys, 'modifiers': modifiers, 'slider': slider,
            'reuse': reuse, 'reset': reset, 'sort': sort, 'search': search, 'close': close}


# --- compile, run, compare ---------------------------------------------------------
SWIFT = SWIFT.replace('@@GLUE@@', glue).replace('@@MEMBERS@@', members).replace('@@DRIVER@@', SWIFT_DRIVER)

failures = []
with tempfile.TemporaryDirectory(prefix='horos-browser-window-') as tmp:
    tmp = Path(tmp)
    (tmp / 'cases.json').write_text(json.dumps(build_cases(random.Random(20261027))))
    (tmp / 'reference.m').write_text(OBJC)
    (tmp / 'driver.h').write_text(DRIVER)
    if args.dump:
        args.dump.mkdir(parents=True, exist_ok=True)
        for name in ('cases.json', 'reference.m', 'driver.h'):
            (args.dump / name).write_bytes((tmp / name).read_bytes())
        (args.dump / 'main.swift').write_text(SWIFT)
    built = subprocess.run(['xcrun', 'clang', '-fno-objc-arc', '-fblocks', '-w', '-framework', 'Cocoa', '-I', str(tmp),
                            str(tmp / 'reference.m'), '-o', str(tmp / 'reference')], capture_output=True, text=True, timeout=300)
    if built.returncode:
        sys.exit('FAIL: the Objective-C reference does not compile:\n' + built.stderr[-3000:])
    (tmp / 'main.swift').write_text(SWIFT)
    built = subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '6', '-o', str(tmp / 'current'), str(RULES), str(tmp / 'main.swift')],
                           capture_output=True, text=True, timeout=300)
    if built.returncode:
        sys.exit('FAIL: the Swift does not compile:\n' + built.stderr[-3000:])
    objc = subprocess.run([str(tmp / 'reference'), str(tmp / 'cases.json')], capture_output=True, timeout=60)
    swift = subprocess.run([str(tmp / 'current'), str(tmp / 'cases.json')], capture_output=True, timeout=60)
    if objc.returncode or swift.returncode:
        sys.exit('FAIL: a driver failed (%d, %d):\n' % (objc.returncode, swift.returncode)
                 + objc.stderr[-1500:].decode('utf-8', 'replace') + swift.stderr[-1500:].decode('utf-8', 'replace'))
    a, b = objc.stdout.decode('utf-8').split('\n'), swift.stdout.decode('utf-8').split('\n')
    if args.dump:
        args.dump.mkdir(parents=True, exist_ok=True)
        (args.dump / 'reference.txt').write_bytes(objc.stdout)
        (args.dump / 'current.txt').write_bytes(swift.stdout)
    if a != b:
        diff = list(difflib.unified_diff(a, b, 'Objective-C', 'Swift', lineterm='', n=1))
        failures.append('records differ:\n' + '\n'.join(diff[:120]))

if failures:
    for failure in failures:
        print('FAIL:', failure)
    sys.exit(1)
kinds = {}
for line in a:
    if line:
        kinds[line.split(' ')[0]] = kinds.get(line.split(' ')[0], 0) + 1
print('ok: the browser window functions of %s and the Swift agree on %d records (%s)'
      % (reference, sum(kinds.values()), ', '.join('%s %d' % kv for kv in sorted(kinds.items()))))
