#!/usr/bin/env python3
"""A plugin built for Horos or OsiriX reaches the instance variables of the
host's classes now implemented in Swift.

The former SDK declared instance variables that plugins read and write
directly, from a subclass or from a category of the host's class:
PluginFilter's viewerController, which almost every image filter reads, the
_height, _width, _fImage, ... of PluginFileFormatDecoder, which a file-format
plugin fills in its -checkLoadAtPath:, and those of the viewer's classes. Such
a plugin's binary finds each one's offset through the _OBJC_IVAR_$_Class.ivar
symbol, by flat lookup in the application, and is refused when it loads if one
is missing. The classes are now Swift and keep these variables as stored
fields, whose offsets Swift stores in symbols of its own.

Horos/Scripts/Horos/legacy-plugin-ivars.json is the table of those variables:
for each, the type the SDK declared, the Swift field, the field's offset
symbol, its state and its ownership. The application target links with the
linker response file Horos/Scripts/Horos/legacy-plugin-ivar-aliases.rsp, which
is the rendering of the table: an -alias line exports each field's offset
under the Objective-C name too, and a -u line keeps that name through dead
stripping (Release strips it otherwise). The file takes no comments.

The table:

- every entry has its five fields, with a state and an ownership of those the
  table defines, and a symbol that demangles as the direct field offset of the
  entry's field, which is not private (a private field's symbol is local to
  its object file); no two entries name one symbol;
- the Swift type the symbol names is the one the SDK's C type has in memory,
  and the ownership is value for what is not an object and of an object
  otherwise (tools/legacy_plugin_ivars.py has the correspondence; an array is
  a C struct of one member that Horos/Sources/LegacyPluginIvarStorage.h
  declares);
- the response file is the rendering of the table, entry by entry in the
  table's order. --write-aliases writes it.

The classes of the SDK that are @objc @implementation extensions. The shipped
PluginFilter.swift, PluginFileFormatDecoder.swift and their headers are
compiled optimized and linked, dead stripped, into a host executable, in a
module named Horos as in the application (the Swift symbols carry the module's
name), with a stand-in ViewerController and with the lines of the table that
belong to the classes compiled here (the whole response file names symbols of
classes this host does not have). A bundle built as the former plugins were
(Objective-C without ARC, -undefined dynamic_lookup), whose classes subclass
both as the former SDK declared them, instance variables included, is loaded
by the host, which checks that:

- the bundle loads: every _OBJC_IVAR_$_ symbol it needs is found;
- after -prepareFilter:, the subclass's direct read of viewerController answers
  the viewer, and its direct write is what the property answers;
- viewerController holds its viewer without owning it, as the former SDK's
  variable did: replacing a viewer the subclass stored with no retain does not
  release it, and the filter does not keep a viewer alive;
- a decoder starts with _isRGB YES, as the former -init set it;
- after the subclass's -checkLoadAtPath: stores the values directly, the
  inherited -height, -width, -rowBytes, -windowWidth, -windowLevel, -isRGB,
  -patientName ... -seriesDescription answer them, and Swift reads the same
  through the stored properties;
- the decoder, with the objects the subclass stored retained, is released
  without a crash.

Classes that are plain Swift classes, as the viewer's are. The same host has
two of them, a subclass of NSView and one of NSObject, each with one internal
field of every kind the SDK's variables need: a short, a float, an NSPoint, a
BOOL, an array of 256 bytes and a float[2][3] inside the object (C structs of
one member), an object the class owns, one it stores with no retain
(unowned(unsafe)), one it retains by hand and never releases (the
ManuallyRetained struct of Horos/Sources/ViewerControllerStorage.swift,
compiled here, declared as a field of its own), and one nothing of the host
uses. Each class also has a field the SDK never had, before the others. Their
aliases come from a table of the test's own, with the same five fields. The
bundle declares both classes as an SDK header would, without the extra field,
and reads and writes every variable from a category. The host checks that:

- each alias is exported, at the address of the Swift symbol it names, and
  holds the offset the Objective-C runtime gives for the field;
- the bundle's category reads what Swift stored in every field, and Swift
  reads what the category stored, the arrays whole, with the field the SDK
  never had untouched;
- the owned object the category replaced was released by the category's own
  release and the one it stored retained is released by Swift; the unowned
  field neither keeps its object nor releases it; the hand-retained field
  takes the category's retained pointer and Swift's next store releases it;
  when the instance goes, it releases the owned object and not the
  hand-retained one.

The completion of the table from a build (tools/legacy_plugin_ivars.py
complete), with the objects of this host as the build: from the entries of
PluginFilter and PluginFileFormatDecoder, one of them with a symbol that is
not its field's, and two fragments that give the variables of the two plain
Swift classes without their symbols, the classes mixed, it writes the table
this test links with, entry for entry, in the table's text: the entries there
were first, then each class's in the order the fragments have, every symbol
read from the objects. Run again, it writes the same. It writes nothing and
names each entry at fault for a field the objects do not have, a C type that
is not the field's, an array of another size, an object whose ownership is
value, two variables on one field, a variable in two fragments, and a field
that is private in the objects.

What must not link or load, each checked beside a link that succeeds:

- without the -u lines the host links and exports none of the names: the
  bundle is refused, for a missing _OBJC_IVAR_$_ symbol;
- without the -alias lines the host does not link;
- with a field of another type, with a private field, or with the
  hand-retained object declared through the property wrapper attribute (whose
  storage Swift makes private), the Swift symbol the table names does not
  exist and the host does not link.

The plugin that reads and writes the variables inside the application,
QALegacyIvars.horosplugin of tools/generate-plugin-load-fixtures.py, is built
here, which needs no application: in both architectures its binary looks up
instance variables of DCMView, ROI, ViewerController and AppController alone,
and among them every one of those classes that tests/legacy-plugin-abi.json
counts as read by a known plugin. It loads only in the application, which is
where it is run.

    python3 tests/test-legacy-plugin-instance-variables.py
    python3 tests/test-legacy-plugin-instance-variables.py --write-aliases
"""
from pathlib import Path
import json
import plistlib
import re
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
import legacy_plugin_ivars  # noqa: E402
from legacy_plugin_ivars import ALIASES, PREFIX, TABLE, render_aliases  # noqa: E402

TOOL = ROOT / 'tools/legacy_plugin_ivars.py'
FIXTURES = ROOT / 'tools/generate-plugin-load-fixtures.py'
REGISTRY = ROOT / 'tests/legacy-plugin-abi.json'
# The classes whose instance variables the in-app plugin reads and writes.
FIXTURE_CLASSES = ('DCMView', 'ROI', 'ViewerController', 'AppController')
SOURCES = {'PluginFilter': ROOT / 'Horos/Sources/PluginFilter.swift',
           'PluginFileFormatDecoder': ROOT / 'Horos/Sources/PluginFileFormatDecoder.swift'}
