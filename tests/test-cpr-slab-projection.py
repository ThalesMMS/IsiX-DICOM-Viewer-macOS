#!/usr/bin/env python3
"""The curved and oblique CPR project a thick slab in a memory that no longer
grows with its depth, and with the bits of the whole-slab projection.

CPRStraightenedOperation, CPRStretchedOperation and CPRObliqueSliceOperation
sampled every plane of the slab into one volume (pixelsWide x pixelsHigh x
slabWidth / sample distance + 1 floats, plus a copy of the row vectors for
every fill) and only then projected it. With the slab slider reaching the
whole volume, one request asked for gigabytes. They now sample a window of
planes and fold each plane into the projection as soon as it is sampled.

The CPR classes are compiled as they are (CPRCurvedPath, the generator
requests and operations, the fill and projection operations, CPRVolumeData
and its C samplers, with Nitrogen's N3 geometry and HorosObjCException), in
Swift 6 like the app, with a double for DCMPix, and driven as the app drives
them. The whole-slab algorithm the operations had before is frozen below
(WholeSlab), the reference, with the planes the slab is sampled by
now (those that cover its whole width):
- same-straightened, same-stretched, same-oblique: under AddressSanitizer,
  each operation gives the volume of the whole-slab algorithm, bit for bit
  (every float, the transform, the size), for MIP, MinIP, mean, VR and an
  unknown mode (the first plane) and none (the slab itself), for slabs of
  1 to 430 planes, more than a window holds, with planes whose size is not a
  multiple of four floats, and with nearest, linear and cubic sampling;
- projection: CPRProjectionOperation, which folds with the same code, still
  projects a whole volume as it did;
- cancel: a deep projection cancelled while it samples, or before it starts,
  finishes promptly without a volume;
- memory: in a Release-like build without the sanitizer, one process per
  slab, the peak memory footprint a straightened MIP adds stays flat from
  100 to 1000 mm (144 to 1430 planes) and below a tenth of the slab, while
  the whole-slab algorithm's grows with it (which shows that the measure sees
  the allocations). The times are printed.

`<git revision>` as an optional argument reads the sources from that
revision, the negative control: the operations before the change give the
same bits, and their memory grows with the slab.
"""
from pathlib import Path
import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import former_sdk_objects  # noqa: E402
import n3_geometry_harness  # noqa: E402
import isix_modules  # noqa: E402

SKIPPED = 2
root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('revision', nargs='?')
parser.add_argument('--keep', type=Path, help='build in this folder and keep it')
arguments = parser.parse_args()
revision = arguments.revision


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
    'Horos/Sources/IdentityToken.swift',
]
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
OBJC_SOURCES = [
    ('Horos/Sources/HorosObjCException.m', ['-fobjc-exceptions']),
    ('Horos/Sources/CPRVolumeData+CAPI.m', ['-DHOROS_BRIDGING_HEADER=1']),
]
N3_OBJC = [(path, ['-fno-objc-arc']) for path in ('Nitrogen/Sources/N3Geometry.m', 'Nitrogen/Sources/N3BezierCore.m',
                                                  'Nitrogen/Sources/N3BezierCoreAdditions.m', 'Nitrogen/Sources/N3BezierPath.m')]
if subprocess.run(['git', '-C', str(root), 'cat-file', '-e', f'{revision or "HEAD"}:Nitrogen/Sources/N3Geometry.m'],
                  capture_output=True).returncode == 0 and (revision or (root / 'Nitrogen/Sources/N3Geometry.m').exists()):
    OBJC_SOURCES = N3_OBJC + OBJC_SOURCES
    N3_LIBRARIES = None
else:
    N3_LIBRARIES = 'n3'

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

// The process's physical footprint in bytes, now or at its peak.
uint64_t HarnessFootprint(int peak);
'''

HARNESS_M = r'''
#import "harness.h"
#include <mach/mach.h>

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

uint64_t HarnessFootprint(int peak)
{
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) != KERN_SUCCESS)
        return 0;
    return peak ? info.ledger_phys_footprint_peak : info.phys_footprint;
}
'''

DRIVER = r'''
import Cocoa
import Accelerate

func fail(_ message: String) -> Never {
    print("FAIL: \(message)")
    exit(1)
}

/// Runs `operation` on a queue of its own and waits for it, at most `seconds`.
func runOperation(_ operation: Operation, seconds: Double = 300) -> Bool {
    let queue = OperationQueue()
    queue.addOperation(operation)
    let deadline = Date(timeIntervalSinceNow: seconds)
    while !operation.isFinished && Date() < deadline {
        usleep(200)
    }
    return operation.isFinished
}

