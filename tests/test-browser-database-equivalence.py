#!/usr/bin/env python3
"""The browser's database, album and search rules decide what their Objective-C did.

The database functions, the albums, the patient list album and the search and
time interval of BrowserController moved from BrowserController.m to Swift
extensions of the class, with their rules in the IsiXDatabase module. This
compiles the Objective-C of those rules, cut out of BrowserController.m in the
last revision that has it (history_reference; the tree itself while it still
has it), over small stand-ins, and the module with swiftc, and gives both the
same synthetic inputs:

* smart albums: the predicate of a stored format with `$TODAY`, `$WEEK`, ...
  written in and `$NSDATE_...` variables, at fixed moments around a change of
  daylight saving time, in three time zones: its format and the studies it
  keeps out of a list of dates;
* the time interval menu: the start and end of every tag, at the same moments,
  and when the PACS On-Demand nodes are asked again;
* the search field: when it also asks the nodes;
* album names: the name an album is saved under, for the "Add Album" sheet and
  for the patient list album;
* dropped files and folders: what is done with each item of a synthetic tree
  (hidden files, application bundles and documents, DICOMDIRs, archives, WADO
  manifests and lists) and the files handed on to the import;
* `.dcmURLs` lists: the URLs read from LF, CR and CRLF text;
* archives: when a password is asked for, first and again;
* "Copy files": copy, link, ask or cancel, for every mode, path and answer;
* the extension a file gets in the database folder, copied by an import or
  copied in on request; the rebuild sheet's estimate; the import refresh
  intervals.

Every record must be identical, with one intended difference: a `.dcmURLs`
list found inside a dropped folder was handed to the download as the folder,
which the download then deleted; it is now the list itself.

    python3 tests/test-browser-database-equivalence.py [--reference REV]
"""
import argparse
import difflib
import os
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import private_tmpdir  # noqa: F401,E402  - its own TMPDIR for the tools it runs
import history_reference  # noqa: E402
import isix_modules  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
BC = 'Horos/Sources/BrowserController.m'
MARK = '- (NSPredicate*) smartAlbumPredicateString:(NSString*) string'
MODULE = ROOT / 'Modules/IsiXDatabase/Sources'

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
    print('skipped: needs the history that has the Objective-C database functions of BrowserController.m')
    sys.exit(2)
if reference == 'tree':
    text = (ROOT / BC).read_bytes().decode('latin1')
else:
    shown = git('show', '%s:%s' % (reference, BC))
    if shown.returncode:
        sys.exit('FAIL: no %s at %s' % (BC, reference))
    text = shown.stdout.decode('latin1')
if MARK not in text:
    sys.exit('FAIL: %s has no Objective-C smart album predicate in %s' % (reference, BC))
if not MODULE.is_dir():
    sys.exit('FAIL: no IsiXDatabase module in the tree')


def matching(source, start):
    """The index just past the brace that closes the one at `start`, skipping
    strings, characters and comments."""
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
    """The implementation of `signature`, not a declaration of it."""
    at = source.index(signature)
    while ';' in source[at:source.index('{', at)]:
        at = source.index(signature, at + 1)
    return source[at:matching(source, source.index('{', at))]


def block(start_text, within):
    """From `start_text` through the brace block that follows it."""
    at = within.index(start_text)
    return within[at:matching(within, within.index('{', at))]


def condition(line_start, within):
    """The condition of the `if(` whose line starts with `line_start`."""
    at = within.index(line_start)
    end = within.index('\n', at)
    line = within[at:end].rstrip()
    assert line.startswith('if(') and line.endswith(')'), line
    return line[len('if('):-1]


compute = method('- (void) computeTimeInterval')
switch = block('switch( self.timeIntervalType)', compute)
interval_condition = condition('if( [timeIntervalStart isEqualToDate: self.distantTimeIntervalStart]', compute)
search_condition = condition('if( _searchString.length > 2', method('- (IBAction)setSearchType: (id)sender'))

add_album = method('- (IBAction) addAlbum:(id)sender')
at = add_album.index('name = [newAlbumName stringValue];')
album_loop = add_album[at:matching(add_album, add_album.index('{', add_album.index('while', at)))]
patient_album = method('- (NSString *)patientListCreateAlbumNamed:(NSString *)name')
at = patient_album.index('NSString *unique = name;')
end = patient_album.index('unique = [NSString stringWithFormat: @"%@ #%d", name, n++];', at)
patient_loop = patient_album[at:patient_album.index('\n', end)]

wado = method('- (void) asyncWADODownload:(NSString*) filename')
wado_try = wado[wado.index('@try'):]
wado_try = wado_try[:matching(wado_try, wado_try.index('{', wado_try.index('@catch')))]

expand = method('- (void)expandArchiveThread:(NSDictionary*)parameters')
first_password = expand[expand.index('BOOL requiresPassword = ') + len('BOOL requiresPassword = '):]
first_password = first_password[:first_password.index(';')]
again = expand.index('requiresPassword = ', expand.index('withPassword:password'))
again_password = expand[again + len('requiresPassword = '):]
again_password = again_password[:again_password.index(';')]

