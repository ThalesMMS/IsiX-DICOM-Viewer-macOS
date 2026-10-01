#!/usr/bin/env python3
"""-[ROI initWithCoder:] checks every value an archived ROI holds (#820).

An archived ROI arrives from outside - an SR received by C-STORE, imported or
read from media, a .roi file, the pasteboard. #816 restricted the classes such
an archive may name; the values were still used as they came: a brush texture
of width x height bytes was copied out of an NSData of any length (a heap
over-read), width x height was an int product that could overflow or be
negative, and any allowed class stood in for the points array, the name, the
comments, the layer colour... to crash later with an unrecognised selector.

ROI.m is compiled here with the command the application's build used, under
AddressSanitizer, and linked with the reader SRs go through
(RestrictedUnarchiver). Archives are forged as ROI's -encodeWithCoder: writes
them, with one value changed each, and every case runs in its own process:
- refused, ASan clean: a texture shorter than width x height, width x height
  past an int, negative or oversized sides, no texture data, a string as the
  texture; a string as the points array or among the points, an array as the
  name, a number as the comments, a string as a number or the frame, strings in
  the z positions, a number as a text line, a string as the layer colour or
  the layer image, an unknown tool;
- sanitised: a texture's down right corner beyond the texture is put back on it;
- read back: polygons, brushes and volume lengths that ROI.o itself archives,
  the forged archives unchanged, and, when ../DICOM_Example is present, every
  ROI archive in it - SRs of earlier Horos versions - which must also copy and
  archive again.

`<git revision>` as an optional argument compiles ROI.m from that revision, the
negative control: before the fix the refusal cases fail, some under ASan.
HOROS_TEST_ROI_EXAMPLES selects a smaller local archive corpus.
Needs a Debug or Release build whose compile command for ROI.m is logged;
without it the test is skipped.
"""
from pathlib import Path
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile

SKIPPED = 2
root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'tools'))
import object_probe  # noqa: E402

SOURCE = 'Horos/Sources/ROI.m'
revision = sys.argv[1] if len(sys.argv) > 1 else None

if shutil.which('xcrun') is None:
    print('skipped: needs xcrun (clang, swiftc)', file=sys.stderr)
    sys.exit(SKIPPED)
try:
    command = object_probe.compile_command(SOURCE, configuration=os.environ.get('HOROS_TEST_CONFIGURATION', 'Debug'))
except LookupError as error:
    print('skipped: %s' % error, file=sys.stderr)
    sys.exit(SKIPPED)
# The shared precompiled header was built without AddressSanitizer, which clang
# refuses to mix; the prefix header it was made from is read instead.
command[command.index('-include') + 1] = str(root / 'Horos/prefix.pch')

BRIDGE = r'''
#import <Cocoa/Cocoa.h>
#import <objc/runtime.h>
#import "HorosObjCException.h"

// ROI as ROI.h declares what the harness uses; ROI.o is compiled from ROI.m.
typedef NS_ENUM(short, ToolMode) { tMesure = 5, tCPolygon = 11, tPlain = 20, tLayerROI = 24 };
@interface ROI : NSObject <NSCoding, NSCopying>
- (NSData *)data;
- (id) initWithType: (ToolMode) itype :(float) ipixelSpacingx :(float) ipixelSpacingy :(NSPoint) iimageOrigin;
- (id) initWithTexture: (unsigned char*)tBuff  textWidth:(int)tWidth textHeight:(int)tHeight textName:(NSString*)tName
             positionX:(int)posX positionY:(int)posY
              spacingX:(float) ipixelSpacingx spacingY:(float) ipixelSpacingy imageOrigin:(NSPoint) iimageOrigin;
@property(nonatomic, copy) NSString *name;
@property(retain) NSString *comments;
@property ToolMode type;
@property(retain) NSMutableArray *points;
@property(readonly) NSMutableArray *zPositions;
@property(readonly) int textureWidth, textureHeight;
@property(readonly) int textureDownRightCornerX, textureDownRightCornerY, textureUpLeftCornerX, textureUpLeftCornerY;
@property(readonly) unsigned char *textureBuffer;
@property(retain) NSString *textualBoxLine1, *textualBoxLine2, *textualBoxLine3, *textualBoxLine4, *textualBoxLine5;
@end
@interface HorosVolumeLengthROI : ROI
@property(copy) NSDictionary *volumeLength;
@end
'''

