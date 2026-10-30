#!/usr/bin/env python3
"""Every row the smart album editor writes reopens in it as it was.

1. A code outside a CS tag's list was lost on reopening: the row's user-defined
   value became nil for a string and the tag's empty string for a number, so
   `modality CONTAINS "XYZ"` came back as `modality CONTAINS nil`. It is now
   kept as stored; a CS tag without a list opens on its user-defined item,
   where it had no item and hid the value.
2. The "is <date>" row writes `date BETWEEN {CAST(…), CAST(…)}`, which the row
   template refused: the album opened in the SQL mode. It now matches and
   reopens as "is" with the day it names.
3. integersFormatter and decimalsFormatter took each other's mono formatter.
   Each takes its own. Both accept "1.5", so no field changes behaviour.
4. O2DicomPredicateEditor made by -initWithFrame: raised when released, removing
   a "value" observer only -awakeFromNib adds. The Swift class already
   guards it; the check stays so it does not come back.
5. O21Year, a "within" tag, was 12 where the others are negative. It is -12.

The editor's sources are compiled as they are, with a double for N2Debug and
for the tag dictionaries (the DCMTK adapter's HorosDICOMDictionaries, which the
IsiXDICOMFile module asks for by name; DCMAttributeTag and DCMTagDictionary for
a revision that still used the DCM framework), and put in an offscreen window. Each predicate
goes through the album's path: its predicateFormat parsed again, matched with
reallyMatchForPredicate: as SmartWindowController does, set as the editor's
value, and read back. `<git revision>` as an optional argument reads the
sources from that revision, the negative control.
"""
from pathlib import Path
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
from isix_modules import build_module  # noqa: E402

root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None


def read(path):
    if revision:
        return subprocess.check_output(['git', '-C', str(root), 'show', f'{revision}:{path}'])
    return (root / path).read_bytes()


SWIFT = ['O2DicomPredicateEditor', 'O2DicomPredicateEditorView', 'O2DicomPredicateEditorCodeStrings',
         'O2DicomPredicateEditorDCMAttributeTag', 'O2DicomPredicateEditorDatePicker',
         'O2DicomPredicateEditorPopUpButton', 'O2DicomPredicateEditorFormatters']
# The view's KVO context token, where the revision has it.
if revision is None or subprocess.run(['git', '-C', str(root), 'cat-file', '-e',
                                       f'{revision}:Horos/Sources/IdentityToken.swift']).returncode == 0:
    SWIFT.append('IdentityToken')
# The main-actor hop the view's KVO override takes, where the revision has it.
if revision is None or subprocess.run(['git', '-C', str(root), 'cat-file', '-e',
                                       f'{revision}:Horos/Sources/MainActorCallbacks.swift']).returncode == 0:
    SWIFT.append('MainActorCallbacks')
# The module's NSLog and unifiedLogv, which the view's DLog calls.
if b'unifiedLogv' in read('Horos/Sources/O2DicomPredicateEditorView.swift'):
    SWIFT.append('UnifiedLogNSLog')
# The value representations (DCM_AE...): the IsiXDICOMDataset module's, or
# DCMAttribute.h's, the dataset model of the DCMTK adapter or of the DCM
# framework with its tag headers, in a revision that still had it.
uses_dataset_module = b'import IsiXDICOMDataset' in read('Horos/Sources/O2DicomPredicateEditorView.swift')
MODEL_ATTRIBUTE = 'Horos/Sources/Adapters/DCMTK/DCMAttribute.h'
if uses_dataset_module:
    FRAMEWORK_HEADERS = []
elif revision is None or subprocess.run(['git', '-C', str(root), 'cat-file', '-e', f'{revision}:{MODEL_ATTRIBUTE}'],
                                      capture_output=True).returncode == 0:
    FRAMEWORK_HEADERS = [MODEL_ATTRIBUTE]
else:
    FRAMEWORK_HEADERS = ['DCM Framework/DCMAttribute.h', 'DCM Framework/DCMAttributeTag.h',
                         'DCM Framework/DCMTagNameAlias.h', 'DCM Framework/DCMTagDictionary.h']
