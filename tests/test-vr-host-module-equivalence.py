#!/usr/bin/env python3
"""The 3D view's Metal snapshot arithmetic, now in IsiXVolumeRendering, gives the
bytes the Objective-C++ host gave.

The host that hands the 3D view's volume to the Metal renderer was
Objective-C++ beside VRView; its arithmetic - the opacity curve per millimetre
of ray, the fused series' opacity points, the transfer tables, the ray step,
the crop planes in voxel space, a projection's values written into the
ray-cast image and a composite render turned into VTK's 15-bit picture - is
now the IsiXVolumeRendering module, and the host is Swift.

The check runs both: the functions of the last revision that had the
Objective-C++ host are compiled as they were (a stand-in for the mapper and
the image data the crop planes read, the defaults the step reads registered in
the harness, the rest as is) and the module is compiled as the app links it.
Both get the same inputs - ordinary values, NaN, infinities, values out of
[0, 1], negative and zero spacings, crops that do not cut, a subvolume, regions
that are not one - and their outputs must be the same bytes.

`<git revision>` as an optional argument names the revision with the
Objective-C++ host; without it, the last one that had it.
"""
import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs
from pathlib import Path
import math
import random
import re
import shutil
import struct
import subprocess
import sys
import tempfile

import history_reference
import isix_modules

SKIPPED = 2
root = Path(__file__).resolve().parents[1]
BRIDGE = 'Horos/Sources/VRHostBridge.mm'

if shutil.which('xcrun') is None:
    print('skipped: needs xcrun (clang, swiftc)', file=sys.stderr)
    sys.exit(SKIPPED)
revision = sys.argv[1] if len(sys.argv) > 1 else history_reference.before_removal(BRIDGE)
if revision is None:
    print('skipped: the history does not reach the revision with the Objective-C++ host', file=sys.stderr)
    sys.exit(SKIPPED)
old = history_reference.show(revision, BRIDGE).decode('latin1')


def braces(text, start):
    """From `start` through the brace that closes the first one after it."""
    opening = text.index('{', start)
    depth = 0
    for index in range(opening, len(text)):
        depth += {'{': 1, '}': -1}.get(text[index], 0)
        if depth == 0:
            return text[start:index + 1]
    raise ValueError('unbalanced braces')


def function(name):
    found = re.search(r'\nstatic [^\n(]*[ *]' + name + r'\(', old)
    if not found:
        print(f'{BRIDGE} at {revision} has no {name}; this test needs a new look', file=sys.stderr)
        sys.exit(1)
    return braces(old, found.start() + 1)


def statement(marker):
    at = old.find(marker)
    if at < 0:
        print(f'{BRIDGE} at {revision} no longer has "{marker}"; this test needs a new look', file=sys.stderr)
        sys.exit(1)
    return braces(old, at)


# Inputs: ordinary values in [0, 1] and around it, and the awkward ones.
rng = random.Random(1490)
special = [math.nan, math.inf, -math.inf, -0.0, 0.0, 1.0, -1.0, 1.0000001, -1e-9, 2.5, 1e40, 0.5]
inputs = [special[i % len(special)] if rng.random() < 0.08 else rng.uniform(-0.25, 1.25) for i in range(4096)]

