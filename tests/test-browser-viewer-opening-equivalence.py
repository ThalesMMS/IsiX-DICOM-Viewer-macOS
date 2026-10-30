#!/usr/bin/env python3
"""The browser's viewer-opening rules decide what their Objective-C did.

Opening 2D and 4D viewers moved from BrowserController.m to Swift, with its
rules in the IsiXImaging module (ViewerOpening/ViewerOpeningRules.swift).
This compiles the Objective-C of those rules, cut out of BrowserController.m
in the last revision that has it (history_reference; the tree itself while it
still has it), and the module with swiftc, gives both the same synthetic
inputs and compares what they produce:

* HorosAccumulateImageMemory (pixel and padded counts, minimum image size,
  overflow);
* -computeEnoughMemory:: (enough or not, megabytes), with allocations that
  fail above a chosen size;
* the memory step of -openViewerFromImages:… (blocks, total, sampling, the
  images kept, which series get their opening date, cache purges, the
  alerts), with the same failing allocations;
* the cut of one series for the 4D player and for "Reparsed Series", on
  repeated passes, direction changes, uneven steps and comment values;
* what the 4D player accepts, and when a cut is 4D;
* the images the sub-series sheet keeps (-produceNewArray:);
* the rows and columns kept from "LastWindowsTilingRowsColumns".

    python3 tests/test-browser-viewer-opening-equivalence.py [--reference REV]
"""
import argparse
import difflib
import plistlib
import random
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import private_tmpdir  # noqa: F401,E402
import history_reference  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
BC = 'Horos/Sources/BrowserController.m'
MARK = '- (BOOL)computeEnoughMemory: (NSArray*)toOpenArray :(unsigned long*)requiredMem'
RULES = ROOT / 'Modules/IsiXImaging/Sources/ViewerOpening/ViewerOpeningRules.swift'

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
    print('skipped: needs the history that has the Objective-C viewer opening of BrowserController.m')
    sys.exit(2)
if reference == 'tree':
    text = (ROOT / BC).read_bytes().decode('latin1')
else:
    shown = git('show', '%s:%s' % (reference, BC))
    if shown.returncode:
        sys.exit('FAIL: no %s at %s' % (BC, reference))
    text = shown.stdout.decode('latin1')
if MARK not in text:
    sys.exit('FAIL: %s has no Objective-C -computeEnoughMemory:: in %s' % (reference, BC))
if not RULES.exists():
    sys.exit('FAIL: no ViewerOpeningRules.swift in IsiXImaging')


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


accumulate = method('static BOOL HorosAccumulateImageMemory(')
enough = method(MARK)
opening = method('- (ViewerController*) openViewerFromImages:(NSArray*) toOpenArray movie:(BOOL) movieViewer viewer:(ViewerController*) viewer keyImagesOnly:(BOOL) keyImages tryToFlipData:(BOOL) tryToFlipData')
memory_pass = between('        BOOL	enoughMemory = NO;', '        int result = HorosAlertDefaultResponse;', opening)
process = method('- (void) processOpenViewerDICOMFromArray:(NSArray*) toOpenArray movie:(BOOL) movieViewer viewer: (ViewerController*) viewer')
movie_split = between('        if( [toOpenArray count] == 1)	// Just one thumbnail is selected, check if multiples lines are selected',
                      '        if( [toOpenArray count] == 1)\n        {\n            HorosRunCriticalAlertPanel', process)
movie_check = between('        if( [toOpenArray count] == 1)\n        {\n            HorosRunCriticalAlertPanel',
                      '\n    }\n    else\n    {\n        tryToFlipData = YES;', process)
reparse_split = between('                NSArray			*singleSeries = [[toOpenArray objectAtIndex: 0] sortedArrayUsingDescriptors:',
                        '                if( [splittedSeries count] > 1)', process)
four_d = between('                    BOOL areData4D = YES;', '                    for( int i = 0 ; i < [splittedSeries count]; i++)', process)
produce = method('- (NSArray*)produceNewArray: (NSArray*)toOpenArray')
tiling = between('                NSDictionary *d = nil;', '                [[AppController sharedAppController] tileWindows: d];', opening)
tiling = tiling.replace('[[NSUserDefaults standardUserDefaults] stringForKey: @"LastWindowsTilingRowsColumns"]', 'storedValue')