HEADERS = {'PluginFilter': ROOT / 'Horos/Sources/PluginFilter.h',
           'PluginFileFormatDecoder': ROOT / 'Horos/Sources/PluginFileFormatDecoder.h'}
STORAGE = ROOT / 'Horos/Sources/ViewerControllerStorage.swift'
# A C array inside the object is a C struct of one member: Swift imports it as a
# value of that size, where a Swift array is a reference to storage elsewhere.
PROBE_STRUCTS = r'''
typedef struct { unsigned char v[256]; } LegacyIvarProbeBytes256;
typedef struct { float v[2][3]; } LegacyIvarProbeFloats2x3;
_Static_assert(sizeof(LegacyIvarProbeBytes256) == 256, "the bytes of unsigned char[256]");
_Static_assert(sizeof(LegacyIvarProbeFloats2x3) == sizeof(float[2][3]), "the bytes of float[2][3]");
'''

# The table of the two plain Swift classes of this test, as the application's
# table has its entries.
PROBES = {
    'LegacyIvarProbeView.curImage': {
        'sdk': 'short', 'field': 'curImage', 'state': 'live', 'ownership': 'value',
        'symbol': '_$s5Horos19LegacyIvarProbeViewC8curImages5Int16VvpWvd'},
    'LegacyIvarProbeView.scaleValue': {
        'sdk': 'float', 'field': 'scaleValue', 'state': 'live', 'ownership': 'value',
        'symbol': '_$s5Horos19LegacyIvarProbeViewC10scaleValueSfvpWvd'},
    'LegacyIvarProbeView.origin': {
        'sdk': 'NSPoint', 'field': 'origin', 'state': 'live', 'ownership': 'value',
        'symbol': '_$s5Horos19LegacyIvarProbeViewC6originSo7CGPointVvpWvd'},
    'LegacyIvarProbeView.xFlipped': {
        'sdk': 'BOOL', 'field': 'xFlipped', 'state': 'live', 'ownership': 'value',
        'symbol': '_$s5Horos19LegacyIvarProbeViewC8xFlippedSbvpWvd'},
    'LegacyIvarProbeView.redTable': {
        'sdk': 'unsigned char[256]', 'field': 'redTable', 'state': 'live', 'ownership': 'value',
        'symbol': '_$s5Horos19LegacyIvarProbeViewC8redTableSo0bcD8Bytes256avpWvd'},
    'LegacyIvarProbeView.sliceFromTo': {
        'sdk': 'float[2][3]', 'field': 'sliceFromTo', 'state': 'live', 'ownership': 'value',
        'symbol': '_$s5Horos19LegacyIvarProbeViewC11sliceFromToSo0bcD9Floats2x3avpWvd'},
    'LegacyIvarProbeView.dcmPixList': {
        'sdk': 'NSMutableArray *', 'field': 'dcmPixList', 'state': 'live', 'ownership': 'strong',
        'symbol': '_$s5Horos19LegacyIvarProbeViewC10dcmPixListSo14NSMutableArrayCSgvpWvd'},
    'LegacyIvarProbeView.clutPopup': {
        'sdk': 'NSObject *', 'field': 'clutPopup', 'state': 'live', 'ownership': 'unowned',
        'symbol': '_$s5Horos19LegacyIvarProbeViewC9clutPopupSo8NSObjectCSgvpWvd'},
    'LegacyIvarProbeView.thickSlab': {
        'sdk': 'NSObject *', 'field': '_thickSlab', 'state': 'live', 'ownership': 'manual',
        'symbol': '_$s5Horos19LegacyIvarProbeViewC10_thickSlabAA16ManuallyRetainedVySo8NSObjectCGvpWvd'},
    'LegacyIvarProbeView.fontListGL': {
        'sdk': 'GLuint', 'field': 'fontListGL', 'state': 'inert', 'ownership': 'value',
        'symbol': '_$s5Horos19LegacyIvarProbeViewC10fontListGLs6UInt32VvpWvd'},
    'LegacyIvarProbeObject.clickCount': {
        'sdk': 'short', 'field': 'clickCount', 'state': 'live', 'ownership': 'value',
        'symbol': '_$s5Horos21LegacyIvarProbeObjectC10clickCounts5Int16VvpWvd'},
    'LegacyIvarProbeObject.thickness': {
        'sdk': 'float', 'field': 'thickness', 'state': 'live', 'ownership': 'value',
        'symbol': '_$s5Horos21LegacyIvarProbeObjectC9thicknessSfvpWvd'},
    'LegacyIvarProbeObject.imageOrigin': {
        'sdk': 'NSPoint', 'field': 'imageOrigin', 'state': 'live', 'ownership': 'value',
        'symbol': '_$s5Horos21LegacyIvarProbeObjectC11imageOriginSo7CGPointVvpWvd'},
    'LegacyIvarProbeObject.locked': {
        'sdk': 'BOOL', 'field': 'locked', 'state': 'live', 'ownership': 'value',
        'symbol': '_$s5Horos21LegacyIvarProbeObjectC6lockedSbvpWvd'},
    'LegacyIvarProbeObject.opacityTable': {
        'sdk': 'unsigned char[256]', 'field': 'opacityTable', 'state': 'live', 'ownership': 'value',
        'symbol': '_$s5Horos21LegacyIvarProbeObjectC12opacityTableSo0bcD8Bytes256avpWvd'},
    'LegacyIvarProbeObject.corners': {
        'sdk': 'float[2][3]', 'field': 'corners', 'state': 'live', 'ownership': 'value',
        'symbol': '_$s5Horos21LegacyIvarProbeObjectC7cornersSo0bcD9Floats2x3avpWvd'},
    'LegacyIvarProbeObject.points': {
        'sdk': 'NSMutableArray *', 'field': 'points', 'state': 'live', 'ownership': 'strong',
        'symbol': '_$s5Horos21LegacyIvarProbeObjectC6pointsSo14NSMutableArrayCSgvpWvd'},
    'LegacyIvarProbeObject.curView': {
        'sdk': 'NSObject *', 'field': 'curView', 'state': 'live', 'ownership': 'unowned',
        'symbol': '_$s5Horos21LegacyIvarProbeObjectC7curViewSo8NSObjectCSgvpWvd'},
    'LegacyIvarProbeObject.parentROI': {
        'sdk': 'NSObject *', 'field': '_parentROI', 'state': 'live', 'ownership': 'manual',
        'symbol': '_$s5Horos21LegacyIvarProbeObjectC10_parentROIAA16ManuallyRetainedVySo8NSObjectCGvpWvd'},
    'LegacyIvarProbeObject.stringTex': {
        'sdk': 'StringTexture *', 'field': 'stringTex', 'state': 'inert', 'ownership': 'strong',
        'symbol': '_$s5Horos21LegacyIvarProbeObjectC9stringTexyXlSgvpWvd'},
}


def fail(message):
    print('FAIL: ' + message)
    raise SystemExit(1)


