#!/usr/bin/env python3
"""The fly-path assistant of IsiXVolumeRendering finds what FlyAssistant.mm found.

FlyAssistant.mm, FlyAssistant+Histo.mm and Quaternion.mm (the endoscopy's path
assistant: the lumen's thresholds from the volume's histogram, the distance
transform, the centerline between two points, the navigator's steps, the view
direction) became FlyPathAssistant, its Histogram and Centerline extensions and
FlyQuaternion in IsiXVolumeRendering; FlyAssistant.swift keeps the app's class
and selectors over it. This compiles, from the last revision that has the
Objective-C++ files, read from git, FlyAssistant.mm with its category,
Quaternion.mm, N3Geometry.m, Point3D and OSIVoxel, and the module's sources
from the tree, each with a driver that runs the same plan on the same
generated volumes:

- the input's histogram (every bin) and its range, and the thresholds the
  histogram gives for values in the lumen, the wall and between, inside the
  range (outside it FlyAssistant+Histo.mm read outside its histogram);
- the navigator's steps before the distance transform (thresholds from the
  voxels around the point) and after it;
- the distance map (every voxel) after the transform at a threshold;
- centerlines between points, thinned by the lumen's radius, as they are and
  smoothed (the smoothing's spline is a stand-in in both, the nearest of its
  points; VTK's spline is the VTK adapter's test), and points outside the
  volume or the same point twice;
- the next center point, the radius and the mean radius along a centerline,
  the view direction from each point toward one further on (the quaternion
  rotations) and the trace of a line.

Every number is printed in hexadecimal; the outputs must be the same, in
Debug (-O0 / -Onone) and Release (-Os / -O). The module's Debug driver runs
under AddressSanitizer, so a read outside the volume (points A and B are
clamped to its corners in one search), the distance map or the histogram
stops it. Exits 2 when the history does
not reach a revision with FlyAssistant.mm.

    python3 tests/test-fly-path-equivalence.py
"""
import math
import os
import random
import shutil
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import private_tmpdir  # noqa: F401,E402  - its own TMPDIR for the tools it runs
import history_reference  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
FLY = 'Horos/Sources/FlyAssistant.mm'
MODULE = ROOT / 'Modules/IsiXVolumeRendering/Sources'
MODULE_FILES = ['FlyQuaternion.swift', 'FlyPathAssistant.swift', 'FlyPathAssistant+Histogram.swift',
                'FlyPathAssistant+Centerline.swift']

if shutil.which('xcrun') is None:
    print('skipped: needs xcrun (swiftc, clang)', file=sys.stderr)
    raise SystemExit(2)
reference = history_reference.before_removal(FLY)
if reference is None and subprocess.run(['git', '-C', str(ROOT), 'cat-file', '-e', f'HEAD:{FLY}'],
                                        capture_output=True).returncode == 0:
    reference = 'HEAD'
if reference is None:
    print('skipped: no revision of this history has ' + FLY, file=sys.stderr)
    raise SystemExit(2)

OLD_SWIFT = ['Horos/Sources/Point3D.swift', 'Horos/Sources/OSIVoxel.swift']
OLD_HEADERS = ['Horos/Sources/Point3D.h', 'Horos/Sources/OSIVoxel.h', 'Horos/Sources/Quaternion.h',
               'Horos/Sources/FlyAssistant.h', 'Horos/Sources/FlyAssistant+Histo.h', 'Nitrogen/Sources/N3Geometry.h']
OLD_OBJC = [('N3Geometry.m', 'objective-c', 'Nitrogen/Sources/N3Geometry.m'),
            ('Quaternion.mm', 'objective-c++', 'Horos/Sources/Quaternion.mm'),
            ('FlyAssistant+Histo.mm', 'objective-c++', 'Horos/Sources/FlyAssistant+Histo.mm'),
            ('FlyAssistant.mm', 'objective-c++', FLY)]

# --- the volumes and the plan -----------------------------------------------------------
rng = random.Random(1491)