OLD = r'''
#import <Foundation/Foundation.h>
#import <Accelerate/Accelerate.h>
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <vector>

// The ray-cast mapper and image data as the crop planes read them.
#define VTK_CROP_SUBVOLUME 0x0002000
struct vtkImageData {
    double origin[3], spacing[3];
    static vtkImageData *SafeDownCast(void *object) { return (vtkImageData *)object; }
    void GetOrigin(double out[3]) { for (int i = 0; i < 3; ++i) out[i] = origin[i]; }
    void GetSpacing(double out[3]) { for (int i = 0; i < 3; ++i) out[i] = spacing[i]; }
};
struct vtkHorosFixedPointVolumeRayCastMapper {
    std::vector<float> voxel;
    int cropping = 0, flags = 0;
    double regions[6] = {0, 0, 0, 0, 0, 0};
    vtkImageData *input = nullptr;
    int GetVoxelClippingPlanes(const float **planes) { *planes = voxel.empty() ? nullptr : voxel.data(); return (int)voxel.size() / 4; }
    int GetCropping() { return cropping; }
    int GetCroppingRegionFlags() { return flags; }
    void *GetInput() { return input; }
    double *GetCroppingRegionPlanes() { return regions; }
};
// What a projection would paint with: not under test here.
@interface HorosMPRColourPlane : NSObject
+ (NSData *)pictureWithComponents:(NSData *)components count:(NSInteger)count tables:(id)tables;
@end
@implementation HorosMPRColourPlane
+ (NSData *)pictureWithComponents:(NSData *)components count:(NSInteger)count tables:(id)tables { return nil; }
@end
@interface HorosVolumeRenderer : NSObject
@end
@implementation HorosVolumeRenderer
+ (NSData *)projectionPictureWithScalar:(NSData *)s level:(double)l width:(double)w colourTable:(NSData *)c opacityTable:(NSData *)o background:(double)b { return nil; }
+ (NSData *)projectionPictureWithScalar:(NSData *)s level:(double)l width:(double)w clut:(NSData *)c opacityPoints:(NSArray *)o background:(double)b { return nil; }
@end

@@FUNCTIONS@@

static std::vector<double> in;
static double input(size_t i) { return in[i % in.size()]; }
static void emit(const char *name, const void *bytes, size_t length) {
    printf("%s ", name);
    for (size_t i = 0; i < length; ++i) printf("%02x", ((const unsigned char *)bytes)[i]);
    printf("\n");
}
static void emitNumbers(const char *name, NSArray *numbers, bool asFloat) {
    std::vector<unsigned char> bytes;
    for (NSNumber *number in numbers) {
        if (asFloat) { float v = [number floatValue]; bytes.insert(bytes.end(), (unsigned char *)&v, (unsigned char *)&v + 4); }
        else { double v = [number doubleValue]; bytes.insert(bytes.end(), (unsigned char *)&v, (unsigned char *)&v + 8); }
    }
    emit(name, bytes.data(), bytes.size());
}

int main(int argc, char **argv) {
    @autoreleasepool {
        NSData *file = [NSData dataWithContentsOfFile:@(argv[1])];
        in.assign((const double *)file.bytes, (const double *)file.bytes + file.length / 8);

        for (int k = 0; k < 3; ++k) {
            int width = 5 + k, height = 3 + k;
            NSUInteger stride = width * 4 + k;
            std::vector<unsigned short> rgba(stride * height, 0x1234);
            std::vector<float> values(width * height);
            for (int j = 0; j < width * height; ++j) values[j] = (float)(input(100 * k + j) * 3000 - 1000);
            HorosWriteFullDepthProjection(rgba.data(), stride, width, height, values.data(),
                                          (float)(input(500 + k) * 2000), (float)(input(510 + k) * 30));
            char name[32]; snprintf(name, sizeof name, "depth%d", k);
            emit(name, rgba.data(), rgba.size() * 2);
        }

        const double fusedSamples[] = {0.5, 1, 3.7, 0.123};
        for (int k = 0; k < 4; ++k) {
            double table[256];
            for (int i = 0; i < 256; ++i) table[i] = input(1000 + 7 * k + i);
            NSMutableArray *opacity = [NSMutableArray array], *projection = [NSMutableArray array];
            HorosFusedOpacityPoints(table, fusedSamples[k], opacity, projection);
            char name[32];
            snprintf(name, sizeof name, "fused%d.opacity", k); emitNumbers(name, opacity, false);
            snprintf(name, sizeof name, "fused%d.projection", k); emitNumbers(name, projection, false);
        }

        std::vector<double> steps;
        for (int i = 0; i < 60; ++i) {
            double a = input(2000 + i) * 4 - 1, b = input(2100 + i) * 4 - 1;
            steps.push_back(HorosCompositeSampleStep(a, b));
            steps.push_back(HorosInteractionStepScale(a, b));
        }
        emit("steps", steps.data(), steps.size() * 8);

        const double cases[][4] = {{2, 0.5, 0, 0}, {1.5, 0.43, 1.6, 0}, {0, 1, 2, 0}, {3, 0.7, 1.2, 2.5}, {2, 0.5, -1, 0},
                                   {2, 0.5, 0.8, -3}, {1, 0.3125, 1.7, 0}};
        std::vector<double> samples;
        for (auto &c : cases) {
            [[NSUserDefaults standardUserDefaults] registerDefaults:@{@"BESTRENDERING": @(c[2]), @"HorosVolumeMetalOpacityExponent": @(c[3])}];
            samples.push_back(HorosSamplesPerMillimetre(c[0], c[1]));
        }
        emit("samples", samples.data(), samples.size() * 8);

        // The view's curve, as -horosVolumeSnapshot reads it.
        for (int k = 0; k < 4; ++k) {
            NSMutableArray *currentOpacityArray = [NSMutableArray array];
            for (int i = 0; i < 30; ++i)
                [currentOpacityArray addObject:[NSString stringWithFormat:@"{%.17g, %.17g}", input(3000 + 2 * i + k) * 4000, input(3001 + 2 * i + k)]];
            int renderingMode = k & 1;
            double superSampling = k & 2 ? 2.5 : 0, samplesPerMillimetre = 1.7 + k;
            NSMutableArray *opacity = [NSMutableArray array];
            NSMutableArray *projectionOpacity = [NSMutableArray array];
            @@CURVE@@
            char name[32];
            snprintf(name, sizeof name, "curve%d.opacity", k); emitNumbers(name, opacity, false);
            snprintf(name, sizeof name, "curve%d.projection", k); emitNumbers(name, projectionOpacity, false);
        }

        // The 16-bit CLUT's tables.
        {
            const int entries = 4096;
            double samplesPerMillimetre = 2.3;
            std::vector<double> colours(3 * entries), alphas(entries);
            for (int i = 0; i < 3 * entries; ++i) colours[i] = input(i);
            for (int i = 0; i < entries; ++i) alphas[i] = input(5 * i + 3);
            NSMutableData *table = [NSMutableData dataWithLength:4 * entries];
            NSMutableData *perMillimetre = [NSMutableData dataWithLength:entries * sizeof(float)];
            NSMutableData *raw = [NSMutableData dataWithLength:entries * sizeof(float)];
            unsigned char *bytes = (unsigned char *)table.mutableBytes;
            float *composite = (float *)perMillimetre.mutableBytes, *painted = (float *)raw.mutableBytes;
            @@TABLES@@
            emit("clut", table.bytes, table.length);
            emit("clut.composite", perMillimetre.bytes, perMillimetre.length);
            emit("clut.painted", raw.bytes, raw.length);
        }

        // A composite render.
        {
            NSUInteger count = 777;
            NSMutableData *bgra = [NSMutableData dataWithLength:count * 4], *scalar = [NSMutableData dataWithLength:count * 4];
            for (NSUInteger i = 0; i < count * 4; ++i) ((unsigned char *)bgra.mutableBytes)[i] = (unsigned char)(i * 37 + (i >> 3));
            for (NSUInteger i = 0; i < count; ++i) ((float *)scalar.mutableBytes)[i] = (float)input(3500 + i);
            NSData *picture = HorosVolumePicture(bgra, scalar, nil);
            emit("picture", picture.bytes, picture.length);
            NSData *mismatched = HorosVolumePicture([bgra subdataWithRange:NSMakeRange(0, 8)], scalar, nil);
            printf("picture.mismatched %s\n", mismatched ? "data" : "nil");
        }

        // The crop planes.
        {
            vtkImageData image = {{-12.5, 3, 40}, {0.5, 0.75, 2}};
            vtkImageData flat = {{0, 0, 0}, {1, 0, 1}};
            struct Case { std::vector<float> voxel; int cropping, flags; double regions[6]; vtkImageData *input; long w, h; NSUInteger d; };
            std::vector<Case> crops = {
                {{}, 0, 0, {0}, &image, 64, 48, 30},
                {{1, 0, 0, -3, -1, 0, 0, 70, 0, 1, 0, 0, 0, 0, 1, 5}, 0, 0, {0}, &image, 64, 48, 30},
                {{0.6f, 0.8f, 0, -20, 0, 0, -1, 29.00001f, 0, 0, -1, 28.9f, 0, -1, 0, 46.9995f}, 0, 0, {0}, &image, 64, 48, 30},
                {{1, 0, 0, -3}, 1, VTK_CROP_SUBVOLUME, {-10, 5, 3.75, 30, 44, 90}, &image, 64, 48, 30},
                {{}, 1, VTK_CROP_SUBVOLUME, {-12.5, 19, 3, 38.25, 40, 98}, &image, 64, 48, 30},
                {{}, 1, 0x0000400, {0}, &image, 64, 48, 30},
                {{}, 1, VTK_CROP_SUBVOLUME, {0}, nullptr, 64, 48, 30},
                {{}, 1, VTK_CROP_SUBVOLUME, {0, 1, 0, 1, 0, 1}, &flat, 64, 48, 30},
            };
            for (size_t k = 0; k < crops.size(); ++k) {
                vtkHorosFixedPointVolumeRayCastMapper mapper;
                mapper.voxel = crops[k].voxel; mapper.cropping = crops[k].cropping; mapper.flags = crops[k].flags;
                for (int i = 0; i < 6; ++i) mapper.regions[i] = crops[k].regions[i];
                mapper.input = crops[k].input;
                NSString *error = nil;
                NSArray *planes = HorosCuttingPlanes(&mapper, crops[k].w, crops[k].h, crops[k].d, &error);
                char name[32]; snprintf(name, sizeof name, "crop%zu", k);
                if (error) printf("%s error %s\n", name, error.UTF8String);
                else emitNumbers(name, planes, true);
            }
            NSString *error = nil;
            NSArray *none = HorosCuttingPlanes(nullptr, 10, 10, 10, &error);
            emitNumbers("crop.nomapper", none, true);
        }
    }
    return 0;
}
'''