copy_into = method('- (void) copyFilesIntoDatabaseIfNeeded: (NSMutableArray*) filesInput options: (NSDictionary*) options')
copy_decision = copy_into[copy_into.index('BOOL COPYDATABASE ='):copy_into.index('NSMutableArray *filesOutput')]
copy_decision = copy_decision.replace('return;', 'return -1;')
imported_extension = copy_into[copy_into.index('if( [[[curFile dicomElements] objectForKey: @"fileType"] hasPrefix: @"DICOM"])'):
                               copy_into.index('NSString *dstPath = [self.database')]
copy_to_db = method('- (IBAction) copyToDBFolder: (id) sender')
linked_extension = copy_to_db[copy_to_db.index('NSString *extension = [srcPath pathExtension];'):
                              copy_to_db.index('NSString *dstPath = [self.database')]
rebuild_sheet = method('- (IBAction) ReBuildDatabaseSheet: (id)sender')
estimate = rebuild_sheet[rebuild_sheet.index('long durationFor1000'):rebuild_sheet.index('[estimatedTime')]
refresh = text[text.index('static const NSTimeInterval HorosImportListRefreshInterval'):]
refresh = refresh[:refresh.index('\n')]



def reference_bytes(path):
    """A file of the reference: the tree's own while it has it, else the
    reference revision's (Horos.m and DCM.framework have left the tree)."""
    if reference == 'tree' and (ROOT / path).exists():
        return (ROOT / path).read_bytes()
    revision = 'HEAD' if reference == 'tree' else reference
    shown = git('show', '%s:%s' % (revision, path))
    if shown.returncode:
        revision = history_reference.before_removal(path)
        shown = git('show', '%s:%s' % (revision, path)) if revision else shown
    if shown.returncode:
        sys.exit('FAIL: no %s in the history' % path)
    return shown.stdout


horos_m = reference_bytes('Horos/Sources/Horos.m').decode('latin1')
date_adding = method('+ (NSDate *):(NSDate *)date dateByAddingYears:', horos_m)

MOMENTS = [796_552_200.0, 796_514_400.0, 793_800_000.5, 815_011_200.0, 0.25]
FORMATS = ['date >= CAST($TODAY, "NSDate")',
           'dateAdded >= CAST($lastHour, "NSDate") AND date <= CAST($Yesterday, "NSDate")',
           'date >= CAST($LAST6HOURS, "NSDate") OR date >= CAST($LAST12HOURS, "NSDate") OR date >= CAST($2DAYS, "NSDate")',
           'date >= CAST($WEEK, "NSDate") AND date < CAST($MONTH, "NSDate")',
           'date >= CAST($2MONTHS, "NSDate") AND date >= CAST($3MONTHS, "NSDate") AND date >= CAST($YEAR, "NSDate")',
           'date >= $NSDATE_TODAY', 'date >= $NSDATE_LASTHOUR AND date < $NSDATE_LAST6HOURS',
           'date >= $NSDATE_LAST12HOURS OR date >= $NSDATE_YESTERDAY OR date >= $NSDATE_2DAYS',
           'date >= $NSDATE_WEEK AND date >= $NSDATE_MONTH AND date >= $NSDATE_2MONTHS',
           'date >= $NSDATE_3MONTHS OR date >= $NSDATE_YEAR',
           'modality CONTAINS[cd] "MR" AND name BEGINSWITH "$TODAY"', '']
TAGS = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, -1, 100]
ALBUMS = [('CT', []), ('CT', ['CT']), ('CT', ['CT', 'CT #2', 'CT #4']), ('ct', ['CT']), ('', ['']),
          ('Café', ['Café']), ('Café', ['Café', 'Café #2']), ('A #2', ['A #2', 'A'])]
URL_TEXTS = ['http://a/1\nhttp://a/2\n', 'http://a/1\rhttp://a/2\r', 'http://a/1\r\nhttp://a/2\r\n',
             '\n\nhttp://a/1\n\n', 'http://a/1', '', 'http://a/1\nhttp://[::1\nhttp://a/3\n',
             'http://a/1\rhttp://a/2\nhttp://a/3\n']
COPY_PATHS = [['/Volumes/S/a.dcm', '/Volumes/S/b.dcm'], ['/volumes/S/a.dcm'], ['/Users/u/a.dcm'],
              ['/db/DATABASE.noindex/1/a.dcm'], ['/cd/a.dcm', '/db/DATABASE.noindex/a.dcm'], ['/'], ['a.dcm']]
EXTENSIONS = ['dcm', '', 'jpg', 'jpeg', 'tiff2', 'gz', 'hdr', 'DCM', 'nii']


def strings(values):
    return ', '.join('@"%s"' % v.encode('unicode_escape').decode().replace('\\u', '\\u').replace('"', '\\"') for v in values)