let none = CPRProjectionMode(CPRProjectionModeNone.rawValue)
let vr = CPRProjectionMode(CPRProjectionModeVR.rawValue)
let mip = CPRProjectionMode(CPRProjectionModeMIP.rawValue)
let minIP = CPRProjectionMode(CPRProjectionModeMinIP.rawValue)
let mean = CPRProjectionMode(CPRProjectionModeMean.rawValue)
let linear = CPRInterpolationMode(CPRInterpolationModeLinear.rawValue)
let nearest = CPRInterpolationMode(CPRInterpolationModeNearestNeighbor.rawValue)
let cubic = CPRInterpolationMode(CPRInterpolationModeCubic.rawValue)

func modeName(_ mode: CPRProjectionMode) -> String {
    switch mode {
    case none: return "none"
    case vr: return "VR"
    case mip: return "MIP"
    case minIP: return "MinIP"
    case mean: return "mean"
    default: return "mode \(mode)"
    }
}

/// A 64x64x48 volume of 0.7 x 0.7 x 1 mm voxels: a smooth pattern, a vessel
/// that wanders through it and noise, so that the maximum, the minimum and the
/// mean of a slab depend on every plane.
func makeVolume() -> CPRVolumeData {
    let (w, h, d) = (64, 64, 48)
    let data = UnsafeMutablePointer<Float>.allocate(capacity: w * h * d)
    var state: UInt64 = 0x2545F4914F6CDD1D
    for z in 0..<d {
        for y in 0..<h {
            for x in 0..<w {
                state = state &* 6364136223846793005 &+ 1442695040888963407
                let noise = Float(state >> 40) / Float(1 << 24)
                let cx = 32 + 8 * sin(Double(z) / 6), cy = 30 + 6 * cos(Double(z) / 8)
                let vessel: Float = hypot(Double(x) - cx, Double(y) - cy) < 4 ? 450 : 0
                data[(z * h + y) * w + x] = Float(-300 + 80 * sin(Double(x) / 5) * cos(Double(y + z) / 9)) + vessel + 150 * noise
            }
        }
    }
    return CPRVolumeData(floatBytesNoCopy: data, pixelsWide: UInt(w), pixelsHigh: UInt(h), pixelsDeep: UInt(d),
                         volumeTransform: N3AffineTransformMakeScale(1 / 0.7, 1 / 0.7, 1), outOfBoundsValue: -1024, freeWhenDone: true)
}

func makePath() -> CPRCurvedPath {
    let path = CPRCurvedPath()
    for (x, y, z) in [(4.0, 6.0, 5.0), (18.0, 22.0, 14.0), (30.0, 26.0, 26.0), (40.0, 38.0, 41.0)] {
        path.addPatientNode(N3VectorMake(x, y, z))
    }
    // The base direction the window gives a path; without it the stretched
    // projection normal is zero.
    path.baseDirection = N3VectorMake(0, 1, 1)
    path.angle = 0.3
    return path
}

enum Kind: String {
    case straightened, stretched, oblique
}

func makeRequest(_ kind: Kind, path: CPRCurvedPath, slabWidth: CGFloat, sampleDistance: CGFloat, mode: CPRProjectionMode,
                 interpolation: CPRInterpolationMode, size: (Int, Int)? = nil) -> CPRGeneratorRequest {
    switch kind {
    case .straightened:
        let request = CPRStraightenedGeneratorRequest()
        let (w, h) = size ?? (181, 63)
        request.pixelsWide = UInt(w)
        request.pixelsHigh = UInt(h)
        request.bezierPath = path.bezierPath
        request.initialNormal = path.initialNormal
        request.projectionMode = mode
        request.slabWidth = slabWidth
        request.slabSampleDistance = sampleDistance
        request.interpolationMode = interpolation
        return request
    case .stretched:
        let request = CPRStretchedGeneratorRequest()
        let (w, h) = size ?? (180, 64)
        request.pixelsWide = UInt(w)
        request.pixelsHigh = UInt(h)
        request.bezierPath = path.bezierPath
        request.projectionNormal = path.stretchedProjectionNormal()
        request.midHeightPoint = N3VectorMake(22, 22, 22)
        request.projectionMode = mode
        request.slabWidth = slabWidth
        request.slabSampleDistance = sampleDistance
        request.interpolationMode = interpolation
        return request
    case .oblique:
        let (w, h) = size ?? (97, 81)
        let request = CPRObliqueSliceGeneratorRequest(center: N3VectorMake(22, 22, 24), pixelsWide: UInt(w), pixelsHigh: UInt(h),
                                                      xBasis: N3VectorMake(0.35, 0.05, 0), yBasis: N3VectorMake(-0.05, 0.3, 0.12))
        request.projectionMode = mode
        request.slabWidth = slabWidth
        request.slabSampleDistance = sampleDistance
        request.interpolationMode = interpolation
        return request
    }
}

func makeOperation(_ kind: Kind, _ request: CPRGeneratorRequest, _ volume: CPRVolumeData) -> CPRGeneratorOperation {
    switch kind {
    case .straightened: return CPRStraightenedOperation(request: request, volumeData: volume)
    case .stretched: return CPRStretchedOperation(request: request, volumeData: volume)
    case .oblique: return CPRObliqueSliceOperation(request: request, volumeData: volume)
    }
}