def run(command, **options):
    return subprocess.run(command, capture_output=True, text=True, **options)


def check_table(ivars, where, structs):
    """What every entry of a table must be, whatever the classes a build has."""
    try:
        problems = legacy_plugin_ivars.table_problems(ivars, where, structs)
    except legacy_plugin_ivars.TableError as error:
        fail(str(error))
    if problems:
        fail('; '.join(problems[:20]))


try:
    table = legacy_plugin_ivars.read_table(TABLE)
    storage = legacy_plugin_ivars.storage_structs(legacy_plugin_ivars.STORAGE.read_text(encoding='utf-8'))
except (legacy_plugin_ivars.TableError, OSError) as error:
    fail(str(error))
ivars = table['ivars']
check_table(ivars, str(TABLE.relative_to(ROOT)), storage)
check_table(PROBES, 'the table of the test', legacy_plugin_ivars.storage_structs(PROBE_STRUCTS))

if sys.argv[1:] == ['--write-aliases']:
    ALIASES.write_text(render_aliases(ivars), encoding='utf-8')
    print(f'{ALIASES.relative_to(ROOT)}: written from the {len(ivars)} entries of {TABLE.relative_to(ROOT)}')
    raise SystemExit(0)
if sys.argv[1:]:
    fail(f'unknown arguments {sys.argv[1:]}; the only one is --write-aliases')
if not ALIASES.is_file() or ALIASES.read_text(encoding='utf-8') != render_aliases(ivars):
    fail(f'{ALIASES.relative_to(ROOT)} is not the rendering of {TABLE.relative_to(ROOT)}: '
         f'python3 tests/{Path(__file__).name} --write-aliases')

# The lines of the application's table this host can link: those of the classes it compiles.
shipped = {name: entry for name, entry in ivars.items() if name.split('.')[0] in SOURCES}
absent = sorted(set(SOURCES) - {name.split('.')[0] for name in shipped})
if absent:
    fail(f'{TABLE.relative_to(ROOT)} has no instance variable of {", ".join(absent)}')

interfaces = []
for name, header in HEADERS.items():
    found = re.search(r'^@interface ' + name + r' : NSObject\b.*?^@end\b', header.read_bytes().decode('latin1'), re.S | re.M)
    if found is None:
        fail(f'{header.relative_to(ROOT)} does not declare @interface {name} : NSObject')
    interfaces.append(found.group(0))
host_header = ('#import <Cocoa/Cocoa.h>\n#import <CoreData/CoreData.h>\n@class ViewerController;\n'
               + '\n'.join(interfaces) + PROBE_STRUCTS)

# What the application gives PluginFilter.swift: the open viewers and a viewer's copy.
stand_ins = r'''
import Foundation

@objc(ViewerController) public final class ViewerController: NSObject {
    nonisolated(unsafe) public static var released = 0
    deinit { ViewerController.released += 1 }
    @objc(getDisplayed2DViewers) public class func getDisplayed2DViewers() -> NSMutableArray! { NSMutableArray() }
    @MainActor @objc(horosDuplicatedViewerWindow) public func horosDuplicatedViewerWindow() -> ViewerController? { nil }
}
'''

# Plain Swift classes, as the viewer's: public, named for the Objective-C
# runtime, with internal stored fields of the types the SDK's declarations have
# in memory. isiXOnly is no variable of the SDK and comes first, so that the
# offsets the bundle uses can only be those of the symbols.
probes = r'''
import AppKit

@objc(LegacyIvarProbeView)
public class LegacyIvarProbeView: NSView {
    final var isiXOnly = 0x1122334455667788
    nonisolated(unsafe) final var curImage: Int16 = 0
    final var scaleValue: Float = 0
    final var origin = NSPoint.zero
    final var xFlipped = false
    final var redTable = LegacyIvarProbeBytes256()
    final var sliceFromTo = LegacyIvarProbeFloats2x3()
    final var dcmPixList: NSMutableArray?
    unowned(unsafe) final var clutPopup: NSObject?
    final var _thickSlab = ManuallyRetained<NSObject>()
    final var fontListGL: UInt32 = 0
}

@objc(LegacyIvarProbeObject)
public class LegacyIvarProbeObject: NSObject {
    final var isiXOnly = 0x1122334455667788
    final var clickCount: Int16 = 0
    final var thickness: Float = 0
    final var imageOrigin = NSPoint.zero
    final var locked = false
    final var opacityTable = LegacyIvarProbeBytes256()
    final var corners = LegacyIvarProbeFloats2x3()
    final var points: NSMutableArray!
    unowned(unsafe) final var curView: NSObject?
    final var _parentROI = ManuallyRetained<NSObject>()
    final var stringTex: AnyObject?
}
'''
# The same classes with one field that no longer is what the table names.
VARIANTS = {
    'a field of another type': ('LegacyIvarProbeView.curImage',
                                'final var curImage: Int16 = 0', 'final var curImage: Int = 0'),
    'a private field': ('LegacyIvarProbeObject.thickness',
                        'final var thickness: Float = 0', 'private final var thickness: Float = 0'),
    'a field declared through the property wrapper attribute': (
        'LegacyIvarProbeView.thickSlab',
        'final var _thickSlab = ManuallyRetained<NSObject>()', '@ManuallyRetained final var thickSlab: NSObject?'),
}
minimal = 'import Foundation\nprint(LegacyIvarProbeView.self, LegacyIvarProbeObject.self)\n'

