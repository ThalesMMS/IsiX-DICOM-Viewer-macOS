#!/usr/bin/env python3
"""The database window's sources and activity, and the database's cleaning and routing, keep their word (#779).

Found while the BrowserController, DicomDatabase and ViewerController
categories moved to Swift (#722), which kept their behaviour:

1. -deallocActivity removed an observer of ThreadsManager's "threads" that was
   never registered, which raises, and then sent [super dealloc] from a
   category, so -[BrowserController dealloc] went on over a freed object. It
   now only lets the activity list and its helper go.
2. -netServiceDidResolveAddress: compared the service's domain with a service
   type, so it always read the TXT record with BonjourPublisher's parser,
   which raises on a DICOM record whose "AETitle" is not UTF-8: that node was
   dropped. The UID that tells Horos it found itself is read the same way for
   both types, and nothing else of the record is parsed for it.
3. -volumeScanThread kept a source for a minute with an autorelease scheduled
   on its own thread's run loop, which never runs: the source leaked. The
   minute now runs on the main queue.
4. HorosVolumeDiscovery was implemented in its header, part of the SDK: every
   plugin including <Horos/Horos.h> compiled a class of its own.
5-7. The time window of a routing rule: the day added to a toTime past
   midnight was thrown away, a window already over waited now - fromTime plus a
   day instead of a day minus that, and the current time went through "%2ld"
   and a formatter. The times themselves were read in one format only, which
   the preference pane's date picker does not write. The delay is worked out on
   times of day, from the formats the pane has written.
8. Cleaning for free space sorted its candidates with a comparator for which a
   study without a date equalled every other: not an order, and a recent study
   could be deleted before an older one. Undated studies now come last.
9. -addImages:toSendQueueForRoutingRule: took out an already queued image with
   -removeObject:, every copy at once, and the loop's next index was past the
   end: NSRangeException when an image was listed twice.
10. A physical Length whose payload lacks its "a" or "b" endpoint stopped the
    ROI export with a failed cast. It is left out, with a log line.

Every item runs the code it names, compiled from the sources with xcrun
swiftc or clang in a temporary folder; 1 and 4 against doubles of the classes
around them. `<git revision>` as an optional argument reads the sources of that
revision, the negative control: where the fixed helper does not exist there,
the former code is compiled in its place.
"""
from pathlib import Path
import atexit
import re
import shutil
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None
failures = []


def read(path):
    if revision:
        data = subprocess.check_output(['git', '-C', str(root), 'show', f'{revision}:{path}'])
    else:
        data = (root / path).read_bytes()
    return data.decode('utf-8' if path.endswith('.swift') else 'latin1')


def block(text, start):
    """From `start` to the brace that closes the first one after it."""
    at = text.find(start)
    if at < 0:
        return None
    opening = text.index('{', at)
    depth = 0
    for index in range(opening, len(text)):
        depth += {'{': 1, '}': -1}.get(text[index], 0)
        if depth == 0:
            return text[at:index + 1]
    return None


def objc_block(text, start):
    """An @implementation, to its @end."""
    at = text.find(start)
    if at < 0:
        return None
    return text[at:text.index('@end', at) + len('@end')]


if subprocess.run(['xcrun', '--find', 'swiftc'], capture_output=True).returncode != 0:
    print('SKIP: no swiftc here')
    sys.exit(2)

folder = Path(tempfile.mkdtemp(prefix='horos-database-helpers-'))
# Removed however the test ends, skips included (#803).
atexit.register(shutil.rmtree, folder, ignore_errors=True)


def build(name, source, command):
    path = folder / name
    path.write_text(source, encoding='utf-8')
    binary = str(folder / (name.split('.')[0]))
    built = subprocess.run(command + [str(path), '-o', binary], capture_output=True, text=True)
    if built.returncode != 0:
        failures.append('%s does not compile:\n%s' % (name, built.stderr[-2500:]))
        return None
    return binary


def swift(name, source, *extra):
    return build(name, source, ['xcrun', 'swiftc', '-suppress-warnings'] + list(extra))


def run(binary, *arguments, env=None):
    return subprocess.run([binary] + list(arguments), capture_output=True, text=True, env=env, timeout=60)


