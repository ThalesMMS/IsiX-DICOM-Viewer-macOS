#!/usr/bin/env python3
"""A mask ROI merged into a group of ROIs keeps its voxels in the group's mask.

A group of volume ROIs (OSICoalescedPlanarROI) merges the masks of its ROIs in
a box of the home volume around their hulls: it asks each ROI for its hull, in
patient space, and for its mask in the box. A mask ROI (OSIMaskROI) holds a
mask of the home volume. It used to give the hull of that mask in the mask's
own indexes, and the mask itself for any volume, so its runs landed outside
the box: past the end of the buffer in the Objective-C class, dropped in the
Swift one.

This compiles the app's OSIMaskROI, OSICoalescedPlanarROI, OSIROIMask,
OSIROIVolumeGeometry and OSIFloatVolumeData with IsiXROI and Nitrogen's
geometry, on stand-ins of their abstract base OSIROI, of the float volume's
base CPRVolumeData (voxels in memory) and of what draws and resamples, and
checks, in a home volume that is scaled, turned and
moved in patient space:

- each mask ROI's hull, in patient space, holds every voxel of its mask;
- the merged box of two mask ROIs holds, voxel for voxel, exactly the voxels
  of the two masks in the home volume, with their intensities;
- the mask of a mask ROI in its home volume is its mask; in a volume on the
  same grid it moves by the offset between them and is cut to that volume; in
  a volume on another grid it is empty;
- the Debug check that a mask lies in a float volume accepts a row that ends
  at the volume's last column and refuses one that goes past it, or past its
  last row or slice.

`<git revision>` as an optional argument takes the two ROI classes, the
geometry and the float volume from that revision, the negative control.
"""
import private_tmpdir  # noqa: F401  (swiftc leaves folders in TMPDIR)
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import isix_modules  # noqa: E402
import n3_geometry_harness  # noqa: E402

SKIPPED = 2
root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None

if shutil.which('xcrun') is None:
    print('skipped: needs xcrun (swiftc, clang)', file=sys.stderr)
    sys.exit(SKIPPED)


def source(name):
    path = 'Horos/Sources/' + name
    if revision and name in ('OSIMaskROI.swift', 'OSICoalescedPlanarROI.swift', 'OSIROIVolumeGeometry.swift',
                            'OSIFloatVolumeData.swift'):
        return subprocess.run(['git', '-C', str(root), 'show', f'{revision}:{path}'], check=True,
                              capture_output=True).stdout.decode('utf-8')
    return (root / path).read_text(encoding='utf-8')


failures = []
coalesced = source('OSICoalescedPlanarROI.swift')
# The merged volume is private to the class; the probe reads it.
MERGED = 'private func coalescedROIMaskVolumeData() -> OSIFloatVolumeData?'
if MERGED not in coalesced:
    failures.append('OSICoalescedPlanarROI has no coalescedROIMaskVolumeData() any more')
coalesced = coalesced.replace(MERGED, MERGED.replace('private ', ''))

