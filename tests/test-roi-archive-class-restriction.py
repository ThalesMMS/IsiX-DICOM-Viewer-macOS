#!/usr/bin/env python3
"""ROI archives, the CLUT editor's pasteboard types and CPR path files are
decoded only with the classes they hold (#816, #818).

ROIs travel as NSArchiver typedstreams - inside DICOM SRs that arrive by
C-STORE, import or media, in .roi and .rois_series files and on the general
pasteboard - and NSUnarchiver instantiates whatever class the archive names,
running its -initWithCoder:. The CLUT editor's curve and colour pasteboard
types are the same format. A CPR path file is a keyed archive whose class was
checked only after decoding.

A marker class, whose -initWithCoder: counts its runs, is archived in each
format and entry point; it must never be instantiated:
- as an SR's or the ROI pasteboard's ROI array holds it, beside a real ROI,
  inside the measurement payload of a real HorosVolumeLengthROI, and in a
  .rois_series file's nested arrays; a .roi file holding it; after the root
  object; in a truncated archive;
- in a CLUT curve and as a CLUT point colour;
- as a CPR path file's root, and under the keys of a curved path and of its
  bezier path (the statement CPRController's Load Path runs is taken from
  CPRController.m and compiled).
What the formats hold still reads back: real ROIs (polygon, brush, volume
length) made and archived by the ROI.o the application is built from, with
zero padding after them as a DICOM value has, and in a big-endian
("typedstream") archive; a CLUT curve and colours; a CPR path saved as
-saveBezierPathToFile: saves it. When ../DICOM_Example is present, every ROI
archive in it - SRs written by earlier Horos versions - must decode to ROIs.

The external entry points must not call NSUnarchiver themselves: SRAnnotation,
DicomImage, DicomStudy, DicomFileDCMTKCategory, BrowserController, DCMPix,
ViewerController (the volume length archive, loading and the comparison before
saving), DCMView (.roi files, pasting), the ROI import and the CLUT editor's
paste. What stays on NSUnarchiver is listed below: archives Horos makes from
its own objects in memory, local CLUT presets and user defaults.

`<git revision>` as an optional argument reads the sources from that revision,
the negative control: before the fix every marker case fails. ROI.o is taken
from build/ (Debug or Release); without it the test is skipped.
"""
from pathlib import Path
import re
import shutil
import struct
import subprocess
import sys
import tempfile

SKIPPED = 2
root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None


def source(path):
    """The file at `revision`, or None when it does not exist there."""
    if revision:
        result = subprocess.run(['git', '-C', str(root), 'show', f'{revision}:{path}'], capture_output=True)
        return result.stdout if result.returncode == 0 else None
    file = root / path
    return file.read_bytes() if file.is_file() else None


if shutil.which('xcrun') is None:
    print('skipped: needs xcrun (swiftc, clang)', file=sys.stderr)
    sys.exit(SKIPPED)
objects = [root / 'build/Build/Intermediates.noindex/Horos.build' / configuration /
           'Horos.build/Objects-normal/arm64/ROI.o' for configuration in ('Debug', 'Release')]
roi_object = next((o for o in objects if o.is_file()), None)
if roi_object is None:
    print('skipped: needs a built ROI.o in %s' % ' or '.join(str(o) for o in objects), file=sys.stderr)
    sys.exit(SKIPPED)

failures = []

# --- The entry points ------------------------------------------------------

# Lines that may still call NSUnarchiver, per file: archives of Horos's own
# objects in memory (the undo of a resample, the CPR views' ROI copies), local
# CLUT presets and user defaults. Every other call is an entry point that must
# go through HorosRestrictedUnarchiver.
INTERNAL_UNARCHIVES = {
    'Horos/Sources/ViewerController.m': [
        '[[roiList[ j] objectAtIndex: x] addObjectsFromArray: [NSUnarchiver unarchiveObjectWithData: r]];',
    ],
    'Horos/Sources/CLUTOpacityView.swift': [
        'guard let clut = NSUnarchiver.unarchiveObject(withFile: path) else { return nil }',
    ],
}
ENTRY_POINT_FILES = [
    'Horos/Sources/SRAnnotation.mm',
    'Horos/Sources/DicomImage.swift',
    'Horos/Sources/DicomStudy.swift',
    'Horos/Sources/DicomFileDCMTKCategory.mm',
    'Horos/Sources/BrowserController.m',
    'Horos/Sources/DCMPix.m',
    'Horos/Sources/ViewerController.m',
    'Horos/Sources/DCMView.m',
    'Horos/Sources/ViewerController+ROIInterchange.swift',
    'Horos/Sources/CLUTOpacityView.swift',
]
for path in ENTRY_POINT_FILES:
    text = source(path).decode('latin-1')
    allowed = INTERNAL_UNARCHIVES.get(path, [])
    for number, line in enumerate(text.splitlines(), 1):
        if 'NSUnarchiver' not in line or line.strip().startswith(('//', '*', '/*')):
            continue
        if line.strip() not in allowed:
            failures.append(f'{path}:{number} decodes with NSUnarchiver: {line.strip()}')

