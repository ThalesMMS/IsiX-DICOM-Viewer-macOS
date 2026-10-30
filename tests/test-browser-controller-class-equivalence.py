#!/usr/bin/env python3
"""BrowserController's own methods decide what their Objective-C did.

The class moved to Swift (BrowserController.swift and its extensions), with
the rules that need neither AppKit nor the database in IsiXDatabase
(BrowserLayoutRules.swift) and IsiXImaging (ParallelImageConversion.swift).
This compiles the Objective-C of the class's own methods, cut out of
BrowserController.m in the last revision that has it (history_reference; the
tree itself while it still has it), against stand-ins for the views and the
preferences, and the Swift as it stands (the same methods, cut out of
BrowserController+Layout.swift, +ClassState.swift and +Compatibility.swift)
with the modules, against stand-ins with the same members. Both write
records of the same cases:

* -fontSize: of every kind of text, and of an unknown one, for the sizes
  -1, 0, 1 and an unknown size, with the stack trace it logs;
* -setTableViewRowHeight: the heights each list is given and the
  thumbnails' cell size, beside the thumbnails and above them;
* +DefaultFolderSizeForDB: the size read, saved when there is none, and kept;
* +tryLock:during:, for no lock, free locks, a lock another thread holds and
  a recursive lock this thread holds;
* +multiThreadedImageConvert:::::, float to 16-bit and back, of images whose
  height does and does not divide by the processors, and an unknown kind;
* -[NSString filenameString], with the file name rules standing in.

    python3 tests/test-browser-controller-class-equivalence.py [--reference REV]
"""
import argparse
import difflib
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import private_tmpdir  # noqa: F401,E402
import history_reference  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
BC = 'Horos/Sources/BrowserController.m'
MARK = '- (float) fontSize: (NSString*) type'
SOURCES = ROOT / 'Horos/Sources'
MODULES = [ROOT / 'Modules/IsiXDatabase/Sources/BrowserLayoutRules.swift',
           ROOT / 'Modules/IsiXImaging/Sources/BufferOperations/ParallelImageConversion.swift']

parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
parser.add_argument('--reference')
parser.add_argument('--dump', type=Path, help='write both programs and their records to this folder')
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
        reference = history_reference.before_removal(BC)
if reference is None:
    print('skipped: needs the history that has BrowserController.m')
    sys.exit(2)
if reference == 'tree':
    text = (ROOT / BC).read_bytes().decode('latin1')
else:
    shown = git('show', '%s:%s' % (reference, BC))
    if shown.returncode:
        sys.exit('FAIL: no %s at %s' % (BC, reference))
    text = shown.stdout.decode('latin1')
if MARK not in text:
    sys.exit('FAIL: %s has no Objective-C -fontSize: in %s' % (reference, BC))
for module in MODULES:
    if not module.exists():
        sys.exit('FAIL: no %s' % module.relative_to(ROOT))


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


def swift_function(name, signature):
    """A function or property of a Swift file, from its attributes to its closing brace."""
    source = (SOURCES / name).read_text()
    at = source.index(signature)
    line = source.rindex('\n', 0, at) + 1
    while True:
        previous = source.rindex('\n', 0, line - 1) + 1
        if source[previous:line].strip().startswith('@') or source[previous:line].strip().startswith('///'):
            line = previous
        else:
            break
    return source[line:matching(source, source.index('{', at))]


def objc(code):
    code = code.replace('[NSUserDefaults standardUserDefaults]', 'testDefaults')
    return code


# --- the Objective-C ---------------------------------------------------------------
font_size = objc(method(MARK))
row_height = objc(method('- (void) setTableViewRowHeight'))
folder_size = objc(method('+ (int) DefaultFolderSizeForDB'))
try_lock = method('+ (BOOL) tryLock:(id) c during:(NSTimeInterval) sec')
image_thread = method('- (void) vImageThread: (NSDictionary*) d')
image_convert = method('+ (void) multiThreadedImageConvert: (NSString*) what :(vImage_Buffer*) src :(vImage_Buffer *) dst :(float) offset :(float) scale')
image_thread = image_thread.replace('else NSLog( @"****** unknown vImageThread what: %@", [d objectForKey: @"what"]);',
                                    'else Unknown();')