# What the ROIs ask of their base class, of the generator that resamples and of
# the canvas they draw on. The probe does not draw nor resample.
STAND_INS = r'''
import Cocoa

open class OSIROI: NSObject {
    private var home: OSIFloatVolumeData?
    public dynamic func name() -> String! { nil }
    public dynamic func convexHull() -> [Any]! { nil }
    public dynamic func roiMask(forFloatVolumeData floatVolume: OSIFloatVolumeData!) -> OSIROIMask! { nil }
    public dynamic func homeFloatVolumeData() -> OSIFloatVolumeData! { home }
    public dynamic func setHomeFloatVolumeData(_ homeFloatVolumeData: OSIFloatVolumeData!) { home = homeFloatVolumeData }
    public dynamic func fillColor() -> NSColor! { nil }
    public dynamic func setFillColor(_ color: NSColor!) {}
    public dynamic func strokeColor() -> NSColor! { nil }
    public dynamic func draw(_ slab: OSISlab, dicomToPixTransform: N3AffineTransform) {}
    public dynamic func osiriXROIs() -> NSSet! { NSSet() }
    func inverseHomeVolumeTransform() -> N3AffineTransform {
        N3AffineTransformInvert(homeFloatVolumeData()?.volumeTransform ?? N3AffineTransform())
    }
    static func openGLMatrix(_ transform: N3AffineTransform) -> [Double] { [Double](repeating: 0, count: 16) }
    static func roiMask(fromResampled volume: CPRVolumeData?) -> OSIROIMask! { OSIROIMask() }
}

final class CPRObliqueSliceGeneratorRequest: NSObject {
    var pixelsWide: UInt = 0, pixelsHigh: UInt = 0
    var slabWidth: CGFloat = 0, slabSampleDistance: CGFloat = 0
    var projectionMode = CPRProjectionMode(0)
    var sliceToDicomTransform = N3AffineTransform()
}
struct CPRProjectionMode: RawRepresentable { var rawValue: Int32; init(_ value: Int32) { rawValue = value }; init(rawValue: Int32) { self.rawValue = rawValue } }
let CPRProjectionModeMIP = CPRProjectionMode(0)
final class CPRGenerator: NSObject {
    static func synchronousRequestVolume(_ request: CPRObliqueSliceGeneratorRequest, volumeData: CPRVolumeData?) -> CPRVolumeData? { nil }
}

// The checks of CPRVolumeData.swift, as the app's Debug build makes them.
func cprVolumeDataAssert(_ condition: @autoclosure () -> Bool, file: StaticString = #file, line: UInt = #line) {
    precondition(condition(), file: file, line: line)
}

// The float volume's base class: the voxels in memory, read by index.
open class CPRVolumeData: NSObject {
    private let bytes: UnsafePointer<Float>?
    private let wide: UInt, high: UInt, deep: UInt
    private let transform: N3AffineTransform
    public init(floatBytesNoCopy floatBytes: UnsafePointer<Float>?, pixelsWide: UInt, pixelsHigh: UInt, pixelsDeep: UInt,
                volumeTransform: N3AffineTransform, outOfBoundsValue: Float, freeWhenDone: Bool) {
        bytes = floatBytes; wide = pixelsWide; high = pixelsHigh; deep = pixelsDeep; transform = volumeTransform
    }
    @objc open var pixelsWide: UInt { wide }
    @objc open var pixelsHigh: UInt { high }
    @objc open var pixelsDeep: UInt { deep }
    @objc open var minPixelSpacing: CGFloat { 1 }
    @objc open var pixelSpacingX: CGFloat { 1 }
    @objc open var pixelSpacingY: CGFloat { 1 }
    @objc open var pixelSpacingZ: CGFloat { 1 }
    @objc open var volumeTransform: N3AffineTransform { transform }
    @objc(getFloatRun:atPixelCoordinateX:y:z:length:)
    open func getFloatRun(_ buffer: UnsafeMutablePointer<Float>!, atPixelCoordinateX x: UInt, y: UInt, z: UInt, length: UInt) -> Bool { false }
    @objc(getFloat:atPixelCoordinateX:y:z:)
    open func getFloat(_ floatPtr: UnsafeMutablePointer<Float>!, atPixelCoordinateX x: UInt, y: UInt, z: UInt) -> Bool {
        guard let bytes, x < wide, y < high, z < deep else { floatPtr.pointee = 0; return false }
        floatPtr.pointee = bytes[Int(x + y * wide + z * wide * high)]
        return true
    }
    @objc(getLinearInterpolatedFloat:atDicomVector:)
    open func getLinearInterpolatedFloat(_ floatPtr: UnsafeMutablePointer<Float>!, atDicomVector vector: N3Vector) -> Bool { false }
    func aquireInlineBuffer(_ buffer: UnsafeMutablePointer<CPRVolumeDataInlineBuffer>) -> Bool { false }
    func releaseInlineBuffer(_ buffer: UnsafeMutablePointer<CPRVolumeDataInlineBuffer>) {}
}

enum ROIGL {
    static let blend: UInt32 = 0, srcAlpha: UInt32 = 0, oneMinusSrcAlpha: UInt32 = 0, quads: UInt32 = 0
    static let pointSmooth: UInt32 = 0, lineSmooth: UInt32 = 0, polygonSmooth: UInt32 = 0, triangleStrip: UInt32 = 0
    static func lineWidth(_ width: Float) {}
    static func enable(_ capability: UInt32) {}
    static func disable(_ capability: UInt32) {}
    static func blendFunc(_ source: UInt32, _ destination: UInt32) {}
    static func color4f(_ r: Float, _ g: Float, _ b: Float, _ a: Float) {}
    static func begin(_ mode: UInt32) {}
    static func end() {}
    static func vertex3d(_ x: Double, _ y: Double, _ z: Double) {}
    static func pushMatrix() {}
    static func popMatrix() {}
    static func multMatrixd(_ matrix: UnsafePointer<Double>) {}
}
'''