host = r'''
import AppKit

var failed = 0
@MainActor func check(_ ok: Bool, _ what: String) {
    if !ok { print("FAIL: " + what); failed += 1 }
}
func send(_ target: AnyObject, _ name: String, _ argument: AnyObject?) -> AnyObject? {
    target.perform(NSSelectorFromString(name), with: argument)?.takeUnretainedValue()
}
func sendLong(_ target: AnyObject, _ name: String, _ argument: AnyObject?) -> Int {
    let selector = NSSelectorFromString(name)
    typealias Method = @convention(c) (AnyObject, Selector, AnyObject?) -> Int
    return unsafeBitCast(target.method(for: selector), to: Method.self)(target, selector, argument)
}

let bundle = Bundle(path: CommandLine.arguments[1])!
do { try bundle.loadAndReturnError() } catch { print("FAIL: the bundle does not load: \(error)"); exit(1) }

// Each exported name holds the offset the runtime gives for the field. A
// plugin's code reads the name as a 32-bit integer, which on a little-endian
// processor is the low half of the 64-bit value Swift keeps.
for line in try! String(contentsOfFile: CommandLine.arguments[2], encoding: .utf8).split(separator: "\n") {
    let parts = line.split(separator: " ").map(String.init)
    let (className, variable, field) = (parts[0], parts[1], parts[2])
    guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "OBJC_IVAR_$_\(className).\(variable)") else {
        check(false, "\(className).\(variable) is not exported"); continue
    }
    guard let found = class_getInstanceVariable(NSClassFromString(className), field) else {
        check(false, "\(className) has no field \(field) for the runtime"); continue
    }
    let offset = ivar_getOffset(found)
    check(offset >= MemoryLayout<Int>.size && Int(symbol.load(as: Int32.self)) == offset && symbol.load(as: Int.self) == offset,
          "_OBJC_IVAR_$_\(className).\(variable) holds \(symbol.load(as: Int.self)), and \(field) is at \(offset)")
}

// PluginFilter.viewerController
guard let filterClass = bundle.classNamed("LegacyIvarFilter") as? PluginFilter.Type, let filter = filterClass.filter() else {
    print("FAIL: no LegacyIvarFilter"); exit(1)
}
let viewer = ViewerController()
check(sendLong(filter, "prepareFilter:", viewer) == 0, "-prepareFilter: answers 0")
check(send(filter, "readViewer", nil) === viewer, "the subclass reads the viewer -prepareFilter: kept in its viewerController instance variable")
let other = ViewerController()
_ = send(filter, "writeViewer:", other)
check(filter.viewerController === other, "what the subclass stores in viewerController is what the property answers")

// The variable holds its viewer without owning it, as the former SDK's did: a
// plugin stores a viewer there with no retain, and what replaces it must not
// release what the plugin never retained.
autoreleasepool {
    var stored: ViewerController? = ViewerController()
    _ = send(filter, "writeViewer:", stored)
    check(sendLong(filter, "prepareFilter:", nil) == 0 && filter.viewerController == nil, "-prepareFilter: with no viewer empties the variable")
    if ViewerController.released != 0 {
        print("FAIL: replacing a viewer the subclass stored without a retain released it"); exit(1)
    }
    stored = nil
}
check(ViewerController.released == 1, "the viewer the subclass stored is released once, by its owner: \(ViewerController.released)")
// Nor does the filter keep alive the viewer -prepareFilter: gave it.
autoreleasepool {
    var kept: ViewerController? = ViewerController()
    weak let watched = kept
    _ = sendLong(filter, "prepareFilter:", kept)
    kept = nil
    check(watched == nil, "the filter does not own the viewer -prepareFilter: gave it")
}
_ = sendLong(filter, "prepareFilter:", nil)

// PluginFileFormatDecoder._height, ...
autoreleasepool {
    guard let decoderClass = bundle.classNamed("LegacyIvarDecoder") as? PluginFileFormatDecoder.Type else {
        print("FAIL: no LegacyIvarDecoder"); exit(1)
    }
    // As DicomFile and DCMPix make it: the principal class, as an NSObject class, sent -init.
    let decoder = (decoderClass as NSObject.Type).init() as! PluginFileFormatDecoder
    check(decoder.isRGB() && decoder._isRGB, "a new decoder is RGB, as the former -init made it")
    check(decoder.height() == nil && decoder.patientName() == nil, "a new decoder answers nil")
    let pixels = decoder.checkLoad(atPath: "/synthetic/image.jpc")
    check(pixels != nil && pixels?[0] == 12.5 && pixels?[5] == -3.0, "-checkLoadAtPath: is the subclass's and answers its pixels")
    check(decoder.height()?.intValue == 3 && decoder.width()?.intValue == 2 && decoder.rowBytes()?.intValue == 8
          && decoder.windowWidth()?.intValue == 400 && decoder.windowLevel()?.intValue == 40,
          "-height, -width, -rowBytes, -windowWidth, -windowLevel answer what the subclass stored")
    check(!decoder.isRGB() && !decoder._isRGB, "-isRGB answers the NO the subclass stored")
    check(decoder.patientName() == "SYNTHETIC^IVAR" && decoder.patientID() == "IVAR-1" && decoder.studyID() == "S1"
          && decoder.seriesID() == "SE1" && decoder.imageID() == "I1" && decoder.studyDescription() == "Study"
          && decoder.seriesDescription() == "Series",
          "-patientName ... -seriesDescription answer what the subclass stored")
    check(decoder._fImage == pixels && decoder._height?.intValue == 3, "Swift reads the same values through the stored properties")
    free(pixels)
    decoder._fImage = nil
}

// The plain Swift classes: one view of the fields of both, for one set of checks.
@MainActor protocol LegacyIvarProbe: NSObject {
    var isiXOnly: Int { get }
    var probeShort: Int16 { get set }
    var probeFloat: Float { get set }
    var probePoint: NSPoint { get set }
    var probeFlag: Bool { get set }
    var probeBytes: LegacyIvarProbeBytes256 { get set }
    var probeFloats: LegacyIvarProbeFloats2x3 { get set }
    var probeOwned: NSMutableArray? { get set }
    var probeUnowned: NSObject? { get set }
    var probeManual: ManuallyRetained<NSObject> { get set }
    /// The field nothing of the host uses, as an object: nil while it is 0 or nil.
    var probeInert: AnyObject? { get }
}
extension LegacyIvarProbeView: LegacyIvarProbe {
    var probeShort: Int16 { get { curImage } set { curImage = newValue } }
    var probeFloat: Float { get { scaleValue } set { scaleValue = newValue } }
    var probePoint: NSPoint { get { origin } set { origin = newValue } }
    var probeFlag: Bool { get { xFlipped } set { xFlipped = newValue } }
    var probeBytes: LegacyIvarProbeBytes256 { get { redTable } set { redTable = newValue } }
    var probeFloats: LegacyIvarProbeFloats2x3 { get { sliceFromTo } set { sliceFromTo = newValue } }
    var probeOwned: NSMutableArray? { get { dcmPixList } set { dcmPixList = newValue } }
    var probeUnowned: NSObject? { get { clutPopup } set { clutPopup = newValue } }
    var probeManual: ManuallyRetained<NSObject> { get { _thickSlab } set { _thickSlab = newValue } }
    var probeInert: AnyObject? { fontListGL == 0 ? nil : NSNumber(value: fontListGL) }
}
extension LegacyIvarProbeObject: LegacyIvarProbe {
    var probeShort: Int16 { get { clickCount } set { clickCount = newValue } }
    var probeFloat: Float { get { thickness } set { thickness = newValue } }
    var probePoint: NSPoint { get { imageOrigin } set { imageOrigin = newValue } }
    var probeFlag: Bool { get { locked } set { locked = newValue } }
    var probeBytes: LegacyIvarProbeBytes256 { get { opacityTable } set { opacityTable = newValue } }
    var probeFloats: LegacyIvarProbeFloats2x3 { get { corners } set { corners = newValue } }
    var probeOwned: NSMutableArray? { get { points } set { points = newValue } }
    var probeUnowned: NSObject? { get { curView } set { curView = newValue } }
    var probeManual: ManuallyRetained<NSObject> { get { _parentROI } set { _parentROI = newValue } }
    var probeInert: AnyObject? { stringTex }
}

/// What the bundle's -legacyWrite: stores in the field nothing of the host uses.
final class InertMarker: NSObject {}
let inertMarker = InertMarker()

@MainActor func checkProbe<Probe: LegacyIvarProbe>(_ name: String, _ make: () -> Probe, inert: (AnyObject?) -> Bool) {
    weak var firstOwned: NSMutableArray?, firstUnowned: NSObject?, firstManual: NSObject?
    weak var secondOwned: NSMutableArray?, secondUnowned: NSObject?, secondManual: NSObject?
    let probe = make()
    autoreleasepool {
        // Swift stores, the bundle's category reads.
        let (owned, unowned, manual) = (NSMutableArray(), NSObject(), NSObject())
        (firstOwned, firstUnowned, firstManual) = (owned, unowned, manual)
        var bytes = LegacyIvarProbeBytes256(), floats = LegacyIvarProbeFloats2x3()
        withUnsafeMutableBytes(of: &bytes) { raw in for i in 0..<raw.count { raw[i] = UInt8(truncatingIfNeeded: i &* 3 &+ 1) } }
        withUnsafeMutableBytes(of: &floats) { raw in
            let values = raw.bindMemory(to: Float.self)
            for i in 0..<values.count { values[i] = Float(i) + 0.5 }
        }
        probe.probeShort = -321; probe.probeFloat = 1.25; probe.probePoint = NSPoint(x: 10.5, y: -20.25); probe.probeFlag = true
        probe.probeBytes = bytes; probe.probeFloats = floats
        probe.probeOwned = owned; probe.probeUnowned = unowned; probe.probeManual.wrappedValue = manual
        guard let seen = send(probe, "legacyRead", nil) as? [AnyObject], seen.count == 10 else {
            check(false, "\(name): the category does not answer its ten variables"); return
        }
        check((seen[0] as? NSNumber)?.int16Value == -321 && (seen[1] as? NSNumber)?.floatValue == 1.25
              && (seen[2] as? NSValue)?.pointValue == NSPoint(x: 10.5, y: -20.25) && (seen[3] as? NSNumber)?.boolValue == true,
              "\(name): the category reads the short, the float, the point and the BOOL Swift stored: \(seen[0]) \(seen[1]) \(seen[2]) \(seen[3])")
        check(seen[4] as? Data == withUnsafeBytes(of: bytes) { Data($0) } && (seen[4] as? Data)?.count == 256,
              "\(name): the category reads the 256 bytes Swift stored")
        check(seen[5] as? Data == withUnsafeBytes(of: floats) { Data($0) } && (seen[5] as? Data)?.count == 24,
              "\(name): the category reads the float[2][3] Swift stored")
        check(seen[6] === owned && seen[7] === unowned && seen[8] === manual, "\(name): the category reads the three objects Swift stored")
        check(seen[9] is NSNull || (seen[9] as? NSNumber)?.intValue == 0, "\(name): the field nothing uses is 0 or nil for the category: \(seen[9])")
    }
    autoreleasepool {
        // The category stores, Swift reads.
        let (owned, unowned, manual) = (NSMutableArray(), NSObject(), NSObject())
        (secondOwned, secondUnowned, secondManual) = (owned, unowned, manual)
        _ = send(probe, "legacyWrite:", [owned, unowned, manual, inertMarker] as NSArray)
        check(probe.probeShort == -12345 && probe.probeFloat == 3.5 && probe.probePoint == NSPoint(x: -7.5, y: 8.25) && !probe.probeFlag,
              "\(name): Swift reads the short, the float, the point and the BOOL the category stored: "
              + "\(probe.probeShort) \(probe.probeFloat) \(probe.probePoint) \(probe.probeFlag)")
        check(withUnsafeBytes(of: probe.probeBytes) { Array($0) } == (0..<256).map { UInt8(255 - $0) },
              "\(name): Swift reads the 256 bytes the category stored")
        check(withUnsafeBytes(of: probe.probeFloats) { Array($0.bindMemory(to: Float.self)) } == (0..<6).map { -Float($0) - 0.25 },
              "\(name): Swift reads the float[2][3] the category stored")
        check(probe.probeOwned === owned && probe.probeUnowned === unowned && probe.probeManual.wrappedValue === manual,
              "\(name): Swift reads the three objects the category stored")
        check(inert(probe.probeInert), "\(name): Swift reads what the category stored in the field nothing uses")
        check(probe.isiXOnly == 0x1122334455667788, "\(name): the field the SDK never had is untouched: \(probe.isiXOnly)")
        // The unowned field is emptied while its object lives; neither store releases it.
        probe.probeUnowned = nil
        check(secondUnowned != nil, "\(name): emptying the unowned field does not release the object the category stored")
    }
    check(firstOwned == nil, "\(name): the owned object the category replaced was released by the category's release")
    check(firstManual == nil, "\(name): the hand-retained object the category replaced was released by the category's release")
    check(firstUnowned == nil && secondUnowned == nil, "\(name): the unowned field keeps no object alive")
    check(secondOwned != nil && secondManual != nil, "\(name): the fields hold the objects the category stored retained")
    probe.probeOwned = nil
    check(secondOwned == nil, "\(name): Swift releases the owned object the category stored retained")
    probe.probeManual.wrappedValue = nil
    check(secondManual == nil, "\(name): Swift's store in the hand-retained field releases what the category stored retained")

    // When the instance goes: it releases the object it owns, not the one retained by hand.
    weak var lastOwned: NSMutableArray?, lastManual: NSObject?
    autoreleasepool {
        let (owned, manual) = (NSMutableArray(), NSObject())
        (lastOwned, lastManual) = (owned, manual)
        let leaving = make()
        _ = send(leaving, "legacyWrite:", [owned, NSNull(), manual, NSNull()] as NSArray)
    }
    check(lastOwned == nil, "\(name): an instance that goes releases the owned object the category stored")
    check(lastManual != nil, "\(name): an instance that goes does not release the hand-retained object")
    autoreleasepool { if let manual = lastManual { Unmanaged.passUnretained(manual).release() } }
    check(lastManual == nil, "\(name): the hand-retained object had the category's retain alone")
}
checkProbe("LegacyIvarProbeView", { LegacyIvarProbeView(frame: .zero) },
           inert: { ($0 as? NSNumber)?.uint32Value == 0xDEADBEEF })
checkProbe("LegacyIvarProbeObject", { LegacyIvarProbeObject() }, inert: { $0 === inertMarker })

if failed > 0 { exit(1) }
print("ok")
'''