# --- The typedstream harness -------------------------------------------------

# Before the fix: the entry points unarchived with NSUnarchiver, whatever the
# archive named. This stands in for the reader they now call.
FORMER_READER = r'''
import Foundation
@objc(HorosRestrictedUnarchiver)
public final class RestrictedUnarchiver: NSObject {
    @objc public static let roiClassNames: Set<String> = []
    @objc public static let clutCurveClassNames: Set<String> = []
    @objc public static let colorClassNames: Set<String> = []
    public static func unarchiveObject(with data: Data, allowedClassNames: Set<String>) throws -> Any {
        var object: Any?
        try HorosObjCException.perform { object = NSUnarchiver.unarchiveObject(with: data) }
        guard let object else { throw NSError(domain: "former", code: 1) }
        return object
    }
    @objc(unarchiveObjectWithData:allowedClassNames:)
    public static func unarchiveObjectOrNil(with data: Data?, allowedClassNames: Set<String>) -> Any? {
        guard let data else { return nil }
        return try? unarchiveObject(with: data, allowedClassNames: allowedClassNames)
    }
    @objc(unarchiveROIsWithData:)
    public static func unarchiveROIs(with data: Data?) -> NSArray? {
        return unarchiveObjectOrNil(with: data, allowedClassNames: []) as? NSArray
    }
    @objc(unarchiveROIsWithFile:)
    public static func unarchiveROIs(withFile path: String?) -> NSArray? {
        guard let path, let data = FileManager.default.contents(atPath: path) else { return nil }
        return unarchiveROIs(with: data)
    }
}
'''

ROI_BRIDGE = r'''
#import <Cocoa/Cocoa.h>
#import "HorosObjCException.h"

// ROI as ROI.h declares what the harness uses; ROI.o is the application's.
typedef NS_ENUM(short, ToolMode) { tMesure = 5, tCPolygon = 11, tPlain = 20 };
@interface ROI : NSObject <NSCoding>
- (id) initWithType: (ToolMode) itype :(float) ipixelSpacingx :(float) ipixelSpacingy :(NSPoint) iimageOrigin;
- (id) initWithTexture: (unsigned char*)tBuff  textWidth:(int)tWidth textHeight:(int)tHeight textName:(NSString*)tName
             positionX:(int)posX positionY:(int)posY
              spacingX:(float) ipixelSpacingx spacingY:(float) ipixelSpacingy imageOrigin:(NSPoint) iimageOrigin;
@property(nonatomic, copy) NSString *name;
@property(retain) NSString *comments;
@property ToolMode type;
@property(retain) NSMutableArray *points;
@property(readonly) int textureWidth, textureHeight;
@property(readonly) unsigned char *textureBuffer;
@end
@interface HorosVolumeLengthROI : ROI
@property(copy) NSDictionary *volumeLength;
@end
'''