DRIVER = r'''
import Cocoa

// The build links in a loop until dyld stops naming a missing symbol.
if CommandLine.arguments.count > 1 && CommandLine.arguments[1] == "--probe-link" { exit(0) }

/// Archived under the name ROI, holding the values ROI's -encodeWithCoder:
/// writes, in its order - or others in their place.
@objc(HorosForgedROI)
final class ForgedROI: NSObject, NSCoding {
    let values: [Any?]
    init(_ values: [Any?]) { self.values = values }
    required init?(coder: NSCoder) { fatalError() }
    func encode(with coder: NSCoder) { for value in values { coder.encode(value) } }
}
class_setVersion(ForgedROI.self, 11)   // ROIVERSION

func archive(_ objects: [Any]) -> Data {
    let archiver = NSArchiver(forWritingWith: NSMutableData())
    archiver.encodeClassName("HorosForgedROI", intoClassName: "ROI")
    archiver.encodeRootObject(NSMutableArray(array: objects))
    return archiver.archiverData as Data
}

let brushPixels = Data((0..<30).map { UInt8($0 % 3 == 0 ? 255 : 0) })   // 6 x 5
let layerPNG = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4,
                                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    .representation(using: .png, properties: [:])!

/// A ROI of `type` as -encodeWithCoder: writes it, with `changes` by name;
/// NSNull stands for nil.
func forged(_ type: Int16, _ changes: [String: Any] = [:]) -> ForgedROI {
    var fields: [(String, Any?)] = [
        ("points", NSMutableArray(array: type == 20 ? [] : [MyPoint(point: NSPoint(x: 1, y: 2)), MyPoint(point: NSPoint(x: 5, y: 9))])),
        ("rect", NSStringFromRect(.zero)), ("type", NSNumber(value: Float(type))),
        ("needQuartz", NSNumber(value: Float(0))), ("thickness", NSNumber(value: Float(2))), ("fill", NSNumber(value: Float(0))),
        ("opacity", NSNumber(value: Float(0.5))), ("red", NSNumber(value: Float(65535))), ("green", NSNumber(value: Float(0))),
        ("blue", NSNumber(value: Float(0))), ("name", "Forged"), ("comments", "a comment"), ("spacingX", NSNumber(value: Float(0.5))),
        ("origin", NSStringFromPoint(.zero)), ("spacingY", NSNumber(value: Float(0.5))),
    ]
    if type == 20 {
        fields += [("width", NSNumber(value: Int32(6))), ("unused1", NSNumber(value: Int32(0))), ("height", NSNumber(value: Int32(5))),
                   ("unused2", NSNumber(value: Int32(0))), ("upLeftX", NSNumber(value: Int32(3))), ("upLeftY", NSNumber(value: Int32(4))),
                   ("downRightX", NSNumber(value: Int32(8))), ("downRightY", NSNumber(value: Int32(8))), ("texture", brushPixels)]
    }
    fields += [("zPositions", NSMutableArray()), ("offsetX", NSNumber(value: Float(0))), ("offsetY", NSNumber(value: Float(0))),
               ("calciumThreshold", NSNumber(value: Int32(130))), ("displayCalcium", NSNumber(value: false)),
               ("groupID", NSNumber(value: Double(0)))]
    if type == 24 { fields.append(("layerImage", layerPNG)) }
    fields += [("line1", "line one"), ("line2", nil), ("line3", nil), ("line4", nil), ("line5", nil),
               ("layerOpacityConstant", NSNumber(value: false)), ("canColorize", NSNumber(value: false)), ("layerColor", nil),
               ("displayTextual", NSNumber(value: true)), ("canResize", NSNumber(value: false)), ("selectable", NSNumber(value: true)),
               ("locked", NSNumber(value: false)), ("aliased", NSNumber(value: false)), ("spline", NSNumber(value: false)),
               ("hasSpline", NSNumber(value: false))]
    for key in changes.keys { precondition(fields.contains { $0.0 == key }, "no field \(key)") }
    return ForgedROI(fields.map { field in
        guard let change = changes[field.0] else { return field.1 }
        return change is NSNull ? nil : change
    })
}

func texture(_ roi: ROI) -> [UInt8] {
    Array(UnsafeBufferPointer(start: roi.textureBuffer, count: Int(roi.textureWidth) * Int(roi.textureHeight)))
}
func points(_ roi: ROI) -> [NSPoint] { (roi.points as! [MyPoint]).map { $0.point } }

/// What the application does with a ROI it has read: its values, a copy, an archive of it.
func exercise(_ roi: ROI) -> String? {
    guard roi.name == nil || roi.name is String, roi.comments == nil || roi.comments is String else { return "name or comments" }
    // A brush's -points is its texture's contour, traced by ITK, which the harness does not link.
    guard roi.type == .tPlain || (roi.points as NSArray? ?? []).allSatisfy({ $0 is MyPoint }) else { return "points" }
    guard (roi.zPositions as NSArray? ?? []).allSatisfy({ $0 is NSNumber }) else { return "z positions" }
    if roi.type == .tPlain {
        let x0 = Int(roi.textureUpLeftCornerX), y0 = Int(roi.textureUpLeftCornerY)
        guard roi.textureWidth >= 0, roi.textureHeight >= 0,
              (x0 - 1...x0 + Int(roi.textureWidth)).contains(Int(roi.textureDownRightCornerX)),
              (y0 - 1...y0 + Int(roi.textureHeight)).contains(Int(roi.textureDownRightCornerY)) else { return "texture geometry" }
        _ = texture(roi).reduce(0) { $0 &+ Int($1) }
    }
    guard let copy = roi.copy() as? ROI else { return "no copy" }
    guard copy.name == roi.name, copy.textureWidth == roi.textureWidth, copy.textureHeight == roi.textureHeight else { return "copy" }
    let again = NSUnarchiver.unarchiveObject(with: roi.data()) as? ROI
    guard again?.name == roi.name, again?.type == roi.type else { return "archive again" }
    return nil
}

func decode(_ data: Data) -> [ROI]? {
    guard let array = RestrictedUnarchiver.unarchiveROIs(with: data) else { return nil }
    return array.compactMap { $0 as? ROI }
}

var failures: [String] = []
func check(_ condition: Bool, _ message: @autoclosure () -> String) { if !condition { failures.append(message()) } }

/// The one ROI a forged archive holds is refused: nothing decodes to a ROI.
func refused(_ roi: ForgedROI, _ label: String) {
    let decoded = decode(archive([roi]))
    check((decoded ?? []).isEmpty, "\(label): accepted as \(decoded!.map { "\(type(of: $0)) \($0.name ?? "")" })")
}

let rejections: [(String, Int16, [String: Any])] = [
    ("a texture shorter than width x height", 20, ["width": NSNumber(value: Int32(64)), "height": NSNumber(value: Int32(64)),
                                                   "downRightX": NSNumber(value: Int32(66)), "downRightY": NSNumber(value: Int32(67)),
                                                   "texture": Data(count: 16)]),
    ("a texture of 65536 x 65536, whose int size wraps to 0", 20, ["width": NSNumber(value: Int32(65536)), "height": NSNumber(value: Int32(65536)),
                                                                    "texture": Data(count: 16)]),
    ("a texture of 46341 x 46341, whose int size is negative", 20, ["width": NSNumber(value: Int32(46341)), "height": NSNumber(value: Int32(46341)),
                                                                     "texture": Data(count: 16)]),
    ("a texture of -8 x -8", 20, ["width": NSNumber(value: Int32(-8)), "height": NSNumber(value: Int32(-8)), "texture": Data(count: 64)]),
    ("a texture wider than any image, 70000 x 1", 20, ["width": NSNumber(value: Int32(70000)), "height": NSNumber(value: Int32(1)),
                                                      "texture": Data(count: 70000)]),
    ("a texture corner far outside any image", 20, ["upLeftX": NSNumber(value: Int32.max - 2)]),
    ("no texture data", 20, ["texture": NSNull()]),
    ("a string as the texture", 20, ["texture": "not pixels"]),
    ("a string as the points", 11, ["points": "not points"]),
    ("a string among the points", 11, ["points": NSMutableArray(array: [MyPoint(point: .zero), "not a point"])]),
    ("an array as the name", 11, ["name": NSMutableArray(array: ["a", "b"])]),
    ("a point as the name", 11, ["name": MyPoint(point: .zero)]),
    ("a number as the comments", 11, ["comments": NSNumber(value: 3)]),
    ("an array as the thickness", 11, ["thickness": NSMutableArray()]),
    ("a string as the opacity", 11, ["opacity": "0.5"]),
    ("a number as the frame", 11, ["rect": NSNumber(value: 1)]),
    ("a string among the z positions", 11, ["zPositions": NSMutableArray(array: ["one"])]),
    ("a number as a text line", 11, ["line1": NSNumber(value: 7)]),
    ("a string as the layer colour", 11, ["layerColor": "red"]),
    ("a string as the layer image", 24, ["layerImage": "not an image"]),
    ("tool 1e9", 11, ["type": NSNumber(value: Float(1e9))]),
    ("tool NaN", 11, ["type": NSNumber(value: Float.nan)]),
    ("tool -3", 11, ["type": NSNumber(value: Float(-3))]),
]

let arguments = CommandLine.arguments
switch arguments[1] {
case "--list":
    print((["read-back", "sanitised"] + rejections.indices.map { "refuse-\($0)" }).joined(separator: "\n"))
    exit(0)

case "read-back":
    // As ROI.o makes and archives them.
    let polygon = ROI(type: .tCPolygon, 0.5, 0.75, NSPoint(x: 10, y: -20))!
    polygon.points = NSMutableArray(array: [MyPoint(point: NSPoint(x: 1, y: 2)), MyPoint(point: NSPoint(x: 30.5, y: 4)),
                                            MyPoint(point: NSPoint(x: 12, y: 40.25))])
    polygon.name = "Lesion é"
    var pixels = [UInt8](repeating: 0, count: 6 * 5)
    for i in stride(from: 0, to: pixels.count, by: 3) { pixels[i] = 255 }
    let brush = ROI(texture: &pixels, textWidth: 6, textHeight: 5, textName: "Brush", positionX: 3, positionY: 4,
                    spacingX: 0.5, spacingY: 0.5, imageOrigin: .zero)!
    let length = HorosVolumeLengthROI(type: .tMesure, 1, 1, .zero)!
    length.volumeLength = ["version": 1, "id": "V1", "series": "1.2.3", "frameOfReference": "1.2.3.4",
                           "a": [0, 0, 0], "b": [3, 4, 12.5], "temporalIndex": 0]
    let made = [polygon, brush, length]
    if let decoded = decode(NSArchiver.archivedData(withRootObject: NSMutableArray(array: made))), decoded.count == 3 {
        check(decoded[0].name == "Lesion é" && points(decoded[0]) == points(polygon), "a polygon read back as \(decoded[0].name ?? "")")
        check(decoded[1].textureWidth == 6 && decoded[1].textureHeight == 5 && texture(decoded[1]) == pixels &&
              decoded[1].textureUpLeftCornerX == 3 && decoded[1].textureDownRightCornerX == 8,
              "a brush read back as \(decoded[1].textureWidth) x \(decoded[1].textureHeight) at \(decoded[1].textureUpLeftCornerX)")
        check((decoded[2] as? HorosVolumeLengthROI)?.volumeLength as NSDictionary? == length.volumeLength as NSDictionary?,
              "a volume length read back without its payload")
        for roi in decoded { if let problem = exercise(roi) { failures.append("\(roi.name ?? ""): \(problem)") } }
    } else {
        failures.append("ROIs archived by ROI.o did not read back")
    }
    // The forged archives, unchanged, are real ROIs: the refusals below are the one value changed.
    for type: Int16 in [11, 20, 24] {
        let decoded = decode(archive([forged(type)]))
        guard let roi = decoded?.first, decoded?.count == 1 else { failures.append("a forged ROI of tool \(type) did not read back"); continue }
        check(roi.name == "Forged" && roi.comments == "a comment" && roi.textualBoxLine1 == "line one" && Int16(roi.type.rawValue) == type,
              "a forged ROI of tool \(type) read back as \(roi.name ?? "") of tool \(roi.type.rawValue)")
        if type == 20 {
            check(roi.textureWidth == 6 && roi.textureHeight == 5 && Data(texture(roi)) == brushPixels, "a forged brush's texture changed")
        } else if type == 11 {
            check(points(roi) == [NSPoint(x: 1, y: 2), NSPoint(x: 5, y: 9)], "a forged polygon's points changed")
        }
        if let problem = exercise(roi) { failures.append("forged tool \(type): \(problem)") }
    }
    // A catalog colour is kept as the RGB colour colorizing reads.
    let coloured = decode(archive([forged(11, ["layerColor": NSColor.controlTextColor])]))?.first
    check(coloured != nil, "a ROI with a catalog layer colour was refused")
    // A decoded value that is not the last: the one after it still reads.
    let pair = decode(archive([forged(20), forged(11, ["name": "Second"])]))
    check(pair?.count == 2 && pair?[1].name == "Second", "two forged ROIs read back as \(String(describing: pair?.map { $0.name }))")
    let mixed = decode(archive([forged(11, ["name": "Kept"]), forged(11, ["points": "not points"])]))
    print(mixed == nil ? "an SR holding a ROI with a wrong value beside a real one is refused whole"
                       : "an SR holding a ROI with a wrong value beside a real one reads as \(mixed!.map { $0.name ?? "" })")

case "sanitised":
    let far = decode(archive([forged(20, ["downRightX": NSNumber(value: Int32(1_000_000)), "downRightY": NSNumber(value: Int32(-50))])]))
    if let roi = far?.first {
        check(roi.textureDownRightCornerX == 8 && roi.textureDownRightCornerY == 8,
              "a down right corner beyond the texture stayed at \(roi.textureDownRightCornerX), \(roi.textureDownRightCornerY)")
        if let problem = exercise(roi) { failures.append("a sanitised brush: \(problem)") }
    } else {
        failures.append("a brush whose down right corner lies beyond its texture was refused")
    }

case let name where name.hasPrefix("refuse-"):
    let (label, type, changes) = rejections[Int(name.dropFirst("refuse-".count))!]
    refused(forged(type, changes), label)
    // Beside a real ROI, in the same SR.
    let decoded = decode(archive([forged(11, ["name": "Kept"]), forged(type, changes)]))
    check(!(decoded ?? []).contains { $0.name == "Forged" }, "\(label), beside a real ROI: accepted")

case "corpus":
    // Earlier Horos versions' SRs, from the example collection.
    let corpus = arguments[2]
    var archives = 0, rois = 0, brushes = 0
    func count(_ object: Any?, _ label: String) -> Int? {
        if let roi = object as? ROI {
            if let problem = exercise(roi) { failures.append("\(label): \(roi.name ?? ""): \(problem)") }
            if roi.type == .tPlain { brushes += 1 }
            return 1
        }
        guard let array = object as? NSArray else { return nil }
        var sum = 0
        for element in array {
            guard let n = count(element, label) else { return nil }
            sum += n
        }
        return sum
    }
    for name in try! FileManager.default.contentsOfDirectory(atPath: corpus).sorted() {
        let data = FileManager.default.contents(atPath: corpus + "/" + name)!
        guard let n = count(RestrictedUnarchiver.unarchiveROIs(with: data), name), n > 0 else {
            failures.append("\(name), a ROI archive of an earlier version, did not decode to ROIs")
            continue
        }
        archives += 1
        rois += n
    }
    print("\(archives) archives of earlier versions, \(rois) ROIs (\(brushes) brushes), each copied and archived again")

default:
    fatalError("unknown case \(arguments[1])")
}

for failure in failures { print("FAIL: \(failure)") }
if failures.isEmpty { print("ok") }
exit(failures.isEmpty ? 0 : 1)
'''