def objc_string(value):
    escaped = ''
    for ch in value:
        if ch == '"':
            escaped += '\\"'
        elif ch == '\\':
            escaped += '\\\\'
        elif ch == '\n':
            escaped += '\\n'
        elif ch == '\r':
            escaped += '\\r'
        elif ord(ch) > 126:
            escaped += '\\u%04x' % ord(ch)
        else:
            escaped += ch
    return '@"%s"' % escaped


def swift_string(value):
    escaped = ''
    for ch in value:
        if ch == '"':
            escaped += '\\"'
        elif ch == '\\':
            escaped += '\\\\'
        elif ch == '\n':
            escaped += '\\n'
        elif ch == '\r':
            escaped += '\\r'
        elif ord(ch) > 126:
            escaped += '\\u{%x}' % ord(ch)
        else:
            escaped += ch
    return '"%s"' % escaped


def objc_array(values):
    return '@[%s]' % ', '.join(objc_string(v) for v in values)


def swift_array(values):
    return '[%s]' % ', '.join(swift_string(v) for v in values)


def build_tree(base):
    """A dropped folder and loose items, as a user might drop them."""
    folder = base / 'Dropped'
    files = ['a.dcm', '.hidden.dcm', 'sub/b.dcm', 'sub/.DS_Store', 'X.app/Contents/Info.plist',
             'X.app/Contents/MacOS/x', 'X.appendix', 'after.dcm', 'c.zip', 'DICOMDIR', 'sub2/dicomdir.',
             'list.dcmURLs', 'w.xml', 'Doc.pages/index.xml', '.hiddendir/inner.dcm', 'Y.APP/z.dcm', 'deep/Z.app/q.dcm',
             'deep/r.dcm']
    for name in files:
        path = folder / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text('x')
    loose = {'top.dcm': 'x', 'top.xml': 'x', 'top.dcmURLs': 'x', 'top.ZIP': 'x', 'dicomdir': 'x', '.hiddentop': 'x'}
    for name, content in loose.items():
        (base / name).write_text(content)
    (base / 'Doc2.pages').mkdir()
    (base / 'Doc2.pages/index.xml').write_text('x')
    (base / 'App2.app').mkdir()
    return [str(folder), str(base / 'top.dcm'), str(base / 'top.xml'), str(base / 'top.dcmURLs'),
            str(base / 'top.ZIP'), str(base / 'dicomdir'), str(base / 'Doc2.pages'), str(base / 'App2.app'),
            str(base / 'missing.dcm'), str(base / '.hiddentop'), str(folder) + '/sub']