plugin = r'''
#import <Cocoa/Cocoa.h>
#import <CoreData/CoreData.h>
#include <stdlib.h>
// The classes as the former SDK declared them, instance variables included; the
// classes themselves are the host's.
@class ViewerController;
@interface PluginFilter : NSObject
{
    ViewerController *viewerController;
}
+ (PluginFilter *)filter;
- (long)prepareFilter:(ViewerController *)vC;
@end
@interface PluginFileFormatDecoder : NSObject
{
    NSNumber *_height;
    NSNumber *_width;
    float *_fImage;
    NSNumber * _rowBytes;
    NSNumber *_windowWidth;
    NSNumber *_windowLevel;
    BOOL _isRGB;

    NSString *_patientName;
    NSString *_patientID;
    NSString *_studyID;
    NSString *_seriesID;
    NSString *_imageID;
    NSString *_studyDescription;
    NSString *_seriesDescription;
}
- (float *)checkLoadAtPath:(NSString *)path;
@end

@interface LegacyIvarFilter : PluginFilter
@end
@implementation LegacyIvarFilter
- (id)readViewer { return (id)viewerController; }
- (void)writeViewer:(id)viewer { viewerController = viewer; }
@end

@interface LegacyIvarDecoder : PluginFileFormatDecoder
@end
@implementation LegacyIvarDecoder
- (float *)checkLoadAtPath:(NSString *)path
{
    _height = [[NSNumber numberWithInt:3] retain];
    _width = [[NSNumber numberWithInt:2] retain];
    _rowBytes = [[NSNumber numberWithInt:8] retain];
    _windowWidth = [[NSNumber numberWithInt:400] retain];
    _windowLevel = [[NSNumber numberWithInt:40] retain];
    _isRGB = NO;
    _patientName = [@"SYNTHETIC^IVAR" retain];
    _patientID = [@"IVAR-1" retain];
    _studyID = [@"S1" retain];
    _seriesID = [@"SE1" retain];
    _imageID = [@"I1" retain];
    _studyDescription = [@"Study" retain];
    _seriesDescription = [[NSString alloc] initWithFormat:@"%@", @"Series"];
    float *pixels = malloc(6 * sizeof(float));
    for (int i = 0; i < 6; i++) pixels[i] = i == 0 ? 12.5f : -3.0f;
    _fImage = pixels;
    return _fImage;
}
@end

// The two plain Swift classes, as a header of the SDK would declare them: the
// host's own extra field is not here, and the variable the host retains by
// hand has the name the SDK gave it.
typedef unsigned int GLuint;
@class StringTexture;
@interface LegacyIvarProbeView : NSView
{
    short curImage;
    float scaleValue;
    NSPoint origin;
    BOOL xFlipped;
    unsigned char redTable[256];
    float sliceFromTo[2][3];
    NSMutableArray *dcmPixList;
    NSObject *clutPopup;
    NSObject *thickSlab;
    GLuint fontListGL;
}
@end
@interface LegacyIvarProbeObject : NSObject
{
    short clickCount;
    float thickness;
    NSPoint imageOrigin;
    BOOL locked;
    unsigned char opacityTable[256];
    float corners[2][3];
    NSMutableArray *points;
    NSObject *curView;
    NSObject *parentROI;
    StringTexture *stringTex;
}
@end

// A category of the host's class that reads and writes every variable directly,
// with the retains and releases the SDK's code expected of whoever stored there.
#define LEGACY_ACCESS(CLASS, SHORT, FLOAT, POINT, FLAG, BYTES, FLOATS, OWNED, UNOWNED, MANUAL, INERT_READ, INERT_WRITE) \
@implementation CLASS (LegacyPlugin) \
- (NSArray *)legacyRead \
{ \
    return [NSArray arrayWithObjects:[NSNumber numberWithShort:SHORT], [NSNumber numberWithFloat:FLOAT], \
            [NSValue valueWithPoint:POINT], [NSNumber numberWithBool:FLAG], \
            [NSData dataWithBytes:BYTES length:sizeof(BYTES)], [NSData dataWithBytes:FLOATS length:sizeof(FLOATS)], \
            OWNED ?: (id)[NSNull null], UNOWNED ?: (id)[NSNull null], MANUAL ?: (id)[NSNull null], INERT_READ, nil]; \
} \
- (void)legacyWrite:(NSArray *)objects \
{ \
    SHORT = -12345; FLOAT = 3.5f; POINT = NSMakePoint(-7.5, 8.25); FLAG = NO; \
    for (int i = 0; i < 256; i++) BYTES[i] = 255 - i; \
    for (int row = 0; row < 2; row++) for (int column = 0; column < 3; column++) FLOATS[row][column] = -(row * 3 + column) - 0.25f; \
    [OWNED release]; OWNED = [[objects objectAtIndex:0] retain]; \
    UNOWNED = [objects objectAtIndex:1]; \
    [MANUAL release]; MANUAL = [[objects objectAtIndex:2] retain]; \
    INERT_WRITE; \
} \
@end

LEGACY_ACCESS(LegacyIvarProbeView, curImage, scaleValue, origin, xFlipped, redTable, sliceFromTo, dcmPixList, clutPopup, thickSlab,
              [NSNumber numberWithUnsignedInt:fontListGL], fontListGL = 0xDEADBEEF)
LEGACY_ACCESS(LegacyIvarProbeObject, clickCount, thickness, imageOrigin, locked, opacityTable, corners, points, curView, parentROI,
              (id)stringTex ?: (id)[NSNull null], stringTex = [[objects objectAtIndex:3] retain])
'''