STUB_CONSTANTS = r'''
NSString * const OsirixROIChangeNotification = @"OsirixROIChangeNotification";
NSString * const OsirixRemoveROINotification = @"OsirixRemoveROINotification";
'''


def run(argv, **kwargs):
    return subprocess.run(argv, check=True, capture_output=True, **kwargs)


def objective_c_stubs(obj):
    """The project classes ROI.o names, except MyPoint, compiled for real."""
    names = [n for n in object_probe.undefined_project_classes(obj) if n != 'MyPoint']
    return '#import <Foundation/Foundation.h>\n' + STUB_CONSTANTS + ''.join(
        '@interface %s : NSObject @end\n@implementation %s @end\n' % (n, n) for n in names)


def build(tmp):
    source = tmp / 'ROI.m'
    if revision:
        object_probe.revision_source(SOURCE, revision, source)
    else:
        shutil.copyfile(root / SOURCE, source)
    roi_object = tmp / 'ROI.o'
    # Compiled outside the checkout, so that ROI.m's headers resolve through the build's own paths only.
    run(command + ['-fsanitize=address', '-c', str(source), '-o', str(roi_object)])
    for path in ('Horos/Sources/RestrictedUnarchiver.swift', 'Horos/Sources/MyPoint.swift',
                 'Horos/Sources/HorosObjCException.h', 'Horos/Sources/HorosObjCException.m'):
        shutil.copyfile(root / path, tmp / Path(path).name)
    (tmp / 'bridge.h').write_text(BRIDGE)
    (tmp / 'main.swift').write_text(DRIVER)
    (tmp / 'stubs.m').write_text(objective_c_stubs(roi_object))
    run(['xcrun', 'clang', '-fobjc-exceptions', '-fsanitize=address', '-c', str(tmp / 'HorosObjCException.m'),
         '-o', str(tmp / 'HorosObjCException.o')])
    run(['xcrun', 'clang', '-fno-objc-arc', '-c', str(tmp / 'stubs.m'), '-o', str(tmp / 'stubs.o')])
    placeholders = set()
    # dyld names one missing data symbol per attempt; functions bind lazily.
    for _ in range(100):
        assembly = ''.join('.globl %s\n%s: .quad 0\n' % (s, s) for s in sorted(placeholders))
        (tmp / 'placeholders.s').write_text('.data\n' + assembly)
        run(['xcrun', 'clang', '-c', str(tmp / 'placeholders.s'), '-o', str(tmp / 'placeholders.o')])
        run(['xcrun', 'swiftc', '-swift-version', '5', '-module-name', 'Horos', '-suppress-warnings', '-sanitize=address',
             '-import-objc-header', str(tmp / 'bridge.h'), '-Xcc', '-iquote', '-Xcc', str(tmp),
             str(tmp / 'RestrictedUnarchiver.swift'), str(tmp / 'MyPoint.swift'), str(tmp / 'main.swift'),
             str(tmp / 'HorosObjCException.o'), str(tmp / 'stubs.o'), str(tmp / 'placeholders.o'), str(roi_object),
             '-Xlinker', '-undefined', '-Xlinker', 'dynamic_lookup',
             '-framework', 'Cocoa', '-framework', 'Accelerate', '-o', str(tmp / 'harness')])
        probe = subprocess.run([str(tmp / 'harness'), '--probe-link'], capture_output=True, text=True, timeout=60)
        missing = re.search(r"symbol not found in flat namespace '([^']+)'", probe.stderr)
        if not missing:
            return tmp / 'harness'
        if missing.group(1) in placeholders:
            raise RuntimeError('cannot satisfy %s' % missing.group(1))
        placeholders.add(missing.group(1))
    raise RuntimeError('too many unresolved symbols in %s' % roi_object)