ROI_DRIVER = r'''
import Cocoa

// The build links in a loop until dyld stops naming a missing symbol.
if CommandLine.arguments.count > 1 && CommandLine.arguments[1] == "--probe-link" { exit(0) }

var markerRuns = 0

/// Records that an archive had it instantiated.
@objc(HorosArchiveMarker)
final class ArchiveMarker: NSObject, NSCoding {
    override init() { super.init() }
    init?(coder: NSCoder) {
        markerRuns += 1
        _ = coder.decodeObject()
        super.init()
    }
    func encode(with coder: NSCoder) { coder.encode("marker" as NSString) }
}

var failures: [String] = []
func check(_ condition: Bool, _ message: String) {
    if !condition { failures.append(message) }
}

func archive(_ object: Any) -> Data { NSArchiver.archivedData(withRootObject: object) }

/// A closed polygon, a brush and a volume length, as ROI.o makes and archives them.
func polygon() -> ROI {
    let roi = ROI(type: .tCPolygon, 0.5, 0.75, NSPoint(x: 10, y: -20))!
    roi.points = NSMutableArray(array: [MyPoint(point: NSPoint(x: 1, y: 2)), MyPoint(point: NSPoint(x: 30.5, y: 4)),
                                        MyPoint(point: NSPoint(x: 12, y: 40.25))])
    roi.name = "Lesion é"
    roi.comments = "a comment"
    return roi
}
func brush() -> ROI {
    var pixels = [UInt8](repeating: 0, count: 6 * 5)
    for i in stride(from: 0, to: pixels.count, by: 3) { pixels[i] = 255 }
    return ROI(texture: &pixels, textWidth: 6, textHeight: 5, textName: "Brush", positionX: 3, positionY: 4,
               spacingX: 0.5, spacingY: 0.5, imageOrigin: .zero)!
}
func volumePayload() -> NSMutableDictionary {
    return NSMutableDictionary(dictionary: ["version": 1, "id": "V1", "series": "1.2.3", "frameOfReference": "1.2.3.4",
                                            "a": [0, 0, 0], "b": [3, 4, 12.5], "temporalIndex": 0])
}
func volumeLength(_ payload: NSDictionary) -> ROI {
    let roi = HorosVolumeLengthROI(type: .tMesure, 1, 1, .zero)!
    roi.volumeLength = payload as? [AnyHashable: Any]
    return roi
}

func points(_ roi: ROI) -> [NSPoint] { (roi.points as! [MyPoint]).map { $0.point } }
func texture(_ roi: ROI) -> [UInt8] {
    Array(UnsafeBufferPointer(start: roi.textureBuffer, count: Int(roi.textureWidth * roi.textureHeight)))
}

/// Decoded ROIs match what was archived.
func same(_ decoded: NSArray?, _ original: [ROI], _ label: String) {
    guard let decoded = decoded as? [ROI], decoded.count == original.count else {
        failures.append("\(label): \(original.count) ROIs did not read back (got \(String(describing: decoded)))")
        return
    }
    for (d, o) in zip(decoded, original) {
        check(type(of: d) == type(of: o) && d.type == o.type && d.name == o.name && d.comments == o.comments,
              "\(label): \(o.name ?? "") read back as \(type(of: d)) \(d.name ?? "")")
        // A brush's -points is its texture's contour, traced by ITK.
        if o.type != .tPlain {
            check(points(d) == points(o), "\(label): the points of \(o.name ?? "") read back as \(points(d))")
        } else {
            check(d.textureWidth == o.textureWidth && d.textureHeight == o.textureHeight && texture(d) == texture(o),
                  "\(label): the brush texture changed")
        }
        if let o = o as? HorosVolumeLengthROI {
            check((d as? HorosVolumeLengthROI)?.volumeLength as NSDictionary? == o.volumeLength as NSDictionary?,
                  "\(label): the volume length payload changed")
        }
    }
}

/// A marker case: nothing decoded, the marker never instantiated.
func refused(_ decoded: Any?, _ label: String) {
    check(markerRuns == 0, "\(label): the marker class was instantiated (\(markerRuns) run)")
    check(decoded == nil, "\(label): decoded \(String(describing: decoded))")
    markerRuns = 0
}

let rois = [polygon(), brush(), volumeLength(volumePayload())]
let roiData = archive(NSMutableArray(array: rois))
let tmp = CommandLine.arguments[1]

// What the formats hold reads back.
same(RestrictedUnarchiver.unarchiveROIs(with: roiData), rois, "an SR's ROI array")
same(RestrictedUnarchiver.unarchiveROIs(with: roiData + Data([0, 0])), rois, "an SR value with zero padding")
let roiFile = tmp + "/rois.roi"
try! roiData.write(to: URL(fileURLWithPath: roiFile))
same(RestrictedUnarchiver.unarchiveROIs(withFile: roiFile), rois, "a .roi file")
let series = RestrictedUnarchiver.unarchiveROIs(with: archive([[NSMutableArray(array: rois)], [NSMutableArray()]] as NSArray))
same((series?.firstObject as? NSArray)?.firstObject as? NSArray, rois, "a .rois_series file")
if let object = try? RestrictedUnarchiver.unarchiveObject(with: roiData, allowedClassNames: RestrictedUnarchiver.roiClassNames) {
    same(object as? NSArray, rois, "the ROI import")
} else {
    failures.append("the ROI import refused a ROI array")
}

// A big-endian archive, as a PowerPC wrote them: the same array of values.
var bigEndian = [UInt8](archive(["a", 300, Float(2.5)] as NSArray))
bigEndian.replaceSubrange(2..<13, with: Array("typedstream".utf8))
bigEndian[14] = 0x03; bigEndian[15] = 0xe8
for i in 16..<(bigEndian.count - 4) {
    if bigEndian[i] == 0x81 && bigEndian[i + 1] == 0x2c && bigEndian[i + 2] == 0x01 { bigEndian[i + 1] = 0x01; bigEndian[i + 2] = 0x2c }
    if bigEndian[i] == 0x83 && Array(bigEndian[i + 1...i + 4]) == [0, 0, 0x20, 0x40] { bigEndian.replaceSubrange(i + 1...i + 4, with: [0x40, 0x20, 0, 0]) }
}
let decodedBigEndian = RestrictedUnarchiver.unarchiveROIs(with: Data(bigEndian))
check(decodedBigEndian == ["a", 300, Float(2.5)] as NSArray, "a big-endian archive read back as \(String(describing: decodedBigEndian))")

// The marker, wherever the formats can carry it.
refused(RestrictedUnarchiver.unarchiveROIs(with: archive(NSMutableArray(array: [polygon(), ArchiveMarker()]))),
        "an SR's ROI array holding the marker")
let payload = volumePayload()
payload["note"] = ArchiveMarker()
refused(RestrictedUnarchiver.unarchiveROIs(with: archive(NSMutableArray(array: [volumeLength(payload)]))),
        "the marker in a volume length's payload")
refused(RestrictedUnarchiver.unarchiveROIs(with: archive([[[polygon()], [ArchiveMarker()]]] as NSArray)),
        "the marker deep in a .rois_series file")
let markerFile = tmp + "/marker.roi"
try! archive(NSMutableArray(array: [ArchiveMarker()])).write(to: URL(fileURLWithPath: markerFile))
refused(RestrictedUnarchiver.unarchiveROIs(withFile: markerFile), "a .roi file holding the marker")
refused(try? RestrictedUnarchiver.unarchiveObject(with: archive(ArchiveMarker()), allowedClassNames: RestrictedUnarchiver.roiClassNames),
        "the marker as the root of an imported file")
refused(RestrictedUnarchiver.unarchiveROIs(with: roiData + archive(ArchiveMarker()).dropFirst(16)),
        "the marker after the root object")
refused(RestrictedUnarchiver.unarchiveROIs(with: archive(NSMutableArray(array: [polygon(), ArchiveMarker()])).dropLast(9)),
        "the marker in a truncated archive")
refused(RestrictedUnarchiver.unarchiveROIs(with: Data("not an archive".utf8)), "data that is no archive")
refused(RestrictedUnarchiver.unarchiveROIs(with: NSKeyedArchiver.archivedData(withRootObject: [ArchiveMarker()])),
        "a keyed archive where a ROI archive belongs")

// The CLUT editor: a curve (its points and colours) and one colour.
let curve = ["curve": [NSValue(point: NSPoint(x: 10, y: 0)), NSValue(point: NSPoint(x: 200, y: 0.5))],
             "colors": [NSColor(calibratedRed: 1, green: 0, blue: 0, alpha: 1), NSColor.controlTextColor]] as NSDictionary
let decodedCurve = RestrictedUnarchiver.unarchiveObjectOrNil(with: archive(curve), allowedClassNames: RestrictedUnarchiver.clutCurveClassNames) as? NSDictionary
check((decodedCurve?["curve"] as? NSArray) == (curve["curve"] as? NSArray) && (decodedCurve?["colors"] as? NSArray)?.count == 2,
      "a CLUT curve read back as \(String(describing: decodedCurve))")
let colour = NSColor(calibratedRed: 0.25, green: 0.5, blue: 1, alpha: 1)
check(RestrictedUnarchiver.unarchiveObjectOrNil(with: archive(colour), allowedClassNames: RestrictedUnarchiver.colorClassNames) as? NSColor == colour,
      "a CLUT point colour did not read back")
refused(RestrictedUnarchiver.unarchiveObjectOrNil(with: archive(["curve": [NSValue(point: .zero)], "colors": [ArchiveMarker()]] as NSDictionary),
                                                  allowedClassNames: RestrictedUnarchiver.clutCurveClassNames),
        "a CLUT curve holding the marker")
refused(RestrictedUnarchiver.unarchiveObjectOrNil(with: archive(ArchiveMarker()), allowedClassNames: RestrictedUnarchiver.colorClassNames),
        "the marker as a CLUT point colour")
refused(RestrictedUnarchiver.unarchiveObjectOrNil(with: archive(polygon()), allowedClassNames: RestrictedUnarchiver.colorClassNames),
        "a ROI as a CLUT point colour")

/// The ROIs of an SR's array, or of a .rois_series file's arrays of them;
/// nil when something else is in them.
func roiCount(_ object: Any?) -> Int? {
    if object is ROI { return 1 }
    guard let array = object as? NSArray else { return nil }
    var sum = 0
    for element in array {
        guard let n = roiCount(element) else { return nil }
        sum += n
    }
    return sum
}

// Earlier Horos versions' SRs, when the example collection is present.
if CommandLine.arguments.count > 2 {
    let corpus = CommandLine.arguments[2]
    var count = 0, total = 0
    for name in try! FileManager.default.contentsOfDirectory(atPath: corpus).sorted() {
        let data = FileManager.default.contents(atPath: corpus + "/" + name)!
        guard let rois = roiCount(RestrictedUnarchiver.unarchiveROIs(with: data)), rois > 0 else {
            failures.append("\(name), a ROI archive of an earlier version, did not decode to ROIs")
            continue
        }
        count += 1
        total += rois
    }
    print("\(count) archives of earlier versions, \(total) ROIs")
}

for failure in failures { print("FAIL: \(failure)") }
if failures.isEmpty { print("real ROIs, CLUT curves and colours read back; the marker is refused in every format") }
exit(failures.isEmpty ? 0 : 1)
'''