OBJC = r'''
#import <Foundation/Foundation.h>
#include <limits.h>
#include <stdint.h>
#define MAX4D 8
#define N2LogException(e) ((void)0)
#define N2LogExceptionWithStackTrace(e) ((void)0)
enum { HorosAlertDefaultResponse = 1, HorosAlertAlternateResponse = 0 };
static NSMutableArray *records, *alerts, *visits;
static NSUInteger allocationLimit, purges;
static void record(NSString *format, ...) {
    va_list list; va_start(list, format);
    [records addObject:[[[NSString alloc] initWithFormat:format arguments:list] autorelease]];
    va_end(list);
}
static int alertPanel(NSString *title, NSString *format, ...) {
    va_list list; va_start(list, format);
    [alerts addObject:[[[NSString alloc] initWithFormat:format arguments:list] autorelease]];
    va_end(list);
    return HorosAlertDefaultResponse;
}
#define HorosRunInformationalAlertPanel(title, format, b1, b2, b3, ...) alertPanel(title, format, ##__VA_ARGS__)
#define HorosRunCriticalAlertPanel(title, format, b1, b2, b3, ...) alertPanel(title, format, ##__VA_ARGS__)
// An allocation above the limit fails; one under it is real but small: the
// probes are never written.
static void *probeAllocation(size_t size) { return size > allocationLimit ? NULL : malloc(1); }
@interface NSThread (Status)
- (void)enterOperation;
- (void)exitOperation;
@property(copy) NSString *status;
@property double progress;
@end
@implementation NSThread (Status)
- (void)enterOperation { record(@"enter"); }
- (void)exitOperation { record(@"exit"); }
- (void)setStatus:(NSString *)status {}
- (NSString *)status { return @""; }
- (void)setProgress:(double)progress {}
- (double)progress { return 0; }
@end
@interface DCMView : NSObject @end
@implementation DCMView
+ (void)purgeStringTextureCache { purges++; }
@end
// An image of the database: its values, and the series whose opening date it sets.
@interface Item : NSObject {
@public
    NSDictionary *values; NSString *tag;
}
@end
@implementation Item
- (id)valueForKey:(NSString *)key {
    if ([key isEqual:@"series"] || [key isEqual:@"study"]) return self;
    if ([key isEqual:@"tag"]) return tag;
    // An attribute the image does not have reads as nil, as in the database.
    return values[key];
}
- (void)setValue:(id)value forKey:(NSString *)key {
    if ([key isEqual:@"dateOpened"]) [visits addObject:tag];
}
- (id)series { return self; }
- (NSArray *)sortDescriptorsForImages { return @[]; }
@end
typedef Item DicomImage;
typedef Item NSManagedObject;
@interface DCMPix : NSObject
- (void)kill8bitsImage;
- (void)revert:(BOOL)value;
@end
@implementation DCMPix
- (void)kill8bitsImage {}
- (void)revert:(BOOL)value {}
@end
@interface Opener : NSObject {
@public
    NSArray *previewPix; id previewPixThumbnails;
    int subFrom, subTo, subInterval;
    id supOpenButtons;
}
@end
#define malloc(size) probeAllocation(size)
@@ACCUMULATE@@
@implementation Opener
@@ENOUGH@@
@@PRODUCE@@
- (NSArray *)memoryPass:(NSArray *)toOpenArray blocks:(unsigned long *)memBlockSize {
    BOOL multiFrame = NO;
@@MEMORY_PASS@@
    NSMutableArray *kept = [NSMutableArray array];
    for (NSArray *list in toOpenArray) [kept addObject:[[list valueForKey:@"tag"] componentsJoinedByString:@","]];
    NSMutableArray *blocks = [NSMutableArray array];
    for (NSUInteger x = 0; x < toOpenArray.count; x++) [blocks addObject:@(memBlockSize[x])];
    record(@"plan: lists [%@] blocks %@ total %lu sampling %ld multiframe %d", [kept componentsJoinedByString:@"|"],
           [blocks componentsJoinedByString:@","], mem, subSampling, multiFrame);
    return toOpenArray;
}
- (NSArray *)movieSplit:(NSArray *)toOpenArray {
@@MOVIE_SPLIT@@
    return toOpenArray;
}
- (BOOL)movieCheck:(NSArray *)toOpenArray {
    BOOL movieError = NO;
    long numberImages = 0;
@@MOVIE_CHECK@@
    return movieError;
}
- (NSArray *)reparseSplit:(NSArray *)toOpenArray {
@@REPARSE_SPLIT@@
    return splittedSeries;
}
- (BOOL)fourD:(NSArray *)splittedSeries {
@@FOUR_D@@
    return areData4D;
}
- (NSDictionary *)tiling:(NSString *)storedValue {
@@TILING@@
    return d;
}
@end
#undef malloc
static Item *item(NSDictionary *values, NSString *tag) {
    Item *i = [[Item new] autorelease]; i->values = [values retain]; i->tag = [tag retain]; return i;
}
static NSArray *lists(NSArray *spec, NSString *prefix) {
    NSMutableArray *result = [NSMutableArray array];
    [spec enumerateObjectsUsingBlock:^(NSArray *images, NSUInteger l, BOOL *stop) {
        NSMutableArray *list = [NSMutableArray array];
        [images enumerateObjectsUsingBlock:^(NSDictionary *values, NSUInteger i, BOOL *s) {
            [list addObject:item(values, [NSString stringWithFormat:@"%@%lu.%lu", prefix, (unsigned long)l, (unsigned long)i])];
        }];
        [result addObject:list];
    }];
    return result;
}
static NSString *tags(NSArray *groups) {
    NSMutableArray *parts = [NSMutableArray array];
    for (NSArray *group in groups) [parts addObject:[[group valueForKey:@"tag"] componentsJoinedByString:@","]];
    return [parts componentsJoinedByString:@"|"];
}
int main(int argc, char **argv) { @autoreleasepool {
    records = [NSMutableArray array]; alerts = [NSMutableArray array]; visits = [NSMutableArray array];
    NSDictionary *cases = [NSPropertyListSerialization propertyListWithData:[NSData dataWithContentsOfFile:@(argv[1])] options:0 format:NULL error:NULL];
    Opener *opener = [[Opener new] autorelease];
    opener->previewPix = @[]; opener->previewPixThumbnails = @"lock";
    for (NSArray *c in cases[@"accumulate"]) {
        unsigned long long pixels = [c[4] unsignedLongLongValue], padded = [c[5] unsignedLongLongValue];
        BOOL ok = HorosAccumulateImageMemory(@{@"width": c[0], @"height": c[1]}, [c[2] unsignedLongLongValue], [c[3] boolValue], &pixels, &padded);
        record(@"accumulate %@: %d %llu %llu", [c componentsJoinedByString:@" "], ok, pixels, padded);
    }
    for (NSDictionary *c in cases[@"memory"]) {
        allocationLimit = [c[@"limit"] unsignedLongValue];
        unsigned long required = 0;
        [records addObject:@"--"];
        BOOL ok = [opener computeEnoughMemory:lists(c[@"lists"], @"") :&required];
        record(@"enough %@: %d %lu", c[@"label"], ok, required);
        [alerts removeAllObjects]; [visits removeAllObjects]; purges = 0;
        NSArray *spec = lists(c[@"lists"], @"");
        unsigned long *blocks = calloc(spec.count ?: 1, sizeof(unsigned long));
        NSArray *planned = [opener memoryPass:spec blocks:blocks];
        free(blocks);
        record(@"plan %@: %@ alerts [%@] visits [%@] purges %lu", c[@"label"], planned ? @"open" : @"none",
               [alerts componentsJoinedByString:@"|"], [visits componentsJoinedByString:@","], (unsigned long)purges);
    }
    for (NSDictionary *c in cases[@"split"]) {
        NSArray *series = lists(@[c[@"images"]], @"")[0];
        record(@"movie split %@: %@", c[@"label"], tags([opener movieSplit:@[series]]));
        record(@"reparse split %@: %@", c[@"label"], tags([opener reparseSplit:@[series]]));
    }
    for (NSArray *counts in cases[@"movie"]) {
        NSMutableArray *selection = [NSMutableArray array];
        for (NSNumber *count in counts) {
            NSMutableArray *list = [NSMutableArray array];
            for (int i = 0; i < count.intValue; i++) [list addObject:@(i)];
            [selection addObject:list];
        }
        [alerts removeAllObjects];
        BOOL error = [opener movieCheck:selection];
        record(@"movie check [%@]: %d [%@] fourD %d", [counts componentsJoinedByString:@","], error, [alerts componentsJoinedByString:@"|"],
               counts.count ? [opener fourD:selection] : -1);
    }
    for (NSDictionary *c in cases[@"subseries"]) {
        opener->subFrom = [c[@"from"] intValue]; opener->subTo = [c[@"to"] intValue]; opener->subInterval = [c[@"interval"] intValue];
        NSMutableArray *spec = [NSMutableArray array];
        for (NSNumber *count in c[@"counts"]) {
            NSMutableArray *list = [NSMutableArray array];
            for (int i = 0; i < count.intValue; i++) [list addObject:@{}];
            [spec addObject:list];
        }
        record(@"subseries %@ %@ %@ [%@]: %@", c[@"from"], c[@"to"], c[@"interval"], [c[@"counts"] componentsJoinedByString:@","],
               tags([opener produceNewArray:lists(spec, @"")]));
    }
    for (NSString *value in cases[@"tiling"]) {
        NSDictionary *d = [opener tiling:[value isEqual:@"<nil>"] ? nil : value];
        record(@"tiling [%@]: %@", value, d ? [NSString stringWithFormat:@"%@x%@", d[@"rows"], d[@"columns"]] : @"none");
    }
    printf("%s\n", [[records componentsJoinedByString:@"\n"] UTF8String]);
}}
'''
for key, value in (('ACCUMULATE', accumulate), ('ENOUGH', enough), ('PRODUCE', produce), ('MEMORY_PASS', memory_pass),
                   ('MOVIE_SPLIT', movie_split), ('MOVIE_CHECK', movie_check), ('REPARSE_SPLIT', reparse_split),
                   ('FOUR_D', four_d), ('TILING', tiling)):
    OBJC = OBJC.replace('@@%s@@' % key, value)