NEW = r'''
import Foundation
import IsiXVolumeRendering

let file = try! Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
let values: [Double] = file.withUnsafeBytes { Array($0.bindMemory(to: Double.self)) }
func input(_ i: Int) -> Double { values[i % values.count] }
func emit(_ name: String, _ bytes: some Collection<UInt8>) {
    print(name + " " + bytes.map { String(format: "%02x", $0) }.joined())
}
func emit<T>(_ name: String, array: [T]) {
    array.withUnsafeBytes { emit(name, Array($0)) }
}

for k in 0..<3 {
    let width = 5 + k, height = 3 + k, stride = width * 4 + k
    var rgba = [UInt16](repeating: 0x1234, count: stride * height)
    let depth = (0..<(width * height)).map { Float(input(100 * k + $0) * 3000 - 1000) }
    rgba.withUnsafeMutableBufferPointer { out in
        depth.withUnsafeBufferPointer {
            RayCastPicture.writeFullDepthProjection(out.baseAddress!, stride: stride, width: width, height: height,
                                                   values: $0.baseAddress!, offset: Float(input(500 + k) * 2000),
                                                   factor: Float(input(510 + k) * 30))
        }
    }
    emit("depth\(k)", array: rgba)
}

let fusedSamples = [0.5, 1, 3.7, 0.123]
for k in 0..<4 {
    let table = (0..<256).map { input(1000 + 7 * k + $0) }
    let points = table.withUnsafeBufferPointer { VolumeOpacityCurve.fusedPoints(table: $0.baseAddress!, samplesPerMillimetre: fusedSamples[k]) }
    emit("fused\(k).opacity", array: points.opacity)
    emit("fused\(k).projection", array: points.projection)
}

var steps: [Double] = []
for i in 0..<60 {
    let a = input(2000 + i) * 4 - 1, b = input(2100 + i) * 4 - 1
    steps.append(VolumeSamplingStep.composite(spacingX: a, superSampling: b))
    steps.append(VolumeSamplingStep.interactionScale(minimumImageSampleDistance: a, lod: b))
}
emit("steps", array: steps)

let cases: [[Double]] = [[2, 0.5, 0, 0], [1.5, 0.43, 1.6, 0], [0, 1, 2, 0], [3, 0.7, 1.2, 2.5], [2, 0.5, -1, 0],
                         [2, 0.5, 0.8, -3], [1, 0.3125, 1.7, 0]]
// The host reads BESTRENDERING as a float, as the Objective-C++ host did.
emit("samples", array: cases.map {
    VolumeOpacityCurve.samplesPerMillimetre(superSampling: $0[0], spacingX: $0[1], rayStep: Double(Float($0[2])), override: $0[3])
})

for k in 0..<4 {
    // The view keeps its curve as point strings; the host reads them as the Objective-C++ one did.
    let points = (0..<30).map { i -> (x: Double, y: Double) in
        let point = NSPointFromString(String(format: "{%.17g, %.17g}", input(3000 + 2 * i + k) * 4000, input(3001 + 2 * i + k)))
        return (Double(point.x), Double(point.y))
    }
    let curve = VolumeOpacityCurve.curvePoints(points, composite: k & 1 == 0, superSampling: k & 2 != 0 ? 2.5 : 0,
                                               samplesPerMillimetre: 1.7 + Double(k))
    emit("curve\(k).opacity", array: curve.opacity)
    emit("curve\(k).projection", array: curve.projection)
}

do {
    let entries = 4096
    let colours = (0..<(3 * entries)).map { input($0) }
    let alphas = (0..<entries).map { input(5 * $0 + 3) }
    emit("clut", colours.withUnsafeBufferPointer { VolumeColourTable.rgba(colours: $0.baseAddress!, count: entries) })
    let tables = alphas.withUnsafeBufferPointer { VolumeOpacityCurve.tables(alphas: $0, samplesPerMillimetre: 2.3) }
    emit("clut.composite", array: tables.composite)
    emit("clut.painted", array: tables.painted)
}

do {
    let count = 777
    let bgra = Data((0..<(count * 4)).map { UInt8(truncatingIfNeeded: $0 * 37 + ($0 >> 3)) })
    var opacity = (0..<count).map { Float(input(3500 + $0)) }
    let scalar = opacity.withUnsafeMutableBytes { Data($0) }
    emit("picture", RayCastPicture.composite(bgra: bgra, opacity: scalar) ?? Data())
    print("picture.mismatched " + (RayCastPicture.composite(bgra: bgra.prefix(8), opacity: scalar) == nil ? "nil" : "data"))
}

let image = (origin: [-12.5, 3, 40.0], spacing: [0.5, 0.75, 2.0]), flat = (origin: [0.0, 0, 0], spacing: [1.0, 0, 1])
let subvolume = true
let crops: [(voxel: [Float], cropping: VolumeCropPlanes.Cropping?)] = [
    ([], nil),
    ([1, 0, 0, -3, -1, 0, 0, 70, 0, 1, 0, 0, 0, 0, 1, 5], nil),
    ([0.6, 0.8, 0, -20, 0, 0, -1, 29.00001, 0, 0, -1, 28.9, 0, -1, 0, 46.9995], nil),
    ([1, 0, 0, -3], .init(subvolume: subvolume, planes: [-10, 5, 3.75, 30, 44, 90], origin: image.origin, spacing: image.spacing)),
    ([], .init(subvolume: subvolume, planes: [-12.5, 19, 3, 38.25, 40, 98], origin: image.origin, spacing: image.spacing)),
    ([], .init(subvolume: false, planes: [0, 0, 0, 0, 0, 0], origin: image.origin, spacing: image.spacing)),
    ([], .init(subvolume: subvolume, planes: [0, 0, 0, 0, 0, 0], origin: nil, spacing: nil)),
    ([], .init(subvolume: subvolume, planes: [0, 1, 0, 1, 0, 1], origin: flat.origin, spacing: flat.spacing)),
]
for (k, crop) in crops.enumerated() {
    do {
        emit("crop\(k)", array: try VolumeCropPlanes.cuttingPlanes(voxelPlanes: crop.voxel, cropping: crop.cropping,
                                                                   width: 64, height: 48, depth: 30))
    } catch {
        print("crop\(k) error \(error.reason)")
    }
}
emit("crop.nomapper", array: try! VolumeCropPlanes.cuttingPlanes(voxelPlanes: [], cropping: nil, width: 10, height: 10, depth: 10))
'''