STUB_CONSTANTS = r'''
NSString * const OsirixROIChangeNotification = @"OsirixROIChangeNotification";
NSString * const OsirixRemoveROINotification = @"OsirixRemoveROINotification";
'''


def objective_c_stubs(obj):
    """The project classes ROI.o names, except MyPoint, compiled for real."""
    listing = subprocess.run(['nm', '-u', str(obj)], capture_output=True, text=True, check=True).stdout
    names = sorted({m.group(1) for m in re.finditer(r'_OBJC_CLASS_\$_(\w+)', listing)})
    project = [n for n in names if not n.startswith('NS') and n != 'MyPoint']
    return '#import <Foundation/Foundation.h>\n' + STUB_CONSTANTS + ''.join(
        '@interface %s : NSObject @end\n@implementation %s @end\n' % (n, n) for n in project)


def run(command, **kwargs):
    return subprocess.run(command, check=True, capture_output=True, **kwargs)


def example_archives(directory):
    """The (0042,0011) values of the SRs in ../DICOM_Example holding a ROI
    archive, and the raw archives there; None without the collection."""
    common = subprocess.run(['git', '-C', str(root), 'rev-parse', '--path-format=absolute', '--git-common-dir'],
                            capture_output=True, text=True).stdout.strip()
    candidates = [root.parent / 'DICOM_Example']
    if common:
        candidates.append(Path(common).parent.parent / 'DICOM_Example')
    examples = next((c for c in candidates if c.is_dir()), None)
    if examples is None:
        return None
    found = subprocess.run(['grep', '-rla', '--', 'streamtyped', str(examples)], capture_output=True, text=True).stdout
    count = 0
    for path in filter(None, found.split('\n')):
        data = Path(path).read_bytes()
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