def exported(binary):
    listing = run(['xcrun', 'nm', '-gUj', str(binary)])
    if listing.returncode != 0:
        fail(f'nm does not list {binary.name}: {listing.stderr.strip()[-500:]}')
    return set(listing.stdout.split())


def addresses(binary):
    listing = run(['xcrun', 'nm', str(binary)])
    if listing.returncode != 0:
        fail(f'nm does not list {binary.name}: {listing.stderr.strip()[-500:]}')
    return {parts[2]: parts[0] for parts in (line.split(' ', 2) for line in listing.stdout.splitlines()) if len(parts) == 3}


with tempfile.TemporaryDirectory(prefix='horos-legacy-ivars-') as temporary:
    work = Path(temporary)
    (work / 'Host.h').write_text(host_header, encoding='latin1')
    for source in (*SOURCES.values(), STORAGE):
        (work / source.name).write_bytes(source.read_bytes())
    (work / 'StandIns.swift').write_text(stand_ins)
    (work / 'Probes.swift').write_text(probes)
    (work / 'main.swift').write_text(host)
    (work / 'Legacy.m').write_text(plugin)
    linked = {**shipped, **PROBES}
    (work / 'linked.rsp').write_text(render_aliases(linked))
    (work / 'linked.txt').write_text(''.join(f'{name.replace(".", " ")} {entry["field"]}\n' for name, entry in linked.items()))
    legacy = work / 'Legacy.bundle'
    (legacy / 'Contents/MacOS').mkdir(parents=True)
    (legacy / 'Contents/Info.plist').write_bytes(plistlib.dumps({
        'CFBundleExecutable': 'Legacy', 'CFBundleIdentifier': 'org.example.legacy-ivars', 'CFBundlePackageType': 'BNDL',
        'NSPrincipalClass': 'LegacyIvarFilter'}))
    swiftc = ['xcrun', 'swiftc', '-swift-version', '6', '-module-name', 'Horos', '-import-objc-header', str(work / 'Host.h')]

    def link(objects, response, output):
        # As the application target passes it, "-Wl,@file": inside -Wl the file reaches ld unexpanded.
        return run([*swiftc, *[str(item) for item in objects], '-Xlinker', '-dead_strip',
                    '-Xclang-linker', '-Wl,@' + str(response), '-o', str(output)])

    # Optimized as Release is, the whole module at once, then linked dead stripped.
    built = run([*swiftc, '-O', '-wmo', '-emit-object', *[str(work / s.name) for s in (*SOURCES.values(), STORAGE)],
                 str(work / 'StandIns.swift'), str(work / 'Probes.swift'), str(work / 'main.swift'), '-o', str(work / 'host.o')])
    if built.returncode != 0:
        fail('the host does not compile: ' + built.stderr[-3000:])
    built = link([work / 'host.o'], work / 'linked.rsp', work / 'host')
    if built.returncode != 0:
        fail('the host does not link with the lines of the tables: ' + built.stderr[-3000:])
    names, placed = exported(work / 'host'), addresses(work / 'host')
    for name, entry in linked.items():
        if PREFIX + name not in names:
            fail(f'the host does not export {PREFIX}{name}')
        if placed.get(PREFIX + name) is None or placed.get(PREFIX + name) != placed.get(entry['symbol']):
            fail(f'{PREFIX}{name} is at {placed.get(PREFIX + name)} and {entry["symbol"]} at {placed.get(entry["symbol"])}')
    built = run(['xcrun', 'clang', '-bundle', '-fno-objc-arc', '-framework', 'Cocoa', '-framework', 'CoreData',
                 '-undefined', 'dynamic_lookup', '-mmacosx-version-min=15.0', str(work / 'Legacy.m'),
                 '-o', str(legacy / 'Contents/MacOS/Legacy')])
    if built.returncode != 0:
        fail('the plugin does not build: ' + built.stderr[-3000:])
    wanted = {name for name in run(['xcrun', 'nm', '-uj', str(legacy / 'Contents/MacOS/Legacy')]).stdout.split()
              if name.startswith(PREFIX)}
    if wanted != {PREFIX + name for name in linked}:
        fail('the plugin does not look up the instance variables of the tables and those alone: '
             + ', '.join(sorted(wanted ^ {PREFIX + name for name in linked})))
    probe = run([str(work / 'host'), str(legacy), str(work / 'linked.txt')], timeout=60)
    if probe.returncode != 0:
        died = f' (signal {-probe.returncode})' if probe.returncode < 0 else ''
        print((probe.stdout + probe.stderr).strip())
        fail(f'the host ended with status {probe.returncode}{died}')

    # The completion of the table from a build, the objects of this host being
    # the build: the entries of the classes the host compiles, and the plain
    # Swift classes' as two fragments without symbols, the classes mixed.
    completion = work / 'completion'
    completion.mkdir()
    partial = completion / 'table.json'

    def start_table():
        entries = {name: dict(entry) for name, entry in shipped.items()}
        # A symbol that is not its field's: the completion reads every symbol again.
        entries[next(iter(entries))]['symbol'] = next(iter(PROBES.values()))['symbol']
        partial.write_text(legacy_plugin_ivars.render_table({'about': table['about'], 'ivars': entries}))

    def complete(*fragments, objects=work / 'host.o'):
        return run([sys.executable, str(TOOL), 'complete', '--table', str(partial), '--storage', str(work / 'Host.h'),
                    '--objects', str(objects), *[str(fragment) for fragment in fragments]], timeout=300)

    def fragment(name, entries):
        path = completion / name
        path.write_text(json.dumps({key: {field: value for field, value in entry.items() if field != 'symbol'}
                                    for key, entry in entries.items()}, indent=1))
        return path

    of_view = [name for name in PROBES if name.startswith('LegacyIvarProbeView.')]
    of_object = [name for name in PROBES if name.startswith('LegacyIvarProbeObject.')]
    mixed = [name for pair in zip(of_view, of_object) for name in pair]
    half = len(mixed) // 2
    first = fragment('first.json', {name: PROBES[name] for name in mixed[:half]})
    second = fragment('second.json', {name: PROBES[name] for name in mixed[half:]})
    start_table()
    for attempt in ('from the fragments', 'run again'):
        completed = complete(first, second)
        if completed.returncode != 0:
            fail(f'the completion of the table, {attempt}, failed: ' + (completed.stdout + completed.stderr).strip()[-3000:])
        written = legacy_plugin_ivars.read_table(partial)['ivars']
        if list(written.items()) != list(linked.items()):
            different = [name for name in linked if written.get(name) != linked[name]] or list(written)[:len(linked)]
            fail(f'the completion of the table, {attempt}, did not write the entries this test links with, in their order: '
                 + ', '.join(different[:10]))
        if partial.read_text() != legacy_plugin_ivars.render_table({'about': table['about'], 'ivars': linked}):
            fail(f'the completion of the table, {attempt}, did not write the table\'s text')
    # What it must refuse, writing nothing: each entry at fault is named.
    start_table()
    before = partial.read_text()
    faults = {
        'LegacyIvarProbeView.curImage': dict(PROBES['LegacyIvarProbeView.curImage'], sdk='int'),
        'LegacyIvarProbeView.redTable': dict(PROBES['LegacyIvarProbeView.redTable'], sdk='unsigned char[128]'),
        'LegacyIvarProbeView.dcmPixList': dict(PROBES['LegacyIvarProbeView.dcmPixList'], ownership='value'),
        'LegacyIvarProbeObject.absent': dict(PROBES['LegacyIvarProbeObject.locked'], field='absent'),
        'LegacyIvarProbeObject.clickCount': PROBES['LegacyIvarProbeObject.clickCount'],
        'LegacyIvarProbeObject.twin': PROBES['LegacyIvarProbeObject.clickCount'],
    }
    completed = complete(fragment('faults.json', faults), fragment('again.json', {'LegacyIvarProbeObject.twin': faults['LegacyIvarProbeObject.twin']}))
    unnamed = [name for name in faults if not any(line.startswith('FAIL: ') and name in line for line in completed.stdout.splitlines())]
    if completed.returncode != 1 or unnamed or partial.read_text() != before \
            or not any('faults.json and in' in line and 'again.json' in line for line in completed.stdout.splitlines()):
        fail('the completion was expected to write nothing and to name each entry at fault (a C type that is not the field\'s, an '
             'array of another size, an object whose ownership is value, a field the objects do not have, two variables on one '
             f'field, a variable in two fragments); not named: {", ".join(unnamed) or "none"}: '
             + (completed.stdout + completed.stderr).strip()[-2000:])
    # A field that is private in the objects has no symbol an alias reaches.
    what, (hidden, declared, private) = next((what, change) for what, change in VARIANTS.items() if what == 'a private field')
    (completion / 'Probes.swift').write_text(probes.replace(declared, private))
    built = run([*swiftc, '-O', '-wmo', '-emit-object', str(completion / 'Probes.swift'), str(work / STORAGE.name),
                 '-o', str(completion / 'private.o')])
    if built.returncode != 0:
        fail(f'the plain Swift classes with {what} do not compile: ' + built.stderr[-3000:])
    partial.write_text(legacy_plugin_ivars.render_table({'about': table['about'], 'ivars': {
        name: entry for name, entry in PROBES.items() if name != hidden and name in of_object}}))
    before = partial.read_text()
    completed = complete(fragment('private.json', {hidden: PROBES[hidden]}), objects=completion / 'private.o')
    if completed.returncode != 1 or partial.read_text() != before \
            or not any(line.startswith(f'FAIL: {hidden}: ') for line in completed.stdout.splitlines()):
        fail(f'with {what} in the objects the completion was expected to write nothing and to name {hidden}: '
             + (completed.stdout + completed.stderr).strip()[-2000:])
    # The same objects, the fragment without that entry: nothing else is at fault.
    completed = complete(objects=completion / 'private.o')
    if completed.returncode != 0:
        fail(f'the completion was expected to accept the other fields of the classes with {what}: '
             + (completed.stdout + completed.stderr).strip()[-2000:])

    # Without the -u lines of the plain Swift classes: the link succeeds, dead
    # stripping drops the names, and the bundle is refused for the first it needs.
    kept = render_aliases(shipped) + ''.join(line + '\n' for line in render_aliases(PROBES).splitlines() if line.startswith('-alias '))
    (work / 'no-u.rsp').write_text(kept)
    built = link([work / 'host.o'], work / 'no-u.rsp', work / 'host-no-u')
    if built.returncode != 0:
        fail('without the -u lines the host was expected to link and to lack the names: ' + built.stderr[-3000:])
    left = sorted(name for name in exported(work / 'host-no-u') if name.startswith(PREFIX + 'LegacyIvarProbe'))
    if left:
        fail('without the -u lines dead stripping was expected to drop the names, and the host exports ' + ', '.join(left[:5]))
    probe = run([str(work / 'host-no-u'), str(legacy), str(work / 'linked.txt')], timeout=60)
    if probe.returncode == 0 or 'the bundle does not load' not in probe.stdout or PREFIX + 'LegacyIvarProbe' not in probe.stdout:
        fail('without the -u lines the bundle was expected to be refused for a missing _OBJC_IVAR_$_ symbol: '
             + (probe.stdout + probe.stderr).strip()[-1500:])

    # Without the -alias lines nothing defines the names the -u lines ask for.
    (work / 'no-alias.rsp').write_text(
        render_aliases(shipped) + ''.join(line + '\n' for line in render_aliases(PROBES).splitlines() if line.startswith('-u ')))
    built = link([work / 'host.o'], work / 'no-alias.rsp', work / 'host-no-alias')
    if built.returncode == 0 or PREFIX + 'LegacyIvarProbe' not in built.stderr:
        fail('without the -alias lines the host was expected not to link: ' + built.stderr[-1500:])

    # A field that is no longer the one the table names: the classes alone, with a
    # main that only names them, link as they are and not with the field changed.
    (work / 'probes.rsp').write_text(render_aliases(PROBES))

    def link_probes(text, label):
        folder = work / label
        folder.mkdir()
        # The file keeps its name: the symbol of a private declaration carries a hash of it.
        (folder / 'Probes.swift').write_text(text)
        (folder / 'main.swift').write_text(minimal)
        return run([*swiftc, '-O', '-wmo', str(folder / 'Probes.swift'), str(work / STORAGE.name), str(folder / 'main.swift'),
                    '-Xlinker', '-dead_strip', '-Xclang-linker', '-Wl,@' + str(work / 'probes.rsp'), '-o', str(folder / 'host')])

    built = link_probes(probes, 'unchanged')
    if built.returncode != 0:
        fail('the plain Swift classes alone do not link with their aliases: ' + built.stderr[-3000:])
    for number, (what, (name, before, after)) in enumerate(VARIANTS.items()):
        if probes.count(before) != 1:
            fail(f'the test no longer has the declaration it changes for {what}: {before}')
        built = link_probes(probes.replace(before, after), f'variant-{number}')
        if built.returncode == 0:
            fail(f'with {what} ({after}) the host was expected not to link')
        # Only the linker names the alias: a source that did not compile would not.
        if PREFIX + name not in built.stderr:
            fail(f'with {what} the link was expected to fail for {PREFIX}{name}: ' + built.stderr[-1500:])