/// The whole-slab algorithm the three operations had before they projected a
/// slab while sampling it, frozen here (the app no longer has it): the depth
/// of the slab, every plane sampled into one volume by
/// CPRHorizontalFillOperations queued all at once, and CPRProjectionOperation's
/// loop over that volume.
enum WholeSlab {
    static let fillHeight = 40

    /// The planes of the slab and the distance between them: the request's
    /// own distance, or the volume's finest spacing or less, what divides the
    /// slab's width evenly, so that the planes cover the whole width.
    static func planes(_ request: CPRGeneratorRequest, _ volume: CPRVolumeData) -> (count: Int, distance: CGFloat) {
        if request.slabSampleDistance != 0 {
            let slabs = request.slabWidth / request.slabSampleDistance
            guard slabs.isFinite else { return (1, request.slabSampleDistance) }
            return (Int((slabs < 0 ? 0 : slabs) + 1), request.slabSampleDistance)
        }
        let spacing = volume.minPixelSpacing
        guard request.slabWidth > 0, spacing > 0 else { return (1, spacing) }
        let steps = max(1, (Double(request.slabWidth / spacing) - 1e-9).rounded(.up))
        return (Int(steps) + 1, request.slabWidth / CGFloat(steps))
    }

    static func sampleDistance(_ request: CPRGeneratorRequest, _ volume: CPRVolumeData) -> CGFloat {
        planes(request, volume).distance
    }

    static func depth(_ request: CPRGeneratorRequest, _ volume: CPRVolumeData) -> Int {
        planes(request, volume).count
    }

    /// Every plane, `fillHeight` rows per fill: `rows(y, z)` is the first row
    /// of the fill at row y of plane z, `step` the step to each next row.
    static func sample(_ volume: CPRVolumeData, _ interpolation: CPRInterpolationMode, width: Int, height: Int, depth: Int,
                       step: [N3Vector], rows: (Int, Int) -> [N3Vector]) -> UnsafeMutablePointer<Float> {
        let floats = malloc(MemoryLayout<Float>.size * width * height * depth)!.assumingMemoryBound(to: Float.self)
        var step = step
        var fills: [Operation] = []
        for z in 0..<depth {
            var y = 0
            while y < height {
                var vectors = rows(y, z)
                fills.append(CPRHorizontalFillOperation(volumeData: volume, interpolationMode: interpolation,
                                                        floatBytes: floats + y * width + z * width * height,
                                                        width: UInt(width), height: UInt(min(fillHeight, height - y)),
                                                        vectors: &vectors, normals: &step))
                y += fillHeight
            }
        }
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = ProcessInfo.processInfo.processorCount
        queue.addOperations(fills, waitUntilFinished: true)
        return floats
    }

    /// CPRProjectionOperation's projection of the whole slab, as it was.
    static func project(_ planes: UnsafeMutablePointer<Float>, width: Int, height: Int, depth: Int, mode: CPRProjectionMode,
                        transform: N3AffineTransform, outOfBounds: Float) -> CPRVolumeData {
        if mode == none {
            return CPRVolumeData(floatBytesNoCopy: planes, pixelsWide: UInt(width), pixelsHigh: UInt(height), pixelsDeep: UInt(depth),
                                 volumeTransform: transform, outOfBoundsValue: outOfBounds, freeWhenDone: true)
        }
        let perPlane = width * height
        let floatBytes = malloc(MemoryLayout<Float>.size * perPlane)!.assumingMemoryBound(to: Float.self)
        memcpy(floatBytes, planes, MemoryLayout<Float>.size * perPlane)
        let count = vDSP_Length(perPlane)
        switch mode {
        case mip:
            for i in 1..<max(depth, 1) {
                vDSP_vmax(floatBytes, 1, planes + i * perPlane, 1, floatBytes, 1, count)
            }
        case minIP:
            for i in 1..<max(depth, 1) {
                vDSP_vmin(floatBytes, 1, planes + i * perPlane, 1, floatBytes, 1, count)
            }
        case mean:
            for i in 1..<max(depth, 1) {
                var floati = Float(i)
                vDSP_vavlin(planes + i * perPlane, 1, &floati, floatBytes, 1, count)
            }
        default:
            break
        }
        free(planes)
        return CPRVolumeData(floatBytesNoCopy: floatBytes, pixelsWide: UInt(width), pixelsHigh: UInt(height), pixelsDeep: 1,
                             volumeTransform: N3AffineTransformConcat(transform, N3AffineTransformMakeScale(1.0, 1.0, 1.0 / CGFloat(depth))),
                             outOfBoundsValue: outOfBounds, freeWhenDone: true)
    }