filename = method('-(NSMutableString*)filenameString')
for name, code in (('fontSize:', font_size), ('setTableViewRowHeight', row_height), ('DefaultFolderSizeForDB', folder_size)):
    if 'NSUserDefaults' in code:
        sys.exit('FAIL: the Objective-C %s changed: cannot stand in for what it reads' % name)
if 'Unknown();' not in image_thread:
    sys.exit('FAIL: the Objective-C vImageThread: changed: cannot count its unknown kinds')

OBJC = r'''
#import <Cocoa/Cocoa.h>
#include <Accelerate/Accelerate.h>
#include <stdatomic.h>
#include <pthread.h>

static NSMutableArray *records;
static NSMutableDictionary *testDefaultsValues;
static atomic_int unknownCount;
static void Rec(NSString *format, ...) {
    va_list list; va_start(list, format);
    [records addObject: [[[NSString alloc] initWithFormat: format arguments: list] autorelease]];
    va_end(list);
}
static void Unknown(void) { atomic_fetch_add(&unknownCount, 1); }
#define N2LogStackTrace(format, ...) Rec(@"logged " format, ##__VA_ARGS__)

@interface TestDefaults : NSObject
@end
@implementation TestDefaults
- (NSInteger) integerForKey: (NSString*) key { return [[testDefaultsValues objectForKey: key] integerValue]; }
- (void) setInteger: (NSInteger) value forKey: (NSString*) key { Rec(@"saved %@ %ld", key, (long) value); [testDefaultsValues setObject: @(value) forKey: key]; }
@end
static TestDefaults *testDefaults;

@interface Recorder : NSObject { NSString *name; }
@end
@implementation Recorder
- (id) initWithName: (NSString*) n { if ((self = [super init])) name = [n retain]; return self; }
- (void) setRowHeight: (CGFloat) h { Rec(@"%@ rowHeight %.3f", name, (double) h); }
- (void) setCellSize: (NSSize) s { Rec(@"%@ cellSize %.3f %.3f", name, (double) s.width, (double) s.height); }
@end

@interface NSString (TestFileNames)
- (NSString*) ASCIIString;
@end
@implementation NSString (TestFileNames)
- (NSString*) ASCIIString {
    NSData *data = [self dataUsingEncoding: NSASCIIStringEncoding allowLossyConversion: YES];
    return [[[NSString alloc] initWithData: data encoding: NSASCIIStringEncoding] autorelease];
}
@end

@interface BrowserController : NSObject {
    id albumTable, _sourcesTableView, databaseOutline, comparativeTable, _activityTableView, oMatrix;
}
@end
static BrowserController *browserWindow = nil;
static BOOL gHorizontalHistory = NO;
static int DefaultFolderSizeForDB = 0;
static NSConditionLock *threadLock = nil;

@implementation BrowserController
- (id) init {
    if ((self = [super init])) {
        albumTable = [[Recorder alloc] initWithName: @"albums"];
        _sourcesTableView = [[Recorder alloc] initWithName: @"sources"];
        databaseOutline = [[Recorder alloc] initWithName: @"studyList"];
        comparativeTable = [[Recorder alloc] initWithName: @"history"];
        _activityTableView = [[Recorder alloc] initWithName: @"activity"];
        oMatrix = [[Recorder alloc] initWithName: @"thumbnails"];
    }
    return self;
}
+ (NSMutableString*) replaceNotAdmitted: (NSString*) name {
    NSMutableString *s = [NSMutableString string];
    for (NSUInteger i = 0; i < name.length; i++) {
        unichar c = [name characterAtIndex: i];
        [s appendString: (isalnum(c) ? [NSString stringWithCharacters: &c length: 1] : @"_")];
    }
    while ([s hasPrefix: @"_"]) [s deleteCharactersInRange: NSMakeRange(0, 1)];
    return s;
}
@@FONTSIZE@@
@@ROWHEIGHT@@
@@FOLDERSIZE@@
@@TRYLOCK@@
@@THREAD@@
@@CONVERT@@
@end

@implementation NSString (BrowserController)
@@FILENAME@@
@end

static float TestFontSize(BrowserController *b, NSString *kind) { return [b fontSize: kind]; }
static void TestRowHeights(BrowserController *b, BOOL horizontal) { gHorizontalHistory = horizontal; [b setTableViewRowHeight]; }
static int TestFolderSize(void) { return [BrowserController DefaultFolderSizeForDB]; }
static void TestResetFolderSize(void) { DefaultFolderSizeForDB = 0; }
static BOOL TestTryLock(id lock, NSTimeInterval sec) { return [BrowserController tryLock: lock during: sec]; }
static void TestConvert(NSString *what, vImage_Buffer *src, vImage_Buffer *dst, float offset, float scale) {
    [BrowserController multiThreadedImageConvert: what : src : dst : offset : scale];
}
static NSString *TestFilename(NSString *s) { return [s filenameString]; }

#include "driver.h"

int main(int argc, char **argv) {
    @autoreleasepool {
        records = [NSMutableArray array];
        testDefaultsValues = [NSMutableDictionary dictionary];
        testDefaults = [[TestDefaults alloc] init];
        BrowserController *b = [[BrowserController alloc] init];
        browserWindow = b;
        RunCases(b);
        for (NSString *line in records) printf("%s\n", line.UTF8String);
    }
    return 0;
}
'''
OBJC = (OBJC.replace('@@FONTSIZE@@', font_size).replace('@@ROWHEIGHT@@', row_height).replace('@@FOLDERSIZE@@', folder_size)
        .replace('@@TRYLOCK@@', try_lock).replace('@@THREAD@@', image_thread).replace('@@CONVERT@@', image_convert)
        .replace('@@FILENAME@@', filename))