activity = read('Horos/Sources/BrowserController+Activity+CAPI.m')
sources = read('Horos/Sources/BrowserController+Sources.swift')
publisher = read('Horos/Sources/BonjourPublisher.swift')
discovery = read('Horos/Sources/HorosVolumeDiscovery.h')
schedule = read('Horos/Sources/RoutingSchedule.swift')
routing = read('Horos/Sources/DicomDatabase+Routing.swift')
clean = read('Horos/Sources/DicomDatabase+Clean.swift')
interchange = read('Horos/Sources/ViewerController+ROIInterchange.swift')

# --- 1: -deallocActivity inside -[BrowserController dealloc] -------------------
category = objc_block(activity, '@implementation BrowserController (Activity)')
if category is None:
    failures.append('1: BrowserController (Activity) is gone from BrowserController+Activity+CAPI.m')
else:
    DEALLOC = r'''
#import <Cocoa/Cocoa.h>
static int helpersFreed = 0, controllersFreed = 0, stepsAfterActivity = 0;
@interface ThreadsManager : NSObject
+ (instancetype)defaultManager;
@end
@implementation ThreadsManager
+ (instancetype)defaultManager { static ThreadsManager *manager; if (!manager) manager = [[self alloc] init]; return manager; }
@end
@interface ActivityHelper : NSObject <NSTableViewDelegate, NSTableViewDataSource>
@end
@implementation ActivityHelper
- (void)dealloc { helpersFreed++; [super dealloc]; }
@end
// NSWindowController, BrowserController's superclass: counts its deallocs.
@interface WindowController : NSObject
@end
@implementation WindowController
- (void)dealloc { controllersFreed++; [super dealloc]; }
@end
@interface BrowserController : WindowController {
@public
    NSTableView *_activityTableView;
    id _activityHelper;
}
@end
@interface BrowserController (Activity)
- (void)deallocActivity;
@end
@implementation BrowserController
- (instancetype)init {
    if ((self = [super init])) {
        _activityTableView = [[NSTableView alloc] initWithFrame:NSZeroRect];
        _activityHelper = [[ActivityHelper alloc] init];
        [_activityTableView setDelegate:_activityHelper];
        [_activityTableView setDataSource:_activityHelper];
    }
    return self;
}
// As -[BrowserController dealloc]: -deallocActivity first, the rest, then super.
- (void)dealloc {
    [self deallocActivity];
    stepsAfterActivity++;
    [_activityTableView release];
    [super dealloc];
}
@end
''' + category + r'''
int main(void) {
    NSTableView *table = nil;
    @autoreleasepool {
        BrowserController *browser = [[BrowserController alloc] init];
        table = [browser->_activityTableView retain];
        @try { [browser release]; }
        @catch (NSException *exception) { printf("raised %s\n", exception.name.UTF8String); return 0; }
    }
    printf("helper %d, controller %d, rest %d, delegate %s\n", helpersFreed, controllersFreed, stepsAfterActivity,
           table.delegate || table.dataSource ? "kept" : "cleared");
    return 0;
}
'''
    binary = build('dealloc.m', DEALLOC, ['xcrun', 'clang', '-fno-objc-arc', '-fobjc-exceptions', '-Wno-objc-root-class',
                                          '-framework', 'Cocoa'])
    if binary:
        result = run(binary)
        answer = result.stdout.strip()
        if result.returncode != 0 or answer != 'helper 1, controller 1, rest 1, delegate cleared':
            failures.append('1: -[BrowserController dealloc] does not end once, with the helper released: %s' %
                            (answer or 'died (%d)' % result.returncode))

# --- 2: which UID a Bonjour TXT record carries -----------------------------------
helper = block(sources, 'fileprivate func bonjourTXTRecordUID(')
if helper is None:
    # The former code: BonjourPublisher's parser for every service type.
    parser = block(publisher, '    public class func dictionaryFromXTRecordData(')
    decode = block(publisher, '    private static func utf8String(')
    helper = 'final class BonjourPublisher: NSObject {\n' + parser + '\n' + decode + '''
}
func bonjourTXTRecordUID(_ data: Data?) -> String? {
    return BonjourPublisher.dictionaryFromXTRecordData(data).object(forKey: "UID") as? String
}'''
if re.search(r'service\.domain as NSString\)\.isEqual\(to: "_osirixdb\._tcp\."\)', sources):
    failures.append('2: -netServiceDidResolveAddress: still compares the domain with a service type')