# The plugin that does the same inside the application: what its binary looks up.
with tempfile.TemporaryDirectory(prefix='horos-legacy-ivars-fixture-') as temporary:
    generated = run([sys.executable, str(FIXTURES), str(Path(temporary) / 'fixtures')], timeout=600)
    fixture = Path(temporary) / 'fixtures/QALegacyIvars.horosplugin/Contents/MacOS/QALegacyIvars'
    if generated.returncode != 0 or not fixture.is_file():
        fail(f'{FIXTURES.relative_to(ROOT)} does not build QALegacyIvars.horosplugin: ' + generated.stderr[-3000:])
    read = {name for name, count in json.loads(REGISTRY.read_text(encoding='utf-8'))['ivars'].items()
            if count > 0 and name.split('.')[0] in FIXTURE_CLASSES}
    for architecture in ('arm64', 'x86_64'):
        looked_up = {name[len(PREFIX):] for name in run(['xcrun', 'nm', '-arch', architecture, '-uj', str(fixture)]).stdout.split()
                     if name.startswith(PREFIX)}
        others = sorted(name for name in looked_up if name.split('.')[0] not in FIXTURE_CLASSES)
        if not looked_up or others:
            fail(f'QALegacyIvars ({architecture}) was expected to look up instance variables of {", ".join(FIXTURE_CLASSES)} alone: '
                 + (', '.join(others[:10]) or 'it looks up none'))
        if read - looked_up:
            fail(f'QALegacyIvars ({architecture}) does not touch instance variables that known plugins read: '
                 + ', '.join(sorted(read - looked_up)[:20]))
print(f'{len(ivars)} instance variables of the table and their response file; PluginFilter.viewerController and those of '
      f'PluginFileFormatDecoder, and {len(PROBES)} of two plain Swift classes (an NSView and an NSObject): a former plugin '
      f'reads and writes them directly and the host answers the same; the table is completed from the objects, and not '
      f'with an entry at fault; no link or no load without -u, without -alias, with a field retyped, private or declared '
      f'through a property wrapper; QALegacyIvars.horosplugin looks up {len(looked_up)} instance variables of '
      f'{", ".join(FIXTURE_CLASSES)}, the {len(read)} known plugins read among them')