# The cases, in C, for the Objective-C; the Swift driver below makes the same.
DRIVER = r'''
static NSArray *Kinds(void) {
    return @[@"threadNameSize", @"threadNameStatus", @"comparativeLineSpace", @"threadCellLineSpace", @"dbFont",
             @"dbComparativeFont", @"dbAlbumFont", @"dbSourceFont", @"dbSeriesFont", @"dbMatrixFont", @"dbSmallMatrixFont",
             @"viewerSmallCellFont", @"viewerNumberFont", @"dbFontSize"];
}

static unsigned long long Checksum(vImage_Buffer *b) {
    unsigned long long sum = 1469598103934665603ULL;
    for (size_t y = 0; y < b->height; y++) {
        const unsigned char *row = (const unsigned char*) b->data + y * b->rowBytes;
        for (size_t x = 0; x < b->rowBytes; x++) { sum ^= row[x]; sum *= 1099511628211ULL; }
    }
    return sum;
}

static void *LockHolder(void *lock) {
    [(NSLock*) lock lock];
    usleep(300000);
    [(NSLock*) lock unlock];
    return NULL;
}

static void RunCases(BrowserController *b) {
    for (NSNumber *mode in @[@-1, @0, @1, @2]) {
        [testDefaultsValues setObject: mode forKey: @"dbFontSize"];
        for (NSString *kind in Kinds())
            Rec(@"fontSize %@ %@ %.3f", mode, kind, (double) TestFontSize(b, kind));
        for (NSNumber *horizontal in @[@NO, @YES]) {
            Rec(@"rows %@ %@", mode, horizontal);
            TestRowHeights(b, horizontal.boolValue);
        }
    }

    for (NSNumber *saved in @[@0, @5000, @-3]) {
        TestResetFolderSize();
        [testDefaultsValues setObject: saved forKey: @"DefaultFolderSizeForDB"];
        Rec(@"folder %@ %d", saved, TestFolderSize());
        [testDefaultsValues setObject: @777 forKey: @"DefaultFolderSizeForDB"];
        Rec(@"folder again %d", TestFolderSize());
    }

    Rec(@"tryLock nil %d", TestTryLock(nil, 0.01));
    NSLock *freeLock = [[NSLock alloc] init];
    Rec(@"tryLock free %d then %d", TestTryLock(freeLock, 0.01), [freeLock tryLock]);
    [freeLock unlock];
    NSConditionLock *condition = [[NSConditionLock alloc] initWithCondition: 3];
    Rec(@"tryLock condition %d then %d", TestTryLock(condition, 0.01), [condition tryLock]);
    [condition unlock];
    NSRecursiveLock *recursive = [[NSRecursiveLock alloc] init];
    [recursive lock];
    Rec(@"tryLock recursive held here %d", TestTryLock(recursive, 0.01));
    [recursive unlock];
    NSLock *held = [[NSLock alloc] init];
    pthread_t thread;
    pthread_create(&thread, NULL, LockHolder, held);
    usleep(50000);
    Rec(@"tryLock held elsewhere %d", TestTryLock(held, 0.02));
    pthread_join(thread, NULL);
    Rec(@"tryLock released %d", TestTryLock(held, 0.02));

    unsigned int seed = 20261027;
    int sizes[][2] = {{37, 53}, {64, 64}, {5, 3}, {101, 1}};
    for (int s = 0; s < 4; s++) {
        int w = sizes[s][0], h = sizes[s][1];
        float *f = malloc(sizeof(float) * w * h), *back = malloc(sizeof(float) * w * h);
        unsigned short *u = calloc(w * h, sizeof(unsigned short));
        for (int i = 0; i < w * h; i++) { seed = seed * 1103515245 + 12345; f[i] = (float) ((seed >> 8) % 70000) - 1024.f + (float) (seed % 7) / 8.f; }
        vImage_Buffer src = {f, h, w, w * sizeof(float)}, dst = {u, h, w, w * sizeof(unsigned short)};
        vImage_Buffer src16 = {u, h, w, w * sizeof(unsigned short)}, dstf = {back, h, w, w * sizeof(float)};
        TestConvert(@"FTo16U", &src, &dst, 1024.f, 1.f / 1.5f);
        Rec(@"convert FTo16U %dx%d %llu", w, h, Checksum(&dst));
        TestConvert(@"16UToF", &src16, &dstf, -1024.f, 1.5f);
        Rec(@"convert 16UToF %dx%d %llu", w, h, Checksum(&dstf));
        atomic_store(&unknownCount, 0);
        unsigned long long before = Checksum(&dst);
        TestConvert(@"bogus", &src, &dst, 0.f, 1.f);
        Rec(@"convert bogus %dx%d unchanged %d unknown %d", w, h, before == Checksum(&dst),
            atomic_load(&unknownCount) == (int) [[NSProcessInfo processInfo] processorCount]);
        free(f); free(back); free(u);
    }

    for (NSString *name in @[@"Durer Unicode", @"Dürer Ünicode", @"", @"///", @"ABC D", @"..x", @"日本"])
        Rec(@"filename [%@] [%@]", name, TestFilename(name));
}
'''