    /// The vectors of a curve sampled `count` times, the last one repeated to
    /// the end of the arrays, or zeros when there is none.
    static func pad(_ vectors: inout [N3Vector], _ tangents: inout [N3Vector], _ normals: inout [N3Vector], count: Int) {
        guard count > 0 else {
            return
        }
        for i in count..<vectors.count {
            vectors[i] = vectors[i - 1]
            tangents[i] = tangents[i - 1]
            normals[i] = normals[i - 1]
        }
    }

    /// The straightened sampling along the curve, the stretched one's too.
    static func curve(_ request: CPRGeneratorRequest, _ volume: CPRVolumeData, mode: CPRProjectionMode, vectors: [N3Vector],
                      tangents: [N3Vector], normals: [N3Vector], sampleSpacing: CGFloat) -> CPRVolumeData {
        let width = Int(request.pixelsWide), height = Int(request.pixelsHigh)
        let distance = sampleDistance(request, volume), depth = depth(request, volume)
        var tangents = tangents
        var fillNormals = normals
        N3VectorScalarMultiplyVectors(sampleSpacing, &fillNormals, width)
        var inSlabNormals = normals
        N3VectorCrossProductWithVectors(&inSlabNormals, &tangents, width)
        N3VectorScalarMultiplyVectors(distance, &inSlabNormals, width)
        let planes = sample(volume, request.interpolationMode, width: width, height: height, depth: depth, step: fillNormals) { y, z in
            let fillDistance = CGFloat(y) - CGFloat(height - 1) / 2.0
            let slabDistance = CGFloat(z) - CGFloat(depth - 1) / 2.0
            return (0..<width).map {
                N3VectorAdd(N3VectorAdd(vectors[$0], N3VectorScalarMultiply(fillNormals[$0], fillDistance)), N3VectorScalarMultiply(inSlabNormals[$0], slabDistance))
            }
        }
        return project(planes, width: width, height: height, depth: depth, mode: mode,
                       transform: N3AffineTransformMakeScale(1.0 / sampleSpacing, 1.0 / sampleSpacing, 1.0 / distance), outOfBounds: volume.outOfBoundsValue)
    }

    static func straightened(_ request: CPRStraightenedGeneratorRequest, _ volume: CPRVolumeData) -> CPRVolumeData {
        let flattened = N3BezierCoreCreateMutableCopy(request.bezierPath?.n3BezierCore())
        N3BezierCoreSubdivide(flattened, 3.0)
        N3BezierCoreFlatten(flattened, 0.6)
        let width = Int(request.pixelsWide)
        let sampleSpacing = N3BezierCoreLength(flattened) / CGFloat(width)
        var vectors = [N3Vector](repeating: N3VectorZero, count: width), tangents = vectors, normals = vectors
        let count = N3BezierCoreGetVectorInfo(flattened, sampleSpacing, 0, request.initialNormal, &vectors, &tangents, &normals, width)
        N3BezierCoreRelease(flattened)
        pad(&vectors, &tangents, &normals, count: count)
        return curve(request, volume, mode: request.projectionMode, vectors: vectors, tangents: tangents, normals: normals, sampleSpacing: sampleSpacing)
    }

    static func stretched(_ request: CPRStretchedGeneratorRequest, _ volume: CPRVolumeData) -> CPRVolumeData {
        let flattened = N3BezierCoreCreateMutableCopy(request.bezierPath?.n3BezierCore())
        N3BezierCoreSubdivide(flattened, 3.0)
        N3BezierCoreFlatten(flattened, 0.6)
        let width = Int(request.pixelsWide)
        let projectionNormal = request.projectionNormal
        let projected = N3BezierCoreCreateMutableCopyProjectedToPlane(flattened, N3PlaneMake(N3VectorZero, projectionNormal))
        let sampleSpacing = N3BezierCoreLength(projected) / CGFloat(width)
        N3BezierCoreRelease(projected)
        var vectors = [N3Vector](repeating: N3VectorZero, count: width), tangents = vectors, normals = vectors
        let count = N3BezierCoreGetProjectedVectorInfo(flattened, sampleSpacing, 0, projectionNormal, &vectors, &tangents, &normals, nil, width)
        N3BezierCoreRelease(flattened)
        pad(&vectors, &tangents, &normals, count: count)
        // Every column: the padding filled them all, with zeros when there was no vector.
        for i in 0..<width {
            vectors[i] = N3LineIntersectionWithPlane(N3LineMake(vectors[i], projectionNormal), N3PlaneMake(request.midHeightPoint, projectionNormal))
            tangents[i] = N3VectorNormalize(N3VectorCrossProduct(normals[i], projectionNormal))
            normals[i] = N3VectorNormalize(projectionNormal)
        }
        return curve(request, volume, mode: request.projectionMode, vectors: vectors, tangents: tangents, normals: normals, sampleSpacing: sampleSpacing)
    }