BRIDGING = r'''
#define HOROS_BRIDGING_HEADER 1
#import <Cocoa/Cocoa.h>
#import "N3Geometry.h"
#import "N3BezierPath.h"
#import "OSIGeometry.h"
#import "OSIROIMask.h"
#import "CPRVolumeData.h"
'''

DRIVER = r'''
import Cocoa

func fail(_ what: String) -> Never { print("FAIL: " + what); exit(1) }

struct Voxel: Hashable, Comparable {
    let x: Int, y: Int, z: Int
    static func < (a: Voxel, b: Voxel) -> Bool { (a.z, a.y, a.x) < (b.z, b.y, b.x) }
}

func runs(_ mask: OSIROIMask?) -> [OSIROIMaskRun] {
    (mask?.maskRuns() as? [NSValue] ?? []).map { $0.osiroiMaskRun() }
}

func voxels(_ mask: OSIROIMask?) -> [Voxel: Float] {
    var found: [Voxel: Float] = [:]
    for run in runs(mask) {
        for x in run.widthRange.location..<NSMaxRange(run.widthRange) {
            found[Voxel(x: x, y: Int(run.heightIndex), z: Int(run.depthIndex))] = run.intensity
        }
    }
    return found
}

func mask(_ rows: [(x: Int, length: Int, y: Int, z: Int, intensity: Float)]) -> OSIROIMask {
    OSIROIMask(maskRuns: rows.map { row -> NSValue in
        var run = OSIROIMaskRunZero
        run.widthRange = NSMakeRange(row.x, row.length)
        run.heightIndex = UInt(row.y)
        run.depthIndex = UInt(row.z)
        run.intensity = row.intensity
        return NSValue(osiroiMaskRun: run)!
    } as NSArray)
}

func volume(_ width: Int, _ height: Int, _ depth: Int, _ transform: N3AffineTransform) -> OSIFloatVolumeData {
    let bytes = UnsafeMutablePointer<Float>.allocate(capacity: width * height * depth)
    bytes.initialize(repeating: 0, count: width * height * depth)
    return OSIFloatVolumeData(floatBytesNoCopy: UnsafePointer(bytes), pixelsWide: UInt(width), pixelsHigh: UInt(height),
                              pixelsDeep: UInt(depth), volumeTransform: transform, outOfBoundsValue: 0, freeWhenDone: true)
}

// Patient space to the home volume's indexes: voxels of 0.8 × 0.8 × 2 mm,
// turned in the axial plane and moved, as a series rarely lies on the axes.
var patientToHome = N3AffineTransformMakeTranslation(-37.5, 112.25, -60)
patientToHome = N3AffineTransformConcat(patientToHome, N3AffineTransformMakeRotation(0.6, 0, 0, 1))
patientToHome = N3AffineTransformConcat(patientToHome, N3AffineTransformMakeScale(1 / 0.8, 1 / 0.8, 1 / 2.0))
let home = volume(120, 100, 40, patientToHome)

var blockRows: [(x: Int, length: Int, y: Int, z: Int, intensity: Float)] = []
for z in 12..<20 { for y in 30..<45 { blockRows.append((x: 50 + (y % 3), length: 12 + (z % 4), y: y, z: z, intensity: 1)) } }
var sideRows: [(x: Int, length: Int, y: Int, z: Int, intensity: Float)] = []
for z in 25..<29 { for y in 70..<75 { sideRows.append((x: 90, length: 6, y: y, z: z, intensity: 0.5)) } }
let block = OSIMaskROI(roiMask: mask(blockRows), homeFloatVolumeData: home, name: "lesion")
let side = OSIMaskROI(roiMask: mask(sideRows), homeFloatVolumeData: home, name: "lesion")

// --- the hull, in patient space -------------------------------------------
for (name, roi) in [("block", block), ("side", side)] {
    let hull = (roi.convexHull() as? [NSValue] ?? []).map { N3VectorApplyTransform($0.n3VectorValue(), patientToHome) }
    if hull.isEmpty { fail("the \(name) mask ROI has no hull") }
    let low = (x: hull.map(\.x).min()!, y: hull.map(\.y).min()!, z: hull.map(\.z).min()!)
    let high = (x: hull.map(\.x).max()!, y: hull.map(\.y).max()!, z: hull.map(\.z).max()!)
    for voxel in voxels(roi.mask).keys {
        let x = CGFloat(voxel.x), y = CGFloat(voxel.y), z = CGFloat(voxel.z)
        if x < low.x || x + 1 > high.x || y < low.y || y + 1 > high.y || z < low.z || z + 1 > high.z {
            fail("the hull of the \(name) mask ROI does not hold its voxel \(voxel): home indexes \(low) to \(high)")
        }
    }
}
print("PASS: the hull of a mask ROI, in patient space, holds every voxel of its mask")

// --- the group's box -------------------------------------------------------
let group = OSICoalescedPlanarROI(sourceROIs: [block, side], homeFloatVolumeData: home)
guard let box = group.coalescedROIMaskVolumeData() else { fail("the group has no merged volume") }
let width = Int(box.pixelsWide), height = Int(box.pixelsHigh), depth = Int(box.pixelsDeep)
if width * height * depth == 0 { fail("the group's box is empty") }
let boxToHome = N3AffineTransformConcat(N3AffineTransformInvert(box.volumeTransform), patientToHome)
var merged: [Voxel: Float] = [:]
for z in 0..<depth { for y in 0..<height { for x in 0..<width {
    var value: Float = 0
    _ = box.getFloat(&value, atPixelCoordinateX: UInt(x), y: UInt(y), z: UInt(z))
    if value != 0 {
        let at = N3VectorApplyTransform(N3VectorMake(CGFloat(x), CGFloat(y), CGFloat(z)), boxToHome)
        merged[Voxel(x: Int(at.x.rounded()), y: Int(at.y.rounded()), z: Int(at.z.rounded()))] = value
    }
} } }
var expected = voxels(block.mask)
expected.merge(voxels(side.mask)) { max($0, $1) }
let missing = Set(expected.keys).subtracting(merged.keys).sorted()
let extra = Set(merged.keys).subtracting(expected.keys).sorted()
if !missing.isEmpty || !extra.isEmpty {
    fail("the group's mask has \(merged.count) voxels, the mask ROIs \(expected.count): \(missing.count) missing "
         + "(first \(missing.prefix(3))), \(extra.count) elsewhere (first \(extra.prefix(3))); box \(width)×\(height)×\(depth)")
}
if let wrong = expected.first(where: { merged[$0.key] != $0.value }) {
    fail("the group's mask has \(merged[wrong.key] ?? 0) at \(wrong.key), the mask ROI \(wrong.value)")
}
for roi in [block, side] where !box.checkDebugROIMask(roi.roiMask(forFloatVolumeData: box)) {
    fail("a mask ROI's mask in the group's box goes past the box")
}
print("PASS: the group's mask has the \(expected.count) voxels of its two mask ROIs, at the same places, with their intensities")

// --- other volumes ----------------------------------------------------------
if block.roiMask(forFloatVolumeData: home) !== block.mask { fail("the mask in the home volume is not the mask") }
// The same grid, 48 voxels to the left, 30 down and 13 slices back, 20 × 20 × 20.
let shifted = volume(20, 20, 20, N3AffineTransformConcat(patientToHome, N3AffineTransformMakeTranslation(-48, -30, -13)))
let moved = voxels(block.roiMask(forFloatVolumeData: shifted))
let cut = Dictionary(uniqueKeysWithValues: voxels(block.mask).compactMap { voxel, value -> (Voxel, Float)? in
    let at = Voxel(x: voxel.x - 48, y: voxel.y - 30, z: voxel.z - 13)
    return (0..<20).contains(at.x) && (0..<20).contains(at.y) && (0..<20).contains(at.z) ? (at, value) : nil
})
if moved != cut || moved.isEmpty { fail("the mask in a volume on the same grid has \(moved.count) voxels, \(cut.count) expected") }
// Half a voxel off, or with other voxels: another grid.
let offGrid = volume(120, 100, 40, N3AffineTransformConcat(patientToHome, N3AffineTransformMakeTranslation(0.5, 0, 0)))
let rescaled = volume(120, 100, 40, N3AffineTransformConcat(patientToHome, N3AffineTransformMakeScale(2, 2, 1)))
if !runs(block.roiMask(forFloatVolumeData: offGrid)).isEmpty || !runs(block.roiMask(forFloatVolumeData: rescaled)).isEmpty {
    fail("a volume on another grid got a mask")
}
print("PASS: in a volume on the same grid the mask moves and is cut to it; on another grid it is empty")

// --- the Debug check of a mask against a volume -----------------------------
// home is 120 × 100 × 40: columns 0...119, rows 0...99, slices 0...39.
let inside: [(String, OSIROIMask)] = [
    ("a row ending at the last column", mask([(x: 110, length: 10, y: 99, z: 39, intensity: 1)])),
    ("a row of the whole width", mask([(x: 0, length: 120, y: 0, z: 0, intensity: 1)])),
]
let outside: [(String, OSIROIMask)] = [
    ("a row one column past the last", mask([(x: 111, length: 10, y: 5, z: 5, intensity: 1)])),
    ("a row past the last row", mask([(x: 0, length: 4, y: 100, z: 5, intensity: 1)])),
    ("a row past the last slice", mask([(x: 0, length: 4, y: 5, z: 40, intensity: 1)])),
]
for (name, roiMask) in inside where !home.checkDebugROIMask(roiMask) { fail("the Debug check refuses \(name)") }
for (name, roiMask) in outside where home.checkDebugROIMask(roiMask) { fail("the Debug check accepts \(name)") }
print("PASS: the Debug check accepts a row ending at the last column and refuses rows past the volume")
'''