def volume(width, height, depth, inside, value, wall, noise):
    data = []
    for z in range(depth):
        for y in range(height):
            for x in range(width):
                v = value(x, y, z) if inside(x, y, z) else wall(x, y, z)
                data.append(v + rng.uniform(-noise, noise))
    return struct.pack('<%df' % len(data), *data)


def tube(x, y, z):
    return 6 <= x < 14 and 6 <= y < 14 and 4 <= z < 124


def curve_center(z):
    return 24 + 9 * math.sin(z / 9.0), 20 + 7 * math.cos(z / 13.0)


def curved(x, y, z):
    cx, cy = curve_center(z)
    return (x - cx) ** 2 + (y - cy) ** 2 <= 30 and 3 <= z < 57


def bright(x, y, z):
    return (x - 8) ** 2 + (y - 32) ** 2 + (z - 30) ** 2 <= 16


VOLUMES = {
    'straight': (20, 20, 128, (0.5, 0.5, 0.5), 1.0,
                 volume(20, 20, 128, tube, lambda *p: 1000, lambda *p: 0, 40)),
    'curved': (48, 40, 60, (0.7, 0.8, 1.25), 1.0,
               volume(48, 40, 60, curved, lambda *p: 300, lambda x, y, z: 1500 if bright(x, y, z) else -900, 60)),
    # A brighter column keeps the lumen's peak inside the histogram: past its
    # end FlyAssistant+Histo.mm read memory outside it.
    'short': (16, 16, 20, (1.0, 1.0, 1.0), 1.5,
              volume(16, 16, 20, lambda x, y, z: 5 <= x < 11 and 5 <= y < 11, lambda *p: 200,
                     lambda x, y, z: 450 if x < 2 and y < 2 else -200, 20)),
}


def point(p):
    return ' '.join('%r' % float(v) for v in p)


PLAN = []
for name, (w, h, d, spacing, vsize, _) in VOLUMES.items():
    PLAN.append(f'volume {name}.raw {w} {h} {d} {point(spacing)} {vsize!r}')
    # Values inside the volume's range: FlyAssistant+Histo.mm read outside its
    # histogram for the others (undefined; the module's bins there are empty).
    PLAN.append('thresholds ' + {'straight': '1000 0 500 12.5 980 30', 'curved': '300 -900 0 1200 600 -500',
                                 'short': '200 -200 0 100 -150'}[name])
    if name == 'straight':
        PLAN.append('unfinished 10 10 60 0 0 1 6')
        PLAN.append('step 1.5')
        PLAN.append('centerline 10 10 12 10 10 115 0')
        PLAN += ['radii', 'views 3', 'center 5 5 30 0 0 1 2', 'center 5 5 30 0 1 1 3']
        PLAN.append('centerline 10 10 12 10 10 115 1')
        PLAN.append('centerline -4 30 -9 19 19 200 0')
        PLAN.append('centerline 10 10 12 10 10 12 0')
        PLAN += ['steps 10 10 20 0 0 1 25', 'steps 1 10 60 1 0 0 3', 'trace 5 5 30 0 0 1', 'trace 5 5 30 1 0 0']
        PLAN.append('transform 500')
    elif name == 'curved':
        cz, cy = curve_center(5), curve_center(54)
        PLAN.append('unfinished %r %r 5 0 0 1 4' % (round(cz[0]), round(cz[1])))
        PLAN.append('step 2')
        PLAN.append('centerline %r %r 5 %r %r 54 0' % (round(cz[0]), round(cz[1]), round(cy[0]), round(cy[1])))
        PLAN += ['radii', 'views 2', 'views 5']
        PLAN.append('centerline %r %r 5 %r %r 54 1' % (round(cz[0]), round(cz[1]), round(cy[0]), round(cy[1])))
        PLAN += ['steps %r %r 8 0.25 0 1 30' % (round(cz[0]), round(cz[1])), 'trace 17 16 20 1 1 0.5']
        PLAN.append('transform -300')
    else:
        PLAN.append('step 1')
        PLAN.append('centerline 8 8 1 8 8 18 0')
        PLAN += ['radii', 'views 1']
        PLAN.append('centerline 8 8 1 8 8 18 1')
        PLAN += ['steps 8 8 2 0 0 1 10', 'center 5 5 6 0 0 1 1.5']