def example_archives(directory):
    """The (0042,0011) values of the SRs in ../DICOM_Example holding a ROI
    archive, and the raw archives there; None without the collection."""
    common = subprocess.run(['git', '-C', str(root), 'rev-parse', '--path-format=absolute', '--git-common-dir'],
                            capture_output=True, text=True).stdout.strip()
    candidates = [root.parent / 'DICOM_Example']
    if common:
        candidates.append(Path(common).parent.parent / 'DICOM_Example')
    selected = os.environ.get('HOROS_TEST_ROI_EXAMPLES')
    examples = Path(selected) if selected else next((c for c in candidates if c.is_dir()), None)
    if examples is None:
        return None
    found = subprocess.run(['rg', '--files-with-matches', '--text', '--null', '--no-ignore', '--', 'streamtyped', str(examples)], capture_output=True)
    if found.returncode not in (0, 1):
        raise RuntimeError('ROI archive corpus scan failed')
    count = 0
    for path in filter(None, found.stdout.split(b'\0')):
        data = Path(os.fsdecode(path)).read_bytes()
        if data.startswith(b'\x04\x0bstreamtyped'):
            value = data
        else:
            at = data.find(b'\x42\x00\x11\x00OB\x00\x00')   # Encapsulated Document, explicit VR
            if at < 0:
                continue
            length = struct.unpack('<I', data[at + 8:at + 12])[0]
            value = data[at + 12:at + 12 + length]
            if not value.startswith(b'\x04\x0bstreamtyped'):
                continue
        (directory / ('%04d' % count)).write_bytes(value)
        count += 1
    return count