BONJOUR = 'import Foundation\n' + helper + r'''
func record(_ pairs: [String: Data]) -> Data { NetService.data(fromTXTRecord: pairs) }
func text(_ string: String) -> Data { Data(string.utf8) }
let data: Data?
switch CommandLine.arguments[1] {
case "database": data = record(["UID": text("HOROS-1"), "AETitle": text("HOROS"), "port": text("8780")])
case "dicom": data = record(["UID": text("HOROS-1"), "serverDescription": text("Horos"), "CGET": text("YES")])
case "latin1": data = record(["UID": text("PACS-2"), "AETitle": Data([0x52, 0xC9, 0x53])])
case "none": data = record(["AETitle": text("PACS")])
default: data = nil
}
print(bonjourTXTRecordUID(data) ?? "nil")
'''
binary = swift('bonjour.swift', BONJOUR)
if binary:
    for case, answer, failure in (('database', 'HOROS-1', 'our database is not recognised'),
                                  ('dicom', 'HOROS-1', 'our DICOM node is not recognised'),
                                  ('latin1', 'PACS-2', 'a DICOM node whose AETitle is not UTF-8 is dropped'),
                                  ('none', 'nil', 'a record without a UID is taken for one'),
                                  ('nil', 'nil', 'a service without a TXT record is taken for one')):
        result = run(binary, case)
        if result.returncode != 0 or result.stdout.strip() != answer:
            failures.append('2: %s: %s' % (failure, result.stdout.strip() or 'died (%d)' % result.returncode))

# --- 3: a source kept for a minute from a thread without a run loop --------------
keep = block(sources, 'fileprivate func keepForAMinute(')
if keep is not None:
    KEEP = keep + '\nfunc keepBriefly(_ object: NSObject) { keepForAMinute(object, delay: 0.2) }'
else:
    retain = block(sources, 'fileprivate func retainForAMinute(')
    release = block(sources, 'fileprivate func autoreleaseAfterAMinute(')
    KEEP = retain + '\n' + release.replace('afterDelay: 60', 'afterDelay: 0.2') + \
        '\nfunc keepBriefly(_ object: NSObject) { retainForAMinute(object); autoreleaseAfterAMinute(object) }'
if re.search(r'perform\(NSSelectorFromString\("autorelease"\), with: nil, afterDelay', sources):
    failures.append('3: BrowserController+Sources.swift still schedules an autorelease on the current run loop')
LEAK = 'import Foundation\n' + KEEP + r'''
final class Source: NSObject {
    static let lock = NSLock()
    static var freedAt: Date? = nil
    deinit { Source.lock.lock(); Source.freedAt = Date(); Source.lock.unlock() }
}
func freed() -> Date? { Source.lock.lock(); defer { Source.lock.unlock() }; return Source.freedAt }
let start = Date()
if CommandLine.arguments[1] == "thread" {
    // -volumeScanThread: -performSelectorInBackground:, no run loop running.
    let thread = Thread { autoreleasepool { keepBriefly(Source()) } }
    thread.start()
} else {
    autoreleasepool { keepBriefly(Source()) }
}
while freed() == nil && Date().timeIntervalSince(start) < 3 {
    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
}
if let at = freed() { print(at.timeIntervalSince(start) >= 0.15 ? "released" : "released early") } else { print("leaked") }
'''
binary = swift('leak.swift', LEAK)
if binary:
    for case in ('thread', 'main'):
        result = run(binary, case)
        if result.returncode != 0 or result.stdout.strip() != 'released':
            failures.append('3: a source kept for a minute from the %s is %s' %
                            ('scan thread' if case == 'thread' else 'main thread',
                             result.stdout.strip() or 'lost (%d)' % result.returncode))

# --- 4: a plugin that includes HorosVolumeDiscovery.h ---------------------------
header = folder / 'HorosVolumeDiscovery.h'
header.write_text(discovery, encoding='latin1')
plugin = folder / 'plugin.m'
plugin.write_text('#import "HorosVolumeDiscovery.h"\n@interface PluginFilter : NSObject @end\n'
                  '@implementation PluginFilter\n- (id)discovery { return [[HorosVolumeDiscovery alloc] init]; }\n@end\n')
built = subprocess.run(['xcrun', 'clang', '-fno-objc-arc', '-c', str(plugin), '-o', str(folder / 'plugin.o')],
                       capture_output=True, text=True)