HEADERS = [*FRAMEWORK_HEADERS, 'Nitrogen/Sources/N2Debug.h', 'Horos/Sources/HorosObjCException.h',
           'Horos/Sources/O2DicomPredicateEditorView.h']
OBJC = ['Horos/Sources/HorosObjCException.m', 'Horos/Sources/O2DicomPredicateEditorView+CAPI.m']
RESOURCES = ['Horos/Resources/dicom3tools-libsrc-standard-strval-base.tpl', 'Horos/Resources/osirix-complementary.tpl']

# The sources name the DICOM tag of the IsiXDICOMFile module; an earlier
# revision named the DCM framework's.
uses_module = b'import IsiXDICOMFile' in read('Horos/Sources/O2DicomPredicateEditorView.swift')

bridge = r'''
#define HOROS_BRIDGING_HEADER 1
#import <Cocoa/Cocoa.h>
#import "DCMAttribute.h"
#import "DCMAttributeTag.h"
#import "DCMTagDictionary.h"
#import "N2Debug.h"
#import "HorosObjCException.h"
'''

# What O2DicomPredicateEditorView+CAPI.m needs of the generated header.
swift_header = r'''
#import <Cocoa/Cocoa.h>
@class DCMAttributeTag;
@interface O2DicomPredicateEditorView : NSView
@property(retain) DCMAttributeTag *DCMAttributeTag;
@end
'''

# A few DICOM tags, as the real dictionary describes them, and one CS tag no
# code-string list knows.
doubles = r'''
#import "DCMAttributeTag.h"
#import "DCMTagDictionary.h"
#import "N2Debug.h"

static NSDictionary *Tags(void) {
    return @{@"0020,0013": @{@"Description": @"InstanceNumber", @"VR": @"IS"},
             @"0018,0050": @{@"Description": @"SliceThickness", @"VR": @"DS"},
             @"0008,0060": @{@"Description": @"Modality", @"VR": @"CS"},
             @"0008,0020": @{@"Description": @"StudyDate", @"VR": @"DA"},
             @"0018,9990": @{@"Description": @"HarnessCodeWithoutList", @"VR": @"CS"}};
}

@implementation DCMTagDictionary
+ (id)sharedTagDictionary { return Tags(); }
@end

@implementation N2Debug
+ (BOOL)isActive { return NO; }
+ (void)setActive:(BOOL)active {}
@end

void _N2LogExceptionImpl(NSException *e, BOOL logStack, const char *pf) { NSLog(@"%s: %@", pf, e); }

@implementation DCMAttributeTag
+ (id)tagWithGroup:(int)group element:(int)element { return [[self alloc] initWithGroup:group element:element]; }
+ (id)tagWithTag:(DCMAttributeTag *)tag { return [[self alloc] initWithTag:tag]; }
+ (id)tagWithTagString:(NSString *)tagString { return [[self alloc] initWithTagString:tagString]; }
+ (id)tagWithName:(NSString *)name { return [[self alloc] initWithName:name]; }
- (id)initWithGroup:(int)group element:(int)element {
    return [self initWithTagString:[NSString stringWithFormat:@"%04X,%04X", group, element]];
}
- (id)initWithTag:(DCMAttributeTag *)tag { return [self initWithGroup:tag.group element:tag.element]; }
- (id)initWithTagString:(NSString *)tagString {
    if ((self = [super init])) {
        unsigned g = 0, e = 0;
        NSScanner *s = [NSScanner scannerWithString:tagString];
        [s scanHexInt:&g]; [s scanString:@"," intoString:nil]; [s scanHexInt:&e];
        _group = g; _element = e;
        NSDictionary *d = Tags()[tagString];
        _name = d[@"Description"] ?: @"Unknown";
        _vr = d[@"VR"] ?: @"UN";
    }
    return self;
}
- (id)initWithName:(NSString *)name {
    for (NSString *k in Tags())
        if ([Tags()[k][@"Description"] isEqualToString:name])
            return [self initWithTagString:k];
    return nil;
}
- (int)group { return _group; }
- (int)element { return _element; }
- (NSString *)name { return _name; }
- (NSString *)vr { return _vr; }
- (void)setVr:(NSString *)vr { _vr = vr; }
- (BOOL)isPrivate { return _group % 2 != 0; }
- (long)longValue { return ((long)_group << 16) + (_element & 0xffff); }
- (NSString *)stringValue { return [NSString stringWithFormat:@"%04X,%04X", _group, _element]; }
- (NSString *)description { return [NSString stringWithFormat:@"%@\t%@\t%@", self.stringValue, _name, _vr]; }
- (NSString *)readableDescription { return _name.length ? _name : self.stringValue; }
- (NSComparisonResult)compare:(DCMAttributeTag *)tag { return [self.stringValue compare:tag.stringValue]; }
- (BOOL)isEquaToTag:(DCMAttributeTag *)tag { return [tag.stringValue isEqualToString:self.stringValue]; }
- (BOOL)isEqual:(id)object { return [object isKindOfClass:[DCMAttributeTag class]] && [self isEquaToTag:object]; }
- (NSUInteger)hash { return self.stringValue.hash; }
- (id)copyWithZone:(NSZone *)zone { return [[DCMAttributeTag allocWithZone:zone] initWithTag:self]; }
@end
'''