def build_roi_harness(tmp):
    reader = source('Horos/Sources/RestrictedUnarchiver.swift')
    (tmp / 'RestrictedUnarchiver.swift').write_bytes(reader if reader is not None else FORMER_READER.encode())
    for path in ('Horos/Sources/MyPoint.swift', 'Horos/Sources/HorosObjCException.h', 'Horos/Sources/HorosObjCException.m'):
        (tmp / Path(path).name).write_bytes(source(path))
    (tmp / 'bridge.h').write_text(ROI_BRIDGE)
    (tmp / 'main.swift').write_text(ROI_DRIVER)
    (tmp / 'stubs.m').write_text(objective_c_stubs(roi_object))
    run(['xcrun', 'clang', '-fobjc-exceptions', '-c', str(tmp / 'HorosObjCException.m'), '-o', str(tmp / 'HorosObjCException.o')])
    run(['xcrun', 'clang', '-fno-objc-arc', '-c', str(tmp / 'stubs.m'), '-o', str(tmp / 'stubs.o')])
    placeholders = set()
    # dyld names one missing data symbol per attempt; functions bind lazily.
    for _ in range(100):
        assembly = ''.join('.globl %s\n%s: .quad 0\n' % (s, s) for s in sorted(placeholders))
        (tmp / 'placeholders.s').write_text('.data\n' + assembly)
        run(['xcrun', 'clang', '-c', str(tmp / 'placeholders.s'), '-o', str(tmp / 'placeholders.o')])
        run(['xcrun', 'swiftc', '-swift-version', '5', '-module-name', 'Horos', '-suppress-warnings',
             '-import-objc-header', str(tmp / 'bridge.h'), '-Xcc', '-iquote', '-Xcc', str(tmp),
             str(tmp / 'RestrictedUnarchiver.swift'), str(tmp / 'MyPoint.swift'), str(tmp / 'main.swift'),
             str(tmp / 'HorosObjCException.o'), str(tmp / 'stubs.o'), str(tmp / 'placeholders.o'), str(roi_object),
             '-Xlinker', '-undefined', '-Xlinker', 'dynamic_lookup',
             '-framework', 'Cocoa', '-framework', 'Accelerate', '-o', str(tmp / 'roi-harness')])
        probe = subprocess.run([str(tmp / 'roi-harness'), '--probe-link'], capture_output=True, text=True, timeout=60)
        missing = re.search(r"symbol not found in flat namespace '([^']+)'", probe.stderr)
        if not missing:
            return
        if missing.group(1) in placeholders:
            raise RuntimeError('cannot satisfy %s' % missing.group(1))
        placeholders.add(missing.group(1))
    raise RuntimeError('too many unresolved symbols in %s' % roi_object)