if built.returncode != 0:
    failures.append('4: a plugin including HorosVolumeDiscovery.h does not compile:\n' + built.stderr[-1500:])
else:
    symbols = subprocess.run(['xcrun', 'nm', '-m', str(folder / 'plugin.o')], capture_output=True, text=True).stdout
    defined = [line for line in symbols.splitlines()
               if '_OBJC_CLASS_$_HorosVolumeDiscovery' in line and 'undefined' not in line]
    if defined:
        failures.append('4: a plugin including HorosVolumeDiscovery.h defines a HorosVolumeDiscovery of its own')
capi = read('Horos/Sources/BrowserController+Sources+CAPI.m')
if '@implementation HorosVolumeDiscovery' not in capi and '@implementation HorosVolumeDiscovery' not in discovery:
    failures.append('4: HorosVolumeDiscovery is implemented nowhere')

# --- 5, 6 and 7: the delay before a time-window rule is applied ------------------
if 'static func windowDelay(for rule:' in schedule:
    WINDOW = schedule.replace('import Foundation', 'import AppKit', 1) + r'''
func windowDelay(_ rule: [String: Any], _ now: Date) -> String {
    return RoutingSchedule.windowDelay(for: rule, at: now).map { String($0.intValue) } ?? "nil"
}
'''
else:
    # The former code, as -applyRoutingRules:toImages: ran it, with `now` for Date().
    start = routing.index('                let dateFormatter = DateFormatter()')
    end = routing.index('                let popTime = DispatchTime.now()', start)
    former = routing[start:end].replace('from: Date())', 'from: now)')
    helpers = ''.join(block(routing, 'private func %s(' % name) + '\n'
                      for name in ('date', 'string', 'timeInterval', 'cInt64'))
    WINDOW = 'import AppKit\n' + helpers + '''
func windowDelay(_ rule: [String: Any], _ now: Date) -> String {
    let routingRule = rule as NSDictionary
''' + former + '''
    return String(delayInSeconds)
}
'''
WINDOW += r'''
let calendar = Calendar.current
func day(_ year: Int, _ month: Int, _ dayOfMonth: Int, _ hour: Int, _ minute: Int, _ second: Int) -> Date {
    return calendar.date(from: DateComponents(year: year, month: month, day: dayOfMonth, hour: hour, minute: minute, second: second))!
}
func now(_ hour: Int, _ minute: Int, _ second: Int = 0) -> Date { day(2026, 9, 28, hour, minute, second) }
// The string the routing read before, in the user's locale.
func former(_ hour: Int, _ minute: Int, _ second: Int = 0) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "EEEE, dd MMMM yyyy HH:mm:ss zzzzzzzzz"
    return formatter.string(from: day(1970, 1, 1, hour, minute, second))
}
// What the preference pane stores: its date picker's -stringValue.
func picker(_ hour: Int, _ minute: Int) -> String {
    let picker = NSDatePicker()
    picker.datePickerElements = [.hourMinute]
    picker.dateValue = day(1970, 1, 1, hour, minute, 0)
    return picker.stringValue
}
let cases: [(String, Any, Any, Date)] = [
    ("ahead", former(8, 0), former(10, 0), now(7, 0)),
    ("inside", former(8, 0), former(10, 0), now(9, 0)),
    ("over", former(8, 0), former(10, 0), now(12, 0)),
    ("overnight-evening", former(21, 0), former(6, 0), now(23, 0)),
    ("overnight-morning", former(21, 0), former(6, 0), now(1, 0)),
    ("overnight-ahead", former(21, 0), former(6, 0), now(12, 0)),
    ("single-digits", former(8, 5, 7), former(10, 0), now(8, 5, 3)),
    ("picker-overnight", picker(21, 0), picker(6, 0), now(23, 0)),
    ("picker-over", picker(8, 0), picker(10, 0), now(12, 0)),
    ("new-rule", "21:00", "06:00", now(12, 0)),
    ("unreadable", "soon", "later", now(12, 0)),
]
for (name, from, to, at) in cases {
    print(name, windowDelay(["scheduleType": 2, "fromTime": from, "toTime": to], at))
}
'''
binary = swift('window.swift', WINDOW)
if binary:
    result = run(binary, env={'TZ': 'UTC', 'PATH': '/usr/bin:/bin'})
    got = dict(line.split(' ', 1) for line in result.stdout.strip().splitlines() if ' ' in line)
    expected = {
        'ahead': ('3600', 'a window ahead does not wait for its start'),
        'inside': ('0', 'a window already open is not routed now'),
        'over': ('72000', 'a window over for today does not wait for tomorrow\'s start (6)'),
        'overnight-evening': ('0', 'a window past midnight is taken for over before midnight (5)'),
        'overnight-morning': ('0', 'a window past midnight is taken for ahead after midnight (5)'),
        'overnight-ahead': ('32400', 'a window past midnight does not wait for its start'),
        'single-digits': ('4', 'a time with single digits is misread (7)'),
        'picker-overnight': ('0', 'the times the preference pane writes are not read'),
        'picker-over': ('72000', 'the times the preference pane writes are not read'),
        'new-rule': ('32400', 'the "21:00" and "06:00" of a new rule are not read'),
        'unreadable': ('nil', 'unreadable times are given a delay'),
    }
    if result.returncode != 0:
        failures.append('5-7: the window harness died (%d): %s' % (result.returncode, result.stderr[-500:]))
    for name, (answer, failure) in expected.items():
        if got.get(name) != answer:
            failures.append('5-7: %s: %s, expected %s' % (failure, got.get(name), answer))