functions = '\n'.join(function(name) for name in (
    'HorosWriteFullDepthProjection', 'HorosSamplesPerMillimetre', 'HorosFusedOpacityPoints', 'HorosVolumePicture',
    'HorosCompositeSampleStep', 'HorosInteractionStepScale', 'HorosCuttingPlanes'))
curve = statement('for (NSString *point in currentOpacityArray) {')
tables = statement('for (int i = 0; i < entries; ++i) {')

failures = []
with tempfile.TemporaryDirectory() as tmp:
    tmp = Path(tmp)
    (tmp / 'inputs.bin').write_bytes(struct.pack(f'<{len(inputs)}d', *inputs))
    (tmp / 'old.mm').write_text(OLD.replace('@@FUNCTIONS@@', functions).replace('@@CURVE@@', curve).replace('@@TABLES@@', tables))
    (tmp / 'new.swift').write_text(NEW)
    builds = [
        ['xcrun', 'clang++', '-std=c++17', '-fno-objc-arc', '-w', '-O0', '-framework', 'Foundation', '-framework', 'Accelerate',
         str(tmp / 'old.mm'), '-o', str(tmp / 'old')],
        ['xcrun', 'swiftc', '-swift-version', '6', '-Onone', *isix_modules.module_flags('IsiXVolumeRendering', tmp / 'module'),
         str(tmp / 'new.swift'), '-o', str(tmp / 'new')],
    ]
    outputs = {}
    for build, name in zip(builds, ('old', 'new')):
        made = subprocess.run(build, capture_output=True, text=True, timeout=300)
        if made.returncode:
            print(made.stderr, file=sys.stderr)
            print(f'the {name} harness does not compile', file=sys.stderr)
            sys.exit(1)
        run = subprocess.run([str(tmp / name), str(tmp / 'inputs.bin')], capture_output=True, text=True, timeout=60)
        if run.returncode:
            print(run.stderr, file=sys.stderr)
            print(f'the {name} harness exited with {run.returncode}', file=sys.stderr)
            sys.exit(1)
        outputs[name] = dict(line.split(' ', 1) for line in run.stdout.splitlines())

old_out, new_out = outputs['old'], outputs['new']
if set(old_out) != set(new_out):
    failures.append(f'the harnesses report different cases: {sorted(set(old_out) ^ set(new_out))}')
for name in sorted(set(old_out) & set(new_out)):
    if old_out[name] != new_out[name]:
        failures.append(f'{name}: the module differs from the Objective-C++ host '
                        f'({old_out[name][:60]}... against {new_out[name][:60]}...)')
if len(old_out) < 30 or not any(value.startswith('error ') for value in old_out.values()):
    failures.append('the harness compared fewer cases than it should')

if failures:
    print('\n'.join(failures), file=sys.stderr)
    sys.exit(1)
print(f'IsiXVolumeRendering gives the bytes of the Objective-C++ host at {revision[:10]} in {len(old_out)} cases')
