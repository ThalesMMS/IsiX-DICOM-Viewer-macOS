#!/usr/bin/env python3
"""A curved path keeps its base direction through an archive, and the CPR
operations clear every float and return defined output when they fail (#773).

The CPR classes are compiled as they are (CPRCurvedPath, the generator
requests and operations, the fill and projection operations, CPRVolumeData
and its C samplers, with Nitrogen's N3BezierPath and HorosObjCException),
under AddressSanitizer, with a double for DCMPix, and driven as the app
drives them:
- archive: -initWithCoder: read baseDirectionDictionary into a local
  initialNormal, so a decoded path, as the Curved MPR's undo restores it, had
  a zero base direction and a zero initial normal. It must come back with the
  base direction, angle and initial normal it was archived with.
- mutable: a decoded path held the immutable N3BezierPath of the archive
  under the N3MutableBezierPath type of -bezierPath. It must be mutable and
  accept -applyAffineTransform:.
- unknown-fill: a fill with an unknown interpolation mode cleared
  height*width bytes, a quarter of the floats. Every float must be zero.
- failed-projection: a MIP of a volume whose data is gone returned the
  malloc'd plane as it was (ASan fills it with 0xaa bytes). It must be zeros.
- straightened, stretched, oblique: with no slab sample distance in the
  request and none from the volume (a CPRVolumeData whose minPixelSpacing is
  0), slabWidth / 0 is NaN for a zero slab and inf for a wide one. NaN gave
  no plane and an operation that never finished; inf wrapped the allocation
  size and the operation failed. Each must finish with one plane, sampled
  from the volume.
- transverse-sections: a transverse view holds a copy of the path, and
  compared it by identity with the one it was given, so every path asked for
  a new slice (#854). A copy, an archived path and a thicker one must define
  the same transverse sections; a moved node, section, spacing or angle not.

`<git revision>` as an optional argument reads the sources from that
revision, the negative control.
"""
from pathlib import Path
import os
import shutil
import subprocess
import sys
import tempfile

SKIPPED = 2
root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None


def source(path):
    if revision:
        return subprocess.check_output(['git', '-C', str(root), 'show', f'{revision}:{path}'])
    return (root / path).read_bytes()


if shutil.which('xcrun') is None:
    print('skipped: needs xcrun (swiftc, clang)', file=sys.stderr)
    sys.exit(SKIPPED)