# --- the Swift ---------------------------------------------------------------------
font_size_swift = swift_function('BrowserController+Layout.swift', 'nonisolated static func fontSize(of kind: BrowserFontKind?, named name: String?) -> Float {')
font_size_objc_entry = swift_function('BrowserController+Layout.swift', 'public nonisolated func fontSize(_ type: String!) -> Float {')
row_height_swift = swift_function('BrowserController+Layout.swift', 'public func setTableViewRowHeight() {')
convert_swift = swift_function('BrowserController+Layout.swift', 'public nonisolated class func multiThreadedImageConvert(')
folder_swift = swift_function('BrowserController+ClassState.swift', 'public nonisolated class func defaultFolderSizeForDB() -> Int32 {')
try_lock_swift = swift_function('BrowserController+ClassState.swift', 'public nonisolated class func tryLock(_ c: Any!, during sec: TimeInterval) -> Bool {')
filename_swift = swift_function('BrowserController+Compatibility.swift', 'public func filenameString() -> NSMutableString {')


def swift_common(code):
    code = code.replace('UserDefaults.standard', 'TestDefaults.shared')
    code = code.replace('NSLog("****** unknown vImageThread what: %@", what ?? "(null)")', 'TestUnknown.add()')
    return code


members = '\n'.join(swift_common(c) for c in (font_size_objc_entry, font_size_swift, row_height_swift, convert_swift,
                                               folder_swift, try_lock_swift))