# --- the reference: FlyAssistant.mm and its spline stand-in -------------------------------
SPLINE_STAND_IN = '''#import <Cocoa/Cocoa.h>
#import "Point3D.h"
#include <iostream>
@interface Spline3D : NSObject
- (void) addPoint:(float)t :(Point3D*)p;
- (Point3D*) evaluateAt:(float)t;
@end
'''

OLD_DRIVER = r'''
#import <Cocoa/Cocoa.h>
#import "FlyAssistant.h"
#import "FlyAssistant+Histo.h"
#import "Spline3D.h"
#include <vector>
#include <cmath>
#include <cstdio>
#include <cstring>

// The nearest of the points given, the first of equals: no arithmetic of its own.
@implementation Spline3D {
    std::vector<float> ts, xs, ys, zs;
}
- (void) addPoint:(float)t :(Point3D*)p { ts.push_back(t); xs.push_back(p.x); ys.push_back(p.y); zs.push_back(p.z); }
- (Point3D*) evaluateAt:(float)t {
    size_t best = 0;
    for (size_t i = 1; i < ts.size(); i++) if (fabsf(t - ts[i]) < fabsf(t - ts[best])) best = i;
    return ts.empty() ? [Point3D point] : [Point3D pointWithX:xs[best] y:ys[best] z:zs[best]];
}
@end

@interface FlyProbe : FlyAssistant
@end
@implementation FlyProbe
- (void) printState {
    printf("range %a %a bins %u", (double)inputMinValue, (double)inputMaxValue, histoSize);
    unsigned long long hash = 1469598103934665603ULL;
    for (unsigned i = 0; i < histoSize; i++) { hash ^= (unsigned long long)inputHisto[i]; hash *= 1099511628211ULL; }
    printf(" histogram %016llx\n", hash);
    printf("resampled %d %d %d scale %a %a %a\n", distmapWidth, distmapHeight, distmapDepth,
           (double)resampleScale_x, (double)resampleScale_y, (double)resampleScale_z);
}
- (void) printThresholds { printf(" -> %a %a\n", (double)thresholdA, (double)thresholdB); }
- (void) printDistmap {
    unsigned long long hash = 1469598103934665603ULL;
    long far = 0;
    for (int i = 0; i < distmapVolumeSize; i++) {
        unsigned bits; memcpy(&bits, &distmap[i], 4);
        hash ^= bits; hash *= 1099511628211ULL;
        if (distmap[i] > 1e30) far++;
    }
    printf("distmap %016llx far %ld finished %d threshold %a\n", hash, far, isDistanceTransformFinished ? 1 : 0, (double)threshold);
}
@end

static void pr(const char *label, float x, float y, float z) { printf("%s %a %a %a", label, (double)x, (double)y, (double)z); }

int main(int argc, char **argv) { @autoreleasepool {
    FILE *plan = fopen(argv[1], "r");
    char line[512], name[256];
    FlyProbe *assistant = nil;
    std::vector<float> volume;
    NSMutableArray *centerline = [NSMutableArray array];
    while (fgets(line, sizeof line, plan)) {
        int w, h, d, n, smooth;
        float a[8];
        if (sscanf(line, "volume %255s %d %d %d %f %f %f %f", name, &w, &h, &d, &a[0], &a[1], &a[2], &a[3]) == 8) {
            [assistant release];
            volume.assign((size_t)w * h * d, 0);
            FILE *raw = fopen([[[NSString stringWithUTF8String:argv[1]] stringByDeletingLastPathComponent]
                               stringByAppendingPathComponent:[NSString stringWithUTF8String:name]].fileSystemRepresentation, "rb");
            fread(volume.data(), 4, volume.size(), raw);
            fclose(raw);
            int dim[3] = {w, h, d};
            float spacing[3] = {a[0], a[1], a[2]};
            assistant = [[FlyProbe alloc] initWithVolume:volume.data() WidthDimension:dim Spacing:spacing ResampleVoxelSize:a[3]];
            printf("volume %s\n", name);
            [assistant printState];
        } else if (!strncmp(line, "thresholds", 10)) {
            char *cursor = line + 10;
            float v; int used;
            while (sscanf(cursor, "%f%n", &v, &used) == 1) {
                cursor += used;
                [assistant computeIntervalThresholdsFrom:v];
                printf("thresholds from %a", (double)v); [assistant printThresholds];
            }
        } else if (sscanf(line, "step %f", &a[0]) == 1) {
            assistant.centerlineResampleStepLength = a[0];
        } else if (sscanf(line, "unfinished %f %f %f %f %f %f %d", &a[0], &a[1], &a[2], &a[3], &a[4], &a[5], &n) == 7 ||
                   sscanf(line, "steps %f %f %f %f %f %f %d", &a[0], &a[1], &a[2], &a[3], &a[4], &a[5], &n) == 7) {
            Point3D *pt = [Point3D pointWithX:a[0] y:a[1] z:a[2]], *dir = [Point3D pointWithX:a[3] y:a[4] z:a[5]];
            for (int i = 0; i < n; i++) {
                int err = [assistant caculateNextPositionFrom:pt Towards:dir];
                printf("step %d", err); pr(" at", pt.x, pt.y, pt.z); pr(" toward", dir.x, dir.y, dir.z); [assistant printThresholds];
            }
        } else if (sscanf(line, "centerline %f %f %f %f %f %f %d", &a[0], &a[1], &a[2], &a[3], &a[4], &a[5], &smooth) == 7) {
            [centerline removeAllObjects];
            Point3D *pa = [Point3D pointWithX:a[0] y:a[1] z:a[2]], *pb = [Point3D pointWithX:a[3] y:a[4] z:a[5]];
            int err = [assistant createCenterline:centerline FromPointA:pa ToPointB:pb withSmoothing:smooth];
            printf("centerline %d points %lu", err, (unsigned long)centerline.count); [assistant printThresholds];
            for (OSIVoxel *v in centerline) { pr(" ", v.x, v.y, v.z); printf("\n"); }
            [assistant printDistmap];
        } else if (!strncmp(line, "radii", 5)) {
            for (NSUInteger i = 0; i < centerline.count; i++)
                printf("radius %a mean %a %a\n", (double)[assistant radiusAtPoint:centerline[i]],
                       (double)[assistant averageRadiusAt:(int)i On:centerline InRange:2],
                       (double)[assistant averageRadiusAt:(int)i On:centerline InRange:5]);
        } else if (sscanf(line, "views %d", &n) == 1) {
            NSUInteger count = centerline.count, stride = count / 12 > 0 ? count / 12 : 1;
            for (NSUInteger i = 0; i + n < count; i += stride) {
                OSIVoxel *view = [assistant computeMaximizingViewDirectionFrom:centerline[i] LookingAt:centerline[i + n]];
                pr("view", view.x, view.y, view.z); printf("\n");
            }
        } else if (sscanf(line, "center %f %f %f %f %f %f %f", &a[0], &a[1], &a[2], &a[3], &a[4], &a[5], &a[6]) == 7) {
            Point3D *c = [assistant caculateNextCenterPointFrom:[Point3D pointWithX:a[0] y:a[1] z:a[2]]
                                                        Towards:[Point3D pointWithX:a[3] y:a[4] z:a[5]] WithStepLength:a[6]];
            if (c) { pr("center", c.x, c.y, c.z); printf("\n"); } else printf("center none\n");
        } else if (sscanf(line, "trace %f %f %f %f %f %f", &a[0], &a[1], &a[2], &a[3], &a[4], &a[5]) == 6) {
            printf("trace %u\n", [assistant traceLineFrom:[Point3D pointWithX:a[0] y:a[1] z:a[2]]
                                             accordingTo:[Point3D pointWithX:a[3] y:a[4] z:a[5]]]);
        } else if (sscanf(line, "transform %f", &a[0]) == 1) {
            [assistant setThreshold:a[0] Asynchronous:NO];
            [assistant printDistmap];
        }
    }
    [assistant release];
    return 0;
} }
'''