call = block(routing, '    @objc(applyRoutingRules:toImages:)') or ''
if 'dateByAddingTimeInterval' in call or '%2ld' in call or 'addingTimeInterval(60 * 60 * 24' in call:
    failures.append('5-7: -applyRoutingRules:toImages: still works the window out itself')

# --- 8: the order of the space cleaning -----------------------------------------
priority = block(clean, 'private func spaceCleanupPriority(')
if priority is not None:
    COMPARE = priority + '\nlet compare: (Any, Any) -> ComparisonResult = spaceCleanupPriority\n'
    options = '.stable' if 'sort(options: .stable, usingComparator: spaceCleanupPriority)' in clean else '[]'
else:
    closure = block(clean, 'studiesDates.sort(comparator: {')
    COMPARE = 'let compare: (Any, Any) -> ComparisonResult = ' + closure[len('studiesDates.sort(comparator: '):] + '\n'
    options = '[]'
ORDER = 'import Foundation\n' + COMPARE + r'''
func entry(_ name: String, _ year: Int?) -> NSArray {
    guard let year else { return NSArray(object: name) }
    return NSArray(objects: name, Calendar.current.date(from: DateComponents(year: year, month: 1, day: 1))! as NSDate)
}
let entries = [entry("2020", 2020), entry("none-1", nil), entry("2010", 2010), entry("2015", 2015), entry("none-2", nil), entry("2005", 2005)]
func permutations(_ items: [NSArray]) -> [[NSArray]] {
    if items.count <= 1 { return [items] }
    return items.indices.flatMap { index -> [[NSArray]] in
        var rest = items
        let first = rest.remove(at: index)
        return permutations(rest).map { [first] + $0 }
    }
}
var wrong = 0
for permutation in permutations(entries) {
    let sorted = NSMutableArray(array: permutation)
    sorted.sort(options: ''' + options + r''', usingComparator: compare)
    let names = sorted.map { ($0 as! NSArray).object(at: 0) as! String }
    if Array(names.prefix(4)) != ["2005", "2010", "2015", "2020"] || !names.suffix(2).allSatisfy({ $0.hasPrefix("none") }) { wrong += 1 }
}
// An order: equal to one and equal to the next means equal to both ends.
var inconsistent = 0
for a in entries { for b in entries { for c in entries {
    if compare(a, b) == .orderedSame && compare(b, c) == .orderedSame && compare(a, c) != .orderedSame { inconsistent += 1 }
} } }
print(wrong, inconsistent)
'''
binary = swift('order.swift', ORDER)
if binary:
    result = run(binary)
    if result.returncode != 0 or result.stdout.strip() != '0 0':
        wrong, _, inconsistent = result.stdout.strip().partition(' ')
        failures.append('8: the space cleaning order is not an order: %s of 720 arrangements sorted wrong, '
                        '%s inconsistent triples' % (wrong or '?', inconsistent or '?'))