SWIFT = r'''
import Foundation
var records: [String] = []
let cases = try! PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])), format: nil) as! NSDictionary
func number(_ value: Any?) -> NSNumber { value as? NSNumber ?? NSNumber(value: 0) }
func memoryImage(_ values: NSDictionary) -> MemoryImage {
    MemoryImage(width: number(values["width"]).int64Value, height: number(values["height"]).int64Value,
                frames: number(values["numberOfFrames"]).int64Value, series: number(values["numberOfSeries"]).int64Value)
}
func describe(_ value: UInt64) -> String { String(value) }
for case let c as [NSNumber] in cases["accumulate"] as! [Any] {
    var pixels = c[4].uint64Value, padded = c[5].uint64Value
    let ok = ViewerMemory.accumulate(width: c[0].int64Value, height: c[1].int64Value, frames: c[2].uint64Value, minimumImageSize: c[3].boolValue,
                                     pixels: &pixels, padded: &padded)
    records.append("accumulate \(c.map(\.stringValue).joined(separator: " ")): \(ok ? 1 : 0) \(pixels) \(padded)")
}
for case let c as NSDictionary in cases["memory"] as! [Any] {
    let limit = number(c["limit"]).uint64Value
    let spec = (c["lists"] as! [[NSDictionary]])
    let label = c["label"] as! String
    records.append("--")
    let result = ViewerMemory.enoughMemory(imageCounts: spec.map(\.count), image: { memoryImage(spec[$0][$1]) },
                                           allocate: { $0 <= limit },
                                           willCount: { _ in records.append("enter") }, didCount: { records.append("exit") })
    records.append("enough \(label): \(result.enough ? 1 : 0) \(result.requiredMegabytes)")
    var visits: [String] = [], purges = 0
    let plan = ViewerMemory.plan(imageCounts: spec.map(\.count), image: { memoryImage(spec[$0][$1]) },
                                 // The opening date of the series and of the study.
                                 visit: { list in visits += ["\(list).0", "\(list).0"] },
                                 allocate: { UInt64($0) &* 4 &+ 4096 <= limit }, purge: { purges += 1 })
    var alerts: [String] = []
    switch plan {
    case .success(let plan):
        let kept = zip(plan.listIndices, plan.imageIndices).map { list, images in images.map { "\(list).\($0)" }.joined(separator: ",") }
        records.append("plan: lists [\(kept.joined(separator: "|"))] blocks \(plan.blocks.map(String.init).joined(separator: ",")) total \(plan.total) sampling \(plan.subSampling) multiframe \(plan.multiFrame ? 1 : 0)")
    case .failure(.unsafeDimensions):
        alerts.append("The selected image dimensions cannot be loaded safely.")
    case .failure(.notEnoughMemory):
        alerts.append("Not enough memory to open the selected images.")
    }
    let opened: Bool
    if case .success = plan { opened = true } else { opened = false }
    records.append("plan \(label): \(opened ? "open" : "none") alerts [\(alerts.joined(separator: "|"))] visits [\(visits.joined(separator: ","))] purges \(purges)")
}
func groupsText(_ groups: [[Int]], _ order: [Int]) -> String {
    groups.map { $0.map { "0.\(order[$0])" }.joined(separator: ",") }.joined(separator: "|")
}
for case let c as NSDictionary in cases["split"] as! [Any] {
    let images = c["images"] as! [NSDictionary]
    let label = c["label"] as! String
    let identity = Array(images.indices)
    records.append("movie split \(label): " + groupsText(SeriesSplitting.movieGroups(sliceLocations: images.map { number($0["sliceLocation"]).floatValue }), identity))
    // Sorted by instance number, then frame, as the reparse sorts its series.
    let order = images.indices.sorted { a, b in
        let ia = number(images[a]["instanceNumber"]), ib = number(images[b]["instanceNumber"])
        if ia.compare(ib) != .orderedSame { return ia.compare(ib) == .orderedAscending }
        let fa = number(images[a]["frameID"]), fb = number(images[b]["frameID"])
        if fa.compare(fb) != .orderedSame { return fa.compare(fb) == .orderedAscending }
        return a < b
    }
    let groups = SeriesSplitting.reparseGroups(sliceLocations: order.map { number(images[$0]["sliceLocation"]).floatValue },
                                               comments: order.map { (images[$0]["comment"] as? NSString)?.floatValue ?? 0 })
    records.append("reparse split \(label): " + groupsText(groups, order))
}
for case let counts as [NSNumber] in cases["movie"] as! [Any] {
    var alerts: [String] = []
    let check = MoviePlayerSelection.check(imageCounts: counts.map(\.intValue), maximum: 8)
    switch check {
    case .singleSeries: alerts.append("To see an animated series, you have to select multiple series of the same area at different times: e.g. a cardiac CT")
    case .tooManySeries: alerts.append(String(format: "4D Player is limited to a maximum number of %d series.", Int32(8)))
    case .differentImageCounts: alerts.append("In the current version, all series must contain the same number of images.")
    case .accepted: break
    }
    let fourD = counts.isEmpty ? -1 : (SeriesSplitting.isFourD(groupSizes: counts.map(\.intValue)) ? 1 : 0)
    records.append("movie check [\(counts.map(\.stringValue).joined(separator: ","))]: \(check == .accepted ? 0 : 1) [\(alerts.joined(separator: "|"))] fourD \(fourD)")
}
for case let c as NSDictionary in cases["subseries"] as! [Any] {
    let counts = (c["counts"] as! [NSNumber]).map(\.intValue)
    var groups: [String] = []
    for (list, count) in counts.enumerated() {
        let kept = SubSeriesSelection.indices(imageCount: count, from: number(c["from"]).int32Value, to: number(c["to"]).int32Value,
                                              interval: number(c["interval"]).int32Value)
        if !kept.isEmpty { groups.append(kept.map { "\(list).\($0)" }.joined(separator: ",")) }
    }
    records.append("subseries \(c["from"]!) \(c["to"]!) \(c["interval"]!) [\((c["counts"] as! [NSNumber]).map(\.stringValue).joined(separator: ","))]: \(groups.joined(separator: "|"))")
}
for case let value as String in cases["tiling"] as! [Any] {
    let parsed = ViewerTiling.rowsAndColumns(value == "<nil>" ? nil : value)
    records.append("tiling [\(value)]: " + (parsed.map { "\($0.rows)x\($0.columns)" } ?? "none"))
}
print(records.joined(separator: "\n"))
'''