NEW_DRIVER = r'''
import Foundation

// The nearest of the points given, the first of equals: no arithmetic of its own.
final class NearestSpline: FlyPathSpline {
    var ts: [Float] = [], points: [SIMD3<Float>] = []
    func addPoint(_ t: Float, _ point: SIMD3<Float>) { ts.append(t); points.append(point) }
    func evaluate(_ t: Float) -> SIMD3<Float> {
        guard !ts.isEmpty else { return .zero }
        var best = 0
        for i in 1..<ts.count where abs(t - ts[i]) < abs(t - ts[best]) { best = i }
        return points[best]
    }
}

func h(_ v: Float) -> String { String(format: "%a", Double(v)) }
func p(_ label: String, _ v: SIMD3<Float>) -> String { "\(label) \(h(v.x)) \(h(v.y)) \(h(v.z))" }
nonisolated(unsafe) var out = ""
func emit(_ s: String) { out += s }

let planPath = CommandLine.arguments[1]
let folder = (planPath as NSString).deletingLastPathComponent
var assistant: FlyPathAssistant?
var volume: UnsafeMutablePointer<Float>?
var centerline: [SIMD3<Float>] = []

func thresholds(_ a: FlyPathAssistant) -> String { " -> \(h(a.thresholdA)) \(h(a.thresholdB))\n" }
func distmapLine(_ a: FlyPathAssistant) -> String {
    var hash: UInt64 = 1469598103934665603
    var far = 0
    for i in 0..<a.distmapVolumeSize {
        let v = a.distmap![i]
        hash ^= UInt64(v.bitPattern); hash = hash &* 1099511628211
        if v > 1e30 { far += 1 }
    }
    return "distmap \(String(format: "%016llx", hash)) far \(far) finished \(a.isDistanceTransformFinished ? 1 : 0) threshold \(h(a.threshold))\n"
}

for raw in try! String(contentsOfFile: planPath, encoding: .utf8).split(separator: "\n") {
    let words = raw.split(separator: " ").map(String.init)
    let f = words.dropFirst().compactMap { Float($0) }
    switch words[0] {
    case "volume":
        assistant = nil
        volume?.deallocate()
        let (w, hh, d) = (Int(words[2])!, Int(words[3])!, Int(words[4])!)
        let data = FileManager.default.contents(atPath: (folder as NSString).appendingPathComponent(words[1]))!
        volume = .allocate(capacity: w * hh * d)
        _ = data.withUnsafeBytes { memcpy(volume!, $0.baseAddress!, w * hh * d * 4) }
        let a = FlyPathAssistant(volume: volume!, width: w, height: hh, depth: d,
                                 spacing: SIMD3(Float(words[5])!, Float(words[6])!, Float(words[7])!),
                                 resampleVoxelSize: Float(words[8])!)!
        assistant = a
        emit("volume \(words[1])\n")
        var hash: UInt64 = 1469598103934665603
        for i in 0..<Int(a.histogramSize) { hash ^= UInt64(a.inputHistogram![i]); hash = hash &* 1099511628211 }
        emit("range \(h(a.inputMinValue)) \(h(a.inputMaxValue)) bins \(a.histogramSize) histogram \(String(format: "%016llx", hash))\n")
        emit("resampled \(a.distmapWidth) \(a.distmapHeight) \(a.distmapDepth) scale \(h(a.resampleScale.x)) \(h(a.resampleScale.y)) \(h(a.resampleScale.z))\n")
    case "thresholds":
        for v in f {
            assistant!.computeIntervalThresholds(from: v)
            emit("thresholds from \(h(v))" + thresholds(assistant!))
        }
    case "step":
        assistant!.centerlineResampleStepLength = f[0]
    case "unfinished", "steps":
        var pt = SIMD3(f[0], f[1], f[2]), dir = SIMD3(f[3], f[4], f[5])
        for _ in 0..<Int(words[7])! {
            let err = assistant!.nextPosition(from: &pt, towards: &dir)
            emit("step \(err)" + p(" at", pt) + p(" toward", dir) + thresholds(assistant!))
        }
    case "centerline":
        // What FlyAssistant.swift does: the points, thinned, then smoothed.
        let a = assistant!
        let (err, points) = a.centerline(from: SIMD3(f[0], f[1], f[2]), to: SIMD3(f[3], f[4], f[5]))
        centerline = err == 0 ? points : []
        if err == 0 && centerline.count > 2 {
            centerline = a.thinnedCenterlineIndices(centerline).map { centerline[$0] }
        }
        if err == 0 && words[7] == "1", let smoothed = FlyPathAssistant.smoothedCenterline(centerline, stepLength: a.centerlineResampleStepLength,
                                                                                         spline: NearestSpline()) {
            centerline = smoothed
        }
        emit("centerline \(err) points \(centerline.count)" + thresholds(a))
        for v in centerline { emit(p(" ", v) + "\n") }
        emit(distmapLine(a))
    case "radii":
        for i in centerline.indices {
            emit("radius \(h(assistant!.radius(at: centerline[i]))) mean \(h(assistant!.averageRadius(at: i, on: centerline, range: 2))) \(h(assistant!.averageRadius(at: i, on: centerline, range: 5)))\n")
        }
    case "views":
        let n = Int(words[1])!, count = centerline.count, stride = count / 12 > 0 ? count / 12 : 1
        var i = 0
        while i + n < count {
            emit(p("view", assistant!.maximizingViewDirection(from: centerline[i], lookingAt: centerline[i + n])) + "\n")
            i += stride
        }
    case "center":
        if let c = assistant!.nextCenterPoint(from: SIMD3(f[0], f[1], f[2]), towards: SIMD3(f[3], f[4], f[5]), stepLength: f[6]) {
            emit(p("center", c) + "\n")
        } else {
            emit("center none\n")
        }
    case "trace":
        emit("trace \(assistant!.traceLine(from: SIMD3(f[0], f[1], f[2]), along: SIMD3(f[3], f[4], f[5])))\n")
    case "transform":
        assistant!.threshold = f[0]
        assistant!.distanceTransform()
        emit(distmapLine(assistant!))
    default:
        break
    }
}
FileHandle.standardOutput.write(out.data(using: .utf8)!)
'''