# --- The CPR path file harness ---------------------------------------------

CPR_SWIFT = [
    'Horos/Sources/CPRCurvedPath.swift',
    'Horos/Sources/CPRDisplayInfo.swift',
    'Horos/Sources/CPRGeneratorRequest.swift',
    'Horos/Sources/CPRGeneratorOperation.swift',
    'Horos/Sources/CPRStraightenedOperation.swift',
    'Horos/Sources/CPRStretchedOperation.swift',
    'Horos/Sources/CPRObliqueSliceOperation.swift',
    'Horos/Sources/CPRHorizontalFillOperation.swift',
    'Horos/Sources/CPRProjectionOperation.swift',
    'Horos/Sources/CPRVolumeData.swift',
    'Horos/Sources/CPRUnsignedInt16ImageRep.swift',
]
CPR_HEADERS = [
    'Horos/Sources/CPRVolumeData.h',
    'Horos/Sources/CPRProjectionOperation.h',
    'Horos/Sources/CPRCurvedPath.h',
    'Horos/Sources/CPRUnsignedInt16ImageRep.h',
    'Horos/Sources/HorosObjCException.h',
    'Nitrogen/Sources/N3Geometry.h',
    'Nitrogen/Sources/N3BezierCore.h',
    'Nitrogen/Sources/N3BezierCoreAdditions.h',
    'Nitrogen/Sources/N3BezierPath.h',
]
CPR_OBJC = [
    ('Nitrogen/Sources/N3Geometry.m', ['-fno-objc-arc']),
    ('Nitrogen/Sources/N3BezierCore.m', ['-fno-objc-arc']),
    ('Nitrogen/Sources/N3BezierCoreAdditions.m', ['-fno-objc-arc']),
    ('Nitrogen/Sources/N3BezierPath.m', ['-fno-objc-arc']),
    ('Horos/Sources/HorosObjCException.m', ['-fobjc-exceptions']),
    ('Horos/Sources/CPRVolumeData+CAPI.m', ['-DHOROS_BRIDGING_HEADER=1']),
    ('Horos/Sources/CPRCurvedPath+CAPI.m', ['-DHOROS_BRIDGING_HEADER=1']),
]
CPR_BRIDGE = r'''
#define HOROS_BRIDGING_HEADER 1
#import <Cocoa/Cocoa.h>
#import "HorosObjCException.h"
#import "N3Geometry.h"
#import "N3BezierPath.h"
#import "CPRVolumeData.h"
#import "CPRProjectionOperation.h"
#import "CPRCurvedPath.h"
#import "CPRUnsignedInt16ImageRep.h"

@interface DCMPix : NSObject
@property (readonly) double sliceInterval, sliceThickness, pixelSpacingX, pixelSpacingY, originX, originY, originZ;
@property (readonly) long pwidth, pheight;
- (void)orientationDouble:(double *)orientation;
@end

/// The statement -[CPRController loadBezierPathFromFile:] decodes a path file with.
id HarnessLoadCurvedPath(NSData *data);
'''
CPR_DCMPIX = r'''
#import "harness.h"
@implementation DCMPix
- (double)sliceInterval { return 0; }
- (double)sliceThickness { return 0; }
- (double)pixelSpacingX { return 0; }
- (double)pixelSpacingY { return 0; }
- (double)originX { return 0; }
- (double)originY { return 0; }
- (double)originZ { return 0; }
- (long)pwidth { return 0; }
- (long)pheight { return 0; }
- (void)orientationDouble:(double *)orientation {}
@end
'''
CPR_LOAD = r'''
#import <Cocoa/Cocoa.h>
@interface CPRCurvedPath : NSObject
@end

id HarnessLoadCurvedPath(NSData *data)
{
    CPRCurvedPath *newCurvedPath = nil;
%s
    return newCurvedPath;
}
'''
CPR_DRIVER = r'''
import Cocoa

var markerRuns = 0
@objc(HorosArchiveMarker)
final class ArchiveMarker: NSObject, NSCoding {
    override init() { super.init() }
    init?(coder: NSCoder) { markerRuns += 1; super.init() }
    func encode(with coder: NSCoder) {}
}

/// Archived as a CPRCurvedPath (or its bezier path), with `value` under `key`.
final class ForgedPath: NSObject, NSCoding {
    let path: CPRCurvedPath, key: String, value: Any
    init(_ path: CPRCurvedPath, _ key: String, _ value: Any) { self.path = path; self.key = key; self.value = value }
    required init?(coder: NSCoder) { fatalError() }
    func encode(with coder: NSCoder) {
        path.encode(with: coder)
        coder.encode(value, forKey: key)
    }
}
final class ForgedBezierPath: NSObject, NSCoding {
    override init() { super.init() }
    required init?(coder: NSCoder) { fatalError() }
    func encode(with coder: NSCoder) { coder.encode(ArchiveMarker(), forKey: "bezierPathDictionaryRepresentation") }
}

var failures: [String] = []

func makePath() -> CPRCurvedPath {
    let path = CPRCurvedPath()
    for point in [NSPoint(x: 0, y: 0), NSPoint(x: 10, y: 0), NSPoint(x: 20, y: 5)] {
        path.addNode(point, transform: N3AffineTransformIdentity)
    }
    path.baseDirection = N3VectorMake(0, 1, 1)
    path.angle = 0.3
    path.thickness = 4
    return path
}

func forged(_ object: Any, as name: String, extra: [(AnyClass, String)] = []) -> Data {
    let archiver = NSKeyedArchiver(requiringSecureCoding: false)
    archiver.setClassName(name, for: type(of: object as AnyObject))
    for (cls, alias) in extra { archiver.setClassName(alias, for: cls) }
    archiver.encode(object, forKey: NSKeyedArchiveRootObjectKey)
    archiver.finishEncoding()
    return archiver.encodedData
}

func refused(_ data: Data, _ label: String) {
    let loaded = HarnessLoadCurvedPath(data)
    if markerRuns != 0 { failures.append("\(label): the marker class was instantiated (\(markerRuns) run)") }
    if loaded != nil { failures.append("\(label): loaded \(loaded!)") }
    markerRuns = 0
}

// As -saveBezierPathToFile: saves a path.
let path = makePath()
if let loaded = HarnessLoadCurvedPath(NSKeyedArchiver.archivedData(withRootObject: path)) as? CPRCurvedPath {
    if loaded.nodes.count != 3 || abs(loaded.thickness - 4) > 1e-12 || abs(loaded.angle - 0.3) > 1e-12 ||
       loaded.bezierPath == nil || loaded.bezierPath!.elementCount() != path.bezierPath!.elementCount() {
        failures.append("a saved path loaded with \(loaded.nodes.count) nodes, thickness \(loaded.thickness)")
    }
} else {
    failures.append("a saved path did not load")
}

refused(NSKeyedArchiver.archivedData(withRootObject: ArchiveMarker()), "a path file whose root is the marker")
refused(forged(ForgedPath(makePath(), "nodeRelativePositions", [ArchiveMarker()]), as: "CPRCurvedPath"),
        "the marker among a path's relative positions")
refused(forged(ForgedPath(makePath(), "bezierPath", ArchiveMarker()), as: "CPRCurvedPath"),
        "the marker as a path's bezier path")
refused(forged(ForgedPath(makePath(), "bezierPath", ForgedBezierPath()), as: "CPRCurvedPath",
               extra: [(ForgedBezierPath.self, "N3BezierPath")]),
        "the marker as a bezier path's dictionary")

for failure in failures { print("FAIL: \(failure)") }
if failures.isEmpty { print("a saved path loads; the marker, as a path file's root or under its keys, is refused") }
exit(failures.isEmpty ? 0 : 1)
'''