OBJC = r'''
#import <Cocoa/Cocoa.h>
#import <objc/runtime.h>
#import "DCMCalendarDate.h"

#define N2LogExceptionWithStackTrace(e, ...) NSLog(@"exception %@", e)
enum { always = 0, cdOnly = 1, notMainDrive = 2, ask = 3 };
enum { HorosAlertDefaultResponse = 1, HorosAlertAlternateResponse = 0, HorosAlertOtherResponse = -1 };
static NSInteger gResponse = 1;
NSInteger HorosRunInformationalAlertPanel(NSString *t, NSString *m, NSString *a, NSString *b, NSString *c, ...) { return gResponse; }
static NSTimeInterval gNow = 0;
static NSMutableArray *gRecord = nil;
static void Record(NSString *line) { [gRecord addObject: line]; }

@interface NSDate (Fixed) @end
@implementation NSDate (Fixed)
+ (instancetype)fixed_date { return [self dateWithTimeIntervalSinceReferenceDate: gNow]; }
+ (instancetype)fixed_dateWithTimeIntervalSinceNow:(NSTimeInterval)s { return [self dateWithTimeIntervalSinceReferenceDate: gNow + s]; }
@end

@interface NSString (Range) - (NSRange)range; @end
@implementation NSString (Range) - (NSRange)range { return NSMakeRange(0, self.length); } @end

@interface NSThread (N2Stand) @property(retain) NSString *status; @property BOOL supportsCancel; @end
@implementation NSThread (N2Stand)
- (NSString*)status { return nil; } - (void)setStatus:(NSString*)s {}
- (BOOL)supportsCancel { return NO; } - (void)setSupportsCancel:(BOOL)b {}
@end

@interface ThreadsManager : NSObject + (instancetype)defaultManager; - (void)addThreadAndStart:(NSThread*)t; @end
@implementation ThreadsManager
+ (instancetype)defaultManager { static ThreadsManager *m = nil; if (!m) m = [ThreadsManager new]; return m; }
- (void)addThreadAndStart:(NSThread*)t { [t main]; }
@end

@interface HorosArchiveImportLedger : NSObject + (BOOL)isArchiveName:(NSString*)name; @end
@implementation HorosArchiveImportLedger
+ (BOOL)isArchiveName:(NSString*)name { return [[[name pathExtension] lowercaseString] isEqualToString: @"zip"]; }
@end

@interface Horos : NSObject
+ (NSDate *):(NSDate *)date dateByAddingYears:(NSInteger)years months:(NSInteger)months days:(NSInteger)days hours:(NSInteger)hours minutes:(NSInteger)minutes seconds:(NSInteger)seconds;
@end
@implementation Horos
DATE_ADDING
@end

@interface CustomIntervalPanel : NSObject
@property(retain) NSDate *fromDate, *toDate;
+ (CustomIntervalPanel*)sharedCustomIntervalPanel;
@end
@implementation CustomIntervalPanel
+ (CustomIntervalPanel*)sharedCustomIntervalPanel {
    static CustomIntervalPanel *p = nil;
    if (!p) { p = [CustomIntervalPanel new]; p.fromDate = [NSDate dateWithTimeIntervalSinceReferenceDate: 700000000]; p.toDate = [NSDate dateWithTimeIntervalSinceReferenceDate: 700086400]; }
    return p;
}
@end

@interface Field : NSObject @property(retain) NSString *stringValue; @end
@implementation Field @end
@interface Database : NSObject - (NSString*)dataDirPath; @end
@implementation Database - (NSString*)dataDirPath { return @"/db/DATABASE.noindex"; } @end
@interface CurFile : NSObject @property(retain) NSDictionary *dicomElements; @end
@implementation CurFile @end

@interface BrowserController : NSObject {
@public
    NSDate *timeIntervalStart, *timeIntervalEnd;
    NSString *_searchString;
    int searchType;
    Field *newAlbumName;
    Database *_database;
}
@property int timeIntervalType;
@property(retain) NSDate *distantTimeIntervalStart, *distantTimeIntervalEnd;
@end

@implementation BrowserController
@synthesize timeIntervalType, distantTimeIntervalStart, distantTimeIntervalEnd;

SMART_ALBUM

- (void)refTimeInterval
{
    SWITCH
}

- (BOOL)refNeedsDistant { return INTERVAL_CONDITION; }
- (BOOL)refSearchDistant { return SEARCH_CONDITION; }

- (NSString*)refAlbumName:(NSString*)requested existing:(NSArray*)names
{
    NSArray *albumsArray = [NSMutableArray array];
    for (NSString *n in names) [(NSMutableArray*)albumsArray addObject: [NSDictionary dictionaryWithObject: n forKey: @"name"]];
    newAlbumName = [[Field alloc] init]; newAlbumName.stringValue = requested;
    NSString *name;
    int i = 2;
    ALBUM_LOOP
    return name;
}

- (NSString*)refPatientAlbumName:(NSString*)name names:(NSArray*)names
{
    PATIENT_LOOP
    return unique;
}

ADD_FILES

- (void) asyncWADODownload:(NSString*) filename { Record([@"wado " stringByAppendingString: filename]); }
- (void) expandArchiveIntoIncomingFolder: (NSString*) archive { Record([@"archive " stringByAppendingString: archive]); }
- (void) addDICOMDIR:(NSString*) dicomdir :(NSMutableArray*) files { Record([@"dicomdir " stringByAppendingString: dicomdir]); }
+ (void) asyncWADOXMLDownloadURL:(NSURL*) url { Record([@"xml " stringByAppendingString: url.path]); }
- (void) copyFilesIntoDatabaseIfNeeded: (NSMutableArray*) files options: (NSDictionary*) options
{
    Record([@"copy " stringByAppendingString: [files componentsJoinedByString: @"|"]]);
}

- (NSArray*)refURLs:(NSString*)filename
{
    NSMutableArray *urlToDownloads = [NSMutableArray array];
    WADO_TRY
    return urlToDownloads;
}

- (BOOL)refFirstPassword:(int)status { return FIRST_PASSWORD; }
- (BOOL)refAgainPassword:(int)status { return AGAIN_PASSWORD; }

+ (BOOL)isItCD:(NSString*)path { return [path hasPrefix: @"/cd"]; }

- (int)refCopy:(NSMutableArray*)filesInput options:(NSDictionary*)options
{
    COPY_DECISION
    return copyFiles;
}

- (NSString*)refImported:(NSString*)srcPath dicom:(BOOL)dicom
{
    NSString *extension = [srcPath pathExtension];
    CurFile *curFile = [[CurFile new] autorelease];
    curFile.dicomElements = [NSDictionary dictionaryWithObject: dicom ? @"DICOM" : @"IMAGE" forKey: @"fileType"];
    IMPORTED_EXTENSION
    return extension;
}

- (NSString*)refLinked:(NSString*)srcPath dicom:(BOOL)dicom
{
    NSDictionary *im = [NSDictionary dictionaryWithObject: dicom ? @"DICOM" : @"IMAGE" forKey: @"fileType"];
    LINKED_EXTENSION
    return extension;
}

- (long)refEstimate:(long)totalFiles
{
    ESTIMATE
    return totalSeconds;
}

REFRESH
- (NSString*)refRefresh { return [NSString stringWithFormat: @"%g %g", HorosImportListRefreshInterval, HorosImportAlbumsRefreshInterval]; }
@end

static NSString *Seconds(NSDate *d) { return d ? [NSString stringWithFormat: @"%.6f", d.timeIntervalSinceReferenceDate] : @"nil"; }

int main(int argc, char **argv)
{
    @autoreleasepool {
        gRecord = [NSMutableArray array];
        method_exchangeImplementations(class_getClassMethod([NSDate class], @selector(date)), class_getClassMethod([NSDate class], @selector(fixed_date)));
        method_exchangeImplementations(class_getClassMethod([NSDate class], @selector(dateWithTimeIntervalSinceNow:)), class_getClassMethod([NSDate class], @selector(fixed_dateWithTimeIntervalSinceNow:)));
        BrowserController *b = [BrowserController new];
        NSMutableArray *out = [NSMutableArray array];
        NSArray *moments = MOMENTS_ARRAY, *formats = FORMATS_ARRAY;
        NSMutableArray *probes = [NSMutableArray array];
        for (NSNumber *m in moments)
            for (int h = -800; h <= 800; h += 7)
                [probes addObject: [NSDictionary dictionaryWithObject: [NSDate dateWithTimeIntervalSinceReferenceDate: m.doubleValue + h * 3600.0] forKey: @"date"]];
        for (NSNumber *m in moments) {
            gNow = m.doubleValue;
            for (NSString *f in formats) {
                NSPredicate *p = [b smartAlbumPredicateString: f];
                NSMutableString *kept = [NSMutableString string];
                for (NSDictionary *probe in probes) {
                    @try { [kept appendString: [p evaluateWithObject: [NSMutableDictionary dictionaryWithObjectsAndKeys: [probe objectForKey: @"date"], @"date", [probe objectForKey: @"date"], @"dateAdded", @"MR", @"modality", @"x", @"name", nil]] ? @"1" : @"0"]; }
                    @catch (NSException *e) { [kept appendString: @"E"]; }
                }
                [out addObject: [NSString stringWithFormat: @"smart %@ %@: %@ | %@", Seconds([NSDate dateWithTimeIntervalSinceReferenceDate: gNow]), f, p.predicateFormat, kept]];
            }
            for (NSNumber *tag in TAGS_ARRAY) {
                b->timeIntervalStart = [[NSDate dateWithTimeIntervalSinceReferenceDate: 1] retain];
                b->timeIntervalEnd = [[NSDate dateWithTimeIntervalSinceReferenceDate: 2] retain];
                b.timeIntervalType = tag.intValue;
                [b refTimeInterval];
                [out addObject: [NSString stringWithFormat: @"interval %@ %@: %@ %@", Seconds([NSDate dateWithTimeIntervalSinceReferenceDate: gNow]), tag, Seconds(b->timeIntervalStart), Seconds(b->timeIntervalEnd)]];
            }
        }
        NSArray *dates = [NSArray arrayWithObjects: [NSNull null], [NSDate dateWithTimeIntervalSinceReferenceDate: 10], [NSDate dateWithTimeIntervalSinceReferenceDate: 20], nil];
        for (id s in dates) for (id e in dates) for (id ds in dates) for (id de in dates) {
            b->timeIntervalStart = s == [NSNull null] ? nil : s; b->timeIntervalEnd = e == [NSNull null] ? nil : e;
            b.distantTimeIntervalStart = ds == [NSNull null] ? nil : ds; b.distantTimeIntervalEnd = de == [NSNull null] ? nil : de;
            [out addObject: [NSString stringWithFormat: @"distant interval %@ %@ %@ %@: %d", Seconds(b->timeIntervalStart), Seconds(b->timeIntervalEnd), Seconds(b.distantTimeIntervalStart), Seconds(b.distantTimeIntervalEnd), [b refNeedsDistant]]];
        }
        for (int length = 0; length <= 4; length++) for (int type = 0; type <= 11; type++) {
            b->_searchString = [@"abcd" substringToIndex: length]; b->searchType = type;
            [out addObject: [NSString stringWithFormat: @"distant search %d %d: %d", length, type, [b refSearchDistant]]];
        }
        ALBUM_CASES
        [gRecord removeAllObjects];
        [b addFilesAndFolderToDatabase: DROPPED_ARRAY];
        for (NSString *line in gRecord) [out addObject: [@"dropped " stringByAppendingString: line]];
        NSString *listFile = [NSTemporaryDirectory() stringByAppendingPathComponent: [[NSUUID UUID] UUIDString]];
        for (NSString *t in URL_ARRAY) {
            [t writeToFile: listFile atomically: NO encoding: NSUTF8StringEncoding error: NULL];
            [out addObject: [NSString stringWithFormat: @"urls %@: %@", [[t stringByReplacingOccurrencesOfString: @"\n" withString: @"\\n"] stringByReplacingOccurrencesOfString: @"\r" withString: @"\\r"], [[[[[b refURLs: listFile] valueForKey: @"absoluteString"] componentsJoinedByString: @" "] stringByReplacingOccurrencesOfString: @"\n" withString: @"\\n"] stringByReplacingOccurrencesOfString: @"\r" withString: @"\\r"]]];
        }
        [[NSFileManager defaultManager] removeItemAtPath: listFile error: NULL];
        for (int status = -1; status <= 100; status++)
            [out addObject: [NSString stringWithFormat: @"password %d: %d %d", status, [b refFirstPassword: status], [b refAgainPassword: status]]];
        b->_database = [Database new];
        for (NSArray *paths in COPY_ARRAY) for (int mode = 0; mode <= 4; mode++) for (int enabled = 0; enabled <= 1; enabled++)
            for (NSNumber *response in [NSArray arrayWithObjects: @1, @0, @-1, nil]) {
                gResponse = response.integerValue;
                NSMutableArray *files = [NSMutableArray arrayWithArray: paths];
                NSDictionary *options = [NSDictionary dictionaryWithObjectsAndKeys: [NSNumber numberWithBool: enabled], @"COPYDATABASE", [NSNumber numberWithInt: mode], @"COPYDATABASEMODE", nil];
                int decision = [b refCopy: files options: options];
                [out addObject: [NSString stringWithFormat: @"copy %@ %d %d %@: %d %lu", [paths componentsJoinedByString: @","], mode, enabled, response, decision, (unsigned long)files.count]];
            }
        for (NSString *e in EXT_ARRAY) for (int dicom = 0; dicom <= 1; dicom++) {
            NSString *path = e.length ? [@"/x/file." stringByAppendingString: e] : @"/x/file";
            [out addObject: [NSString stringWithFormat: @"extension %@ %d: %@ %@", e, dicom, [b refImported: path dicom: dicom], [b refLinked: path dicom: dicom]]];
        }
        for (long n = 0; n < 5000; n += 333) [out addObject: [NSString stringWithFormat: @"estimate %ld: %ld", n, [b refEstimate: n]]];
        [out addObject: [@"refresh " stringByAppendingString: [b refRefresh]]];
        printf("%s\n", [[out componentsJoinedByString: @"\n"] UTF8String]);
    }
    return 0;
}
'''