def run(command, **kw):
    return subprocess.run(command, capture_output=True, text=True, **kw)


def build_old(tmp, optimization):
    swift_opt, c_opt = ('-Onone', '-O0') if optimization == 'debug' else ('-O', '-Os')
    out = tmp / f'old-{optimization}'
    out.mkdir()
    for path in OLD_SWIFT + OLD_HEADERS + [p for _, _, p in OLD_OBJC]:
        (out / Path(path).name).write_bytes(history_reference.show(reference, path))
    (out / 'bridging.h').write_text('#define HOROS_BRIDGING_HEADER 1\n#import <Cocoa/Cocoa.h>\n'
                                    '#import "Point3D.h"\n#import "OSIVoxel.h"\n')
    (out / 'Spline3D.h').write_text(SPLINE_STAND_IN)
    (out / 'driver.mm').write_text(OLD_DRIVER)
    steps = [['xcrun', 'swiftc', '-swift-version', '5', '-module-name', 'Horos', '-parse-as-library', '-wmo', swift_opt,
              '-import-objc-header', str(out / 'bridging.h'), '-Xcc', '-I' + str(out),
              '-emit-objc-header-path', str(out / 'Horos-Swift.h'),
              '-c', *[str(out / Path(p).name) for p in OLD_SWIFT], '-o', str(out / 'swift.o')]]
    objects = [str(out / 'swift.o')]
    for name, language, _ in OLD_OBJC + [('driver.mm', 'objective-c++', None)]:
        obj = out / (Path(name).stem + '.o')
        std = ['-std=c++17'] if language == 'objective-c++' else []
        steps.append(['xcrun', 'clang', '-x', language, *std, '-fno-objc-arc', c_opt, '-w',
                      '-include', 'Cocoa/Cocoa.h', '-I', str(out), '-c', str(out / name), '-o', str(obj)])
        objects.append(str(obj))
    steps.append(['xcrun', 'swiftc', *objects, '-lc++', '-framework', 'Cocoa', '-framework', 'Accelerate',
                  '-framework', 'QuartzCore', '-o', str(out / 'driver')])
    for step in steps:
        built = run(step, timeout=600)
        if built.returncode:
            print('FAIL: the reference does not build:\n' + built.stderr[-3000:])
            raise SystemExit(1)
    return out / 'driver'