def load_statement():
    """The decoding in -[CPRController loadBezierPathFromFile:]."""
    text = source('Horos/Sources/CPRController.m').decode('utf-8').replace('\r\n', '\n')
    method = text.index('-(void) loadBezierPathFromFile: (NSString*) path')
    start = text.index('CPRCurvedPath *newCurvedPath = nil;', method) + len('CPRCurvedPath *newCurvedPath = nil;')
    end = text.index('if( newCurvedPath)', start)
    return text[start:end]


def build_cpr_harness(tmp):
    for path in CPR_HEADERS + [p for p, _ in CPR_OBJC] + CPR_SWIFT:
        (tmp / Path(path).name).write_bytes(source(path))
    (tmp / 'harness.h').write_text(CPR_BRIDGE)
    (tmp / 'DCMPixDouble.m').write_text(CPR_DCMPIX)
    (tmp / 'Load.m').write_text(CPR_LOAD % load_statement())
    (tmp / 'main.swift').write_text(CPR_DRIVER)
    objects = []
    for path, flags in CPR_OBJC + [('DCMPixDouble.m', ['-fno-objc-arc']), ('Load.m', ['-fno-objc-arc', '-fobjc-exceptions'])]:
        obj = tmp / (Path(path).stem + '.o')
        run(['xcrun', 'clang', '-x', 'objective-c', '-include', 'Cocoa/Cocoa.h', '-iquote', str(tmp), *flags,
             '-c', str(tmp / Path(path).name), '-o', str(obj)])
        objects.append(str(obj))
    run(['xcrun', 'swiftc', '-swift-version', '5', '-module-name', 'Horos', '-suppress-warnings', '-Onone',
         '-import-objc-header', str(tmp / 'harness.h'), '-Xcc', '-iquote', '-Xcc', str(tmp),
         *[str(tmp / Path(p).name) for p in CPR_SWIFT], str(tmp / 'main.swift'), *objects,
         '-framework', 'Cocoa', '-framework', 'Accelerate', '-framework', 'QuartzCore', '-o', str(tmp / 'cpr-harness')])