SWIFT_SOURCES = [
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
# The operations' KVO context token (#1005); older revisions do not have it.
if revision is None or subprocess.run(['git', '-C', str(root), 'cat-file', '-e',
                                       f'{revision}:Horos/Sources/IdentityToken.swift']).returncode == 0:
    SWIFT_SOURCES.append('Horos/Sources/IdentityToken.swift')
HEADERS = [
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
# (source, extra clang flags): Nitrogen is manual retain/release, as in the app.
OBJC_SOURCES = [
    ('Nitrogen/Sources/N3Geometry.m', ['-fno-objc-arc']),
    ('Nitrogen/Sources/N3BezierCore.m', ['-fno-objc-arc']),
    ('Nitrogen/Sources/N3BezierCoreAdditions.m', ['-fno-objc-arc']),
    ('Nitrogen/Sources/N3BezierPath.m', ['-fno-objc-arc']),
    ('Horos/Sources/HorosObjCException.m', ['-fobjc-exceptions']),
    ('Horos/Sources/CPRVolumeData+CAPI.m', ['-DHOROS_BRIDGING_HEADER=1']),
    ('Horos/Sources/CPRCurvedPath+CAPI.m', ['-DHOROS_BRIDGING_HEADER=1']),
]

BRIDGING = r'''
#define HOROS_BRIDGING_HEADER 1
#import <Cocoa/Cocoa.h>
#import "HorosObjCException.h"
#import "N3Geometry.h"
#import "N3BezierPath.h"
#import "CPRVolumeData.h"
#import "CPRProjectionOperation.h"
#import "CPRCurvedPath.h"
#import "CPRUnsignedInt16ImageRep.h"

// DCMPix as -[CPRVolumeData initWithWithPixList:volume:] reads it; the cases
// below never build a volume from a pixel list.
@interface DCMPix : NSObject
@property (readonly) double sliceInterval, sliceThickness, pixelSpacingX, pixelSpacingY, originX, originY, originZ;
@property (readonly) long pwidth, pheight;
- (void)orientationDouble:(double *)orientation;
@end
'''

DCMPIX_DOUBLE = r'''
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

DRIVER = r'''
import Cocoa

func fail(_ message: String) -> Never {
    print("FAIL: \(message)")
    exit(1)
}

func close(_ a: N3Vector, _ b: N3Vector) -> Bool {
    return abs(a.x - b.x) < 1e-9 && abs(a.y - b.y) < 1e-9 && abs(a.z - b.z) < 1e-9
}

func describe(_ v: N3Vector) -> String {
    return "(\(v.x), \(v.y), \(v.z))"
}

/// A path through three nodes in the z = 0 plane, with a base direction that is
/// not the one -setInitialNormal: would pick, and an angle.
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

func roundTrip(_ path: CPRCurvedPath) -> CPRCurvedPath {
    let data = try! NSKeyedArchiver.archivedData(withRootObject: path, requiringSecureCoding: true)
    guard let decoded = try! NSKeyedUnarchiver.unarchivedObject(ofClass: CPRCurvedPath.self, from: data) else {
        fail("the archive did not decode to a CPRCurvedPath")
    }
    return decoded
}

/// Runs the operation on a queue and waits for it at most `seconds`.
func runOperation(_ operation: Operation, seconds: Double = 10) -> Bool {
    let queue = OperationQueue()
    queue.addOperation(operation)
    let deadline = Date(timeIntervalSinceNow: seconds)
    while !operation.isFinished && Date() < deadline {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
    }
    return operation.isFinished
}

/// A 16 mm cube of 5.0, out of bounds 5.0 too: every sample is 5.0.
let sampledValue: Float = 5

/// The volume of a series whose smallest spacing reads as 0.
final class ZeroSpacingVolume: CPRVolumeData {
    override var minPixelSpacing: CGFloat { 0 }
}

func zeroSpacingVolume() -> CPRVolumeData {
    let side: UInt = 16
    let data = UnsafeMutablePointer<Float>.allocate(capacity: Int(side * side * side))
    data.initialize(repeating: sampledValue, count: Int(side * side * side))
    let volume = ZeroSpacingVolume(floatBytesNoCopy: data, pixelsWide: side, pixelsHigh: side, pixelsDeep: side,
                                   volumeTransform: N3AffineTransformIdentity, outOfBoundsValue: sampledValue, freeWhenDone: true)
    if volume.minPixelSpacing != 0 {
        fail("the volume double does not report a zero spacing")
    }
    return volume
}

/// Nil when the operation finished with its one plane, sampled
/// from the volume; else what went wrong.
func checkGenerated(_ name: String, _ operation: CPRGeneratorOperation, pixelsWide: UInt, pixelsHigh: UInt) -> String? {
    if !runOperation(operation) {
        return "\(name): the operation never finished (no plane from a NaN slab count)"
    }
    if operation.didFail {
        return "\(name): the operation failed (an infinite slab count wrapped the allocation)"
    }
    guard let volume = operation.generatedVolume else {
        return "\(name): the operation finished without a volume"
    }
    if volume.pixelsDeep != 1 || volume.pixelsWide != pixelsWide || volume.pixelsHigh != pixelsHigh {
        return "\(name): generated \(volume.pixelsWide)x\(volume.pixelsHigh)x\(volume.pixelsDeep)"
    }
    var inlineBuffer = CPRVolumeDataInlineBuffer()
    defer { volume.releaseInlineBuffer(&inlineBuffer) }
    if !volume.aquireInlineBuffer(&inlineBuffer) {
        return "\(name): the generated volume has no data"
    }
    let floats = CPRVolumeDataFloatBytes(&inlineBuffer)!
    for i in 0..<Int(pixelsWide * pixelsHigh) where floats[i] != sampledValue {
        return "\(name): float \(i) is \(floats[i]), not the volume's \(sampledValue)"
    }
    return nil
}

/// Both slabs are run, so that each reports.
func checkSlabs(_ make: (CGFloat) -> (String, CPRGeneratorOperation)) {
    var problems: [String] = []
    for slabWidth in [CGFloat(0), 5] {
        let (name, operation) = make(slabWidth)
        if let problem = checkGenerated("\(name), slab \(slabWidth) mm", operation, pixelsWide: stretchedPixelsWide, pixelsHigh: pixelsHigh) {
            problems.append(problem)
        }
    }
    if !problems.isEmpty {
        fail(problems.joined(separator: "; "))
    }
    print("one plane for a zero and a 5 mm slab")
}

let stretchedPixelsWide: UInt = 32
let pixelsHigh: UInt = 8

switch CommandLine.arguments[1] {
case "archive":
    let path = makePath()
    let expectedBase = path.baseDirection
    let expectedNormal = path.initialNormal
    let decoded = roundTrip(path)
    if !close(decoded.baseDirection, expectedBase) {
        fail("the base direction decoded as \(describe(decoded.baseDirection)), archived as \(describe(expectedBase))")
    }
    if abs(decoded.angle - path.angle) > 1e-12 || abs(decoded.thickness - path.thickness) > 1e-12 {
        fail("the angle or thickness changed through the archive")
    }
    if N3VectorIsZero(expectedNormal) || !close(decoded.initialNormal, expectedNormal) {
        fail("the initial normal decoded as \(describe(decoded.initialNormal)), archived as \(describe(expectedNormal))")
    }
    // A second trip keeps it too.
    if !close(roundTrip(decoded).initialNormal, expectedNormal) {
        fail("the initial normal did not survive a second archive")
    }
    print("base direction \(describe(decoded.baseDirection)), initial normal \(describe(decoded.initialNormal))")

case "mutable":
    let decoded = roundTrip(makePath())
    guard let bezierPath = decoded.bezierPath else {
        fail("the decoded path has no bezier path")
    }
    if !bezierPath.isKind(of: N3MutableBezierPath.self) {
        fail("the decoded bezier path is a \(type(of: bezierPath as AnyObject)), not an N3MutableBezierPath")
    }
    let start = bezierPath.vectorAtStart()
    bezierPath.applyAffineTransform(N3AffineTransformMakeTranslation(1, 2, 3))
    if !close(bezierPath.vectorAtStart(), N3VectorAdd(start, N3VectorMake(1, 2, 3))) {
        fail("the decoded bezier path did not move")
    }
    print("decoded bezier path is \(type(of: bezierPath as AnyObject)) and moves")

case "snapshot":
    let path = makePath()
    path.transverseSectionPosition = 0.6
    path.transverseSectionSpacing = 3
    let snapshot = path.copy() as! CPRCurvedPath
    let expectedNormal = path.initialNormal
    path.moveNode(at: 1, to: N3VectorMake(10, 9, 0))
    path.angle = 0.7
    path.thickness = 10
    path.transverseSectionSpacing = 9
    let restored = snapshot.copy() as! CPRCurvedPath
    if restored === snapshot || !close(restored.initialNormal, expectedNormal) ||
       restored.angle != 0.3 || restored.thickness != 4 ||
       restored.transverseSectionPosition != 0.6 || restored.transverseSectionSpacing != 3 ||
       !restored.hasSameTransverseSections(as: snapshot) {
        fail("an undo snapshot changed when the original path was edited")
    }
    restored.moveNode(at: 1, to: N3VectorMake(10, 7, 0))
    if restored.hasSameTransverseSections(as: snapshot) {
        fail("restoring undo shared mutable nodes with its snapshot")
    }
    print("undo copies preserve geometry and settings independently")

case "unknown-fill":
    let width: UInt = 16, height: UInt = 8
    let count = Int(width * height)
    let floats = UnsafeMutablePointer<Float>.allocate(capacity: count)
    floats.initialize(repeating: 7, count: count)
    var vectors = [N3Vector](repeating: N3VectorZero, count: Int(width))
    var normals = [N3Vector](repeating: N3VectorMake(0, 1, 0), count: Int(width))
    let fill = CPRHorizontalFillOperation(volumeData: nil, interpolationMode: 0x5EED, floatBytes: floats,
                                          width: width, height: height, vectors: &vectors, normals: &normals)
    fill.start()
    let left = (0..<count).filter { floats[$0] != 0 }.count
    if left != 0 {
        fail("\(left) of \(count) floats were left as they were after a fill with an unknown interpolation mode")
    }
    print("all \(count) floats cleared")

case "failed-projection":
    let side: UInt = 16, depth: UInt = 4
    let count = Int(side * side * depth)
    let data = UnsafeMutablePointer<Float>.allocate(capacity: count)
    for i in 0..<count { data[i] = Float(i % 97) + 1 }
    let volume = CPRVolumeData(floatBytesNoCopy: data, pixelsWide: side, pixelsHigh: side, pixelsDeep: depth,
                               volumeTransform: N3AffineTransformIdentity, outOfBoundsValue: 0, freeWhenDone: false)
    volume.invalidateData()
    let projection = CPRProjectionOperation()
    projection.volumeData = volume
    projection.projectionMode = CPRProjectionMode(CPRProjectionModeMIP.rawValue)
    projection.start()
    guard let generated = projection.generatedVolume else {
        fail("the projection returned no volume")
    }
    var inlineBuffer = CPRVolumeDataInlineBuffer()
    if !generated.aquireInlineBuffer(&inlineBuffer) {
        fail("the projected volume has no data")
    }
    let plane = CPRVolumeDataFloatBytes(&inlineBuffer)!
    let undefined = (0..<Int(side * side)).filter { plane[$0] != 0 }
    generated.releaseInlineBuffer(&inlineBuffer)
    if let first = undefined.first {
        fail("\(undefined.count) of \(side * side) projected floats are not zero (float \(first) is \(plane[first]), bits 0x\(String(plane[first].bitPattern, radix: 16)))")
    }
    print("the projection of a volume without data is \(side)x\(side) zeros")

case "straightened":
    checkSlabs { slabWidth in
        let request = CPRStraightenedGeneratorRequest()
        request.pixelsWide = stretchedPixelsWide
        request.pixelsHigh = pixelsHigh
        request.slabWidth = slabWidth
        request.slabSampleDistance = 0
        request.interpolationMode = CPRInterpolationMode(CPRInterpolationModeLinear.rawValue)
        request.bezierPath = makePath().bezierPath
        request.initialNormal = N3VectorMake(0, 0, 1)
        return ("straightened", CPRStraightenedOperation(request: request, volumeData: zeroSpacingVolume()))
    }

case "stretched":
    checkSlabs { slabWidth in
        let request = CPRStretchedGeneratorRequest()
        request.pixelsWide = stretchedPixelsWide
        request.pixelsHigh = pixelsHigh
        request.slabWidth = slabWidth
        request.slabSampleDistance = 0
        request.interpolationMode = CPRInterpolationMode(CPRInterpolationModeLinear.rawValue)
        request.bezierPath = makePath().bezierPath
        request.projectionNormal = N3VectorMake(0, 0, 1)
        request.midHeightPoint = N3VectorMake(10, 0, 0)
        return ("stretched", CPRStretchedOperation(request: request, volumeData: zeroSpacingVolume()))
    }

case "oblique":
    checkSlabs { slabWidth in
        let request = CPRObliqueSliceGeneratorRequest(center: N3VectorZero, pixelsWide: stretchedPixelsWide, pixelsHigh: pixelsHigh,
                                                      xBasis: N3VectorMake(1, 0, 0), yBasis: N3VectorMake(0, 1, 0))
        request.slabWidth = slabWidth
        request.slabSampleDistance = 0
        request.interpolationMode = CPRInterpolationMode(CPRInterpolationModeLinear.rawValue)
        return ("oblique", CPRObliqueSliceOperation(request: request, volumeData: zeroSpacingVolume()))
    }

case "transverse-sections":
    let path = makePath()
    path.transverseSectionPosition = 0.5
    path.transverseSectionSpacing = 3
    func variant(_ change: (CPRCurvedPath) -> Void) -> CPRCurvedPath {
        let copy = path.copy() as! CPRCurvedPath
        change(copy)
        return copy
    }
    var problems: [String] = []
    for (name, other) in [("a copy", variant { _ in }), ("the archived path", roundTrip(path)),
                          ("a thicker path", variant { $0.thickness = 9 })]
        where !other.hasSameTransverseSections(as: path) || !path.hasSameTransverseSections(as: other) {
        problems.append("\(name) does not define the same sections")
    }
    for (name, other) in [("a moved node", variant { $0.moveNode(at: 1, to: N3VectorMake(10, 3, 0)) }),
                          ("a moved section", variant { $0.transverseSectionPosition = 0.7 }),
                          ("another spacing", variant { $0.transverseSectionSpacing = 5 }),
                          ("another angle", variant { $0.angle = 0.4 }),
                          ("another base direction", variant { $0.baseDirection = N3VectorMake(1, 0, 1) }),
                          ("an empty path", CPRCurvedPath())]
        where other.hasSameTransverseSections(as: path) || path.hasSameTransverseSections(as: other) {
        problems.append("\(name) defines the same sections")
    }
    if !problems.isEmpty {
        fail(problems.joined(separator: "; "))
    }
    print("copies, archives and thickness keep the sections; nodes, section, spacing and angle change them")

default:
    fail("unknown case \(CommandLine.arguments[1])")
}
exit(0)
'''

CASES = [
    ('archive', 'a decoded curved path keeps its base direction and initial normal'),
    ('mutable', 'a decoded curved path holds a mutable bezier path'),
    ('snapshot', 'CPR undo snapshots and restored paths own independent geometry'),
    ('unknown-fill', 'a fill with an unknown interpolation mode clears every float'),
    ('failed-projection', 'a projection whose volume has no data returns zeros'),
    ('straightened', 'the straightened operation finishes with one plane when no slab sample distance is known'),
    ('stretched', 'the stretched operation finishes with one plane when no slab sample distance is known'),
    ('oblique', 'the oblique slice operation finishes with one plane when no slab sample distance is known'),
    ('transverse-sections', 'curved paths compare by their transverse sections, not by identity'),
]


def run(command, **kwargs):
    return subprocess.run(command, check=True, capture_output=True, **kwargs)


failures = []
with tempfile.TemporaryDirectory(prefix='horos-cpr-archive-fill-') as tmp:
    tmp = Path(tmp)
    for path in HEADERS + [path for path, _ in OBJC_SOURCES] + SWIFT_SOURCES:
        (tmp / Path(path).name).write_bytes(source(path))
    (tmp / 'harness.h').write_text(BRIDGING)
    (tmp / 'DCMPixDouble.m').write_text(DCMPIX_DOUBLE)
    (tmp / 'main.swift').write_text(DRIVER)
    objects = []
    try:
        for path, flags in OBJC_SOURCES + [('DCMPixDouble.m', ['-fno-objc-arc'])]:
            name = Path(path).name
            obj = tmp / (Path(path).stem + '.o')
            # The app's prefix header brings Cocoa into every source.
            run(['xcrun', 'clang', '-x', 'objective-c', '-include', 'Cocoa/Cocoa.h', '-fsanitize=address', '-g',
                 '-iquote', str(tmp), *flags,
                 '-c', str(tmp / name), '-o', str(obj)])
            objects.append(str(obj))
        run(['xcrun', 'swiftc', '-swift-version', '5', '-module-name', 'Horos', '-sanitize=address', '-g', '-Onone',
             '-D', 'DEBUG', '-import-objc-header', str(tmp / 'harness.h'), '-Xcc', '-iquote', '-Xcc', str(tmp),
             *[str(tmp / Path(path).name) for path in SWIFT_SOURCES], str(tmp / 'main.swift'), *objects,
             '-framework', 'Cocoa', '-framework', 'Accelerate', '-framework', 'QuartzCore',
             '-o', str(tmp / 'harness')])
    except subprocess.CalledProcessError as e:
        print('FAIL: the harness did not build:', (e.stderr or b'').decode(errors='replace')[-3000:])
        sys.exit(1)

    # ASan fills fresh allocations with 0xaa, so bytes never written read as such,
    # and returns NULL for an allocation it cannot make, as malloc does.
    env = dict(os.environ, ASAN_OPTIONS='malloc_fill_byte=170:max_malloc_fill_size=1048576:allocator_may_return_null=1:detect_leaks=0')
    for case, claim in CASES:
        try:
            result = subprocess.run([str(tmp / 'harness'), case], capture_output=True, text=True, timeout=60, env=env)
        except subprocess.TimeoutExpired:
            failures.append(f'{claim}: timed out')
            continue
        if result.returncode == 0:
            lines = result.stdout.strip().splitlines()
            print('ok:', claim, '-', lines[-1] if lines else 'exit 0')
            continue
        # The driver's own FAIL line, else the sanitizer's report, else the last line.
        lines = [line for line in (result.stdout + result.stderr).splitlines() if line.strip()]
        detail = next((line[len('FAIL: '):] for line in lines if line.startswith('FAIL:')), None) or \
            next((line for line in lines if 'ERROR: AddressSanitizer' in line), None) or \
            (lines[-1] if lines else f'exit {result.returncode}')
        failures.append(f'{claim}: {detail}')

for failure in failures:
    print('FAIL:', failure)
if failures:
    sys.exit(1)
print('PASS: curved paths keep their base direction and mutable path through an archive; '
      'fills and projections return defined output')