    static func oblique(_ request: CPRObliqueSliceGeneratorRequest, _ volume: CPRVolumeData) -> CPRVolumeData {
        let width = Int(request.pixelsWide), height = Int(request.pixelsHigh)
        let distance = sampleDistance(request, volume), depth = depth(request, volume)
        let leftDirection = N3VectorScalarMultiply(N3VectorNormalize(request.directionX), request.pixelSpacingX)
        let downDirection = N3VectorScalarMultiply(N3VectorNormalize(request.directionY), request.pixelSpacingY)
        let inSlabNormal = N3VectorScalarMultiply(N3VectorNormalize(N3VectorCrossProduct(leftDirection, downDirection)), distance)
        let vectors = (0..<width).map { N3VectorAdd(request.origin, N3VectorScalarMultiply(leftDirection, CGFloat($0))) }
        let planes = sample(volume, request.interpolationMode, width: width, height: height, depth: depth,
                            step: [N3Vector](repeating: downDirection, count: width)) { y, z in
            let slabOffset = N3VectorScalarMultiply(inSlabNormal, CGFloat(z) - CGFloat(depth - 1) / 2.0)
            let heightOffset = N3VectorScalarMultiply(downDirection, CGFloat(y))
            return vectors.map { N3VectorAdd(N3VectorAdd($0, heightOffset), slabOffset) }
        }
        let volumeOrigin = N3VectorAdd(request.origin, N3VectorScalarMultiply(inSlabNormal, CGFloat(UInt(depth) &- 1) / -2.0))
        var transform = N3AffineTransformIdentity
        transform.m41 = volumeOrigin.x
        transform.m42 = volumeOrigin.y
        transform.m43 = volumeOrigin.z
        transform.m11 = leftDirection.x
        transform.m12 = leftDirection.y
        transform.m13 = leftDirection.z
        transform.m21 = downDirection.x
        transform.m22 = downDirection.y
        transform.m23 = downDirection.z
        transform.m31 = inSlabNormal.x
        transform.m32 = inSlabNormal.y
        transform.m33 = inSlabNormal.z
        return project(planes, width: width, height: height, depth: depth, mode: request.projectionMode,
                       transform: N3AffineTransformInvert(transform), outOfBounds: volume.outOfBoundsValue)
    }

    static func volume(_ kind: Kind, _ request: CPRGeneratorRequest, _ volume: CPRVolumeData) -> CPRVolumeData {
        switch kind {
        case .straightened: return straightened(request as! CPRStraightenedGeneratorRequest, volume)
        case .stretched: return stretched(request as! CPRStretchedGeneratorRequest, volume)
        case .oblique: return oblique(request as! CPRObliqueSliceGeneratorRequest, volume)
        }
    }
}

/// Nil when `volume` has the size, the transform and every float of
/// `expected` bit for bit; else what differs.
func difference(_ volume: CPRVolumeData, _ expected: CPRVolumeData) -> String? {
    if volume.pixelsWide != expected.pixelsWide || volume.pixelsHigh != expected.pixelsHigh || volume.pixelsDeep != expected.pixelsDeep {
        return "\(volume.pixelsWide)x\(volume.pixelsHigh)x\(volume.pixelsDeep), not \(expected.pixelsWide)x\(expected.pixelsHigh)x\(expected.pixelsDeep)"
    }
    if volume.outOfBoundsValue.bitPattern != expected.outOfBoundsValue.bitPattern {
        return "out of bounds value \(volume.outOfBoundsValue), not \(expected.outOfBoundsValue)"
    }
    var transform = volume.volumeTransform, expectedTransform = expected.volumeTransform
    if memcmp(&transform, &expectedTransform, MemoryLayout<N3AffineTransform>.size) != 0 {
        return "the transform differs"
    }
    var buffer = CPRVolumeDataInlineBuffer(), expectedBuffer = CPRVolumeDataInlineBuffer()
    defer {
        volume.releaseInlineBuffer(&buffer)
        expected.releaseInlineBuffer(&expectedBuffer)
    }
    guard volume.aquireInlineBuffer(&buffer), expected.aquireInlineBuffer(&expectedBuffer) else {
        return "a volume has no data"
    }
    let floats = CPRVolumeDataFloatBytes(&buffer)!, expectedFloats = CPRVolumeDataFloatBytes(&expectedBuffer)!
    let count = Int(volume.pixelsWide * volume.pixelsHigh * volume.pixelsDeep)
    var differing = 0, first = -1, largest: Float = 0
    for i in 0..<count where floats[i].bitPattern != expectedFloats[i].bitPattern {
        differing += 1
        if first < 0 {
            first = i
        }
        largest = max(largest, abs(floats[i] - expectedFloats[i]))
    }
    if differing > 0 {
        return "\(differing) of \(count) floats differ, the first at \(first) (\(floats[first]) for \(expectedFloats[first])), by \(largest) at most"
    }
    return nil
}