SWIFT = r'''
import Foundation

func seconds(_ d: Date?) -> String { d.map { String(format: "%.6f", $0.timeIntervalSinceReferenceDate) } ?? "nil" }
func flag(_ b: Bool) -> String { b ? "1" : "0" }
var out: [String] = []
let zone = NSTimeZone.default
let moments: [Double] = MOMENTS_LIST
let formats: [String] = FORMATS_LIST
var probes: [Date] = []
for m in moments { for h in stride(from: -800, through: 800, by: 7) { probes.append(Date(timeIntervalSinceReferenceDate: m + Double(h) * 3600)) } }
for m in moments {
    let now = Date(timeIntervalSinceReferenceDate: m)
    for f in formats {
        // As -smartAlbumPredicateString: builds it.
        let predicate: NSPredicate
        if (f as NSString).length == 0 {
            predicate = NSPredicate(value: true)
        } else {
            let variables = SmartAlbumDateVariables(now: now, timeZone: zone)
            predicate = NSPredicate(format: variables.expandedFormat(f)).withSubstitutionVariables(variables.substitutionVariables)
        }
        var kept = ""
        for probe in probes {
            let object = NSMutableDictionary(dictionary: ["date": probe, "dateAdded": probe, "modality": "MR", "name": "x"])
            kept += predicate.evaluate(with: object) ? "1" : "0"
        }
        out.append("smart \(seconds(now)) \(f): \(predicate.predicateFormat) | \(kept)")
    }
    for tag in TAGS_LIST {
        var start: Date? = Date(timeIntervalSinceReferenceDate: 1), end: Date? = Date(timeIntervalSinceReferenceDate: 2)
        switch StudyDateInterval.change(forTag: tag, now: now, timeZone: zone) {
        case .clear: start = nil; end = nil
        case .since(let date): start = date; end = nil
        case .custom: start = Date(timeIntervalSinceReferenceDate: 700000000); end = Date(timeIntervalSinceReferenceDate: 700086400)
        case .unchanged: break
        }
        out.append("interval \(seconds(now)) \(tag): \(seconds(start)) \(seconds(end))")
    }
}
let dates: [Date?] = [nil, Date(timeIntervalSinceReferenceDate: 10), Date(timeIntervalSinceReferenceDate: 20)]
for s in dates { for e in dates { for ds in dates { for de in dates {
    out.append("distant interval \(seconds(s)) \(seconds(e)) \(seconds(ds)) \(seconds(de)): \(flag(StudyDateInterval.needsDistantQuery(start: s, end: e, askedStart: ds, askedEnd: de)))")
} } } }
for length in 0...4 { for type in 0...11 {
    out.append("distant search \(length) \(type): \(flag(StudySearchRules.queriesDistantNodes(searchLength: length, searchType: type)))")
} }
ALBUM_CASES
let isArchive: (String) -> Bool = { ($0 as NSString).pathExtension.lowercased() == "zip" }
var files: [String] = []
for action in DroppedItemsPlan.actions(forDroppedPaths: DROPPED_LIST, isArchive: isArchive) {
    switch action.item {
    case .wadoManifest: out.append("dropped xml \(action.path)")
    case .wadoURLList: out.append("dropped wado \(action.path)")
    case .archive: out.append("dropped archive \(action.path)")
    case .dicomdir: out.append("dropped dicomdir \(action.path)")
    case .file: files.append(action.path)
    case .folder, .ignore: break
    }
}
out.append("dropped copy " + files.joined(separator: "|"))
for t in URL_LIST {
    // As -asyncWADODownload: reads the list: the URLs up to the first that cannot be made.
    var urls: [String] = []
    for line in DownloadURLList.lines(of: t) {
        guard let url = NSURL(string: line) else { break }
        urls.append(url.absoluteString ?? "")
    }
    out.append("urls \(t.replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "\\r")): \(urls.joined(separator: " ").replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "\\r"))")
}
for status in Int32(-1)...100 {
    out.append("password \(status): \(flag(ArchivePasswordRule.needsPassword(afterStatus: status))) \(flag(ArchivePasswordRule.needsPasswordAgain(afterStatus: status)))")
}
for paths in COPY_LIST { for mode in 0...4 { for enabled in [false, true] { for response in [1, 0, -1] {
    let outside = DatabaseCopyRule.filesOutside(dataDirectory: "/db/DATABASE.noindex", in: paths)
    var decision: Int
    var count = paths.count
    switch DatabaseCopyRule.decision(copyEnabled: enabled, mode: mode, hasFilesOutside: !outside.isEmpty, firstPath: paths[0], isOnCD: { $0.hasPrefix("/cd") }) {
    case .copy: decision = 1
    case .link: decision = 0
    case .askUser:
        switch response { case 1: decision = 1; case -1: decision = 0; default: decision = -1; count = 0 }
    }
    out.append("copy \(paths.joined(separator: ",")) \(mode) \(enabled ? 1 : 0) \(response): \(decision) \(count)")
} } } }
for e in EXT_LIST { for dicom in [false, true] {
    out.append("extension \(e) \(dicom ? 1 : 0): \(DataFileExtension.forImportedFile(pathExtension: e, isDICOM: dicom)) \(DataFileExtension.forLinkedFile(pathExtension: e, isDICOM: dicom))")
} }
for n in stride(from: 0, to: 5000, by: 333) { out.append("estimate \(n): \(RebuildEstimate.seconds(forFileCount: n))") }
out.append(String(format: "refresh %g %g", ImportRefreshSchedule.listInterval, ImportRefreshSchedule.albumsInterval))
print(out.joined(separator: "\n"))
'''