# --- 9: an image listed twice in -addImages:toSendQueueForRoutingRule: ----------
loop = block(routing, '                    var i = dicomImages.count - 1')
if loop is None:
    failures.append('9: the queued-image loop of -addImages:toSendQueueForRoutingRule: is gone')
else:
    QUEUE = r'''import Foundation
final class DicomImage: NSObject {
    let path: String
    init(_ path: String) { self.path = path }
    func completePath() -> String? { path }
}
func dropQueued(_ dicomImages: NSMutableArray, _ orderFilePaths: NSArray?) {
''' + loop + r'''
}
let a = DicomImage("/db/a.dcm"), b = DicomImage("/db/b.dcm"), c = DicomImage("/db/c.dcm")
let lists: [String: [DicomImage]] = ["twice": [a, a], "spread": [a, b, a, c, a], "once": [b, a, c]]
let images = NSMutableArray(array: lists[CommandLine.arguments[1]]!)
dropQueued(images, ["/db/a.dcm"] as NSArray)
print(images.map { ($0 as! DicomImage).path }.joined(separator: " "))
'''
    binary = swift('queue.swift', QUEUE)
    if binary:
        for case, answer in (('twice', ''), ('spread', '/db/b.dcm /db/c.dcm'), ('once', '/db/b.dcm /db/c.dcm')):
            result = run(binary, case)
            if result.returncode != 0 or result.stdout.strip() != answer:
                failures.append('9: an already queued image listed %s: %s' %
                                (case, 'raised (%d)' % result.returncode if result.returncode else result.stdout.strip()))

# --- 10: a physical Length without its endpoints ------------------------------------
endpoints = block(interchange, 'fileprivate func interchangeVolumeLengthEndpoints(')
if endpoints is None:
    # The former line of -interchangeROIForROI:pix:, as it ran.
    line = next(l for l in interchange.splitlines() if 'record.patientPoints = [record.volumeLength?["a"] as!' in l)
    endpoints = '''func interchangeVolumeLengthEndpoints(_ payload: Any?) -> (payload: [String: Any], points: [[Double]])? {
    let volumeLength: [String: Any]? = (payload as? NSDictionary).map { $0 as! [String: Any] }
''' + line.replace('record.patientPoints =', 'let points =').replace('record.volumeLength', 'volumeLength') + '''
    return (volumeLength!, points)
}'''
else:
    call = block(interchange, '    public func interchangeROI(for roi: ROI, pix: DCMPix)') or ''
    if 'as! [Double]' in call or 'HorosVolumeLengthROI.validPayload(payload)' not in call \
            or 'interchangeVolumeLengthEndpoints(payload)' not in call:
        failures.append('10: -interchangeROIForROI:pix: does not check the Length\'s endpoints before reading them')
LENGTH = 'import Foundation\n' + endpoints.replace('fileprivate func', 'func') + r'''
var payload: [String: Any] = ["version": 1, "id": "L1", "series": "1.2.3", "frameOfReference": "1.2.4",
                              "a": [1.0, 2.0, 3.0], "b": [4.0, 5.0, 6.0]]
switch CommandLine.arguments[1] {
case "no-a": payload["a"] = nil
case "no-b": payload["b"] = nil
case "short": payload["b"] = [4.0, 5.0]
case "text": payload["a"] = ["1", "2", "3"]
case "nan": payload["b"] = [4.0, Double.nan, 6.0]
default: break
}
if let result = interchangeVolumeLengthEndpoints(payload as NSDictionary) {
    print(result.points.map { $0.map { String($0) }.joined(separator: ",") }.joined(separator: "|"))
} else {
    print("left out")
}
'''
binary = swift('length.swift', LENGTH)
if binary:
    for case, answer in (('valid', '1.0,2.0,3.0|4.0,5.0,6.0'), ('no-a', 'left out'), ('no-b', 'left out'),
                         ('short', 'left out'), ('text', 'left out'), ('nan', 'left out')):
        result = run(binary, case)
        if result.returncode != 0 or result.stdout.strip() != answer:
            failures.append('10: a Length payload "%s" gives %s' %
                            (case, 'a crash (%d)' % result.returncode if result.returncode else result.stdout.strip()))

subprocess.run(['rm', '-rf', str(folder)])
if failures:
    for failure in failures:
        print('FAIL: ' + failure)
    sys.exit(1)
print('PASS: the sources, activity, cleaning, routing and ROI export helpers keep their word (#779)')