if 'UserDefaults' in members.replace('TestDefaults', ''):
    sys.exit('FAIL: the Swift reads other preferences: cannot stand in for them')
if 'TestUnknown.add()' not in members:
    sys.exit('FAIL: the Swift multiThreadedImageConvert changed: cannot count its unknown kinds')

SWIFT = r'''
import Accelerate
import AppKit

nonisolated(unsafe) var records: [String] = []
func rec(_ s: String) { records.append(s) }
func f3(_ v: Double) -> String { String(format: "%.3f", v) }

enum TestUnknown {
    nonisolated(unsafe) static var count = 0
    static let lock = NSLock()
    static func add() { lock.lock(); count += 1; lock.unlock() }
}

final class TestDefaults: @unchecked Sendable {
    nonisolated(unsafe) static let shared = TestDefaults()
    var values: [String: Int] = [:]
    func integer(forKey key: String) -> Int { values[key] ?? 0 }
    func set(_ value: Int, forKey key: String) { rec("saved \(key) \(value)"); values[key] = value }
}

enum BrowserObjC {
    static func logStackTrace(_ message: String) { rec("logged " + message) }
}

final class Recorder {
    let name: String
    init(_ name: String) { self.name = name }
    var rowHeight: CGFloat { get { 0 } set { rec("\(name) rowHeight \(f3(Double(newValue)))") } }
    var cellSize: NSSize { get { .zero } set { rec("\(name) cellSize \(f3(Double(newValue.width))) \(f3(Double(newValue.height)))") } }
}

final class WindowOutlets: @unchecked Sendable {
    let albumTable: Recorder? = Recorder("albums")
    let sourcesTableView: Recorder? = Recorder("sources")
    let databaseOutline: Recorder? = Recorder("studyList")
    let comparativeTable: Recorder? = Recorder("history")
    let activityTableView: Recorder? = Recorder("activity")
    let oMatrix: Recorder? = Recorder("thumbnails")
}

enum BrowserClassState {
    nonisolated(unsafe) static var horizontalHistory = false
    nonisolated(unsafe) static var defaultFolderSizeForDB: Int32 = 0
}

final class BrowserController: NSObject, @unchecked Sendable {
    let windowOutlets = WindowOutlets()

    class func replaceNotAdmitted(_ name: NSString!) -> NSMutableString! {
        let s = NSMutableString()
        for i in 0..<name.length {
            let c = name.character(at: i)
            s.append(c < 128 && isalnum(Int32(c)) != 0 ? String(utf16CodeUnits: [c], count: 1) : "_")
        }
        while s.hasPrefix("_") { s.deleteCharacters(in: NSRange(location: 0, length: 1)) }
        return s
    }

@@MEMBERS@@
}

extension NSString {
    @objc func ASCIIString() -> NSString? {
        guard let data = self.data(using: String.Encoding.ascii.rawValue, allowLossyConversion: true) else { return nil }
        return NSString(data: data, encoding: String.Encoding.ascii.rawValue)
    }

@@FILENAME@@
}

func checksum(_ b: vImage_Buffer) -> UInt64 {
    var sum: UInt64 = 1469598103934665603
    for y in 0..<Int(b.height) {
        let row = b.data!.advanced(by: y * b.rowBytes).assumingMemoryBound(to: UInt8.self)
        for x in 0..<b.rowBytes { sum ^= UInt64(row[x]); sum = sum &* 1099511628211 }
    }
    return sum
}

@main
struct Main {
    static func main() {
        let b = BrowserController()
        let kinds = ["threadNameSize", "threadNameStatus", "comparativeLineSpace", "threadCellLineSpace", "dbFont",
                     "dbComparativeFont", "dbAlbumFont", "dbSourceFont", "dbSeriesFont", "dbMatrixFont", "dbSmallMatrixFont",
                     "viewerSmallCellFont", "viewerNumberFont", "dbFontSize"]
        for mode in [-1, 0, 1, 2] {
            TestDefaults.shared.values["dbFontSize"] = mode
            for kind in kinds { rec("fontSize \(mode) \(kind) \(f3(Double(b.fontSize(kind))))") }
            for horizontal in [false, true] {
                rec("rows \(mode) \(horizontal ? 1 : 0)")
                BrowserClassState.horizontalHistory = horizontal
                b.setTableViewRowHeight()
            }
        }

        for saved in [0, 5000, -3] {
            BrowserClassState.defaultFolderSizeForDB = 0
            TestDefaults.shared.values["DefaultFolderSizeForDB"] = saved
            rec("folder \(saved) \(BrowserController.defaultFolderSizeForDB())")
            TestDefaults.shared.values["DefaultFolderSizeForDB"] = 777
            rec("folder again \(BrowserController.defaultFolderSizeForDB())")
        }

        rec("tryLock nil \(BrowserController.tryLock(nil, during: 0.01) ? 1 : 0)")
        let freeLock = NSLock()
        rec("tryLock free \(BrowserController.tryLock(freeLock, during: 0.01) ? 1 : 0) then \(freeLock.try() ? 1 : 0)")
        freeLock.unlock()
        let condition = NSConditionLock(condition: 3)
        rec("tryLock condition \(BrowserController.tryLock(condition, during: 0.01) ? 1 : 0) then \(condition.try() ? 1 : 0)")
        condition.unlock()
        let recursive = NSRecursiveLock()
        recursive.lock()
        rec("tryLock recursive held here \(BrowserController.tryLock(recursive, during: 0.01) ? 1 : 0)")
        recursive.unlock()
        let held = NSLock()
        let holder = Thread { held.lock(); usleep(300000); held.unlock() }
        holder.start()
        usleep(50000)
        rec("tryLock held elsewhere \(BrowserController.tryLock(held, during: 0.02) ? 1 : 0)")
        while holder.isExecuting || !holder.isFinished { usleep(10000) }
        rec("tryLock released \(BrowserController.tryLock(held, during: 0.02) ? 1 : 0)")

        var seed: UInt32 = 20261027
        for (w, h) in [(37, 53), (64, 64), (5, 3), (101, 1)] {
            let f = UnsafeMutablePointer<Float>.allocate(capacity: w * h)
            let back = UnsafeMutablePointer<Float>.allocate(capacity: w * h)
            let u = UnsafeMutablePointer<UInt16>.allocate(capacity: w * h)
            u.initialize(repeating: 0, count: w * h)
            for i in 0..<(w * h) {
                seed = seed &* 1103515245 &+ 12345
                f[i] = Float((seed >> 8) % 70000) - 1024 + Float(seed % 7) / 8
            }
            var src = vImage_Buffer(data: f, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 4)
            var dst = vImage_Buffer(data: u, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 2)
            var src16 = vImage_Buffer(data: u, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 2)
            var dstf = vImage_Buffer(data: back, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 4)
            BrowserController.multiThreadedImageConvert("FTo16U", &src, &dst, 1024, 1 / 1.5)
            rec("convert FTo16U \(w)x\(h) \(checksum(dst))")
            BrowserController.multiThreadedImageConvert("16UToF", &src16, &dstf, -1024, 1.5)
            rec("convert 16UToF \(w)x\(h) \(checksum(dstf))")
            TestUnknown.count = 0
            let before = checksum(dst)
            BrowserController.multiThreadedImageConvert("bogus", &src, &dst, 0, 1)
            rec("convert bogus \(w)x\(h) unchanged \(before == checksum(dst) ? 1 : 0) unknown \(TestUnknown.count == ProcessInfo.processInfo.processorCount ? 1 : 0)")
            f.deallocate(); back.deallocate(); u.deallocate()
        }

        for name in ["Durer Unicode", "D\u{00fc}rer \u{00dc}nicode", "", "///", "ABC D", "..x", "\u{65e5}\u{672c}"] {
            rec("filename [\(name)] [\((name as NSString).filenameString())]")
        }
        for line in records { print(line) }
    }
}
'''
SWIFT = SWIFT.replace('@@MEMBERS@@', members).replace('@@FILENAME@@', filename_swift)
# The stand-ins are not actors' classes: the app's isolation words do not apply.
SWIFT = SWIFT.replace('public nonisolated ', '').replace('nonisolated static ', 'static ').replace('public func', 'func')