def run(command, env=None):
    done = subprocess.run(command, capture_output=True, text=True, env=env)
    if done.returncode:
        sys.exit('FAIL: %s\n%s%s' % (' '.join(map(str, command[:3])), done.stdout[-3000:], done.stderr[-3000:]))
    return done.stdout


with tempfile.TemporaryDirectory() as tmp:
    folder = Path(tmp)
    tree = folder / 'tree'
    tree.mkdir()
    dropped = build_tree(tree)

    objc_albums = []
    swift_albums = []
    for requested, existing in ALBUMS:
        objc_albums.append('[out addObject: [NSString stringWithFormat: @"album %%@ %%@: %%@ %%@", %s, [%s componentsJoinedByString: @","], [b refAlbumName: %s existing: %s], [b refPatientAlbumName: %s names: %s]]];'
                           % (objc_string(requested), objc_array(existing), objc_string(requested), objc_array(existing), objc_string(requested), objc_array(existing)))
        swift_albums.append('out.append("album \\(%s) \\(%s.joined(separator: ",")): \\(AlbumNaming.uniqueName(for: %s, existing: %s)) \\(AlbumNaming.uniqueName(for: %s, existing: %s))")'
                            % (swift_string(requested), swift_array(existing), swift_string(requested), swift_array(existing), swift_string(requested), swift_array(existing)))

    objc = OBJC
    for key, value in [('DATE_ADDING', date_adding), ('SMART_ALBUM', method(MARK)), ('SWITCH', switch),
                       ('INTERVAL_CONDITION', interval_condition), ('SEARCH_CONDITION', search_condition),
                       ('ALBUM_LOOP', album_loop), ('PATIENT_LOOP', patient_loop),
                       ('ADD_FILES', method('- (void) addFilesAndFolderToDatabase:(NSArray*) filenames')),
                       ('WADO_TRY', wado_try), ('FIRST_PASSWORD', first_password), ('AGAIN_PASSWORD', again_password),
                       ('COPY_DECISION', copy_decision), ('IMPORTED_EXTENSION', imported_extension),
                       ('LINKED_EXTENSION', linked_extension.replace('NSString *extension = [srcPath pathExtension];', 'NSString *extension = [srcPath pathExtension];')),
                       ('ESTIMATE', estimate), ('REFRESH', refresh),
                       ('MOMENTS_ARRAY', '@[%s]' % ', '.join('@%r' % m for m in MOMENTS)),
                       ('FORMATS_ARRAY', objc_array(FORMATS)), ('TAGS_ARRAY', '@[%s]' % ', '.join('@(%d)' % t for t in TAGS)),
                       ('ALBUM_CASES', '\n'.join(objc_albums)), ('DROPPED_ARRAY', objc_array(dropped)),
                       ('URL_ARRAY', objc_array(URL_TEXTS)),
                       ('COPY_ARRAY', '@[%s]' % ', '.join(objc_array(p) for p in COPY_PATHS)),
                       ('EXT_ARRAY', objc_array(EXTENSIONS))]:
        objc = objc.replace(key, value)
    swift = SWIFT
    for key, value in [('MOMENTS_LIST', repr(MOMENTS)), ('FORMATS_LIST', swift_array(FORMATS)), ('TAGS_LIST', repr(TAGS)),
                       ('ALBUM_CASES', '\n'.join(swift_albums)), ('DROPPED_LIST', swift_array(dropped)),
                       ('URL_LIST', swift_array(URL_TEXTS)), ('COPY_LIST', '[%s]' % ', '.join(swift_array(p) for p in COPY_PATHS)),
                       ('EXT_LIST', swift_array(EXTENSIONS))]:
        swift = swift.replace(key, value)

    # DCMCalendarDate as the reference compiled it, without the rest of the DICOM framework.
    for name in ('DCMCalendarDate.h', 'DCMCalendarDate.m'):
        (folder / name).write_bytes(reference_bytes('DCM Framework/' + name))
    (folder / 'DCM.h').write_text('#import <Foundation/Foundation.h>\n#define DCMDEBUG 0\n')
    (folder / 'reference.m').write_text(objc)
    run(['xcrun', 'clang', '-fno-objc-arc', '-fblocks', '-w', '-I', str(folder), str(folder / 'reference.m'),
         str(folder / 'DCMCalendarDate.m'), '-framework', 'Cocoa', '-o', str(folder / 'reference')])
    (folder / 'main.swift').write_text(swift)
    # The modules it depends on (IsiXLogging, which its log goes through).
    below = [flag for name in isix_modules.dependencies('IsiXDatabase')
             for flag in isix_modules.module_flags(name, folder / 'modules')]
    run(['xcrun', 'swiftc', '-swift-version', '6', '-module-name', 'Check', *below, str(folder / 'main.swift'),
         *map(str, sorted(MODULE.glob('*.swift'))), '-o', str(folder / 'current')])

    failures = []
    for zone in ('Europe/Paris', 'America/Sao_Paulo', 'Asia/Kolkata'):
        env = dict(os.environ, TZ=zone)
        objc_lines = run([str(folder / 'reference')], env).splitlines()
        swift_lines = run([str(folder / 'current')], env).splitlines()
        if args.dump:
            args.dump.mkdir(parents=True, exist_ok=True)
            (args.dump / ('reference-%s.txt' % zone.replace('/', '-'))).write_text('\n'.join(objc_lines) + '\n')
            (args.dump / ('current-%s.txt' % zone.replace('/', '-'))).write_text('\n'.join(swift_lines) + '\n')
        # The one intended change: the list found in a folder, not the folder.
        folder_list = dropped[0] + '/list.dcmURLs'
        expected = ['dropped wado ' + dropped[0]]
        if expected[0] not in objc_lines:
            failures.append('%s: the reference no longer hands the folder to the download; check the intended change' % zone)
        objc_lines = ['dropped wado ' + folder_list if line == expected[0] else line for line in objc_lines]
        if objc_lines != swift_lines:
            diff = list(difflib.unified_diff(objc_lines, swift_lines, 'Objective-C (%s)' % reference, 'IsiXDatabase', lineterm='', n=0))
            failures.append('%s: %d differences\n%s' % (zone, len(diff), '\n'.join(diff[:60])))
        counts = {}
        for line in objc_lines:
            counts[line.split(' ')[0]] = counts.get(line.split(' ')[0], 0) + 1
    if failures:
        print('FAIL:\n' + '\n'.join(failures))
        sys.exit(1)
    print('ok: the database, album and search rules of %s and IsiXDatabase agree on %d records in 3 time zones (%s)'
          % (reference, len(swift_lines), ', '.join('%s %d' % kv for kv in sorted(counts.items()))))