if uses_module:
    # The value representations (DCM_AE...) are DCMAttribute.h's, before the
    # IsiXDICOMDataset module.
    bridge = r'''
#define HOROS_BRIDGING_HEADER 1
#import <Cocoa/Cocoa.h>
''' + ('' if uses_dataset_module else '#import "DCMAttribute.h"\n') + r'''#import "N2Debug.h"
#import "HorosObjCException.h"
'''
    # The row's tag property is attributeTag; it was DCMAttributeTag while the
    # framework's class lent it the name.
    tag_property = ('attributeTag' if b'self.attributeTag' in read('Horos/Sources/O2DicomPredicateEditorView+CAPI.m')
                    else 'DCMAttributeTag')
    swift_header = r'''
#import <Cocoa/Cocoa.h>
@class IsiXDICOMAttributeTag;
@interface O2DicomPredicateEditorView : NSView
@property(retain) IsiXDICOMAttributeTag *''' + tag_property + r''';
@end
'''
    doubles = doubles[:doubles.index('@implementation DCMAttributeTag')].replace(
        '#import "DCMAttributeTag.h"\n#import "DCMTagDictionary.h"\n', '').replace(
        '''@implementation DCMTagDictionary
+ (id)sharedTagDictionary { return Tags(); }
@end''', '''// The dictionaries the module asks the DCMTK adapter for, by its name.
@interface HorosDICOMDictionaries : NSObject
@end
@implementation HorosDICOMDictionaries
+ (NSDictionary *)tagDictionary { return Tags(); }
+ (NSDictionary *)tagForNameDictionary {
    NSMutableDictionary *names = [NSMutableDictionary dictionary];
    for (NSString *k in Tags()) names[Tags()[k][@"Description"]] = k;
    return names;
}
@end''')