def run(argv, timeout=600):
    done = subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
    if done.returncode:
        raise RuntimeError(' '.join(map(str, argv[:3])) + ' failed:\n' + (done.stdout + done.stderr)[-4000:])
    return done.stdout


if not failures:
    with tempfile.TemporaryDirectory(prefix='horos-osi-mask-coalesced-') as folder:
        folder = Path(folder)
        sources = folder / 'sources'
        sources.mkdir()
        for name in ('OSIMaskROI.swift', 'OSIROIVolumeGeometry.swift', 'OSIGeometry.swift', 'OSIROIMask.swift',
                     'OSIROIMaskRunStack.swift', 'OSIFloatVolumeData.swift'):
            (sources / name).write_text(source(name))
        (sources / 'OSICoalescedPlanarROI.swift').write_text(coalesced)
        (sources / 'StandIns.swift').write_text(STAND_INS)
        (sources / 'main.swift').write_text(DRIVER)
        (folder / 'bridging.h').write_text(BRIDGING)
        nitrogen = root / 'Nitrogen/Sources'
        # Nitrogen's N3 geometry, Swift: IsiXGeometry and N3*.swift.
        n3_geometry_harness.build(folder / 'n3', 'release')
        objects = n3_geometry_harness.libraries(folder / 'n3')
        for objc in [root / 'Horos/Sources/OSIROIMask+CAPI.m']:
            obj = folder / (objc.stem + '.o')
            run(['xcrun', 'clang', '-x', 'objective-c', '-include', 'Cocoa/Cocoa.h', '-c', '-fno-objc-arc', '-w', '-O0',
                 '-DHOROS_BRIDGING_HEADER=1', '-I', str(root / 'Horos/Sources'), '-I', str(nitrogen), str(objc), '-o', str(obj)])
            objects.append(obj)
        module = isix_modules.module_flags('IsiXROI', folder / 'module')
        try:
            # -O, as the app's Debug build compiles Swift: assert() is not checked.
            run(['xcrun', 'swiftc', '-swift-version', '6', '-suppress-warnings', '-O', '-module-name', 'OSIMaskProbe',
                 '-import-objc-header', str(folder / 'bridging.h'), '-Xcc', '-I' + str(root / 'Horos/Sources'),
                 '-Xcc', '-I' + str(nitrogen), *module, *map(str, sorted(sources.iterdir())), *map(str, objects),
                 '-framework', 'Cocoa', '-framework', 'QuartzCore', '-framework', 'Accelerate', '-o', str(folder / 'probe')])
        except RuntimeError as error:
            failures.append(f'the OSI classes do not compile with the probe: {error}')
        else:
            try:
                done = subprocess.run([str(folder / 'probe')], capture_output=True, text=True, timeout=60)
                print(done.stdout.strip())
                if done.returncode and 'FAIL' not in done.stdout:
                    failures.append(f'the probe stopped ({done.returncode}): {done.stderr.strip()[-2000:]}')
                elif done.returncode:
                    failures.append('the probe failed')
            except subprocess.TimeoutExpired:
                failures.append('the probe did not finish within 60 s')

for failure in failures:
    print('FAIL:', failure)
if failures:
    sys.exit(1)
print('ok: a mask ROI keeps its voxels in the mask of the group it is merged into')