failures = []
with tempfile.TemporaryDirectory(prefix='horos-browser-class-') as tmp:
    tmp = Path(tmp)
    (tmp / 'reference.m').write_text(OBJC)
    (tmp / 'driver.h').write_text(DRIVER)
    (tmp / 'main.swift').write_text(SWIFT)
    modules = []
    for module in MODULES:
        target = tmp / module.name
        target.write_text(module.read_text())
        modules.append(str(target))
    if args.dump:
        args.dump.mkdir(parents=True, exist_ok=True)
        for name in ('reference.m', 'driver.h', 'main.swift'):
            (args.dump / name).write_bytes((tmp / name).read_bytes())
    built = subprocess.run(['xcrun', 'clang', '-fno-objc-arc', '-fblocks', '-w', '-framework', 'Cocoa', '-framework', 'Accelerate',
                            '-I', str(tmp), str(tmp / 'reference.m'), '-o', str(tmp / 'reference')],
                           capture_output=True, text=True, timeout=300)
    if built.returncode:
        sys.exit('FAIL: the Objective-C reference does not compile:\n' + built.stderr[-3000:])
    built = subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '6', '-o', str(tmp / 'current'),
                            *modules, str(tmp / 'main.swift')], capture_output=True, text=True, timeout=300)
    if built.returncode:
        sys.exit('FAIL: the Swift does not compile:\n' + built.stderr[-3000:])
    objc_run = subprocess.run([str(tmp / 'reference')], capture_output=True, timeout=60)
    swift_run = subprocess.run([str(tmp / 'current')], capture_output=True, timeout=60)
    if objc_run.returncode or swift_run.returncode:
        sys.exit('FAIL: a driver failed (%d, %d):\n' % (objc_run.returncode, swift_run.returncode)
                 + objc_run.stderr[-1500:].decode('utf-8', 'replace') + swift_run.stderr[-1500:].decode('utf-8', 'replace'))
    a = objc_run.stdout.decode('utf-8').split('\n')
    b = swift_run.stdout.decode('utf-8').split('\n')
    if args.dump:
        (args.dump / 'reference.txt').write_bytes(objc_run.stdout)
        (args.dump / 'current.txt').write_bytes(swift_run.stdout)
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
print('ok: the class methods of %s and the Swift agree on %d records (%s)'
      % (reference, sum(kinds.values()), ', '.join('%s %d' % kv for kv in sorted(kinds.items()))))