def build_new(tmp, optimization):
    out = tmp / f'new-{optimization}'
    out.mkdir()
    (out / 'main.swift').write_text(NEW_DRIVER)
    # Debug runs under AddressSanitizer: no read outside the volume, the map or the histogram.
    built = run(['xcrun', 'swiftc', '-swift-version', '6', '-module-name', 'FlyPathDriver',
                 *(['-Onone', '-sanitize=address'] if optimization == 'debug' else ['-O']),
                 *[str(MODULE / name) for name in MODULE_FILES], str(out / 'main.swift'), '-o', str(out / 'driver')],
                timeout=600)
    if built.returncode:
        print('FAIL: the module does not build with the driver:\n' + built.stderr[-3000:])
        raise SystemExit(1)
    return out / 'driver'


failures = []
with tempfile.TemporaryDirectory(prefix='isix-fly-path-') as folder:
    tmp = Path(folder)
    for name, (*_, data) in VOLUMES.items():
        (tmp / f'{name}.raw').write_bytes(data)
    (tmp / 'plan.txt').write_text('\n'.join(PLAN) + '\n')
    outputs = {}
    for optimization in ('debug', 'release'):
        for side, build in (('reference', build_old), ('module', build_new)):
            driver = build(tmp, optimization)
            try:
                ran = subprocess.run([str(driver), str(tmp / 'plan.txt')], capture_output=True, text=True, timeout=300,
                                     env={**os.environ, 'ASAN_OPTIONS': 'detect_leaks=0'})
            except subprocess.TimeoutExpired:
                print(f'FAIL: the {side} driver ({optimization}) did not finish within 300 s')
                raise SystemExit(1)
            if ran.returncode:
                print(f'FAIL: the {side} driver ({optimization}) exited with {ran.returncode} after:\n' +
                      '\n'.join(ran.stdout.splitlines()[-4:]) + '\n' + ran.stderr[-1000:])
                raise SystemExit(1)
            # The reference prints A and B on std::cout; only the plan's lines count.
            outputs[side, optimization] = [line for line in ran.stdout.splitlines() if not line.startswith('x= ')]
        old, new = outputs['reference', optimization], outputs['module', optimization]
        if old != new:
            first = next((i for i, (a, b) in enumerate(zip(old, new)) if a != b), min(len(old), len(new)))
            failures.append(f'{optimization}: line {first + 1} differs (of {len(old)} and {len(new)} lines)\n'
                            f'  reference: {old[first] if first < len(old) else "(end)"}\n'
                            f'  module:    {new[first] if first < len(new) else "(end)"}')
        else:
            lines = old
            print(f'ok: {optimization}: {len(lines)} lines the same; '
                  f'{sum(l.startswith("centerline ") for l in lines)} centerlines, '
                  f'{sum(l.startswith("thresholds") for l in lines)} thresholds, '
                  f'{sum(l.startswith("step ") for l in lines)} steps, {sum(l.startswith("view") for l in lines)} views, '
                  f'{sum(l.startswith("distmap") for l in lines)} distance maps, '
                  f'{sum(l.startswith("radius") for l in lines)} radii')
    if not failures and outputs['reference', 'debug'] != outputs['reference', 'release']:
        print('note: the reference itself differs between Debug and Release')

for failure in failures:
    print('FAIL:', failure)
if failures:
    raise SystemExit(1)
print('PASS: FlyPathAssistant gives, bit for bit, the histogram, thresholds, distance maps, centerlines, steps, '
      'radii and view directions of FlyAssistant.mm (reference ' + reference[:12] + '), in Debug and Release')