failures = []
environment = dict(os.environ, ASAN_OPTIONS='abort_on_error=0:halt_on_error=1:detect_leaks=0')


def run_case(harness, name, *extra):
    result = subprocess.run([str(harness), name, *extra], capture_output=True, text=True, timeout=300, env=environment)
    output = result.stdout + result.stderr
    asan = re.search(r'SUMMARY: AddressSanitizer: (.*)', output)
    marks = [line[len('FAIL: '):] for line in result.stdout.splitlines() if line.startswith('FAIL: ')]
    if asan:
        failures.append('%s: AddressSanitizer: %s' % (name, asan.group(1)))
    elif result.returncode != 0:
        # How it ended: an uncaught exception's reason, a Swift trap, a signal.
        ending = re.search(r"reason: '(.*)'|Fatal error: .*|Could not cast .*", output)
        how = 'signal %d' % -result.returncode if result.returncode < 0 else 'exit %d' % result.returncode
        failures.extend(marks or ['%s: %s%s' % (name, how, ': ' + (ending.group(1) or ending.group(0)) if ending else '')])
    else:
        for line in result.stdout.splitlines():
            if line != 'ok':
                print('ok: %s - %s' % (name, line))


with tempfile.TemporaryDirectory(prefix='horos-roi-archive-content-') as tmp:
    tmp = Path(tmp)
    (tmp / 'examples').mkdir()
    try:
        harness = build(tmp)
    except (subprocess.CalledProcessError, RuntimeError) as e:
        detail = e.stderr.decode(errors='replace')[-3000:] if isinstance(e, subprocess.CalledProcessError) else str(e)
        print('FAIL: the harness did not build:', detail)
        sys.exit(1)
    cases = run([str(harness), '--list'], text=True).stdout.split()
    labels = re.findall(r'\("([^"]+)", \d+, \[', DRIVER)
    for case in cases:
        before = len(failures)
        run_case(harness, case)
        if case.startswith('refuse-') and len(failures) == before:
            print('ok: refused, ASan clean -', labels[int(case[len('refuse-'):])])
        elif len(failures) == before:
            print('ok:', case)
    if example_archives(tmp / 'examples'):
        run_case(harness, 'corpus', str(tmp / 'examples'))
    else:
        print('note: no ROI archives of earlier versions (../DICOM_Example) to read')

for failure in failures:
    print('FAIL:', failure)
if failures:
    sys.exit(1)
print('PASS: archived ROIs are refused when a value is not of its class or a texture does not fit its data; '
      'real and earlier ROI archives still read back')