/// Each operation of `kind` against the whole-slab algorithm.
func same(_ kind: Kind) {
    let volume = makeVolume()
    let path = makePath()
    // (slab width in mm, sample distance in mm, 0 for the volume's 0.7 mm):
    // 1, 4, 16, 144 (the former 100 mm thick end), 273 and 430 planes.
    let slabs: [(CGFloat, CGFloat)] = [(0, 0), (2.1, 0), (10, 0), (100, 0), (30, 0.11), (300, 0)]
    let modes = [mip, minIP, mean, vr, CPRProjectionMode(7), none]
    var cases: [(CGFloat, CGFloat, CPRInterpolationMode)] = slabs.map { ($0.0, $0.1, linear) }
    cases += [(10, 0, nearest), (30, 0.11, nearest), (10, 0, cubic), (30, 0.11, cubic)]
    var problems: [String] = []
    var compared = 0, deepest = 0
    for (slabWidth, sampleDistance, interpolation) in cases {
        for mode in modes {
            let request = makeRequest(kind, path: path, slabWidth: slabWidth, sampleDistance: sampleDistance, mode: mode, interpolation: interpolation)
            let operation = makeOperation(kind, request, volume)
            let name = "\(kind.rawValue) \(modeName(mode)), \(slabWidth) mm slab every \(sampleDistance) mm, interpolation \(interpolation)"
            if !runOperation(operation) {
                problems.append("\(name): the operation never finished")
                continue
            }
            if operation.didFail {
                problems.append("\(name): the operation failed")
                continue
            }
            guard let generated = operation.generatedVolume else {
                problems.append("\(name): no volume")
                continue
            }
            let expected = WholeSlab.volume(kind, request, volume)
            deepest = max(deepest, WholeSlab.depth(request, volume))
            if let problem = difference(generated, expected) {
                problems.append("\(name): \(problem)")
            }
            compared += 1
        }
    }
    if !problems.isEmpty {
        fail(problems.prefix(6).joined(separator: "; ") + (problems.count > 6 ? "; and \(problems.count - 6) more" : ""))
    }
    print("\(compared) \(kind.rawValue) volumes bit-identical to the whole-slab projection, slabs of up to \(deepest) planes")
}

/// CPRProjectionOperation against the frozen loop, on volumes whose planes
/// are not a multiple of four floats.
func projection() {
    var state: UInt64 = 0x51ED27
    var compared = 0
    for (w, h, d) in [(7, 5, 1), (13, 11, 9), (33, 17, 61)] {
        for mode in [mip, minIP, mean, vr, CPRProjectionMode(7)] {
            let count = w * h * d
            func data() -> UnsafeMutablePointer<Float> {
                let data = UnsafeMutablePointer<Float>.allocate(capacity: count)
                for i in 0..<count {
                    state = state &* 6364136223846793005 &+ 1
                    data[i] = Float(Int(state >> 44) - 500_000) / 37
                }
                return data
            }
            let values = data()
            let copy = malloc(MemoryLayout<Float>.size * count)!.assumingMemoryBound(to: Float.self)
            memcpy(copy, values, MemoryLayout<Float>.size * count)
            let transform = N3AffineTransformMakeScale(2, 3, 0.5)
            let operation = CPRProjectionOperation()
            operation.volumeData = CPRVolumeData(floatBytesNoCopy: values, pixelsWide: UInt(w), pixelsHigh: UInt(h), pixelsDeep: UInt(d),
                                                 volumeTransform: transform, outOfBoundsValue: -7, freeWhenDone: true)
            operation.projectionMode = mode
            operation.start()
            guard let generated = operation.generatedVolume else {
                fail("CPRProjectionOperation \(modeName(mode)) of \(w)x\(h)x\(d) gave no volume")
            }
            let expected = WholeSlab.project(copy, width: w, height: h, depth: d, mode: mode, transform: transform, outOfBounds: -7)
            if let problem = difference(generated, expected) {
                fail("CPRProjectionOperation \(modeName(mode)) of \(w)x\(h)x\(d): \(problem)")
            }
            compared += 1
        }
    }
    print("\(compared) projections of whole volumes as before")
}

func cancel() {
    let volume = makeVolume()
    let path = makePath()
    for kind in [Kind.straightened, .stretched, .oblique] {
        // 1429 planes: seconds of sampling, cancelled after a few planes.
        let request = makeRequest(kind, path: path, slabWidth: 1000, sampleDistance: 0, mode: mip, interpolation: cubic, size: (200, 160))
        let operation = makeOperation(kind, request, volume)
        let queue = OperationQueue()
        queue.addOperation(operation)
        let started = Date()
        while !operation.isExecuting && !operation.isFinished && Date().timeIntervalSince(started) < 10 {
            usleep(200)
        }
        usleep(30_000)
        let cancelled = Date()
        operation.cancel()
        while !operation.isFinished && Date().timeIntervalSince(cancelled) < 10 {
            usleep(200)
        }
        if !operation.isFinished {
            fail("\(kind.rawValue): a cancelled projection did not finish within 10 s")
        }
        let seconds = Date().timeIntervalSince(cancelled)
        if seconds > 2 {
            fail("\(kind.rawValue): a cancelled projection took \(seconds) s to finish")
        }
        if operation.generatedVolume != nil {
            fail("\(kind.rawValue): a cancelled projection gave a volume")
        }
        let early = makeOperation(kind, request, volume)
        early.cancel()
        if !runOperation(early, seconds: 10) || early.generatedVolume != nil {
            fail("\(kind.rawValue): an operation cancelled before it started did not finish without a volume")
        }
    }
    print("cancelled projections finish without a volume")
}