def report(name, result):
    lines = [line for line in (result.stdout + result.stderr).splitlines() if line.strip()]
    marks = [line[len('FAIL: '):] for line in lines if line.startswith('FAIL: ')]
    if result.returncode == 0:
        for line in result.stdout.splitlines():
            print('ok:', name, '-', line)
        return
    # The driver's FAIL lines, else how it ended (an uncaught exception's reason).
    failures.extend(marks or ['%s: exit %d: %s' % (name, result.returncode, ' / '.join(lines[:3]) if lines else '')])


with tempfile.TemporaryDirectory(prefix='horos-roi-archive-classes-') as tmp:
    tmp = Path(tmp)
    (tmp / 'roi').mkdir()
    (tmp / 'cpr').mkdir()
    (tmp / 'files').mkdir()
    (tmp / 'examples').mkdir()
    try:
        build_roi_harness(tmp / 'roi')
        build_cpr_harness(tmp / 'cpr')
    except (subprocess.CalledProcessError, RuntimeError) as e:
        detail = e.stderr.decode(errors='replace')[-3000:] if isinstance(e, subprocess.CalledProcessError) else str(e)
        print('FAIL: a harness did not build:', detail)
        sys.exit(1)
    examples = example_archives(tmp / 'examples')
    arguments = [str(tmp / 'roi' / 'roi-harness'), str(tmp / 'files')]
    if examples:
        arguments.append(str(tmp / 'examples'))
    else:
        print('note: no ROI archives of earlier versions (../DICOM_Example) to read')
    report('ROI archives', subprocess.run(arguments, capture_output=True, text=True, timeout=120))
    report('CPR path files', subprocess.run([str(tmp / 'cpr' / 'cpr-harness')], capture_output=True, text=True, timeout=120))

for failure in failures:
    print('FAIL:', failure)
if failures:
    sys.exit(1)
print('PASS: ROI archives, CLUT pasteboard types and CPR path files decode only their own classes; '
      'real and earlier ROI archives still read back')