main = r'''
import AppKit

final class N2PopUpMenu: NSObject {
    static func popUpContextMenu(_ menu: NSMenu, with event: NSEvent, for view: NSPopUpButton, with font: NSFont?) -> NSWindow? { nil }
}

func fail(_ reason: String) { print("FAIL: \(reason)") }

if CommandLine.arguments.count > 1 && CommandLine.arguments[1] == "dealloc" {
    // Released right away, and after showing a row.
    autoreleasepool { _ = O2DicomPredicateEditor(frame: NSRect(x: 0, y: 0, width: 600, height: 200)) }
    autoreleasepool {
        let editor = O2DicomPredicateEditor(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
        editor.dbMode = true
        editor.objectValue = NSPredicate(format: "name CONTAINS[c] \"A\"")
    }
    print("released")
    exit(0)
}

NSApplication.shared.setActivationPolicy(.prohibited)
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 400), styleMask: [.titled], backing: .buffered, defer: false)

func makeEditor(dbMode: Bool) -> O2DicomPredicateEditor {
    let editor = O2DicomPredicateEditor(frame: window.contentView!.bounds)
    window.contentView!.addSubview(editor)
    editor.dbMode = dbMode // as SmartWindowController's -awakeFromNib
    return editor
}
let albums = makeEditor(dbMode: true)
let dicom = makeEditor(dbMode: false)

let equalTo = Int(NSComparisonPredicate.Operator.equalTo.rawValue)
let within = -3 // O2Within

func rows(_ editor: O2DicomPredicateEditor) -> [O2DicomPredicateEditorView] {
    (0..<editor.numberOfRows).compactMap { editor.displayValues(forRow: $0).first as? O2DicomPredicateEditorView }
}

/// The comparisons of a predicate, flattened, as their formats.
func comparisons(_ p: NSPredicate?) -> [String] {
    if let c = p as? NSCompoundPredicate {
        if c.compoundPredicateType == .and {
            return c.subpredicates.flatMap { comparisons($0 as? NSPredicate) }
        }
        return [c.predicateFormat]
    }
    return p.map { [$0.predicateFormat] } ?? []
}

/// The album's path: the stored text parsed, matched, shown and read back.
@discardableResult
func reopen(_ format: String, in editor: O2DicomPredicateEditor = albums, _ what: String) -> [O2DicomPredicateEditorView] {
    let stored = NSPredicate(format: format)
    if !editor.reallyMatch(for: stored) {
        fail("\(what): the editor refuses `\(format)`, and the album opens in the SQL mode")
        return []
    }
    editor.objectValue = stored
    editor.reloadPredicate()
    let back = comparisons(editor.objectValue as? NSPredicate)
    let expected = comparisons(stored)
    if back != expected {
        fail("\(what): `\(format)` reopens as `\(back.joined(separator: " AND "))`")
    }
    return rows(editor)
}

func valueField(_ row: O2DicomPredicateEditorView) -> NSTextField? {
    row.subviews.compactMap { $0 as? NSTextField }.first { $0.isEditable }
}

// A row the editor writes, set as the user would.
func written(_ keyPath: String, _ set: (O2DicomPredicateEditorView) -> Void) -> String {
    let row = O2DicomPredicateEditorView(frame: NSRect(x: 0, y: 0, width: 4000, height: 20))
    row.dcmAttributeTag = row.tag(withKeyPath: keyPath)
    set(row)
    return row.predicate.predicateFormat
}

// 1. Codes outside the list.
let modalityCount = O2DicomPredicateEditorCodeStrings.codeStrings(for: O2DicomPredicateEditorView(frame: .zero).tag(withKeyPath: "modality")).count
let userDefined = written("modality") { $0.codeStringTag = modalityCount + 1; $0.stringValue = "XYZ" }
if userDefined != "modality CONTAINS \"XYZ\"" { fail("the user-defined modality row writes `\(userDefined)`") }
for (format, shown) in [(userDefined, "XYZ"), ("modality CONTAINS 5", "5"), ("stateText CONTAINS 7", "7")] {
    let tag = format.hasPrefix("modality") ? "modality" : "stateText"
    let count = O2DicomPredicateEditorCodeStrings.codeStrings(for: O2DicomPredicateEditorView(frame: .zero).tag(withKeyPath: tag)).count
    guard let row = reopen(format, "a code outside the list").first else { continue }
    if row.codeStringTag != count + 1 { fail("`\(format)` reopens on item \(row.codeStringTag), not user-defined (\(count + 1))") }
    if valueField(row)?.stringValue != shown { fail("`\(format)` reopens with the value field showing \(valueField(row)?.stringValue ?? "nothing")") }
}
for format in ["modality CONTAINS \"CT\"", "stateText CONTAINS 2"] {
    if let row = reopen(format, "a listed code").first, valueField(row) != nil { fail("`\(format)` reopens with a user-defined value field") }
}
if let row = reopen("HarnessCodeWithoutList CONTAINS \"ABC\"", in: dicom, "a CS tag without a list").first,
   valueField(row)?.stringValue != "ABC" {
    fail("a CS tag without a list reopens with the value field showing \(valueField(row)?.stringValue ?? "nothing")")
}

// 2. "is <date>", and the date rows that already reopened.
let day = NSCalendar.current.date(from: DateComponents(year: 2026, month: 3, day: 14, hour: 9))!
for keyPath in ["date", "dateAdded"] {
    let isDay = written(keyPath) { $0.operatorTag = equalTo; $0.dateValue = day as NSDate }
    if !isDay.contains("BETWEEN") { fail("the \"is\" row writes `\(isDay)`") }
    if let row = reopen(isDay, "the \"is <date>\" row").first {
        let start = NSCalendar.current.startOfDay(for: day)
        if row.operatorTag != equalTo || (row.dateValue as Date?) != start {
            fail("`\(isDay)` reopens with operator \(row.operatorTag) and date \(String(describing: row.dateValue))")
        }
        if !row.subviews.contains(where: { $0 is NSDatePicker }) { fail("`\(isDay)` reopens without its date picker") }
    }
}
for format in ["date >= $NSDATE_TODAY", "date BETWEEN {$NSDATE_YESTERDAY, $NSDATE_TODAY}",
               "date BETWEEN {$NSDATE_2DAYS, $NSDATE_YESTERDAY}", "date >= $NSDATE_WEEK",
               written("date") { $0.operatorTag = 1; $0.dateValue = day as NSDate },
               written("date") { $0.operatorTag = 3; $0.dateValue = day as NSDate },
               "name CONTAINS[c] \"SMITH\"", "patientID ==[c] \"42\""] {
    reopen(format, "a row that reopened before")
}
reopen(userDefined + " AND " + written("date") { $0.operatorTag = equalTo; $0.dateValue = day as NSDate } + " AND name BEGINSWITH[c] \"A\"",
       "an album of three rows")

// 5. The "within" tags are negative, "the last year" included, and it reopens.
if let row = reopen("date >= $NSDATE_YEAR", "the last year").first {
    let popUps = row.subviews.compactMap { $0 as? NSPopUpButton }
    if let withinPopUp = popUps.first(where: { $0.itemArray.contains { $0.title == "the last year" } }) {
        let tags = withinPopUp.itemArray.filter { !$0.isSeparatorItem }.map { $0.tag }
        if tags.contains(where: { $0 >= 0 }) { fail("the \"within\" items have tags \(tags); O2 time tags must be negative") }
        if row.operatorTag != within || withinPopUp.selectedItem?.title != "the last year" {
            fail("`date >= $NSDATE_YEAR` reopens as operator \(row.operatorTag), \(withinPopUp.selectedItem?.title ?? "no item")")
        }
    } else {
        fail("`date >= $NSDATE_YEAR` reopens without the \"within\" pop-up")
    }
}

// 3. Each multiplicity formatter takes its own mono formatter.
let integers = O2DicomPredicateEditorView.integersFormatter() as? O2DicomPredicateEditorMultiplicityFormatter
let decimals = O2DicomPredicateEditorView.decimalsFormatter() as? O2DicomPredicateEditorMultiplicityFormatter
if integers?.monoFormatter !== O2DicomPredicateEditorView.integerFormatter() { fail("integersFormatter takes another mono formatter") }
if decimals?.monoFormatter !== O2DicomPredicateEditorView.decimalFormatter() { fail("decimalsFormatter takes another mono formatter") }
for (keyPath, value, formatter) in [("InstanceNumber", "3\\4", O2DicomPredicateEditorView.integersFormatter()),
                                   ("SliceThickness", "1.5", O2DicomPredicateEditorView.decimalsFormatter())] {
    let format = written(keyPath) { $0.operatorTag = equalTo; $0.stringValue = value as NSString }
    if let row = reopen(format, in: dicom, "a multi-valued number").first, valueField(row)?.formatter !== formatter {
        fail("`\(format)` reopens with another formatter")
    }
}
print("done")
'''