/// One straightened MIP (`whole`: the whole-slab algorithm) of `slabWidth` mm:
/// the bytes it adds to the peak footprint, its planes and its seconds.
func memory(whole: Bool, slabWidth: CGFloat) {
    let volume = makeVolume()
    let path = makePath()
    let request = makeRequest(.straightened, path: path, slabWidth: slabWidth, sampleDistance: 0, mode: mip, interpolation: linear,
                              size: (200, 160)) as! CPRStraightenedGeneratorRequest
    let planes = WholeSlab.depth(request, volume)
    let before = HarnessFootprint(0)
    let start = Date()
    let generated: CPRVolumeData?
    if whole {
        generated = WholeSlab.straightened(request, volume)
    } else {
        let operation = CPRStraightenedOperation(request: request, volumeData: volume)
        if !runOperation(operation) {
            fail("the operation never finished")
        }
        generated = operation.generatedVolume
    }
    let seconds = Date().timeIntervalSince(start)
    let peak = HarnessFootprint(1)
    if generated == nil {
        fail("no volume")
    }
    print("growth \(peak > before ? peak - before : 0) planes \(planes) plane-bytes \(200 * 160 * 4) seconds \(seconds)")
}

let arguments = CommandLine.arguments
switch arguments[1] {
case "same":
    same(Kind(rawValue: arguments[2])!)
case "projection":
    projection()
case "cancel":
    cancel()
case "memory":
    memory(whole: arguments[2] == "whole", slabWidth: CGFloat(Double(arguments[3])!))
default:
    fail("unknown case \(arguments[1])")
}
exit(0)
'''

CHECKED_CASES = [
    (['same', 'straightened'], 'the straightened operation projects as the whole slab did'),
    (['same', 'stretched'], 'the stretched operation projects as the whole slab did'),
    (['same', 'oblique'], 'the oblique slice operation projects as the whole slab did'),
    (['projection'], 'CPRProjectionOperation projects a whole volume as it did'),
    (['cancel'], 'a cancelled projection finishes promptly without a volume'),
]
# Slab widths in mm at the volume's 0.7 mm: 143 (the former thick end),
# 715 and 1429 planes.
MEMORY_SLABS = ['100', '500', '1000']


def run(command, **kwargs):
    return subprocess.run(command, check=True, capture_output=True, **kwargs)


def build(folder, checked):
    """The harness: `checked` with AddressSanitizer and Swift -Onone, else -O
    without the sanitizer, for the memory and the times."""
    folder.mkdir(parents=True, exist_ok=True)
    for path in HEADERS + [path for path, _ in OBJC_SOURCES] + SWIFT_SOURCES:
        (folder / Path(path).name).write_bytes(source(path))
    (folder / 'harness.h').write_text(BRIDGING)
    (folder / 'Harness.m').write_text(HARNESS_M)
    (folder / 'main.swift').write_text(DRIVER)
    sanitizer = ['-fsanitize=address'] if checked else []
    objects = []
    if N3_LIBRARIES:
        n3_geometry_harness.build(folder / N3_LIBRARIES, 'debug' if checked else 'release', headers=folder)
        objects += n3_geometry_harness.libraries(folder / N3_LIBRARIES)
        # The constants CPRCurvedPath.h declares extern, which the slice reads.
        objects.append(former_sdk_objects.app(folder / N3_LIBRARIES))
    for path, flags in OBJC_SOURCES + [('Harness.m', ['-fno-objc-arc'])]:
        name = Path(path).name
        obj = folder / (Path(path).stem + '.o')
        # The C samplers are -O3 in the app; the rest is -O0 when checked.
        optimization = ['-O3'] if name == 'CPRVolumeData+CAPI.m' or not checked else []
        run(['xcrun', 'clang', '-x', 'objective-c', *n3_geometry_harness.TARGET, '-include', 'Cocoa/Cocoa.h', *sanitizer, '-g',
             '-iquote', str(folder), *flags, *optimization, '-c', str(folder / name), '-o', str(obj)])
        objects.append(str(obj))
    swift = ['-Onone', '-D', 'DEBUG', '-sanitize=address'] if checked else ['-O']
    run(['xcrun', 'swiftc', *n3_geometry_harness.TARGET, '-swift-version', '6', '-module-name', 'Horos', '-g', *swift,
         '-import-objc-header', str(folder / 'harness.h'), '-Xcc', '-iquote', '-Xcc', str(folder),
         *[str(folder / Path(path).name) for path in SWIFT_SOURCES], str(folder / 'main.swift'), *objects,
         *isix_modules.module_flags('IsiXImaging', folder / 'modules', n3_geometry_harness.TARGET),
         '-framework', 'Cocoa', '-framework', 'Accelerate', '-framework', 'QuartzCore',
         '-o', str(folder / 'harness')])
    return folder / 'harness'


def outcome(result):
    """The driver's FAIL line, else the sanitizer's report, else the last line."""
    lines = [line for line in (result.stdout + result.stderr).splitlines() if line.strip()]
    return next((line[len('FAIL: '):] for line in lines if line.startswith('FAIL:')), None) or \
        next((line for line in lines if 'ERROR: AddressSanitizer' in line), None) or \
        (lines[-1] if lines else f'exit {result.returncode}')


failures = []
with tempfile.TemporaryDirectory(prefix='horos-cpr-slab-projection-') as tmp:
    tmp = arguments.keep or Path(tmp)
    try:
        checked = build(tmp / 'checked', checked=True)
        measured = build(tmp / 'measured', checked=False)
    except subprocess.CalledProcessError as e:
        print('FAIL: the harness did not build:', (e.stderr or b'').decode(errors='replace')[-3000:])
        sys.exit(1)

    # ASan fills fresh allocations with 0xaa, so floats never written differ.
    env = dict(os.environ, ASAN_OPTIONS='malloc_fill_byte=170:max_malloc_fill_size=1048576:allocator_may_return_null=1:detect_leaks=0')
    for case, claim in CHECKED_CASES:
        try:
            result = subprocess.run([str(checked), *case], capture_output=True, text=True, timeout=600, env=env)
        except subprocess.TimeoutExpired:
            failures.append(f'{claim}: timed out')
            continue
        if result.returncode == 0:
            lines = result.stdout.strip().splitlines()
            print('ok:', claim, '-', lines[-1] if lines else 'exit 0')
        else:
            failures.append(f'{claim}: {outcome(result)}')

    measures = {}
    for algorithm in ('streamed', 'whole'):
        for slab in MEMORY_SLABS if algorithm == 'streamed' else (MEMORY_SLABS[0], MEMORY_SLABS[-1]):
            try:
                result = subprocess.run([str(measured), 'memory', algorithm, slab], capture_output=True, text=True, timeout=600)
            except subprocess.TimeoutExpired:
                failures.append(f'the {algorithm} {slab} mm projection timed out')
                continue
            match = re.search(r'growth (\d+) planes (\d+) plane-bytes (\d+) seconds ([0-9.e-]+)', result.stdout)
            if result.returncode or not match:
                failures.append(f'the {algorithm} {slab} mm projection: {outcome(result)}')
                continue
            growth, planes, plane_bytes, seconds = int(match[1]), int(match[2]), int(match[3]), float(match[4])
            measures[algorithm, slab] = (growth, planes, plane_bytes)
            print(f'measured: {algorithm} straightened MIP, {slab} mm ({planes} planes of {plane_bytes // 1024} KiB, '
                  f'{planes * plane_bytes / 2**20:.0f} MiB of slab): peak footprint +{growth / 2**20:.1f} MiB, {seconds:.2f} s')

    if len(measures) == len(MEMORY_SLABS) + 2:
        thin, thick = MEMORY_SLABS[0], MEMORY_SLABS[-1]
        growth, planes, plane_bytes = measures['streamed', thick]
        slab_bytes = planes * plane_bytes
        whole_growth = measures['whole', thick][0]
        if whole_growth < 0.8 * slab_bytes:
            failures.append(f'the measure does not see the whole slab: {whole_growth / 2**20:.1f} MiB for a slab of '
                            f'{slab_bytes / 2**20:.1f} MiB')
        elif growth > 0.1 * slab_bytes:
            failures.append(f'a {thick} mm projection adds {growth / 2**20:.1f} MiB, more than a tenth of its '
                            f'{slab_bytes / 2**20:.1f} MiB slab')
        elif growth > measures['streamed', thin][0] + 8 * 2**20:
            failures.append(f'the memory grows with the slab: +{measures["streamed", thin][0] / 2**20:.1f} MiB at {thin} mm, '
                            f'+{growth / 2**20:.1f} MiB at {thick} mm')
        else:
            print(f'ok: the memory of a projection does not grow with the slab - +{measures["streamed", thin][0] / 2**20:.1f} MiB '
                  f'at {thin} mm, +{growth / 2**20:.1f} MiB at {thick} mm, where the whole slab took +{whole_growth / 2**20:.1f} MiB')

for failure in failures:
    print('FAIL:', failure)
if failures:
    sys.exit(1)
print('PASS: the CPR operations project a slab of any depth in bounded memory, with the bits of the whole-slab projection')