def build_cases():
    rng = random.Random(20261027)
    big = [0, -1, 1, 255, 256, 257, 512, 65535, 65536, 2**31, 2**32 + 1, 2**40, 2**62]
    accumulate_cases = []
    for _ in range(400):
        accumulate_cases.append([rng.choice(big + [rng.randint(1, 4096)]), rng.choice(big + [rng.randint(1, 4096)]),
                                 rng.choice([0, 1, 2, 7, 300, 2**40, 2**63]), rng.choice([0, 1]),
                                 rng.choice([0, 12345, 2**64 - 10]), rng.choice([0, 999, 2**64 - 5])])

    def image(width, height, frames=1, series=1):
        return {'width': width, 'height': height, 'numberOfFrames': frames, 'numberOfSeries': series}

    memory = [
        {'label': 'small series', 'limit': 2**40, 'lists': [[image(128, 128)] * 20]},
        {'label': 'two series', 'limit': 2**40, 'lists': [[image(512, 512)] * 30, [image(256, 256)] * 10]},
        {'label': 'with empty list', 'limit': 2**40, 'lists': [[], [image(64, 64)] * 3]},
        {'label': 'multi-frame', 'limit': 2**40, 'lists': [[image(300, 200, 40)]]},
        {'label': 'multi-series file', 'limit': 2**40, 'lists': [[image(300, 200, 1, 3)]]},
        {'label': 'no frames', 'limit': 2**40, 'lists': [[image(300, 200, 0, 3)]]},
        {'label': 'bad size', 'limit': 2**40, 'lists': [[image(0, 512)] * 3]},
        {'label': 'overflow', 'limit': 2**40, 'lists': [[image(2**31, 2**31)] * 2]},
        {'label': 'tight', 'limit': 3 * 1024 * 1024, 'lists': [[image(512, 512)] * 16]},
        {'label': 'tighter', 'limit': 600 * 1024, 'lists': [[image(512, 512)] * 16, [image(128, 128)] * 5]},
        {'label': 'one image only', 'limit': 1000, 'lists': [[image(512, 512)]]},
        {'label': 'nothing fits', 'limit': 10, 'lists': [[image(512, 512)] * 9]},
        {'label': 'multi-frame tight', 'limit': 1024 * 1024, 'lists': [[image(512, 512, 30)]]},
        {'label': 'mixed sizes', 'limit': 2**40, 'lists': [[image(100, 100), image(1024, 768), image(16, 16)]]},
    ]
    for n in range(20):
        lists = []
        for _ in range(rng.randint(1, 4)):
            size = rng.choice([0, 1, 2, 3, 8, 25])
            if size == 1 and rng.random() < 0.5:
                lists.append([image(rng.choice([64, 256, 513]), rng.choice([64, 256, 513]), rng.choice([1, 2, 17]), rng.choice([1, 2]))])
            else:
                lists.append([image(rng.choice([1, 64, 255, 256, 640]), rng.choice([1, 64, 255, 256, 480])) for _ in range(size)])
        memory.append({'label': 'random %d' % n, 'limit': rng.choice([2**40, 4 * 1024 * 1024, 900 * 1024, 300 * 1024, 70000]),
                       'lists': lists})

    def series(locations, comments=None, instances=None):
        images = []
        for i, location in enumerate(locations):
            values = {'sliceLocation': float(location), 'instanceNumber': instances[i] if instances else i + 1, 'frameID': 0}
            if comments is not None:
                values['comment'] = str(comments[i])
            images.append(values)
        return images

    passes = [x * 2.5 for x in range(6)]
    split = [
        {'label': 'one image', 'images': series([1.0])},
        {'label': 'two equal', 'images': series([1.0, 1.0])},
        {'label': 'plain 3D', 'images': series([x * 1.25 for x in range(10)])},
        {'label': 'repeated passes', 'images': series(passes * 4)},
        {'label': 'interleaved 4D', 'images': series([p for p in passes for _ in range(3)])},
        {'label': 'up and down', 'images': series([0, 1, 2, 3, 2, 1, 0, 1, 2, 3])},
        {'label': 'uneven step', 'images': series([0, 1, 2, 3, 10, 11, 12, 13, 13.5, 14])},
        {'label': 'twenty percent', 'images': series([0, 1, 2, 3.2, 4.4, 5.9, 7.0, 8.0])},
        {'label': 'all equal', 'images': series([5] * 6)},
        {'label': 'equal with comments', 'images': series([5] * 6, comments=[1, 1, 2, 2, 3, 3])},
        {'label': 'equal with zero comments', 'images': series([5] * 4, comments=[0, 0, 0, 0])},
        {'label': 'phases', 'images': series([7] * 8, comments=[10, 20, 30, 40, 10, 20, 30, 40])},
        {'label': 'unsorted instances', 'images': series([3, 2, 1, 0, 3, 2, 1, 0], instances=[5, 6, 7, 8, 1, 2, 3, 4])},
        {'label': 'mostly equal', 'images': series([1, 1, 1, 2, 2, 2, 3, 3, 3])},
        {'label': 'float edge', 'images': series([0, 1, 2.2, 3.2, 4.2, 5.4, 6.6])},
    ]
    for n in range(30):
        kind = rng.choice(['passes', 'walk', 'noisy'])
        if kind == 'passes':
            count = rng.randint(2, 6)
            locations = [round(rng.uniform(-50, 50), 2) for _ in range(rng.randint(2, 5))] * count
        elif kind == 'walk':
            location, locations = 0.0, []
            for _ in range(rng.randint(2, 30)):
                location += rng.choice([1.0, 1.0, 1.1, -1.0, 2.5, 0.0, 1.21])
                locations.append(location)
        else:
            locations = [rng.choice([0.0, 0.5, 1.0, 1.5]) for _ in range(rng.randint(2, 20))]
        comments = [rng.choice([0, 0, 1, 2]) for _ in locations] if rng.random() < 0.4 else None
        split.append({'label': 'random %d' % n, 'images': series(locations, comments)})

    movie = [[1], [], [5, 5], [5, 4], [3, 3, 3], [0, 0], [2] * 8, [2] * 9, [4, 4, 4, 5], [10, 10, 10, 10, 10, 10, 10, 11, 10]]
    subseries = []
    for _ in range(80):
        subseries.append({'from': rng.choice([-3, 0, 1, 2, 5, 40]), 'to': rng.choice([-1, 0, 1, 3, 10, 50]),
                          'interval': rng.choice([-2, 0, 1, 2, 3, 7]), 'counts': [rng.choice([0, 1, 4, 10, 33]) for _ in range(rng.randint(1, 3))]})
    tiling = ['<nil>', '', '1', '22', '13', '3x', 'ab', '123', '0 ', '９9', 'é1', '45']
    return {'accumulate': accumulate_cases, 'memory': memory, 'split': split, 'movie': movie, 'subseries': subseries, 'tiling': tiling}