failures = []
with tempfile.TemporaryDirectory(prefix='horos-smart-album-reopen-') as tmp:
    p = Path(tmp)
    for path in HEADERS + OBJC + RESOURCES:
        (p / Path(path).name).write_bytes(read(path))
    sources = []
    for name in SWIFT:
        (p / f'{name}.swift').write_bytes(read(f'Horos/Sources/{name}.swift'))
        sources.append(str(p / f'{name}.swift'))
    (p / 'Bridge.h').write_text(bridge)
    (p / 'Horos-Swift.h').write_text(swift_header)
    (p / 'Doubles.m').write_text(doubles)
    # The row's tag, in Swift: attributeTag, formerly dcmAttributeTag.
    swift_tag = ('attributeTag' if b'public dynamic var attributeTag' in read('Horos/Sources/O2DicomPredicateEditorView.swift')
                 else 'dcmAttributeTag')
    (p / 'main.swift').write_text(main.replace('row.dcmAttributeTag', 'row.' + swift_tag))

    modules = []
    if uses_module:
        build_module('IsiXImaging', p / 'modules')
        build_module('IsiXDICOMFile', p / 'modules', ['-I', str(p / 'modules')])
        if uses_dataset_module:
            build_module('IsiXDICOMDataset', p / 'modules', ['-I', str(p / 'modules')])
        modules = ['-I', str(p / 'modules')]
    # The app's NSLog writes through IsiXLogging, where the revision has it.
    uses_logging = 'UnifiedLogNSLog' in SWIFT and b'import IsiXLogging' in read('Horos/Sources/UnifiedLogNSLog.swift')
    if uses_logging:
        build_module('IsiXLogging', p / 'modules')
        modules = ['-I', str(p / 'modules')]
    objects = []
    for m in ['Doubles.m'] + [Path(o).name for o in OBJC]:
        o = p / (m + '.o')
        build = subprocess.run(['xcrun', 'clang', '-c', '-fobjc-arc', '-w', '-I', str(p), *modules, str(p / m), '-o', str(o)],
                               capture_output=True, text=True)
        if build.returncode:
            print(build.stderr[-2000:])
            failures.append(f'{m} does not compile')
        objects.append(str(o))
    if not failures:
        build = subprocess.run(['xcrun', 'swiftc', '-import-objc-header', str(p / 'Bridge.h'), '-I', str(p),
                                *modules, *sources, str(p / 'main.swift'), *objects,
                                *(['-L', str(p / 'modules'), '-lIsiXDICOMFile', '-lIsiXImaging'] if uses_module else []),
                                *(['-lIsiXDICOMDataset'] if uses_dataset_module else []),
                                *(['-L', str(p / 'modules'), '-lIsiXLogging'] if uses_logging else []),
                                '-o', str(p / 'test')],
                               capture_output=True, text=True)
        if build.returncode:
            print(build.stderr[-3000:])
            failures.append('the editor does not compile')
    if not failures:
        done = subprocess.run([str(p / 'test')], capture_output=True, text=True, timeout=120)
        failures += [line[6:] for line in done.stdout.splitlines() if line.startswith('FAIL: ')]
        if done.returncode or 'done' not in done.stdout.splitlines():
            failures.append(f'the harness stopped with status {done.returncode}: {done.stderr[-500:]}')
        released = subprocess.run([str(p / 'test'), 'dealloc'], capture_output=True, text=True, timeout=60)
        if released.returncode or 'released' not in released.stdout:
            failures.append(f'an editor made by initWithFrame: fails when released (status {released.returncode}): '
                            f'{released.stderr[-300:]}')

for failure in failures:
    print('FAIL:', failure)
if failures:
    sys.exit(1)
print('PASS: codes outside the list, "is <date>" and "within the last year" rows reopen as written; '
      'each multiplicity formatter takes its own mono formatter; a code-made editor is released cleanly')