failures = []
with tempfile.TemporaryDirectory(prefix='horos-viewer-opening-') as tmp:
    tmp = Path(tmp)
    (tmp / 'cases.plist').write_bytes(plistlib.dumps(build_cases(), fmt=plistlib.FMT_BINARY))
    (tmp / 'reference.m').write_text(OBJC)
    built = subprocess.run(['xcrun', 'clang', '-fno-objc-arc', '-fblocks', '-Wno-format', '-Wno-objc-method-access',
                            '-framework', 'Foundation', str(tmp / 'reference.m'), '-o', str(tmp / 'reference')],
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
        diff = list(difflib.unified_diff(a, b, 'Objective-C', 'IsiXImaging', lineterm='', n=0))
        failures.append('records differ:\n' + '\n'.join(diff[:60]))

if failures:
    for failure in failures:
        print('FAIL:', failure)
    sys.exit(1)
kinds = {}
for line in a:
    if line in ('--', 'enter', 'exit'):
        continue
    key = ' '.join(line.split()[:2]) if line.split()[0] in ('movie', 'reparse') else line.split()[0].rstrip(':')
    kinds[key] = kinds.get(key, 0) + 1
print('ok: the viewer opening rules of %s and IsiXImaging agree on %d records (%s)'
      % (reference, sum(kinds.values()), ', '.join('%s %d' % kv for kv in sorted(kinds.items()))))
